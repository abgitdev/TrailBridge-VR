import XCTest
import BasaltCore
@testable import BasaltManagerKit

/// The Setup check "adb" is ready only with an adb that can really run.
/// Everything here lives in temporary folders: no real adb, no real key.
final class HeadsetToolsTests: XCTestCase {
    private struct Folders {
        let repo: URL
        /// Outside the repository, as a data folder may be.
        let data: URL
        let home: URL
        let wrapper: URL
        let developer: URL
        let managed: URL
        let key: URL
    }

    private func folders() throws -> Folders {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let data = root.appendingPathComponent("elsewhere/data", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [repo, data, home] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return Folders(
            repo: repo, data: data, home: home,
            wrapper: repo.appendingPathComponent("scripts/tools/adb"),
            developer: repo.appendingPathComponent(".local/tools/platform-tools/adb"),
            managed: data.appendingPathComponent("Tools/platform-tools/adb"),
            key: home.appendingPathComponent(".android/adbkey"))
    }

    private func write(_ file: URL, executable: Bool = true) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: Data(),
            attributes: [.posixPermissions: executable ? 0o755 : 0o644]))
    }

    /// As the developer script sets PATH: the wrapper's folder first, then
    /// the developer copy's.
    private func adb(_ folders: Folders, path: [URL]? = nil) -> URL? {
        let path = path ?? [folders.wrapper.deletingLastPathComponent(),
                            folders.developer.deletingLastPathComponent()]
        return HeadsetTools.runnableADB(
            repoRoot: folders.repo, dataRoot: folders.data,
            environment: ["PATH": path.map(\.path).joined(separator: ":"), "HOME": folders.home.path],
            fallbackDirectories: [])
    }

    func testTheWrapperAloneIsNotAnADB() throws {
        let folders = try folders()
        // Nothing anywhere.
        XCTAssertNil(adb(folders))
        // The wrapper is found, as the locator finds it; nothing is behind it.
        try write(folders.wrapper)
        XCTAssertEqual(
            AlvrADBExecutableLocator.find(
                environment: ["PATH": folders.wrapper.deletingLastPathComponent().path],
                fallbackDirectories: [], dataRoot: folders.data),
            folders.wrapper)
        XCTAssertNil(adb(folders))
    }

    /// The wrapper's first branch: the developer copy runs only with this
    /// Mac's adb key.
    func testTheDeveloperCopyNeedsTheKey() throws {
        let folders = try folders()
        try write(folders.wrapper)
        try write(folders.developer)
        XCTAssertNil(adb(folders))
        // A folder of that name is not a key.
        try FileManager.default.createDirectory(at: folders.key, withIntermediateDirectories: true)
        XCTAssertNil(adb(folders))
        try FileManager.default.removeItem(at: folders.key)
        try write(folders.key, executable: false)
        XCTAssertEqual(adb(folders), folders.developer)
        // The key without the copy, or with a copy that cannot run.
        try FileManager.default.removeItem(at: folders.developer)
        XCTAssertNil(adb(folders))
        try write(folders.developer, executable: false)
        XCTAssertNil(adb(folders))
    }

    /// The wrapper's second branch: the copy the Headset page downloads
    /// into the data folder, wherever that folder is.
    func testTheDownloadedCopyCounts() throws {
        let folders = try folders()
        try write(folders.wrapper)
        try write(folders.managed, executable: false)
        XCTAssertNil(adb(folders))
        try FileManager.default.removeItem(at: folders.managed)
        try write(folders.managed)
        XCTAssertEqual(adb(folders), folders.managed)
        XCTAssertFalse(folders.data.path.hasPrefix(folders.repo.path))
        // A developer copy without the key changes nothing.
        try write(folders.developer)
        XCTAssertEqual(adb(folders), folders.managed)
        // With the key the developer copy comes first, as in the wrapper.
        try write(folders.key, executable: false)
        XCTAssertEqual(adb(folders), folders.developer)

        // Without the wrapper in PATH the locator finds the copy itself.
        let plain = try self.folders()
        try write(plain.managed)
        XCTAssertEqual(adb(plain, path: [plain.repo.appendingPathComponent("empty")]), plain.managed)
    }

    func testAnADBOutsideTheWrapperCountsAsItIs() throws {
        let folders = try folders()
        let other = folders.repo.deletingLastPathComponent().appendingPathComponent("bin/adb")
        try write(other)
        try write(folders.wrapper)
        // Before the wrapper in PATH: it is the one that runs.
        XCTAssertEqual(adb(folders, path: [other.deletingLastPathComponent(),
                                           folders.wrapper.deletingLastPathComponent()]), other)
        // After the wrapper: the wrapper runs, and it has nothing.
        XCTAssertNil(adb(folders, path: [folders.wrapper.deletingLastPathComponent(),
                                         other.deletingLastPathComponent()]))
        // No wrapper at all.
        XCTAssertEqual(adb(folders, path: [other.deletingLastPathComponent()]), other)
        // A wrapper of another checkout is just an adb.
        let foreign = folders.repo.deletingLastPathComponent().appendingPathComponent("other/scripts/tools/adb")
        try write(foreign)
        XCTAssertEqual(adb(folders, path: [foreign.deletingLastPathComponent()]), foreign)
    }

    /// PATH may reach the wrapper through a link: it is still the wrapper.
    func testTheWrapperIsKnownThroughALink() throws {
        let folders = try folders()
        try write(folders.wrapper)
        let link = folders.repo.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders.repo)
        let linked = link.appendingPathComponent("scripts/tools")
        XCTAssertNil(adb(folders, path: [linked]))
        try write(folders.managed)
        XCTAssertEqual(adb(folders, path: [linked]), folders.managed)
    }
}
