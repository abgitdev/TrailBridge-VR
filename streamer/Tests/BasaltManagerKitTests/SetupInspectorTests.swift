import XCTest
@testable import BasaltBottleKit
@testable import BasaltManagerKit

/// The Setup checks a packaged app adds: Rosetta, and the Wine it can
/// download itself.
final class SetupInspectorTests: XCTestCase {
    func testRosettaIsInstalledWhenItsServiceIsThere() throws {
        let folder = try temporaryDirectory()
        let service = folder.appendingPathComponent("Library/Apple/usr/libexec/oahd")
        XCTAssertFalse(Rosetta.isInstalled(servicePath: service.path))
        try FileManager.default.createDirectory(
            at: service.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: service)
        XCTAssertTrue(Rosetta.isInstalled(servicePath: service.path))
        XCTAssertEqual(Rosetta.servicePath, "/Library/Apple/usr/libexec/oahd")
        XCTAssertEqual(Rosetta.installCommand, "softwareupdate --install-rosetta --agree-to-license")
        XCTAssertFalse(Rosetta.installCommand.contains("sudo"))
    }

    func testRosettaCheckComesRightAfterTheMacCheck() throws {
        let fixture = try makeFixture()
        let checks = inspector(fixture, rosetta: true).inspect()
        XCTAssertEqual(Array(checks.map(\.id).prefix(2)), ["mac", "rosetta"])
        XCTAssertEqual(Set(checks.map(\.id)).count, checks.count)
        let rosetta = try XCTUnwrap(checks.first { $0.id == "rosetta" })
        XCTAssertEqual(rosetta.status, .ready)
        XCTAssertTrue(rosetta.required)
        XCTAssertFalse(rosetta.isFixedOnSetupPage)
    }

    func testMissingRosettaAsksForTheCommandAndNeverRunsIt() throws {
        try XCTSkipUnless(isAppleSilicon, "the check is for Apple Silicon")
        let fixture = try makeFixture()
        let rosetta = try XCTUnwrap(inspector(fixture, rosetta: false).inspect().first { $0.id == "rosetta" })
        XCTAssertEqual(rosetta.status, .actionNeeded)
        XCTAssertTrue(rosetta.required)
        XCTAssertEqual(rosetta.detail, Rosetta.installCommand)
        XCTAssertEqual(rosetta.action, SetupInspector.copyRosettaCommandAction)
        XCTAssertTrue(rosetta.isFixedOnSetupPage)
    }

    func testWithNoPinnedWineTheEngineCheckOffersTheDownload() throws {
        let fixture = try makeFixture()
        let wine = try XCTUnwrap(inspector(fixture).inspect().first { $0.id == "wine" })
        XCTAssertEqual(wine.status, .actionNeeded)
        XCTAssertTrue(wine.required)
        XCTAssertEqual(wine.action, SetupInspector.downloadWineAction)
        XCTAssertTrue(wine.offersWineDownload)
        XCTAssertTrue(wine.isFixedOnSetupPage)
    }

    func testDownloadedWineTurnsTheEngineCheckReady() throws {
        let fixture = try makeFixture()
        try makeWine(at: BottleEngineDiscovery.downloadedWineRoot(dataRoot: fixture.data))
        try makeFile(fixture.repo.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so"))
        let wine = try XCTUnwrap(inspector(fixture).inspect().first { $0.id == "wine" })
        XCTAssertEqual(wine.status, .ready)
        XCTAssertFalse(wine.offersWineDownload)
        XCTAssertFalse(wine.isFixedOnSetupPage)
    }

    /// A download would not help: the Wine is there, the DXMT fork is not.
    func testWineWithoutTheDXMTForkPointsToTheBuildInstructions() throws {
        let fixture = try makeFixture()
        try makeWine(at: BottleEngineDiscovery.downloadedWineRoot(dataRoot: fixture.data))
        let wine = try XCTUnwrap(inspector(fixture).inspect().first { $0.id == "wine" })
        XCTAssertEqual(wine.status, .actionNeeded)
        XCTAssertEqual(wine.action, "Open Build Instructions")
        XCTAssertFalse(wine.offersWineDownload)
    }

    func testPackagedSupportFilesAreReadyWithoutABuild() throws {
        let fixture = try makeFixture()
        for file in ["runtime/build/bin/basalt_openxr.dll",
                     "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so"] {
            try makeFile(fixture.repo.appendingPathComponent(file))
        }
        let checks = inspector(fixture).inspect()
        XCTAssertEqual(checks.first { $0.id == "runtime" }?.status, .ready)
        XCTAssertEqual(checks.first { $0.id == "dxmt" }?.status, .ready)
        // The only required part left is the one the app downloads.
        let missing = checks.filter { $0.required && $0.status != .ready && $0.id != "mac" }
        XCTAssertEqual(missing.map(\.id), ["wine"])
        XCTAssertTrue(missing.allSatisfy(\.isFixedOnSetupPage))
    }

    // MARK: - Fixtures

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private func makeFixture() throws -> (repo: URL, data: URL) {
        let folder = try temporaryDirectory()
        let repo = folder.appendingPathComponent("TrailBridge VR.app/Contents/Resources/BasaltVR", isDirectory: true)
        let data = folder.appendingPathComponent("Volumes/Games/TrailBridge", isDirectory: true)
        for url in [repo, data] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (repo, data)
    }

    private func inspector(_ fixture: (repo: URL, data: URL), rosetta: Bool = true) -> SetupInspector {
        SetupInspector(repoRoot: fixture.repo,
                       manager: BottleManager(root: fixture.data, repoRoot: fixture.repo),
                       rosettaInstalled: { rosetta })
    }

    private func makeWine(at root: URL) throws {
        for name in ["bin/wine", "bin/wineserver"] {
            let executable = root.appendingPathComponent(name)
            try makeFile(executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try makeFile(root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"))
    }

    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }
}
