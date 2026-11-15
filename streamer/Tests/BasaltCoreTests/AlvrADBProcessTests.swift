import XCTest
@testable import BasaltCore

final class AlvrADBProcessTests: XCTestCase {
    private func shell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            try XCTUnwrap(ProcessInfo.processInfo.environment["SHELL"]))
        process.arguments = ["-c", script]
        return process
    }

    func testReadsOutputAndReportsNonzeroExit() throws {
        XCTAssertEqual(try AlvrADBProcess.run(shell("printf ready")), "ready")
        XCTAssertThrowsError(try AlvrADBProcess.run(shell("printf offline >&2; exit 1"))) {
            XCTAssertTrue($0.localizedDescription.contains("offline"))
        }
    }

    func testTimeoutKillsChildIgnoringTermination() throws {
        let process = try shell("trap '' TERM; while :; do :; done")
        let start = Date()
        XCTAssertThrowsError(try AlvrADBProcess.run(process, timeout: 0.1)) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(process.isRunning)
    }

    func testInheritedWriterDoesNotHoldSuccessfulCommandOpen() throws {
        // Simulates a server inheriting stdout, without starting adb.
        let start = Date()
        XCTAssertEqual(try AlvrADBProcess.run(shell("sleep 1 & printf ready"), timeout: 0.3), "ready")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }

    func testDrainsOutputLargerThanPipeCapacity() throws {
        let result = try AlvrADBProcess.run(shell("i=0; while [ $i -lt 12000 ]; do printf 0123456789; i=$((i+1)); done"))
        XCTAssertEqual(result.count, 120_000)
    }

    // What adb 37 prints when a command has to start the server.
    private let serverStart = "* daemon not running; starting now at tcp:5039\n"
        + "* daemon started successfully\nList of devices attached\n"

    func testOnlyAServerStartedHereIsOurs() {
        let ownership = AlvrADBServerOwnership()
        ownership.note(output: "List of devices attached\nTEST device usb:1\n")
        XCTAssertFalse(ownership.takeStarted(), "a server that was already running is not ours")
        ownership.note(output: serverStart)
        XCTAssertTrue(ownership.takeStarted())
        XCTAssertFalse(ownership.takeStarted(), "asked to stop once")
        ownership.note(output: "* daemon not running; starting now at tcp:5039\n"
            + "ADB server didn't ACK\n* failed to start daemon\n")
        XCTAssertFalse(ownership.takeStarted(), "a start that failed left no server")
    }

    func testTheStreamersLineCountsAndNothingElseDoes() {
        let ownership = AlvrADBServerOwnership()
        ownership.note(streamerLine: "game: " + AlvrADBServerOwnership.startedLine)
        ownership.note(streamerLine: "Game audio capture ready")
        XCTAssertFalse(ownership.takeStarted())
        ownership.note(streamerLine: AlvrADBServerOwnership.startedLine + "\n")
        XCTAssertTrue(ownership.takeStarted())
    }

    /// The management app writes the start into its session marker at the
    /// moment the streamer reports it, and when a session begins after it.
    func testTheStartIsReportedWhenSeenAndCanBeAskedWithoutTakingIt() {
        let ownership = AlvrADBServerOwnership()
        XCTAssertFalse(ownership.note(streamerLine: "game: " + AlvrADBServerOwnership.startedLine))
        XCTAssertFalse(ownership.hasStarted)
        XCTAssertTrue(ownership.note(streamerLine: AlvrADBServerOwnership.startedLine))
        XCTAssertTrue(ownership.hasStarted)
        XCTAssertTrue(ownership.hasStarted, "asking does not take it")
        XCTAssertTrue(ownership.takeStarted())
        XCTAssertFalse(ownership.hasStarted, "stopped since")
    }

    func testStoppingTheServerIsBoundedAndPassesTheEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BasaltCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stand-in for adb: records how it was called, then hangs.
        let fake = folder.appendingPathComponent("adb")
        let record = folder.appendingPathComponent("called")
        try "#!/bin/sh\nprintf '%s %s' \"$1\" \"$ADB_SERVER_SOCKET\" > \"$RECORD\"\nexec sleep 30\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let start = Date()
        AlvrADBServer.stop(adb: fake, environment: [
            "ADB_SERVER_SOCKET": "tcp:localhost:5039", "RECORD": record.path,
        ], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8),
                       "kill-server tcp:localhost:5039")
    }
}
