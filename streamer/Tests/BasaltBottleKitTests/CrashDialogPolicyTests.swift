import XCTest
@testable import BasaltBottleKit

/// The Wine crash dialog policy (`ShowCrashDialog=0`), checked without
/// starting Wine: file copies really run, every Wine command is recorded.
final class CrashDialogPolicyTests: XCTestCase {
    private let crashDialogCommand = [
        "reg.exe", "add", #"HKCU\Software\Wine\WineDbg"#,
        "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f",
    ]
    private let marker = ".trailbridge-crash-dialog-disabled-v1"

    func testNewEnvironmentDisablesTheDialogOnceAndPrepareKeepsIt() throws {
        let fixture = try makeRepository()
        let manager = BottleManager(root: fixture.data, repoRoot: fixture.repo, runner: fixture.runner)
        let bottle = try manager.createBottle(
            name: "fresh", engineID: BottleEngineDiscovery.pinnedDXMTEngineID)
        let prefix = URL(fileURLWithPath: bottle.prefixPath)
        // Set right after the first boot, in this environment's own prefix.
        XCTAssertEqual(fixture.runner.wineCalls(in: prefix), [["wineboot", "-u"], crashDialogCommand])
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(marker), encoding: .utf8), "1\n")

        // Prepare, Prepare again and a launch's runtime sync never repeat it.
        _ = try manager.installRuntime(in: "fresh")
        _ = try manager.installRuntime(in: "fresh")
        try manager.syncRuntime(in: "fresh")
        let calls = fixture.runner.wineCalls(in: prefix)
        XCTAssertEqual(calls.filter { $0 == crashDialogCommand }.count, 1)
        XCTAssertEqual(calls.filter { $0.contains("ActiveRuntime") }.count, 3)
    }

    func testImportedEnvironmentGetsTheSettingAtPrepareBeforeAnyLaunch() throws {
        let fixture = try makeRepository()
        let manager = BottleManager(root: fixture.data, repoRoot: fixture.repo, runner: fixture.runner)
        let source = fixture.repo.appendingPathComponent("Whisky/prefix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: source.appendingPathComponent("system.reg"))
        let imported = try manager.importPrefix(
            name: "imported", engineID: BottleEngineDiscovery.pinnedDXMTEngineID, sourcePrefix: source)
        let prefix = URL(fileURLWithPath: imported.prefixPath)
        // Import only copies files; Wine first runs at Prepare.
        XCTAssertEqual(fixture.runner.wineCalls(in: prefix), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent(marker).path))

        // A refused setting fails Prepare, and an unprepared environment cannot launch.
        fixture.runner.crashDialogStatus = 1
        XCTAssertThrowsError(try manager.installRuntime(in: "imported"))
        XCTAssertFalse(try manager.loadBottle("imported").runtimeInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent(marker).path))

        fixture.runner.crashDialogStatus = 0
        XCTAssertTrue(try manager.installRuntime(in: "imported").runtimeInstalled)
        _ = try manager.installRuntime(in: "imported")
        let calls = fixture.runner.wineCalls(in: prefix)
        XCTAssertEqual(calls.first, crashDialogCommand)
        XCTAssertEqual(calls.filter { $0 == crashDialogCommand }.count, 2, "one refused, one accepted")
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(marker), encoding: .utf8), "1\n")
    }

    private func makeRepository() throws -> (repo: URL, data: URL, runner: RecordingWineRunner) {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltCrashDialog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        let pinned = repo.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine")
        for name in ["bin/wine", "bin/wineserver"] {
            let executable = pinned.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never run: the recording runner stands in for Wine.
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let macDriver = pinned.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(
            at: macDriver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: macDriver)
        let runtime = repo.appendingPathComponent("runtime/build/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: runtime.appendingPathComponent("basalt_openxr.dll"))
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("basalt_openxr.json"))
        return (repo, repo.appendingPathComponent("data", isDirectory: true), RecordingWineRunner())
    }
}

private final class RecordingWineRunner: BottleCommandRunning, @unchecked Sendable {
    var crashDialogStatus: Int32 = 0
    private var calls = [(prefix: String?, arguments: [String])]()

    func wineCalls(in prefix: URL) -> [[String]] {
        calls.filter { $0.prefix == prefix.path }.map { $0.arguments }
    }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        if executable.path == "/bin/cp" {
            return try ProcessBottleCommandRunner().run(
                executable: executable, arguments: arguments,
                environment: environment, currentDirectory: currentDirectory)
        }
        calls.append((environment["WINEPREFIX"], arguments))
        let status = arguments.contains("ShowCrashDialog") ? crashDialogStatus : 0
        return CommandOutput(status: status, output: status == 0 ? "" : "reg: access denied")
    }
}
