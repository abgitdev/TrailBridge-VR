import XCTest
@testable import BasaltBottleKit
@testable import BasaltManagerKit

final class AppWorkspaceTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testCheckoutKeepsItsFilesInDotLocal() throws {
        let repo = try makeCheckout()
        let workspace = AppWorkspace(repoRoot: repo, environment: [:], home: home)
        XCTAssertFalse(workspace.isPackaged)
        XCTAssertEqual(workspace.configFolder.path, repo.appendingPathComponent(".local/config").path)
        XCTAssertEqual(workspace.standardDataFolder.path, repo.appendingPathComponent(".local/data").path)
    }

    func testPackagedSupportRootWritesOnlyInTheSupportFolder() throws {
        let support = try makePackagedSupport()
        let workspace = AppWorkspace(repoRoot: support, environment: [:], home: home)
        XCTAssertTrue(workspace.isPackaged)
        let folder = "/Users/someone/Library/Application Support/TrailBridge VR"
        XCTAssertEqual(workspace.supportFolder.path, folder)
        XCTAssertEqual(workspace.configFolder.path, folder + "/config")
        XCTAssertEqual(workspace.standardDataFolder.path, folder + "/Data")
        for url in [workspace.configFolder, workspace.standardDataFolder] {
            XCTAssertFalse(url.path.hasPrefix(support.path), "nothing is written among the app's own files")
        }
    }

    func testSupportFolderVariableNamesAnotherFolder() throws {
        let support = try makePackagedSupport()
        let workspace = AppWorkspace(
            repoRoot: support, environment: ["TRAILBRIDGE_SUPPORT_DIR": "/Volumes/Games/TB"], home: home)
        XCTAssertEqual(workspace.configFolder.path, "/Volumes/Games/TB/config")
        XCTAssertEqual(workspace.standardDataFolder.path, "/Volumes/Games/TB/Data")
        // Empty counts as absent.
        let plain = AppWorkspace(repoRoot: support, environment: ["TRAILBRIDGE_SUPPORT_DIR": ""], home: home)
        XCTAssertEqual(plain.supportFolder.path, "/Users/someone/Library/Application Support/TrailBridge VR")
    }

    func testTheVariableDoesNotMoveACheckoutsFiles() throws {
        let repo = try makeCheckout()
        let workspace = AppWorkspace(
            repoRoot: repo, environment: ["TRAILBRIDGE_SUPPORT_DIR": "/Volumes/Games/TB"], home: home)
        XCTAssertEqual(workspace.configFolder.path, repo.appendingPathComponent(".local/config").path)
        XCTAssertEqual(workspace.standardDataFolder.path, repo.appendingPathComponent(".local/data").path)
    }

    /// `make package` output inside a checkout does not turn it into a packaged app.
    func testCheckoutThatAlsoHoldsPackagedFilesStaysACheckout() throws {
        let repo = try makeCheckout()
        try makePackagedFiles(in: repo)
        XCTAssertFalse(AppWorkspace(repoRoot: repo, environment: [:], home: home).isPackaged)
    }

    func testFolderWithNeitherLayoutIsTreatedAsACheckout() throws {
        let folder = try temporaryDirectory()
        let workspace = AppWorkspace(repoRoot: folder, environment: [:], home: home)
        XCTAssertFalse(workspace.isPackaged)
        XCTAssertEqual(workspace.standardDataFolder.path, folder.appendingPathComponent(".local/data").path)
    }

    /// A bundle whose support files are incomplete still starts packaged
    /// (`PackagedStart` goes by the marker), so it must not write beside them.
    func testSupportRootWithOnlyItsMarkerIsStillPackaged() throws {
        let resources = try temporaryDirectory()
        let support = resources.appendingPathComponent("BasaltVR", isDirectory: true)
        try write(support.appendingPathComponent("BasaltVR.support.json"))
        XCTAssertNotNil(PackagedStart.plan(environment: [:], resourceURL: resources))
        XCTAssertFalse(RepositoryLocator.hasPackagedLayout(support))

        let workspace = AppWorkspace(repoRoot: support, environment: [:], home: home)
        XCTAssertTrue(workspace.isPackaged)
        let folder = "/Users/someone/Library/Application Support/TrailBridge VR"
        XCTAssertEqual(workspace.configFolder.path, folder + "/config")
        XCTAssertEqual(workspace.standardDataFolder.path, folder + "/Data")
        let start = DataFolderStart.choose(environment: nil, saved: nil, workspace: workspace)
        for url in [workspace.configFolder, workspace.standardDataFolder, start.folder] {
            XCTAssertFalse(url.path.hasPrefix(support.path), "nothing is written among the app's own files")
        }
    }

    // MARK: - The data folder at start

    func testPackagedAppStartsInTheSupportFoldersDataFolder() throws {
        let support = try makePackagedSupport()
        let workspace = AppWorkspace(repoRoot: support, environment: [:], home: home)
        let start = DataFolderStart.choose(environment: nil, saved: nil, workspace: workspace)
        XCTAssertEqual(start.source, .standard)
        XCTAssertEqual(start.folder.path,
                       "/Users/someone/Library/Application Support/TrailBridge VR/Data")
    }

    func testPackagedAppOpensTheFolderSavedInSettingsOnAnyDisk() throws {
        let support = try makePackagedSupport()
        let workspace = AppWorkspace(repoRoot: support, environment: [:], home: home)
        for saved in ["/Volumes/Games/TrailBridge", "/Volumes/nas/share/TrailBridge", "/Users/someone/Games"] {
            let start = DataFolderStart.choose(environment: nil, saved: saved, workspace: workspace)
            XCTAssertEqual(start.source, .saved)
            XCTAssertEqual(start.folder.path, saved)
        }
    }

    func testPackagedAppHonorsAnExplicitDataFolderVariable() throws {
        let support = try makePackagedSupport()
        let workspace = AppWorkspace(repoRoot: support, environment: [:], home: home)
        let start = DataFolderStart.choose(
            environment: "/Volumes/Games/Other", saved: "/Volumes/Games/TrailBridge", workspace: workspace)
        XCTAssertEqual(start.source, .environment)
        XCTAssertEqual(start.folder.path, "/Volumes/Games/Other")
        // The standard folder named by the variable is not a choice.
        let standard = DataFolderStart.choose(
            environment: workspace.standardDataFolder.path, saved: "/Volumes/Games/TrailBridge",
            workspace: workspace)
        XCTAssertEqual(standard.source, .saved)
    }

    // MARK: - Packaged start

    func testPackagedAppStartsFromTheSupportFilesInItsBundle() throws {
        let resources = try temporaryDirectory()
        try makePackagedFiles(in: resources.appendingPathComponent("BasaltVR", isDirectory: true))
        let plan = try XCTUnwrap(PackagedStart.plan(
            environment: ["PATH": "/usr/bin:/bin"], resourceURL: resources))
        XCTAssertEqual(plan.supportRoot.path, resources.appendingPathComponent("BasaltVR").path)
        XCTAssertNil(plan.path, "a PATH that is there stays")
        XCTAssertEqual(plan.environment, ["BASALT_REPO_ROOT": plan.supportRoot.path])
        // What the app then finds is that folder, and it is a packaged one.
        let found = try RepositoryLocator.find(
            startingAt: URL(fileURLWithPath: "/"), environment: plan.environment)
        XCTAssertEqual(found.path, plan.supportRoot.standardizedFileURL.path)
        XCTAssertTrue(AppWorkspace(repoRoot: found, environment: [:], home: home).isPackaged)
    }

    func testPackagedStartGivesAnEmptyPathTheSystemDefault() throws {
        let resources = try temporaryDirectory()
        try makePackagedFiles(in: resources.appendingPathComponent("BasaltVR", isDirectory: true))
        for environment in [[:], ["PATH": ""]] {
            let plan = try XCTUnwrap(PackagedStart.plan(environment: environment, resourceURL: resources))
            XCTAssertEqual(plan.path, "/usr/bin:/bin:/usr/sbin:/sbin")
            XCTAssertEqual(plan.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        }
    }

    func testAppStartedThroughTheDevelopmentScriptIsLeftAlone() throws {
        let resources = try temporaryDirectory()
        try makePackagedFiles(in: resources.appendingPathComponent("BasaltVR", isDirectory: true))
        XCTAssertNil(PackagedStart.plan(
            environment: ["BASALT_REPO_ROOT": "/project/trailbridge"], resourceURL: resources))
    }

    func testAppWithoutSupportFilesInItsBundleIsNotPackaged() throws {
        let resources = try temporaryDirectory()
        XCTAssertNil(PackagedStart.plan(environment: [:], resourceURL: resources))
        XCTAssertNil(PackagedStart.plan(environment: [:], resourceURL: nil))
        // The development app bundle has an icon and licenses there, nothing more.
        try Data().write(to: resources.appendingPathComponent("AppIcon.icns"))
        XCTAssertNil(PackagedStart.plan(environment: [:], resourceURL: resources))
    }

    // MARK: - Fixtures

    private func makeCheckout() throws -> URL {
        let repo = try temporaryDirectory()
        for file in ["runtime/CMakeLists.txt", "streamer/Package.swift"] {
            try write(repo.appendingPathComponent(file))
        }
        return repo
    }

    private func makePackagedSupport() throws -> URL {
        let support = try temporaryDirectory().appendingPathComponent(
            "TrailBridge VR.app/Contents/Resources/BasaltVR", isDirectory: true)
        try makePackagedFiles(in: support)
        return support
    }

    private func makePackagedFiles(in folder: URL) throws {
        for file in ["BasaltVR.support.json", "runtime/build/bin/basalt_openxr.dll",
                     "runtime/build/bin/basalt_openxr.json", "docs/BOTTLES.md"] {
            try write(folder.appendingPathComponent(file))
        }
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
