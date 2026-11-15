// SPDX-License-Identifier: MIT
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BasaltBottleKit

/// A data root with fake managed bottles, for tests that must prove Wine never
/// runs: every Wine command goes to `runner`, which records it and fails, and
/// the bottles' own `wine` and `wineserver` scripts log any direct start to
/// `wineLog` before failing too.
struct GameFolderFixture {
    let scratch: URL
    let data: URL
    let repo: URL
    let wineLog: URL
    let runner: RefusingWineRunner
    let manager: BottleManager

    init(_ testCase: XCTestCase) throws {
        scratch = try testCase.makeScratchFolder()
        data = scratch.appendingPathComponent("data", isDirectory: true)
        repo = scratch.appendingPathComponent("repo", isDirectory: true)
        wineLog = scratch.appendingPathComponent("wine-started.log")
        runner = RefusingWineRunner()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        manager = BottleManager(root: data, repoRoot: repo, runner: runner)
        try manager.prepare()
    }

    func bottleDirectory(_ name: String) -> URL {
        data.appendingPathComponent("Bottles/\(name)", isDirectory: true)
    }

    func prefix(_ name: String) -> URL {
        bottleDirectory(name).appendingPathComponent("prefix", isDirectory: true)
    }

    func games(_ name: String) -> URL {
        prefix(name).appendingPathComponent("drive_c/Games", isDirectory: true)
    }

    /// A pinned-engine bottle shaped like the ones `createBottle` makes, with
    /// an empty drive C.
    @discardableResult
    func makeBottle(_ name: String, ready: Bool = true) throws -> ManagedBottle {
        let directory = bottleDirectory(name)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engine.appendingPathComponent("bin/wine")
        let wineserver = engine.appendingPathComponent("bin/wineserver")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix(name).appendingPathComponent("drive_c", isDirectory: true),
            withIntermediateDirectories: true)
        for executable in [wine, wineserver] {
            try Data("#!/bin/sh\necho \"$0 $*\" >> \"\(wineLog.path)\"\nexit 71\n".utf8)
                .write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        var bottle = ManagedBottle(
            name: name,
            engine: BottleEngine(
                id: BottleEngineDiscovery.pinnedDXMTEngineID, kind: .pinned,
                wineBinary: wine, wineserverBinary: wineserver, root: engine,
                supportsBasaltDXMT: true),
            prefix: prefix(name), engineRoot: engine, wineBinary: wine,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        bottle.dxmtInstalled = ready
        bottle.runtimeInstalled = ready
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        return bottle
    }

    /// Nothing started Wine, through the runner or directly.
    func assertWineNeverRan(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(runner.calls, [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wineLog.path),
                       "a bottle's Wine script ran", file: file, line: line)
    }
}

/// Profiles shaped like the ones `SteamInstallation.gameProfile` made for the
/// two working Steam games, and their environments' names.
enum WorkingGames {
    static let bottles = ["brutalistick-vr", "blood-trail"]

    static let profiles = [
        LaunchProfile(
            name: "brutalistick-vr-steam", bottleName: "brutalistick-vr", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\BrutalistickVR\BrutalistickVR.exe"#,
            workingDirectory: "/Data/Bottles/brutalistick-vr/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/BrutalistickVR",
            environment: ["SteamAppId": "2669380", "SteamGameId": "2669380"],
            gameRoot: #"C:\Program Files (x86)\Steam\steamapps\common\BrutalistickVR"#),
        LaunchProfile(
            name: "blood-trail-blood-trail", bottleName: "blood-trail", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe"#,
            workingDirectory: "/Data/Bottles/blood-trail/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Blood Trail/BTVR/Binaries/Win64",
            environment: [
                "BASALT_TOUCH_GRIP_PITCH_DEGREES": "15",
                "SteamAppId": "1032430", "SteamGameId": "1032430",
            ],
            gameRoot: #"C:\Program Files (x86)\Steam\steamapps\common\Blood Trail"#),
    ]

    /// The game executables whose shader caches live in `host/cache/dxmt`.
    static let executables = ["BrutalistickVR.exe", "BTVR-Win64-Shipping.exe"]
}

/// Stands in for Wine and refuses every command, so a test sees any attempt.
final class RefusingWineRunner: BottleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [[String]]()

    var calls: [[String]] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        lock.withLock { recorded.append([executable.path] + arguments) }
        return CommandOutput(status: 71, output: "Wine must not run in this test")
    }
}

/// One entry of a folder snapshot. Folders and links compare by kind and
/// target, files by size, modification time and SHA-256 of their bytes.
struct SnapshotEntry: Equatable, CustomStringConvertible {
    let kind: String
    let size: Int64
    let modified: Date?
    let digest: String

    var description: String { "\(kind) \(size) \(digest.prefix(12))" }
}

/// Every entry under `root`, keyed by relative path, read without following
/// links. An absent root gives an empty snapshot.
func snapshot(_ root: URL) throws -> [String: SnapshotEntry] {
    var entries = [String: SnapshotEntry]()
    guard FileManager.default.fileExists(atPath: root.path) else { return entries }
    func visit(_ url: URL, relative: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        switch type {
        case .typeDirectory?:
            entries[relative] = SnapshotEntry(kind: "folder", size: 0, modified: modified, digest: "")
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                try visit(url.appendingPathComponent(name),
                          relative: relative.isEmpty ? name : relative + "/" + name)
            }
        case .typeSymbolicLink?:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            entries[relative] = SnapshotEntry(kind: "link", size: 0, modified: nil, digest: target)
        case .typeRegular?:
            entries[relative] = SnapshotEntry(
                kind: "file", size: size, modified: modified,
                digest: sha256(try Data(contentsOf: url)))
        default:
            entries[relative] = SnapshotEntry(
                kind: String(describing: type), size: size, modified: modified, digest: "")
        }
    }
    try visit(root, relative: "")
    return entries
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Bytes that differ from file to file, so a copy that mixed files up fails.
func sampleBytes(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

extension XCTestCase {
    /// A scratch folder under the repository's `.local/tmp`. The system
    /// temporary folder sits behind a symbolic link (`/var` → `/private/var`),
    /// which the no-link checks under test would rightly refuse. Teardown
    /// unlocks and removes everything, including unreadable test files.
    func makeScratchFolder() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(
            ".local/tmp/game-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { forceRemove(root) }
        return root
    }
}

/// Removes a test tree even when a test locked files or made them unreadable.
func forceRemove(_ root: URL) {
    if let enumerator = FileManager.default.enumerator(atPath: root.path) {
        for case let relative as String in enumerator {
            let path = root.appendingPathComponent(relative).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
            _ = lchflags(path, 0)
            _ = chmod(path, info.st_mode & S_IFMT == S_IFDIR ? 0o755 : 0o644)
        }
    }
    try? FileManager.default.removeItem(at: root)
}
