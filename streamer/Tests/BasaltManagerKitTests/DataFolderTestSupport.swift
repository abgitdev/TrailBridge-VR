// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

// Shared by the data-folder tests (DamagedFilesTests, DataFolderPathTests,
// DataFolderDiskGoneTests, HealthyDataFolderTests): a data folder shaped like
// the app makes it, with Wine replaced by a runner that refuses everything.

/// Stands in for Wine and refuses every command.
final class RefusingWineRunner: BottleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [[String]]()
    var calls: [[String]] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        lock.withLock { recorded.append([executable.path] + arguments) }
        return CommandOutput(status: 71, output: "Wine must not run in a test")
    }
}

/// A data folder with fake managed bottles, shaped like `createBottle` makes them.
struct FakeDataFolder {
    let root: URL
    let repo: URL
    let runner = RefusingWineRunner()

    /// A new manager each time, as a new start of the app has.
    var manager: BottleManager { BottleManager(root: root, repoRoot: repo, runner: runner) }

    func bottleDirectory(_ name: String) -> URL {
        root.appendingPathComponent("Bottles/\(name)", isDirectory: true)
    }

    func prefix(_ name: String) -> URL {
        bottleDirectory(name).appendingPathComponent("prefix", isDirectory: true)
    }

    func bottleJSON(_ name: String) -> URL {
        bottleDirectory(name).appendingPathComponent("bottle.json")
    }

    func profileJSON(_ name: String) -> URL {
        root.appendingPathComponent("Profiles/\(name).json")
    }

    /// `bottle.json` is written as the app writes it (`BottleManager.saveBottle`).
    @discardableResult
    func makeBottle(_ name: String) throws -> ManagedBottle {
        let files = FileManager.default
        try manager.prepare()
        let directory = bottleDirectory(name)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engine.appendingPathComponent("bin/wine")
        let wineserver = engine.appendingPathComponent("bin/wineserver")
        try files.createDirectory(at: wine.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.createDirectory(at: prefix(name).appendingPathComponent("drive_c"),
                                  withIntermediateDirectories: true)
        for executable in [wine, wineserver] {
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        var bottle = ManagedBottle(
            name: name,
            engine: BottleEngine(
                id: BottleEngineDiscovery.pinnedDXMTEngineID, kind: .pinned,
                wineBinary: wine, wineserverBinary: wineserver, root: engine,
                supportsBasaltDXMT: true),
            prefix: prefix(name), engineRoot: engine, wineBinary: wine,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: bottleJSON(name))
        return bottle
    }

    func profile(_ name: String, bottle: String) -> LaunchProfile {
        LaunchProfile(name: name, bottleName: bottle, source: .direct,
                      executable: #"C:\Games\Test\game.exe"#,
                      environment: ["TEST": "1"], gameRoot: #"C:\Games\Test"#,
                      title: "Test Game")
    }
}

/// What is at `url` now, read without following a final link.
func fileState(_ url: URL) -> String {
    let files = FileManager.default
    if let target = try? files.destinationOfSymbolicLink(atPath: url.path) {
        return "link→\(URL(fileURLWithPath: target).lastPathComponent)"
    }
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "absent" }
    if isDirectory.boolValue {
        return "folder\(((try? files.contentsOfDirectory(atPath: url.path)) ?? []).sorted())"
    }
    let size = ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    // An unreadable file still has a size; its bytes are compared when readable.
    let digest = (try? Data(contentsOf: url)).map { String($0.hashValue, radix: 16).suffix(6) } ?? "unreadable"
    return "file(\(size),\(digest))"
}

/// A short, single-line description of an error.
func errorText(_ error: any Error) -> String {
    let text = "\(type(of: error)): \(error.localizedDescription)"
    return String(text.replacingOccurrences(of: "\n", with: " ").prefix(200))
}

/// "ok …" with what `body` returned, or "THROWS …" with what it threw.
func attempt<T>(_ body: () throws -> T, _ show: (T) -> String = { "\($0)" }) -> String {
    do { return "ok " + String(show(try body()).replacingOccurrences(of: "\n", with: "⏎").prefix(200)) }
    catch { return "THROWS " + errorText(error) }
}

/// Runs `body` off the calling thread; "HANG" when it has not returned in `timeout` seconds.
func timed(_ timeout: TimeInterval = 30, _ body: @escaping @Sendable () -> String) -> (String, TimeInterval) {
    let done = DispatchSemaphore(value: 0)
    let box = LockedText()
    let start = Date()
    let thread = Thread {
        box.set(body())
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        return ("HANG (> \(Int(timeout)) s)", Date().timeIntervalSince(start))
    }
    return (box.get(), Date().timeIntervalSince(start))
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ new: String) { lock.withLock { value = new } }
    func get() -> String { lock.withLock { value } }
}

extension XCTestCase {
    /// A scratch folder under the worktree's `.local/tmp`, without links in
    /// its path (the system temporary folder is reached through one).
    func dataFolderScratch() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".local/tmp/data-folder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { forceRemove(root) }
        return root
    }
}

/// Removes a folder also when files in it were made unreadable.
func forceRemove(_ root: URL) {
    let files = FileManager.default
    if let enumerator = files.enumerator(atPath: root.path) {
        for case let relative as String in enumerator {
            let path = root.appendingPathComponent(relative).path
            if (try? files.destinationOfSymbolicLink(atPath: path)) == nil {
                try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }
        }
    }
    try? files.removeItem(at: root)
}
