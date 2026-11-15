import XCTest
import Darwin
@testable import BasaltBottleKit

final class BottleManagerTests: XCTestCase {
    func testOpenCompositeContentRequiresPEAndBothMarkers() {
        XCTAssertFalse(OpenCompositeContent.isOpenComposite(peDLL()))
        XCTAssertFalse(OpenCompositeContent.isOpenComposite(Data("OCOVR OpenComposite".utf8)))
        XCTAssertFalse(OpenCompositeContent.isOpenComposite(peDLL() + Data("OCOVR".utf8)))
        XCTAssertFalse(OpenCompositeContent.isOpenComposite(peDLL() + Data("OpenComposite".utf8)))
        XCTAssertTrue(OpenCompositeContent.isOpenComposite(peDLL() + Data("OCOVR OpenComposite".utf8)))
        XCTAssertTrue(OpenCompositeContent.isOpenComposite(peDLL(x64: false) + Data("OCOVR OpenComposite".utf8)))
    }

    func testBottleDeletionRemovesOnlyManagedBottleAndItsProfiles() throws {
        let root = try temporaryDirectory()
        let manager = BottleManager(root: root, repoRoot: root)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bottle = ManagedBottle(name: "Test", engine: BottleEngine(id: "fixture", kind: .pinned,
            wineBinary: wine, wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true), prefix: prefix, engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        try manager.saveProfile(LaunchProfile(name: "game", bottleName: "Test", source: .direct, executable: "game.exe"))
        let outside = root.appendingPathComponent("preserve.dat")
        try Data("preserve".utf8).write(to: outside)
        XCTAssertThrowsError(try manager.deleteBottle("../Test"))
        try manager.deleteBottle("Test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try manager.listProfiles().isEmpty)
        XCTAssertEqual(try String(contentsOf: outside), "preserve")
    }

    func testCrashDialogPolicyRunsOnceAndRetriesAfterFailure() throws {
        let temporary = try temporaryDirectory()
        let runner = CrashPolicyRunner()
        let manager = BottleManager(root: temporary.appendingPathComponent("data"),
                                    repoRoot: temporary, runner: runner)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let bottle = ManagedBottle(name: "Test", engine: BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true), prefix: prefix,
            engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        runner.status = 1
        XCTAssertThrowsError(try manager.suppressCrashDialogs(in: "Test"))
        runner.status = 0
        try manager.suppressCrashDialogs(in: "Test")
        try manager.suppressCrashDialogs(in: "Test")
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls.last, [
            "reg.exe", "add", #"HKCU\Software\Wine\WineDbg"#,
            "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f",
        ])
    }
    private func peDLL(x64: Bool = true, marker: UInt8 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[0x3c] = 64
        bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = x64 ? 0x64 : 0x4c; bytes[69] = x64 ? 0x86 : 0x01
        bytes[84] = 2; bytes[87] = 0x20
        bytes[88] = 0x0b; bytes[89] = x64 ? 0x02 : 0x01
        bytes[127] = marker
        return Data(bytes)
    }

    func testOpenCompositePEArchitectureValidation() throws {
        XCTAssertEqual(try OpenCompositeArchitecture.dllArchitecture(in: peDLL()), .x64)
        XCTAssertEqual(try OpenCompositeArchitecture.dllArchitecture(in: peDLL(x64: false)), .x86)
        let valid = peDLL()
        for length in [0, 2, 63, 64, 89] {
            XCTAssertThrowsError(try OpenCompositeArchitecture.dllArchitecture(in: valid.prefix(length)))
        }
        for (offset, value) in [(0, UInt8(0)), (64, 0), (68, 0), (87, 0), (89, 0), (84, 255), (60, 255)] {
            var invalid = valid
            invalid[offset] = value
            XCTAssertThrowsError(try OpenCompositeArchitecture.dllArchitecture(in: invalid))
        }
    }

    func testProcessRunnerDoesNotWaitForBackgroundDescendantsHoldingOutput() throws {
        let runner = ProcessBottleCommandRunner()
        let started = Date()
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 3) & printf ready"],
            environment: [:], currentDirectory: nil)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "ready")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testProcessRunnerWithATimeoutStopsACommandThatHangs() throws {
        // Ignores SIGTERM, as a wedged tool may: it is killed after a grace.
        for script in ["exec sleep 30", "trap '' TERM; exec sleep 30"] {
            let started = Date()
            XCTAssertThrowsError(try ProcessBottleCommandRunner(timeout: 0.4).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: [:], currentDirectory: nil)) {
                XCTAssertTrue("\($0)".contains("did not finish"), "\($0)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
        let quick = try ProcessBottleCommandRunner(timeout: 5).run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf ready; exit 3"],
            environment: [:], currentDirectory: nil)
        XCTAssertEqual(quick.status, 3)
        XCTAssertEqual(quick.output, "ready", "one that finishes in time is reported as before")
    }

    func testExplicitCommandDeadlineHonorsTheShorterTimeout() throws {
        for (ownLimit, commandLimit) in [(nil, 0.2), (0.2, 5.0), (5.0, 0.2)] as [(TimeInterval?, TimeInterval)] {
            let runner: any BottleCommandRunning = ProcessBottleCommandRunner(timeout: ownLimit)
            let started = Date()
            XCTAssertThrowsError(try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 30"],
                environment: [:], currentDirectory: nil, timeout: commandLimit)) {
                XCTAssertTrue("\($0)".contains("did not finish"), "\($0)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    /// The stop a start runs after a crashed session: a `wineserver --kill
    /// --wait` that never returns is followed by the private-engine sweep.
    func testAHungWineserverDoesNotHoldABoundedBottleCleanup() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltWineCleanup-\(UUID().uuidString)", isDirectory: true)
        let bin = temporary.appendingPathComponent("engine/bin", isDirectory: true)
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let wineserver = bin.appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: wineserver)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let processes = FakeBottleProcessAccess()
        processes.running = [BottleProcess(
            pid: 42, uid: 501, realUID: 501, executable: bin.appendingPathComponent("wine").path,
            startSeconds: 1, startMicroseconds: 1)]
        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary,
            runner: ProcessBottleCommandRunner(timeout: 0.4), processAccess: processes)
        let started = Date()
        let result = try manager.terminateBottleProcesses(launchedWith: BottleLaunchCommand(
            executable: bin.appendingPathComponent("wine"), arguments: [],
            environment: ["WINEPREFIX": prefix.path], currentDirectory: nil))
        XCTAssertEqual(result.removedLeftoverProcesses, 1)
        XCTAssertTrue(result.forcedStop)
        XCTAssertTrue(processes.running.isEmpty)
        XCTAssertEqual(processes.signals.map { $0.1 }, [SIGTERM])
        let sharedCommand = BottleLaunchCommand(
            executable: bin.appendingPathComponent("wine"), arguments: [],
            environment: ["WINEPREFIX": temporary.appendingPathComponent("shared-prefix").path],
            currentDirectory: nil)
        XCTAssertThrowsError(try manager.terminateBottleProcesses(launchedWith: sharedCommand)) {
            XCTAssertTrue("\($0)".contains("wineserver did not finish"), "\($0)")
        }
        XCTAssertEqual(processes.signals.map { $0.1 }, [SIGTERM])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testDefaultRunnerBoundsBottleCleanupAndEscalatesTheSweep() throws {
        let temporary = try temporaryDirectory()
        let bin = temporary.appendingPathComponent("engine/bin", isDirectory: true)
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let wineserver = bin.appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: wineserver)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        let processes = FakeBottleProcessAccess()
        processes.running = [41, 42].map { pid in
            BottleProcess(pid: pid, uid: 501, realUID: 501,
                          executable: bin.appendingPathComponent("wine").path,
                          startSeconds: 1, startMicroseconds: UInt64(pid))
        }
        processes.ignoreTerm = [42]
        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary,
            runner: ProcessBottleCommandRunner(), processAccess: processes)
        let started = Date()
        let result = try manager.terminateBottleProcesses(launchedWith: BottleLaunchCommand(
            executable: bin.appendingPathComponent("wine"), arguments: [],
            environment: ["WINEPREFIX": prefix.path], currentDirectory: nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), BottleManager.wineStopLimit + 3)
        XCTAssertTrue(result.forcedStop)
        XCTAssertEqual(result.removedLeftoverProcesses, 2)
        XCTAssertTrue(processes.running.isEmpty)
        XCTAssertEqual(processes.signals.map { $0.0 }, [41, 42, 42])
        XCTAssertEqual(processes.signals.map { $0.1 }, [SIGTERM, SIGTERM, SIGKILL])
    }

    /// What the Steam setup asks once a second: is anything of this bottle
    /// still running. It starts and stops nothing.
    func testRunningProcessCountLooksOnlyAtTheBottlesOwnEngine() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltWineCount-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let processes = FakeBottleProcessAccess()
        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary,
            processAccess: processes)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let bin = engineRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        let wineserver = bin.appendingPathComponent("wineserver")
        let engine = BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine, wineserverBinary: wineserver,
            root: engineRoot, supportsBasaltDXMT: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ManagedBottle(
            name: "Test", engine: engine, prefix: prefix, engineRoot: engineRoot, wineBinary: wine))
            .write(to: directory.appendingPathComponent("bottle.json"))

        func process(_ pid: Int32, _ path: String) -> BottleProcess {
            BottleProcess(pid: pid, uid: 501, realUID: 501, executable: path,
                          startSeconds: 1, startMicroseconds: UInt64(pid))
        }
        let other = try manager.paths.bottleDirectory("Other")
            .appendingPathComponent("engine/bin/wineserver").path
        processes.running = [
            process(41, wineserver.path),
            process(42, engineRoot.appendingPathComponent("lib/wine/x86_64-unix/wine").path),
            process(43, other),
        ]
        XCTAssertEqual(try manager.runningProcessCount(inBottle: "Test"), 2)
        processes.running = [process(43, other)]
        XCTAssertEqual(try manager.runningProcessCount(inBottle: "Test"), 0)
        XCTAssertTrue(processes.signals.isEmpty)
        XCTAssertThrowsError(try manager.runningProcessCount(inBottle: "Missing"))
    }

    func testPrefixCommandForBottleMatchesItsProfile() throws {
        let temporary = try temporaryDirectory()
        let manager = BottleManager(root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        let bottle = try writeTestBottle(manager: manager)
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct, executable: "game.exe",
            arguments: ["ignored"], environment: ["WINEDEBUG": "+all"]))
        let command = try manager.prefixCommand(forBottle: "Test")
        XCTAssertEqual(command, try manager.prefixCommand(forProfile: "game"))
        XCTAssertEqual(command.executable, URL(fileURLWithPath: bottle.wineBinaryPath))
        XCTAssertEqual(command.arguments, [])
        XCTAssertEqual(command.environment, ["WINEPREFIX": bottle.prefixPath, "WINEARCH": "win64", "WINEDEBUG": "-all"])
        XCTAssertNil(command.currentDirectory)
    }

    func testIOActivityIncludesOnlyTheBottlesProcessesAndSignalsNothing() throws {
        let temporary = try temporaryDirectory()
        let access = FakeBottleProcessAccess()
        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary,
            fileManager: SharedEngineFileManager(), processAccess: access)
        let bottle = try writeTestBottle(manager: manager)
        let engine = URL(fileURLWithPath: bottle.engineRootPath)
        func process(_ pid: Int32, _ path: String, uid: UInt32 = 501,
                     realUID: UInt32 = 501) -> BottleProcess {
            BottleProcess(pid: pid, uid: uid, realUID: realUID, executable: path,
                          startSeconds: 1, startMicroseconds: UInt64(pid))
        }
        let wine = engine.appendingPathComponent("bin/wine").path
        access.running = [
            process(1, wine),
            process(2, engine.appendingPathComponent("bin/wineserver").path),
            process(3, engine.appendingPathComponent("lib/wine/helper").path),
            process(4, temporary.appendingPathComponent("data/Bottles/Other/engine/bin/wine").path),
            process(5, bottle.engineRootPath + "-old/bin/wine"),
            process(6, wine, uid: 502),
            process(7, wine, realUID: 502),
            process(99, wine),
            process(0, wine),
        ]
        access.bytes = [1: 120, 2: 30, 4: 1000, 5: 1000, 6: 1000, 7: 1000, 99: 1000, 0: 1000]
        XCTAssertEqual(try manager.ioActivity(inBottle: "Test"), 150)
        XCTAssertEqual(access.byteReads, [1, 2, 3], "unavailable counters contribute zero")
        access.bytes[1] = .max
        access.bytes[2] = 2
        XCTAssertEqual(try manager.ioActivity(inBottle: "Test"), 1, "counters wrap")
        access.running = []
        XCTAssertEqual(try manager.ioActivity(inBottle: "Test"), 0)

        var shared = bottle
        shared.engineKind = .gptk
        shared.engineID = "gptk-2"
        shared.engineRootPath = SharedEngineFileManager.enginePath
        shared.wineBinaryPath = shared.engineRootPath + "/bin/wine64"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(shared).write(to: manager.paths.bottleMetadata("Test"))
        access.byteReads = []
        XCTAssertNil(try manager.ioActivity(inBottle: "Test"))
        XCTAssertNil(try manager.runningProcessCount(inBottle: "Test"))
        XCTAssertTrue(access.byteReads.isEmpty)
        XCTAssertTrue(access.signals.isEmpty)
        XCTAssertThrowsError(try manager.ioActivity(inBottle: "Missing"))
    }

    func testBottleProcessCleanupUsesPrefixScopedWineserver() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltWineCleanup-\(UUID().uuidString)", isDirectory: true)
        let bin = temporary.appendingPathComponent("engine/bin", isDirectory: true)
        let wine = bin.appendingPathComponent("wine")
        let wineserver = bin.appendingPathComponent("wineserver")
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try Data("#!/bin/sh\nprintf '%s|%s|%s' \"$WINEPREFIX\" \"$1\" \"$2\"\n".utf8)
            .write(to: wineserver)
        for executable in [wine, wineserver] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let processes = FakeBottleProcessAccess()
        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"),
            repoRoot: temporary, processAccess: processes)
        let command = BottleLaunchCommand(
            executable: wine,
            arguments: [#"C:\Games\Game.exe"#],
            environment: ["WINEPREFIX": prefix.path],
            currentDirectory: nil)

        let result = try manager.terminateBottleProcesses(launchedWith: command)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "\(prefix.path)|--kill|--wait")
        XCTAssertFalse(result.forcedStop)

        try manager.prepare()
        let bottleDirectory = try manager.paths.bottleDirectory("Test")
        let managedPrefix = bottleDirectory.appendingPathComponent(
            "prefix", isDirectory: true)
        let managedEngine = bottleDirectory.appendingPathComponent(
            "engine", isDirectory: true)
        let managedBin = managedEngine.appendingPathComponent(
            "bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: managedBin, withIntermediateDirectories: true)
        let managedWine = managedBin.appendingPathComponent("wine")
        let managedWineserver = managedBin.appendingPathComponent("wineserver")
        try FileManager.default.copyItem(at: wine, to: managedWine)
        try FileManager.default.copyItem(at: wineserver, to: managedWineserver)
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: managedWine, wineserverBinary: managedWineserver,
            root: managedEngine,
            supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: managedPrefix,
            engineRoot: managedEngine,
            wineBinary: managedWine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(
            to: bottleDirectory.appendingPathComponent("bottle.json"))
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct,
            executable: #"C:\Games\Game.exe"#))

        processes.running = [BottleProcess(
            pid: 42, uid: 501, realUID: 501,
            executable: managedBin.appendingPathComponent("wine64-preloader").path,
            startSeconds: 1, startMicroseconds: 1)]
        let profileResult = try manager.terminateBottleProcesses(
            forProfile: "game")

        XCTAssertEqual(profileResult.status, 0)
        XCTAssertEqual(profileResult.output, "\(managedPrefix.path)|--kill|--wait")
        XCTAssertEqual(profileResult.removedLeftoverProcesses, 1)

        let sharedCommand = BottleLaunchCommand(
            executable: wine, arguments: [],
            environment: ["WINEPREFIX": managedPrefix.path], currentDirectory: nil)
        processes.running = [BottleProcess(
            pid: 43, uid: 501, realUID: 501,
            executable: bin.appendingPathComponent("wine64-preloader").path,
            startSeconds: 2, startMicroseconds: 2)]
        let signalCount = processes.signals.count
        let sharedResult = try manager.terminateBottleProcesses(launchedWith: sharedCommand)
        XCTAssertTrue(sharedResult.leftoverSweepSkipped)
        XCTAssertEqual(processes.signals.count, signalCount)
        processes.running = []

        // Wine reports "no server for this prefix" as status 1 with no
        // diagnostic. Cleanup is already complete in that case.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: wineserver)
        let inactiveResult = try manager.terminateBottleProcesses(
            launchedWith: command)
        XCTAssertEqual(inactiveResult, CommandOutput(status: 0, output: ""))

        try Data("#!/bin/sh\nprintf 'permission denied\\n' >&2\nexit 1\n".utf8)
            .write(to: wineserver)
        let nothingLeft = try manager.terminateBottleProcesses(launchedWith: command)
        XCTAssertFalse(nothingLeft.forcedStop, "a failing wineserver with nothing left to stop forces nothing")
        processes.running = [BottleProcess(
            pid: 44, uid: 501, realUID: 501, executable: bin.appendingPathComponent("wine").path,
            startSeconds: 3, startMicroseconds: 3)]
        let forcedResult = try manager.terminateBottleProcesses(launchedWith: command)
        XCTAssertEqual(forcedResult.removedLeftoverProcesses, 1)
        XCTAssertTrue(forcedResult.forcedStop)
        XCTAssertTrue(processes.running.isEmpty)
        processes.running = [BottleProcess(
            pid: 45, uid: 501, realUID: 501, executable: bin.appendingPathComponent("wine").path,
            startSeconds: 4, startMicroseconds: 4)]
        processes.ignoreTerm = [45]
        processes.ignoreKill = [45]
        XCTAssertThrowsError(try manager.terminateBottleProcesses(launchedWith: command)) {
            XCTAssertEqual($0 as? WineProcessesSurvived, WineProcessesSurvived(count: 1),
                           "the sweep failure takes precedence over the wineserver failure")
        }
        let signalsAfterSweep = processes.signals.count
        XCTAssertThrowsError(try manager.terminateBottleProcesses(
            launchedWith: sharedCommand)) { error in
            XCTAssertEqual(
                error as? BottleToolError,
                BottleToolError(
                    "Could not stop Wine processes for \(managedPrefix.path): permission denied"))
        }
        XCTAssertEqual(processes.signals.count, signalsAfterSweep)
    }

    func testBottleNamesRejectTraversalAndWhitespace() throws {
        XCTAssertEqual(try BottleName.validate("beat-saber_1.2"), "beat-saber_1.2")
        for invalid in ["", "../Steam", "two words", "/absolute", ".hidden", "a/b"] {
            XCTAssertThrowsError(try BottleName.validate(invalid))
        }
    }

    func testManagedPathsStayUnderRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/Basalt Managed", isDirectory: true)
        let paths = BasaltManagedPaths(root: root)
        let bottle = try paths.bottleDirectory("BeatSaber")
        XCTAssertTrue(paths.contains(bottle))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/Basalt Managed Elsewhere/x")))
        XCTAssertThrowsError(try paths.bottleDirectory("../escape"))
    }

    func testPrepareRejectsManagedDirectorySymlinkEscape() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleRoot-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Bottles"),
            withDestinationURL: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let manager = BottleManager(root: root, repoRoot: temporary)
        XCTAssertThrowsError(try manager.prepare())
    }

    func testWinePathMapsPrefixAndExternalPaths() {
        let prefix = URL(fileURLWithPath: "/tmp/Basalt/Bottles/Test/prefix")
        XCTAssertEqual(
            BottleManager.winePath(
                for: prefix.appendingPathComponent("drive_c/Games/Test/game.exe"),
                prefix: prefix),
            #"C:\Games\Test\game.exe"#)
        XCTAssertEqual(
            BottleManager.winePath(
                for: URL(fileURLWithPath: "/tmp/runtime-control"), prefix: prefix),
            #"Z:\tmp\runtime-control"#)
    }

    func testBottleAndProfileRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: URL(fileURLWithPath: "/engine/bin/wine"),
            wineserverBinary: URL(fileURLWithPath: "/engine/bin/wineserver"),
            root: URL(fileURLWithPath: "/engine"), supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "test", engine: engine,
            prefix: URL(fileURLWithPath: "/data/prefix"),
            engineRoot: URL(fileURLWithPath: "/data/engine"),
            wineBinary: URL(fileURLWithPath: "/data/engine/bin/wine"),
            createdAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try decoder.decode(
            ManagedBottle.self, from: encoder.encode(bottle)), bottle)

        let profile = LaunchProfile(
            name: "beat-saber", bottleName: "test", source: .steam,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#,
            arguments: ["--verbose"], workingDirectory: "/data/prefix/drive_c/Games",
            environment: ["KEY": "VALUE"])
        XCTAssertEqual(try decoder.decode(
            LaunchProfile.self, from: encoder.encode(profile)), profile)

        // gameRoot is optional: profiles saved before it existed still load.
        let legacy = Data("""
            {"formatVersion":1,"name":"lab","bottleName":"test","source":"steam",\
            "executable":"C:\\\\Lab.exe","arguments":[],"environment":{}}
            """.utf8)
        XCTAssertNil(try decoder.decode(LaunchProfile.self, from: legacy).gameRoot)
        var rooted = profile
        rooted.gameRoot = #"C:\Program Files (x86)\Steam\steamapps\common\The Lab"#
        XCTAssertEqual(try decoder.decode(
            LaunchProfile.self, from: encoder.encode(rooted)).gameRoot, rooted.gameRoot)
    }

    func testOpenCompositeRoundTripDiscoveryAndPrefixSafety() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let repo = temporary.appendingPathComponent("repo", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineRoot.appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix, withIntermediateDirectories: true)

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix,
            engineRoot: engineRoot,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"))
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        try metadataEncoder.encode(bottle).write(
            to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: repo)
        let profile = LaunchProfile(
            name: "beat-saber", bottleName: "Test", source: .steam,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#,
            gameRoot: #"C:\Games\Beat Saber"#)
        try manager.saveProfile(profile)
        XCTAssertEqual(try manager.loadProfile("beat-saber"), profile)

        let artifact = temporary.appendingPathComponent("openvr_api.dll")
        let replacement = peDLL(marker: 1) + Data("OCOVR OpenComposite".utf8)
        try replacement.write(to: artifact)
        let target = prefix.appendingPathComponent(
            "drive_c/Games/Beat Saber/Beat Saber_Data/Plugins/x86_64/openvr_api.dll")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = peDLL(marker: 2)
        try original.write(to: target)

        XCTAssertEqual(
            try manager.installOpenComposite(
                profileName: profile.name, artifact: artifact, targetDLL: target),
            target.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: target), replacement)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathExtension("basalt-original")),
            original)
        let configuration = try String(contentsOf:
            target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini"))
        let options = configuration.split(separator: "\n").filter { !$0.hasPrefix(";") }
        XCTAssertEqual(options.map(String.init), ["initUsingVulkan=false"])
        XCTAssertFalse(configuration.contains("enableAudio"))


        let backup = target.appendingPathExtension("basalt-original")
        let ini = target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        XCTAssertEqual(try manager.openVRTargets(profileName: profile.name), [target])
        // Reinstallation of OpenComposite retains the original.
        let cache = manager.openCompositeCacheURL(for: .x64)
        XCTAssertEqual(try Data(contentsOf: cache), replacement)
        try FileManager.default.removeItem(at: cache)
        XCTAssertTrue(try manager.isOpenComposite(at: target))
        XCTAssertEqual(try Data(contentsOf: cache), replacement)
        _ = try manager.installOpenComposite(profileName: profile.name, artifact: artifact, targetDLL: target)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        // Steam restores a newer original: refresh the backup during repair.
        let newerOriginal = peDLL(marker: 3)
        try newerOriginal.write(to: target)
        XCTAssertFalse(try manager.isOpenComposite(at: target))
        try FileManager.default.removeItem(at: cache)
        XCTAssertThrowsError(try manager.repairOpenComposite(profileName: profile.name))
        XCTAssertEqual(try Data(contentsOf: target), newerOriginal)
        try replacement.write(to: cache)
        XCTAssertTrue(try manager.repairOpenComposite(profileName: profile.name))
        XCTAssertEqual(try Data(contentsOf: backup), newerOriginal)
        XCTAssertEqual(try Data(contentsOf: target), replacement)
        XCTAssertFalse(try manager.repairOpenComposite(profileName: profile.name))
        try manager.uninstallOpenComposite(profileName: profile.name, targetDLL: target)
        XCTAssertEqual(try Data(contentsOf: target), newerOriginal)
        try original.write(to: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ini.path))
        XCTAssertThrowsError(try manager.uninstallOpenComposite(profileName: profile.name, targetDLL: target))

        let userINI = "; My settings\ninitUsingVulkan=true\n"
        try userINI.write(to: ini, atomically: true, encoding: .utf8)
        _ = try manager.installOpenComposite(profileName: profile.name, artifact: artifact, targetDLL: target)
        try manager.uninstallOpenComposite(profileName: profile.name, targetDLL: target)
        XCTAssertEqual(try String(contentsOf: ini, encoding: .utf8), userINI)
        try FileManager.default.removeItem(at: ini)

        // Wrong architecture and MZ-only artifacts are rejected before any changes.
        for invalid in [peDLL(x64: false), Data([0x4d, 0x5a])] {
            try invalid.write(to: artifact)
            XCTAssertThrowsError(try manager.installOpenComposite(
                profileName: profile.name, artifact: artifact, targetDLL: target))
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
        try replacement.write(to: artifact)

        let escaped = temporary.appendingPathComponent("openvr_api.dll")
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: profile.name, artifact: artifact, targetDLL: escaped))

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        let redirect = prefix.appendingPathComponent("drive_c/redirect", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: redirect, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: profile.name, artifact: artifact,
            targetDLL: redirect.appendingPathComponent("openvr_api.dll")))

        for invalid in [escaped, redirect.appendingPathComponent("openvr_api.dll"),
                        prefix.appendingPathComponent("../openvr_api.dll"),
                        target.deletingLastPathComponent().appendingPathComponent("wrong.dll")] {
            XCTAssertThrowsError(try manager.uninstallOpenComposite(profileName: profile.name, targetDLL: invalid))
        }
        // Both operations reject target, backup and ini links, including dangling ones.
        let external = outside.appendingPathComponent("original.dll")
        try original.write(to: external)
        for location in [target, backup, ini] {
            if FileManager.default.fileExists(atPath: location.path) {
                try FileManager.default.removeItem(at: location)
            }
            for destination in [external, outside.appendingPathComponent("missing.dll")] {
                try FileManager.default.createSymbolicLink(at: location, withDestinationURL: destination)
                XCTAssertThrowsError(try manager.installOpenComposite(
                    profileName: profile.name, artifact: artifact, targetDLL: target))
                XCTAssertThrowsError(try manager.uninstallOpenComposite(profileName: profile.name, targetDLL: target))
                XCTAssertEqual(try Data(contentsOf: external), original)
                try FileManager.default.removeItem(at: location)
            }
            if location == target { try original.write(to: target) }
        }

        let second = target.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("x86/openvr_api.dll")
        let backupFolder = target.deletingLastPathComponent().appendingPathComponent("backups/openvr_api.dll")
        for file in [second, backupFolder] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: file)
        }
        try original.write(to: target.appendingPathExtension("bak"))
        XCTAssertEqual(Set(try manager.openVRTargets(profileName: profile.name)), Set([target, second]))
        var escapedProfile = profile
        escapedProfile.gameRoot = outside.path
        try manager.saveProfile(escapedProfile)
        XCTAssertThrowsError(try manager.openVRTargets(profileName: profile.name))
        escapedProfile.gameRoot = nil
        try manager.saveProfile(escapedProfile)
        XCTAssertThrowsError(try manager.openVRTargets(profileName: profile.name))
    }

    func testProfileLaunchCommandIsValidatedAndResolvedForGUIOwnership() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltLaunchCommand-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix,
            engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct,
            executable: #"C:\Games\Game.exe"#, arguments: ["-vr"],
            environment: ["GAME_MODE": "test"]))
        let control = temporary.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let command = try manager.profileLaunchCommand(
            "game", controlFile: control, additionalArguments: ["-debug"])

        XCTAssertEqual(command.executable, wine.standardizedFileURL)
        XCTAssertEqual(
            command.arguments,
            [#"C:\Games\Game.exe"#, "-vr", "-debug"])
        XCTAssertEqual(command.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(command.environment["WINEARCH"], "win64")
        XCTAssertEqual(command.environment["MVK_CONFIG_LOG_LEVEL"], "0")
        XCTAssertEqual(command.environment["DXMT_BASALT_IOSURFACE"], "1")
        XCTAssertEqual(command.environment["GAME_MODE"], "test")
        XCTAssertEqual(
            command.environment["BASALT_CONTROL"],
            "Z:" + control.path.replacingOccurrences(of: "/", with: #"\"#))
    }

    func testLegacySteamBeatSaberProfileResolvesToWaitedGameProcess() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltSteamLaunch-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Steam", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        let beatSaber = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber.exe")
        let steam = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe")
        let webHelper = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe")
        let compatibilityArtifact = temporary.appendingPathComponent(
            "runtime/build/bin/steamwebhelper_compat.exe")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: beatSaber.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: webHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: compatibilityArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try Data([0x4d, 0x5a]).write(to: beatSaber)
        try Data([0x4d, 0x5a]).write(to: steam)
        let originalHelper = Data([0x4d, 0x5a, 0x10])
        let shimMarker = Data("steamwebhelper.basalt-original.exe".utf16.flatMap {
            [UInt8($0 & 0xff), UInt8($0 >> 8)]
        })
        let compatibilityShim = Data([0x4d, 0x5a, 0x20]) + shimMarker
        try originalHelper.write(to: webHelper)
        try compatibilityShim.write(to: compatibilityArtifact)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Steam", engine: engine, prefix: prefix,
            engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "beat-saber", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-applaunch", "620980", "-vrmode", "openxr"]))
        let control = temporary.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let command = try manager.profileLaunchCommand("beat-saber", controlFile: control)

        XCTAssertEqual(command.arguments, [
            #"C:\Program Files (x86)\Steam\steamapps\common\Beat Saber\Beat Saber.exe"#,
            "-vrmode", "openxr",
        ])
        XCTAssertEqual(command.currentDirectory, beatSaber.deletingLastPathComponent())
        XCTAssertEqual(command.environment["SteamAppId"], "620980")
        XCTAssertEqual(command.environment["SteamGameId"], "620980")

        XCTAssertEqual(
            try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber"),
            webHelper)
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        let preservedHelper = webHelper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")
        XCTAssertEqual(try Data(contentsOf: preservedHelper), originalHelper)

        // An external Steam update replaces the shim. Basalt must retain the
        // new matching original instead of launching the stale preserved copy.
        let updatedHelper = Data([0x4d, 0x5a, 0x30])
        try updatedHelper.write(to: webHelper)
        _ = try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber")
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        XCTAssertEqual(try Data(contentsOf: preservedHelper), updatedHelper)

        // A rebuilt shim differs byte-for-byte from the installed older build.
        // The older shim must be replaced, never preserved as Steam's helper.
        let rebuiltShim = Data([0x4d, 0x5a, 0x21]) + shimMarker
        try rebuiltShim.write(to: compatibilityArtifact)
        _ = try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber")
        XCTAssertEqual(try Data(contentsOf: webHelper), rebuiltShim)
        XCTAssertEqual(try Data(contentsOf: preservedHelper), updatedHelper)
        XCTAssertTrue(BottleManager.isSteamWebHelperShim(rebuiltShim))
        XCTAssertFalse(BottleManager.isSteamWebHelperShim(updatedHelper))

        // A backup already overwritten by an older Basalt build is refused
        // rather than installed as a self-launching loop.
        try compatibilityShim.write(to: preservedHelper)
        XCTAssertThrowsError(
            try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber"))
        try updatedHelper.write(to: preservedHelper)

        let bootstrap = try XCTUnwrap(
            manager.steamBootstrapCommand(forProfile: "beat-saber"))
        XCTAssertEqual(bootstrap.executable, wine.standardizedFileURL)
        XCTAssertEqual(bootstrap.arguments, [
            #"C:\Program Files (x86)\Steam\steam.exe"#,
            "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
        ])
        XCTAssertEqual(bootstrap.currentDirectory, prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam"))
        XCTAssertEqual(bootstrap.environment["MVK_CONFIG_LOG_LEVEL"], "0")
        XCTAssertEqual(
            try manager.steamConnectionLogURL(forProfile: "beat-saber"),
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"))

        // BSManager instances are launched directly from their external
        // BSInstances directory, but still require the managed bottle's Steam
        // client to be signed in before SteamAPI initializes.
        try manager.saveProfile(LaunchProfile(
            name: "bsmanager-instance", bottleName: "Steam", source: .bsmanager,
            executable: #"Z:\Users\player\BSManager\BSInstances\1.40.8\Beat Saber.exe"#,
            environment: ["WINEDLLOVERRIDES": "winhttp=n,b"]))
        XCTAssertNotNil(try manager.installSteamWebHelperCompatibility(
            forProfile: "bsmanager-instance"))
        XCTAssertEqual(
            try manager.steamBootstrapCommand(
                forProfile: "bsmanager-instance")?.arguments,
            [
                #"C:\Program Files (x86)\Steam\steam.exe"#,
                "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
            ])
        XCTAssertEqual(
            try manager.steamConnectionLogURL(
                forProfile: "bsmanager-instance"),
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"))
    }

    func testImportsExternalPrefixIntoIsolatedManagedCopy() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltImport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let pinned = temporary.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine")
        let bin = pinned.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let executable = bin.appendingPathComponent(name)
            // Import is a file operation and must never boot the copied prefix.
            // A Wine invocation makes this test fail immediately.
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let macDriver = pinned.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(
            at: macDriver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: macDriver)
        let fork = temporary.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fork)

        let source = temporary.appendingPathComponent("Whisky", isDirectory: true)
        let game = source.appendingPathComponent("drive_c/Games/Test/Game.exe")
        try FileManager.default.createDirectory(
            at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: game)
        try Data("WINE REGISTRY".utf8).write(to: source.appendingPathComponent("system.reg"))
        let sourceUserRegistry = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Run]
        "Other"="C:\\Other.exe"
        "Steam"="\"C:\\Program Files (x86)\\Steam\\steam.exe\" -silent"

        [Software\\Valve\\Steam]
        "SuppressAutoRun"=dword:00000000
        """#
        try Data(sourceUserRegistry.utf8).write(
            to: source.appendingPathComponent("user.reg"))

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        let imported = try manager.importPrefix(
            name: "imported", engineID: BottleEngineDiscovery.pinnedDXMTEngineID,
            sourcePrefix: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            URL(fileURLWithPath: imported.prefixPath)
                .appendingPathComponent("drive_c/Games/Test/Game.exe").path))
        XCTAssertEqual(try Data(contentsOf:
            URL(fileURLWithPath: imported.prefixPath).appendingPathComponent("system.reg")),
            Data("WINE REGISTRY".utf8))
        let importedUserRegistry = try String(contentsOf:
            URL(fileURLWithPath: imported.prefixPath).appendingPathComponent("user.reg"))
        XCTAssertFalse(importedUserRegistry.contains(#""Steam"="#))
        XCTAssertTrue(importedUserRegistry.contains(
            #""SuppressAutoRun"=dword:00000001"#))
        XCTAssertTrue(importedUserRegistry.contains(#""Other"="C:\\Other.exe""#))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("user.reg")),
                       sourceUserRegistry, "The source registry must remain untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.path),
                      "The external source must remain untouched")
        XCTAssertFalse(imported.dxmtInstalled)
        XCTAssertFalse(imported.runtimeInstalled)
    }

    func testFailedCreateAndImportRemoveTheHalfMadeBottle() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltFailedCreate-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: temporary.appendingPathComponent("Source/locked").path)
            try? FileManager.default.removeItem(at: temporary)
        }
        let pinned = temporary.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine")
        let bin = pinned.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            // wineboot runs through this stub and fails.
            let executable = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let macDriver = pinned.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(
            at: macDriver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: macDriver)
        let fork = temporary.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fork)

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        let directory = try manager.paths.bottleDirectory("Broken")

        XCTAssertThrowsError(try manager.createBottle(
            name: "Broken", engineID: BottleEngineDiscovery.pinnedDXMTEngineID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try manager.listBottles().count, 0)

        // An unreadable source file makes the prefix copy fail after the
        // bottle directory exists.
        let source = temporary.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("WINE REGISTRY".utf8).write(to: source.appendingPathComponent("system.reg"))
        let locked = source.appendingPathComponent("locked")
        try Data([1]).write(to: locked)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path)

        XCTAssertThrowsError(try manager.importPrefix(
            name: "Broken", engineID: BottleEngineDiscovery.pinnedDXMTEngineID,
            sourcePrefix: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try manager.listBottles().count, 0)

        // The name is free again once the source is fixed.
        try FileManager.default.removeItem(at: locked)
        XCTAssertNoThrow(try manager.importPrefix(
            name: "Broken", engineID: BottleEngineDiscovery.pinnedDXMTEngineID,
            sourcePrefix: source))
    }

    func testInstallDXMTMigratesLegacyPinnedEngineBeforeOverlay() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltEngineMigration-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let provider = temporary.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine",
            isDirectory: true)
        let providerWine = provider.appendingPathComponent("bin/wine")
        let providerServer = provider.appendingPathComponent("bin/wineserver")
        let providerMac = provider.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        for executable in [providerWine, providerServer] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try FileManager.default.createDirectory(
            at: providerMac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("matched-mac-driver".utf8).write(to: providerMac)

        let fork = temporary.appendingPathComponent("runtime/build/dxmt/fork-install")
        let forkWindows = fork.appendingPathComponent("x86_64-windows")
        let forkUnix = fork.appendingPathComponent("x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: forkWindows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: forkUnix.deletingLastPathComponent(), withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            try Data("fork-\(dll)".utf8).write(to: forkWindows.appendingPathComponent(dll))
        }
        try Data("fork-unix".utf8).write(to: forkUnix)

        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Legacy", isDirectory: true)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let legacyWine = engine.appendingPathComponent("bin/wine")
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyWine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: legacyWine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: legacyWine.path)
        try Data("legacy".utf8).write(to: engine.appendingPathComponent("legacy.marker"))

        let legacyProvider = BottleEngine(
            id: "pinned-wine-8.17-dxmt-0.80", kind: .pinned,
            wineBinary: legacyWine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Legacy", engine: legacyProvider, prefix: prefix,
            engineRoot: engine, wineBinary: legacyWine)
        bottle.dxmtInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        let migrated = try manager.installDXMT(in: "Legacy")

        XCTAssertEqual(migrated.engineID, BottleEngineDiscovery.pinnedDXMTEngineID)
        XCTAssertTrue(migrated.dxmtInstalled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: engine.appendingPathComponent("legacy.marker").path))
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent(
            "lib/wine/x86_64-unix/winemac.so")), "matched-mac-driver")
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent(
            "lib/wine/x86_64-unix/winemetal.so")), "fork-unix")
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(
            "drive_c/windows/system32/d3d11.dll")), "fork-d3d11.dll")
    }

    func testDeletesOnlyRequestedProfileAndBuildsMaintenanceCommand() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltProfileDelete-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("data")
        let directory = root.appendingPathComponent("Bottles/Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let provider = BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: provider, prefix: prefix,
            engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "one", bottleName: "Test", source: .direct, executable: #"C:\one.exe"#))
        try manager.saveProfile(LaunchProfile(
            name: "two", bottleName: "Test", source: .direct, executable: #"C:\two.exe"#))

        try manager.deleteProfile("one")
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["two"])
        let command = try manager.applicationLaunchCommand(
            bottleName: "Test", executable: #"C:\steam.exe"#, arguments: ["-silent"])
        XCTAssertEqual(command.arguments, [#"C:\steam.exe"#, "-silent"])
        XCTAssertEqual(command.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(command.environment["XDG_CONFIG_HOME"], directory.appendingPathComponent("host/config").path)
        XCTAssertEqual(command.environment["TMPDIR"], directory.appendingPathComponent("host/tmp").path)
        XCTAssertEqual(command.environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        let folderConfig = try String(contentsOf: directory.appendingPathComponent("host/config/user-dirs.dirs"))
        XCTAssertTrue(folderConfig.contains(directory.appendingPathComponent("host/folders/Documents").path))
        XCTAssertFalse(folderConfig.contains("$HOME"))
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("host/tmp"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("host/tmp"), withDestinationURL: outside)
        XCTAssertThrowsError(try manager.applicationLaunchCommand(bottleName: "Test", executable: "winecfg"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testReadsActiveOpenXRRuntimeFromWineHive() {
        let hive = #"""
            WINE REGISTRY Version 2
            ;; All keys relative to REGISTRY\\Machine

            [Software\\Khronos\\OpenXR\\1] 1784710400
            #time=1dd19b78b874098
            "ActiveRuntime"="C:\\basalt\\runtime\\basalt_openxr.json"

            [Software\\Khronos\\Vulkan\\Drivers] 1749700164
            "C:\\windows\\system32\\winevulkan.json"=dword:00000000
            """#
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.utf8)),
            BottleManager.runtimeManifestWindowsPath)
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
                of: #"C:\\basalt\\runtime\\basalt_openxr.json"#,
                with: #"C:\\Program Files\\SteamVR\\steamxr_win64.json"#).utf8)),
            #"C:\Program Files\SteamVR\steamxr_win64.json"#)
        XCTAssertNil(BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
            of: "OpenXR", with: "OpenVR").utf8)))
        // Key names are case-insensitive.
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
                of: "Software", with: "SOFTWARE").utf8)),
            BottleManager.runtimeManifestWindowsPath)
    }

    func testRuntimeSyncSkipsWineWhenTheBottleIsCurrent() throws {
        let temporary = try temporaryDirectory()
        let bin = temporary.appendingPathComponent("runtime/build/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("dll-v1".utf8).write(to: bin.appendingPathComponent("basalt_openxr.dll"))
        try Data("{}".utf8).write(to: bin.appendingPathComponent("basalt_openxr.json"))

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Records each Wine start, including the one-time crash-dialog policy.
        try Data("#!/bin/sh\necho \"$@\" >> \"$WINEPREFIX/wine-calls\"\n".utf8).write(to: wine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let bottle = ManagedBottle(
            name: "Test",
            engine: BottleEngine(
                id: "test", kind: .pinned, wineBinary: wine,
                wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
                root: engine, supportsBasaltDXMT: true),
            prefix: prefix, engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        func wineStarts() -> Int {
            ((try? String(contentsOf: prefix.appendingPathComponent("wine-calls")))?
                .split(separator: "\n").count) ?? 0
        }

        // A first sync registers even without a hive.
        XCTAssertTrue(try manager.syncRuntime(in: "Test").runtimeInstalled)
        XCTAssertEqual(wineStarts(), 2)

        // Wine flushed the registration; an unchanged bottle needs no Wine.
        try Data(#"""

            [Software\\Khronos\\OpenXR\\1] 1784710400
            "ActiveRuntime"="C:\\basalt\\runtime\\basalt_openxr.json"

            """#.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 2)

        // A rebuilt DLL is still copied without re-registering.
        try Data("dll-v2".utf8).write(to: bin.appendingPathComponent("basalt_openxr.dll"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 2)
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(
            "drive_c/basalt/runtime/basalt_openxr.dll")), "dll-v2")

        // Another runtime took over, and Prepare always re-registers.
        try Data(#"""

            [Software\\Khronos\\OpenXR\\1] 1784710400
            "ActiveRuntime"="C:\\SteamVR\\steamxr_win64.json"

            """#.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 3)
        _ = try manager.installRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 4)
    }

    func testFinderCopiesOfABottleOrProfileAreNotListedAndNotTouched() throws {
        let root = try temporaryDirectory()
        let manager = BottleManager(root: root, repoRoot: root)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bottle = ManagedBottle(name: "Test", engine: BottleEngine(id: "fixture", kind: .pinned,
            wineBinary: wine, wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true), prefix: prefix, engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct, executable: "game.exe"))

        // What "Duplicate" in Finder leaves: the metadata inside keeps the old name.
        let bottleCopy = manager.paths.bottles.appendingPathComponent("Test copy", isDirectory: true)
        let profileCopy = manager.paths.profiles.appendingPathComponent("game copy.json")
        try FileManager.default.copyItem(at: directory, to: bottleCopy)
        try FileManager.default.copyItem(at: try manager.paths.profileFile("game"), to: profileCopy)

        XCTAssertEqual(try manager.listBottles().map(\.name), ["Test"])
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["game"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bottleCopy.appendingPathComponent("bottle.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileCopy.path))

        // The same name in another case is the app's own file only where the
        // volume ignores case; there it must stay listed.
        let renamed = manager.paths.profiles.appendingPathComponent("GAME.json")
        try FileManager.default.moveItem(at: try manager.paths.profileFile("game"), to: renamed)
        let ignoresCase = FileManager.default.fileExists(atPath: try manager.paths.profileFile("game").path)
        XCTAssertEqual(try manager.listProfiles().map(\.name), ignoresCase ? ["game"] : [])
    }

    private func writeTestBottle(manager: BottleManager) throws -> ManagedBottle {
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bottle = ManagedBottle(name: "Test", engine: BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true), prefix: prefix, engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        return bottle
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class CrashPolicyRunner: BottleCommandRunning, @unchecked Sendable {
    var status: Int32 = 0
    var calls = [[String]]()
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        calls.append(arguments)
        return CommandOutput(status: status, output: "")
    }
}

private final class SharedEngineFileManager: FileManager, @unchecked Sendable {
    static let enginePath = "/Applications/Game Porting Toolkit 2.app/Contents/Resources/wine"

    override func isExecutableFile(atPath path: String) -> Bool {
        path == Self.enginePath + "/bin/wine64" || path == Self.enginePath + "/bin/wineserver"
    }
}
