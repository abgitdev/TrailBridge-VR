import XCTest
import Darwin
@testable import BasaltBottleKit

final class FakeBottleProcessAccess: BottleProcessAccess, @unchecked Sendable {
    let currentPID: Int32 = 99
    let currentUID: UInt32 = 501
    var running: [BottleProcess] = []
    var signals: [(Int32, Int32)] = []
    var ignoreTerm: Set<Int32> = []
    var ignoreKill: Set<Int32> = []
    var pauses = 0
    var bytes: [Int32: UInt64] = [:]
    var byteReads: [Int32] = []

    func processes() throws -> [BottleProcess] { running }
    func signal(_ signal: Int32, process: BottleProcess) -> Bool {
        signals.append((process.pid, signal))
        if signal == SIGKILL ? !ignoreKill.contains(process.pid) : !ignoreTerm.contains(process.pid) {
            running.removeAll { $0 == process }
        }
        return true
    }
    func pause() { pauses += 1 }
    func ioBytes(of process: BottleProcess) -> UInt64? {
        byteReads.append(process.pid)
        return bytes[process.pid]
    }
}

final class BottleProcessSweepTests: XCTestCase {
    /// Looks only at this test process and at a `/bin/sleep` it starts itself.
    func testARunningProcessIsToldByItsPidAndStartTimeAlone() throws {
        let system = SystemBottleProcessAccess()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        addTeardownBlock { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let listed = try XCTUnwrap(system.processes().first { $0.pid == child.processIdentifier })
        XCTAssertTrue(system.isRunning(pid: listed.pid, startSeconds: listed.startSeconds,
                                       startMicroseconds: listed.startMicroseconds))
        XCTAssertFalse(system.isRunning(pid: listed.pid, startSeconds: listed.startSeconds + 1,
                                        startMicroseconds: listed.startMicroseconds),
                       "another process that later got the pid")
        XCTAssertFalse(system.isRunning(pid: listed.pid, startSeconds: listed.startSeconds,
                                        startMicroseconds: listed.startMicroseconds + 1))
        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(system.isRunning(pid: listed.pid, startSeconds: listed.startSeconds,
                                        startMicroseconds: listed.startMicroseconds))

        // What a fake process table answers, unless it says otherwise.
        let fake = FakeBottleProcessAccess()
        fake.running = [BottleProcess(pid: 7, uid: 501, realUID: 501, executable: "/moved/app",
                                      startSeconds: 10, startMicroseconds: 20)]
        XCTAssertTrue(try fake.isRunning(pid: 7, startSeconds: 10, startMicroseconds: 20))
        XCTAssertFalse(try fake.isRunning(pid: 7, startSeconds: 11, startMicroseconds: 20))
    }

    func testSystemIOBytesReportsAChildsFileWritesAndChecksIdentity() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltProcessIO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output")
        let ready = temporary.appendingPathComponent("ready")
        let child = Process()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.standardInput = input
        child.arguments = ["-c", """
            block='\(String(repeating: "x", count: 1024))'
            i=0
            while [ "$i" -lt 2048 ]; do
                printf '%s' "$block"
                i=$((i + 1))
            done > "$1"
            : > "$2"
            read -r done
            """, "io-writer", output.path, ready.path]
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: ready.path), child.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertEqual(try Data(contentsOf: output).count, 2 * 1024 * 1024)
        let system = SystemBottleProcessAccess()
        let process = try XCTUnwrap(system.processes().first { $0.pid == child.processIdentifier })
        guard let bytes = system.ioBytes(of: process) else {
            throw XCTSkip("Process I/O counters are unavailable on this system")
        }
        XCTAssertGreaterThan(bytes, 0)
        let reused = BottleProcess(
            pid: process.pid, uid: process.uid, realUID: process.realUID, executable: process.executable,
            startSeconds: process.startSeconds + 1, startMicroseconds: process.startMicroseconds)
        XCTAssertNil(system.ioBytes(of: reused))
        let changedImage = BottleProcess(
            pid: process.pid, uid: process.uid, realUID: process.realUID, executable: "/different/image",
            startSeconds: process.startSeconds, startMicroseconds: process.startMicroseconds)
        XCTAssertNil(system.ioBytes(of: changedImage))
    }

    func testCountingABottlesProcessesSignalsNothing() throws {
        let access = FakeBottleProcessAccess()
        func process(_ pid: Int32, _ path: String, uid: UInt32 = 501) -> BottleProcess {
            BottleProcess(pid: pid, uid: uid, realUID: uid, executable: path,
                          startSeconds: 10, startMicroseconds: UInt64(pid))
        }
        let engine = URL(fileURLWithPath: "/bottles/one/engine")
        access.running = [
            process(1, "/bottles/one/engine/lib/wine/x86_64-unix/wine"),
            process(2, "/bottles/one/engine/bin/wineserver"),
            process(4, "/bottles/two/engine/bin/wineserver"),
            process(5, "/bottles/one/engine-old/bin/wineserver"),
            process(6, "/usr/bin/other"),
            process(7, "/bottles/one/engine/bin/wineserver", uid: 502),
            process(99, "/bottles/one/engine/bin/wine"),
        ]
        let sweep = BottleProcessSweep(access: access)
        XCTAssertEqual(try sweep.count(engine: engine), 2)
        access.running.removeAll { $0.pid == 1 || $0.pid == 2 }
        XCTAssertEqual(try sweep.count(engine: engine), 0, "another bottle, user or this app is not counted")
        XCTAssertTrue(access.signals.isEmpty)
        XCTAssertEqual(access.running.map(\.pid), [4, 5, 6, 7, 99])
    }

    func testSurvivingSIGKILLWaitsForTheFullCleanupWindow() throws {
        let access = FakeBottleProcessAccess()
        access.running = [BottleProcess(
            pid: 1, uid: 501, realUID: 501, executable: "/bottles/one/engine/bin/wine",
            startSeconds: 10, startMicroseconds: 20)]
        access.ignoreTerm = [1]
        access.ignoreKill = [1]
        XCTAssertThrowsError(try BottleProcessSweep(access: access).remove(
            engine: URL(fileURLWithPath: "/bottles/one/engine"))) {
            XCTAssertEqual($0 as? WineProcessesSurvived, WineProcessesSurvived(count: 1))
            XCTAssertEqual($0.localizedDescription, "Could not remove 1 leftover Wine processes")
        }
        XCTAssertEqual(access.pauses, 15 + 30)
        XCTAssertEqual(access.signals.map { $0.1 }, [SIGTERM, SIGKILL])
    }

    func testOnlyOwnBottleAndUserAreSignaledAndKillEscalatesOnlySurvivors() throws {
        let access = FakeBottleProcessAccess()
        func process(_ pid: Int32, _ path: String, uid: UInt32 = 501) -> BottleProcess {
            BottleProcess(pid: pid, uid: uid, realUID: uid, executable: path,
                          startSeconds: 10, startMicroseconds: UInt64(pid))
        }
        let engine = URL(fileURLWithPath: "/bottles/one/engine")
        access.running = [
            process(1, "/bottles/one/engine/bin/wine64-preloader"),
            process(2, "/bottles/one/engine/bin/wine-preloader"),
            process(3, "/bottles/one/engine/bin/wineserver"),
            process(4, "/bottles/two/engine/bin/wine64-preloader"),
            process(5, "/bottles/one/engine-old/bin/wine64-preloader"),
            process(6, "/usr/bin/other"),
            process(7, "/bottles/one/engine/bin/wine64-preloader", uid: 502),
            process(99, "/bottles/one/engine/bin/wine64-preloader"),
        ]
        access.ignoreTerm = [2]
        XCTAssertEqual(try BottleProcessSweep(access: access).remove(engine: engine), 3)
        XCTAssertEqual(access.signals.map { $0.0 }, [1, 2, 3, 2])
        XCTAssertEqual(access.signals.map { $0.1 }, [SIGTERM, SIGTERM, SIGTERM, SIGKILL])
        XCTAssertEqual(access.running.map(\.pid), [4, 5, 6, 7, 99])
    }
}
