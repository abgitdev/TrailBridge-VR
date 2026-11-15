import XCTest
@testable import BasaltBottleKit

/// Where the pinned Wine is found: built in a checkout, or downloaded by
/// the app into its data folder.
final class EngineDiscoveryTests: XCTestCase {
    private let checkoutWine = "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine"
    private let downloadedWine = "Tools/wine-11.10/Wine Devel.app/Contents/Resources/wine"

    func testFindsTheWineDownloadedIntoTheDataFolder() throws {
        let fixture = try makeFixture()
        try makeWine(at: fixture.data.appendingPathComponent(downloadedWine))
        try makeFork(in: fixture.repo)

        let engines = BottleEngineDiscovery.discover(
            repoRoot: fixture.repo, dataRoot: fixture.data, home: fixture.home)
        XCTAssertEqual(engines.count, 1)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.id, BottleEngineDiscovery.pinnedDXMTEngineID)
        XCTAssertEqual(engine.kind, .pinned)
        XCTAssertTrue(engine.supportsBasaltDXMT)
        XCTAssertEqual(engine.root.path, fixture.data.appendingPathComponent(downloadedWine).path)
        XCTAssertEqual(engine.wineBinary.path, engine.root.appendingPathComponent("bin/wine").path)
        XCTAssertEqual(engine.wineserverBinary.path, engine.root.appendingPathComponent("bin/wineserver").path)
        XCTAssertEqual(BottleEngineDiscovery.downloadedWineRoot(dataRoot: fixture.data).path, engine.root.path)
    }

    func testCheckoutsOwnWineComesFirst() throws {
        let fixture = try makeFixture()
        try makeWine(at: fixture.repo.appendingPathComponent(checkoutWine))
        try makeWine(at: fixture.data.appendingPathComponent(downloadedWine))

        let engines = BottleEngineDiscovery.discover(
            repoRoot: fixture.repo, dataRoot: fixture.data, home: fixture.home)
        XCTAssertEqual(engines.map(\.id), [BottleEngineDiscovery.pinnedDXMTEngineID], "one engine, not two")
        XCTAssertEqual(engines.first?.root.path, fixture.repo.appendingPathComponent(checkoutWine).path)
        XCTAssertEqual(engines.first?.supportsBasaltDXMT, false, "the DXMT fork is not built here")
    }

    func testIncompleteDownloadedWineIsNotAnEngine() throws {
        for missing in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"] {
            let fixture = try makeFixture()
            let root = fixture.data.appendingPathComponent(downloadedWine)
            try makeWine(at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent(missing))
            XCTAssertEqual(BottleEngineDiscovery.discover(
                repoRoot: fixture.repo, dataRoot: fixture.data, home: fixture.home), [], missing)
            XCTAssertFalse(BottleEngineDiscovery.isUsablePinnedWine(root), missing)
        }
    }

    func testWithoutADataFolderOnlyTheCheckoutIsLookedAt() throws {
        let fixture = try makeFixture()
        try makeWine(at: fixture.data.appendingPathComponent(downloadedWine))
        XCTAssertEqual(BottleEngineDiscovery.discover(repoRoot: fixture.repo, home: fixture.home), [])
    }

    /// The manager and `basaltctl`, which lists engines through it, look in
    /// their own data folder, wherever it is.
    func testManagerFindsTheWineInItsOwnDataFolder() throws {
        let fixture = try makeFixture()
        try makeWine(at: fixture.data.appendingPathComponent(downloadedWine))
        let manager = BottleManager(root: fixture.data, repoRoot: fixture.repo)
        XCTAssertTrue(manager.engines().contains { $0.id == BottleEngineDiscovery.pinnedDXMTEngineID })

        let elsewhere = BottleManager(
            root: fixture.repo.appendingPathComponent("other-data"), repoRoot: fixture.repo)
        XCTAssertFalse(elsewhere.engines().contains { $0.kind == .pinned })
    }

    // MARK: - Fixtures

    private func makeFixture() throws -> (repo: URL, data: URL, home: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EngineDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let repo = folder.appendingPathComponent("support", isDirectory: true)
        // On another disk than the app, as far as any path can say.
        let data = folder.appendingPathComponent("Volumes/Games/TrailBridge", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        for url in [repo, data, home] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (repo, data, home)
    }

    private func makeWine(at root: URL) throws {
        let files = FileManager.default
        for name in ["bin/wine", "bin/wineserver"] {
            let executable = root.appendingPathComponent(name)
            try files.createDirectory(at: executable.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let driver = root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try files.createDirectory(at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: driver)
    }

    private func makeFork(in repo: URL) throws {
        let fork = repo.appendingPathComponent("runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fork)
    }
}
