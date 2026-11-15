import XCTest
@testable import BasaltManagerKit

final class AppFootprintTests: XCTestCase {
    private let bundleID = "local.trailbridge.vr.manager"

    func testFindsEverythingTheAppLeavesWithSizes() throws {
        let fixture = try makeFixture()
        try makeFile(fixture.data.appendingPathComponent("Bottles/game/prefix/drive_c/game.exe"), bytes: 8192)
        try makeFile(fixture.data.appendingPathComponent("Profiles/game.json"))
        try makeFile(fixture.data.appendingPathComponent("SessionHistory.json"))
        // The marker of a session whose app died; a file the app does not
        // list would keep the folder from going whole.
        try makeFile(fixture.data.appendingPathComponent("ActiveSession.json"))
        try makeFile(fixture.preferences.appendingPathComponent("manager-preferences.json"))
        try makeFile(fixture.preferences.appendingPathComponent("learning.json"))
        let library = fixture.home.appendingPathComponent("Library")
        try makeFile(library.appendingPathComponent("Preferences/\(bundleID).plist"))
        try makeFile(library.appendingPathComponent("Saved Application State/\(bundleID).savedState/data.data"))
        try makeFile(fixture.userCache.appendingPathComponent("\(bundleID)/com.apple.metal/cache"))
        try makeFile(fixture.userCache.appendingPathComponent("org.winehq.wine/com.apple.metal/cache"))
        try makeFile(fixture.userCache.appendingPathComponent("com.other.app/cache"))
        try makeFile(fixture.temporary.appendingPathComponent("basalt-manager-1.control"))
        try makeFile(fixture.temporary.appendingPathComponent("BasaltVR-command-2.log"))
        try makeFile(fixture.temporary.appendingPathComponent("someone-else.log"))
        let upstream = library.appendingPathComponent("Application Support/BasaltVR/Profiles/cli.json")
        try makeFile(upstream)

        let items = AppFootprint.items(at: fixture.locations)
        let byGroup = Dictionary(grouping: items, by: \.group)
            .mapValues { $0.map(\.url.lastPathComponent).sorted() }

        XCTAssertEqual(byGroup[.games], ["data"],
                       "a folder holding only the app's entries goes whole; "
                       + "Application Support/BasaltVR is not listed unless asked for")
        XCTAssertEqual(byGroup[.settings],
                       ["learning.json", "\(bundleID).plist", "manager-preferences.json"])
        XCTAssertEqual(byGroup[.systemCaches],
                       ["\(bundleID)", "\(bundleID).savedState", "org.winehq.wine"])
        XCTAssertEqual(byGroup[.temporaryFiles], ["BasaltVR-command-2.log", "basalt-manager-1.control"])
        XCTAssertGreaterThanOrEqual(AppFootprint.totalBytes(items, in: .games), 8192)

        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        XCTAssertTrue(AppFootprint.items(at: fixture.locations).isEmpty,
                      "nothing is left, and the BasaltVR folder that stays does not count as left over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: upstream.path),
                      "the original BasaltVR app's default data folder stays")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.userCache.appendingPathComponent("com.other.app/cache").path),
            "other apps' caches stay")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.temporary.appendingPathComponent("someone-else.log").path))
    }

    /// A session history that was not one and a settings file that could not
    /// be read are kept beside the new ones under a `.damaged-` name. They
    /// are the app's files too, and go with it.
    func testFilesSetAsideAsDamagedAreTheAppsOwnAndGoWithIt() throws {
        let fixture = try makeFixture()
        let history = fixture.data.appendingPathComponent("SessionHistory.json")
        try makeFile(history)
        try makeFile(fixture.data.appendingPathComponent("Bottles/game/bottle.json"))
        let preferences = fixture.preferences.appendingPathComponent("manager-preferences.json")
        try makeFile(preferences)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let oldHistory = try DamagedFile.setAside(history, now: date)
        let oldPreferences = try DamagedFile.setAside(preferences, now: date)
        XCTAssertEqual(oldHistory.lastPathComponent, "SessionHistory.damaged-20270115T080000Z.json")
        XCTAssertEqual(oldPreferences.lastPathComponent, "manager-preferences.damaged-20270115T080000Z.json")
        try makeFile(history)
        try makeFile(preferences)
        // The same second again: another name, nothing replaced.
        XCTAssertEqual(try DamagedFile.setAside(history, now: date).lastPathComponent,
                       "SessionHistory.damaged-20270115T080000Z-2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldHistory.path))
        try makeFile(history)

        var items = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(items.filter { $0.group == .games }.map(\.url.lastPathComponent), ["data"],
                       "the folder still holds only the app's entries and goes whole")
        XCTAssertEqual(items.filter { $0.group == .settings }.map(\.url.lastPathComponent),
                       ["manager-preferences.json", "manager-preferences.damaged-20270115T080000Z.json"])

        // Beside the person's own file each of them is listed by itself.
        try makeFile(fixture.data.appendingPathComponent("my notes.txt"))
        try makeFile(fixture.data.appendingPathComponent("SessionHistory.damaged.json"))
        items = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(items.filter { $0.group == .games }.map(\.url.lastPathComponent), [
            "Bottles", "SessionHistory.damaged-20270115T080000Z-2.json",
            "SessionHistory.damaged-20270115T080000Z.json", "SessionHistory.json",
        ])
        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        AppFootprint.removeEmptyFolders(from: fixture.preferences, levels: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.data.path).sorted(),
                       ["SessionHistory.damaged.json", "my notes.txt"], "only what is not the app's stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.preferences.path))
    }

    func testOnlyNamesTheAppGivesCountAsSetAside() {
        XCTAssertTrue(DamagedFile.isSetAside("SessionHistory.damaged-20270115T080000Z.json", of: "SessionHistory.json"))
        XCTAssertTrue(DamagedFile.isSetAside("SessionHistory.damaged-20270115T080000Z-2.json", of: "SessionHistory.json"))
        for name in ["SessionHistory.json", "SessionHistory.damaged-.json", "SessionHistory.damaged.json",
                     "SessionHistory.damaged-20270115T080000Z.txt", "Other.damaged-20270115T080000Z.json",
                     "manager-preferences.damaged-20270115T080000Z.json"] {
            XCTAssertFalse(DamagedFile.isSetAside(name, of: "SessionHistory.json"), name)
        }
    }

    func testTheBasaltVRFolderGoesOnlyWhenAskedFor() throws {
        var fixture = try makeFixture()
        try makeFile(fixture.data.appendingPathComponent("Bottles/game/bottle.json"))
        let basaltVR = fixture.home.appendingPathComponent("Library/Application Support/BasaltVR")
        try makeFile(basaltVR.appendingPathComponent("Bottles/upstream-game/prefix/drive_c/game.exe"),
                     bytes: 8192)
        try makeFile(basaltVR.appendingPathComponent("Profiles/upstream-game.json"))

        let folder = try XCTUnwrap(AppFootprint.basaltVRFolder(at: fixture.locations),
                                   "the folder exists, so the choice is offered")
        XCTAssertEqual(folder.url, basaltVR.standardizedFileURL)
        XCTAssertEqual(folder.items.map(\.url), [basaltVR.standardizedFileURL])
        XCTAssertGreaterThanOrEqual(folder.bytes, 8192)

        let kept = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(kept.map(\.url.lastPathComponent), ["data"], "off unless chosen")

        fixture.locations.includesBasaltVRFolder = true
        let all = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(all.map(\.url.lastPathComponent), ["data", "BasaltVR"])
        XCTAssertEqual(AppFootprint.totalBytes(all), AppFootprint.totalBytes(kept) + folder.bytes,
                       "the total shown with the box ticked is what gets deleted")

        XCTAssertTrue(AppFootprint.remove(all).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: basaltVR.path))
        XCTAssertNil(AppFootprint.basaltVRFolder(at: fixture.locations), "no folder, no choice")
        XCTAssertTrue(AppFootprint.items(at: fixture.locations).isEmpty)
    }

    func testTheBasaltVRFolderKeepsFilesTheAppsToolsDidNotMake() throws {
        var fixture = try makeFixture()
        let basaltVR = fixture.home.appendingPathComponent("Library/Application Support/BasaltVR")
        try makeFile(basaltVR.appendingPathComponent("Profiles/cli.json"))
        try makeFile(basaltVR.appendingPathComponent("Something else/file"))

        fixture.locations.includesBasaltVRFolder = true
        let items = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Profiles"])
        AppFootprint.remove(items)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: basaltVR.path),
                       ["Something else"])
        XCTAssertNil(AppFootprint.basaltVRFolder(at: fixture.locations),
                     "nothing left there to offer")
    }

    func testTheBasaltVRFolderChosenAsDataFolderIsListedOnce() throws {
        let fixture = try makeFixture()
        // Written without the trailing slash a folder URL may carry.
        let basaltVR = URL(fileURLWithPath:
            fixture.home.appendingPathComponent("Library/Application Support/BasaltVR").path)
        try makeFile(basaltVR.appendingPathComponent("Bottles/game/bottle.json"))

        for included in [false, true] {
            let locations = AppFootprint.Locations(
                dataRoot: basaltVR, preferencesFolder: fixture.preferences, bundleIdentifier: bundleID,
                home: fixture.home, userCacheDirectory: fixture.userCache,
                temporaryDirectory: fixture.temporary, includesBasaltVRFolder: included)
            XCTAssertNil(AppFootprint.basaltVRFolder(at: locations),
                         "the app's own data folder is not a separate choice")
            XCTAssertEqual(AppFootprint.items(at: locations).map(\.url),
                           [basaltVR.standardizedFileURL], "listed once, and removed by default")
        }
    }

    func testNoBasaltVRFolderNoChoice() throws {
        var fixture = try makeFixture()
        try makeFile(fixture.data.appendingPathComponent("Profiles/game.json"))
        XCTAssertNil(AppFootprint.basaltVRFolder(at: fixture.locations))

        fixture.locations.includesBasaltVRFolder = true
        XCTAssertEqual(AppFootprint.items(at: fixture.locations).map(\.url.lastPathComponent), ["data"])
    }

    func testAChosenFolderKeepsTheUsersOwnFiles() throws {
        let fixture = try makeFixture()
        try makeFile(fixture.data.appendingPathComponent("Bottles/game/bottle.json"))
        try makeFile(fixture.data.appendingPathComponent("Tools/Android/adbkey"))
        try makeFile(fixture.data.appendingPathComponent("My notes.txt"))
        try makeFile(fixture.data.appendingPathComponent(".DS_Store"))

        let items = AppFootprint.items(at: fixture.locations).filter { $0.group == .games }
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Bottles", "Tools"])
        AppFootprint.remove(items)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.data.path).sorted(),
                       [".DS_Store", "My notes.txt"])
    }

    func testLinksAreRemovedNotFollowed() throws {
        let fixture = try makeFixture()
        let outside = try makeTemporaryFolder().appendingPathComponent("Games on another disk")
        try makeFile(outside.appendingPathComponent("game.exe"))
        try FileManager.default.createDirectory(at: fixture.data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.data.appendingPathComponent("Bottles"), withDestinationURL: outside)

        let items = AppFootprint.items(at: fixture.locations)
        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("game.exe").path),
                      "the link goes, the folder it points to stays")
    }

    func testHomeAndVolumeRootsAreNeverRemovedWhole() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(AppFootprint.dataFolderItems(home, fileManager: .default).contains(home.standardizedFileURL))
        XCTAssertFalse(AppFootprint.dataFolderItems(URL(fileURLWithPath: "/Volumes/Data"),
                                                    fileManager: .default)
            .contains(URL(fileURLWithPath: "/Volumes/Data")))
    }

    func testOnlyOldTemporaryFilesCountAsLeftOver() throws {
        let directory = try makeTemporaryFolder()
        let old = directory.appendingPathComponent("basalt-manager-old.control")
        let current = directory.appendingPathComponent("basalt-manager-now.control")
        try makeFile(old)
        try makeFile(current)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: old.path)

        XCTAssertEqual(AppFootprint.temporaryFiles(in: directory, olderThan: Date(timeIntervalSinceNow: -86_400)),
                       [old], "a running session's file is younger than a day and stays")
        XCTAssertEqual(AppFootprint.temporaryFiles(in: directory, olderThan: nil).count, 2)
    }

    /// A complete removal also takes the reports macOS wrote when the app or
    /// its streamer crashed; other apps' reports and Wine's, which other
    /// Wine apps write under the same names, stay.
    func testTheAppsAndTheStreamersCrashReportsGoOthersStay() throws {
        let fixture = try makeFixture()
        let reports = fixture.locations.diagnosticReportsFolder
        XCTAssertEqual(reports.path, fixture.home.appendingPathComponent("Library/Logs/DiagnosticReports").path)
        let ours = ["TrailBridgeVR-2026-01-01-120000.ips", "basalt-streamer-2026-01-02-120000.ips",
                    "TrailBridgeVR_2026-01-01-120000_Mac.cpu_resource.diag"]
        let others = ["Safari-2026-01-01-101010.ips", "wine64-preloader-2026-01-02-090909.ips",
                      "TrailBridgeVRHelper-2026-01-01-120000.ips", "basalt-streamerX-1.ips"]
        for name in ours + others { try makeFile(reports.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(
            at: reports.appendingPathComponent("TrailBridgeVR-folder"), withIntermediateDirectories: true)
        let elsewhere = try makeTemporaryFolder().appendingPathComponent("kept.ips")
        try makeFile(elsewhere)
        try FileManager.default.createSymbolicLink(
            at: reports.appendingPathComponent("basalt-streamer-link.ips"), withDestinationURL: elsewhere)

        let items = AppFootprint.items(at: fixture.locations).filter { $0.group == .crashReports }
        XCTAssertEqual(items.map(\.url.lastPathComponent).sorted(), ours.sorted())
        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: reports.path).sorted()
        XCTAssertEqual(left, (others + ["TrailBridgeVR-folder", "basalt-streamer-link.ips"]).sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    /// tccutil gets the bundle identifier only when it is a plain one.
    func testPermissionsAreResetForAPlainBundleIdentifierOnly() {
        XCTAssertEqual(AppPermissions.resetArguments(bundleIdentifier: bundleID), ["reset", "All", bundleID])
        for bad in ["", "-h", ".hidden", "local.trail bridge", "local/trailbridge", "local.trailbridgé",
                    "a;rm", String(repeating: "a", count: 256)] {
            XCTAssertNil(AppPermissions.resetArguments(bundleIdentifier: bad), bad)
        }
    }

    func testEmptyPreferenceFoldersGoButNotOnesStillInUse() throws {
        let root = try makeTemporaryFolder()
        let config = root.appendingPathComponent(".local/config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        AppFootprint.removeEmptyFolders(from: config, levels: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".local").path))

        let used = try makeTemporaryFolder().appendingPathComponent(".local/config")
        try makeFile(used.appendingPathComponent("swiftpm/configuration.json"))
        AppFootprint.removeEmptyFolders(from: used, levels: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.appendingPathComponent("swiftpm").path))
    }

    // MARK: - Packaged app

    /// A packaged app keeps its settings and its standard data folder in
    /// its support folder; all of it goes, and then the folder itself.
    func testPackagedAppLeavesNothingInItsSupportFolder() throws {
        let fixture = try makePackagedFixture()
        let support = fixture.support
        try makeFile(support.appendingPathComponent("config/manager-preferences.json"))
        try makeFile(support.appendingPathComponent("config/learning.json"))
        try makeFile(support.appendingPathComponent("config/manager-preferences.damaged-20270115T080000Z.json"))
        try makeFile(support.appendingPathComponent("Data/Bottles/game/prefix/drive_c/game.exe"), bytes: 8192)
        try makeFile(support.appendingPathComponent("Data/Profiles/game.json"))
        // The Wine the app downloaded, and an archive a killed download left.
        try makeFile(support.appendingPathComponent(
            "Data/Tools/wine-11.10/Wine Devel.app/Contents/Resources/wine/bin/wine"), bytes: 4096)
        try makeFile(support.appendingPathComponent("Data/Tools/.wine-11.10.partial/Wine Devel.app/x"))
        try makeFile(support.appendingPathComponent("Data/Downloads/wine-devel-11.10-osx64.tar.xz"))

        let items = AppFootprint.items(at: fixture.locations)
        let byGroup = Dictionary(grouping: items, by: \.group)
            .mapValues { $0.map(\.url.lastPathComponent).sorted() }
        XCTAssertEqual(byGroup[.games], ["Data"], "the standard data folder goes whole, Wine included")
        XCTAssertEqual(byGroup[.settings],
                       ["learning.json", "manager-preferences.damaged-20270115T080000Z.json",
                        "manager-preferences.json"])
        XCTAssertGreaterThanOrEqual(AppFootprint.totalBytes(items, in: .games), 8192 + 4096)
        for item in items {
            XCTAssertTrue(item.url.path.hasPrefix(support.standardizedFileURL.path + "/"), item.url.path)
        }

        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        AppFootprint.removeEmptyFolders(at: fixture.locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path),
                       "the support folder itself is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.deletingLastPathComponent().path),
                      "Application Support stays")
        XCTAssertTrue(AppFootprint.items(at: fixture.locations).isEmpty)
    }

    /// The data folder was moved to another disk: what the app stored in
    /// its standard folder before that is still its own, and goes too.
    func testPackagedAppWithAChosenDataFolderAlsoListsItsStandardOne() throws {
        var fixture = try makePackagedFixture()
        let support = fixture.support
        let chosen = try makeTemporaryFolder().appendingPathComponent("Volumes/Games/TrailBridge")
        fixture.locations.dataRoot = chosen
        try makeFile(chosen.appendingPathComponent("Bottles/new/bottle.json"))
        try makeFile(support.appendingPathComponent("Data/Bottles/old/bottle.json"))
        try makeFile(support.appendingPathComponent("config/manager-preferences.json"))

        let items = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(items.filter { $0.group == .games }.map(\.url.path),
                       [chosen.standardizedFileURL.path,
                        support.appendingPathComponent("Data").standardizedFileURL.path])
        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        AppFootprint.removeEmptyFolders(at: fixture.locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.path))
    }

    /// The standard folder in use is listed once, not twice.
    func testPackagedStandardDataFolderInUseIsListedOnce() throws {
        var fixture = try makePackagedFixture()
        try makeFile(fixture.support.appendingPathComponent("Data/Profiles/game.json"))
        for spelling in [fixture.support.appendingPathComponent("Data", isDirectory: true),
                         URL(fileURLWithPath: fixture.support.path + "/Data"),
                         URL(fileURLWithPath: fixture.support.path + "/config/../Data/")] {
            fixture.locations.dataRoot = spelling
            XCTAssertEqual(AppFootprint.items(at: fixture.locations).map(\.url.lastPathComponent), ["Data"],
                           spelling.path)
        }
    }

    /// Files the person keeps in the support folder are theirs: they stay,
    /// and so does the folder.
    func testPackagedSupportFolderWithOtherFilesStays() throws {
        let fixture = try makePackagedFixture()
        let support = fixture.support
        try makeFile(support.appendingPathComponent("config/learning.json"))
        try makeFile(support.appendingPathComponent("Data/Profiles/game.json"))
        try makeFile(support.appendingPathComponent("Data/my saves.zip"))
        try makeFile(support.appendingPathComponent("notes.txt"))

        let items = AppFootprint.items(at: fixture.locations)
        XCTAssertEqual(items.map(\.url.lastPathComponent).sorted(), ["Profiles", "learning.json"])
        XCTAssertTrue(AppFootprint.remove(items).isEmpty)
        AppFootprint.removeEmptyFolders(at: fixture.locations)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path).sorted(),
                       ["Data", "notes.txt"], "the empty config folder went, the rest stayed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("Data").path), ["my saves.zip"])
    }

    /// With no settings ever saved there is no config folder; the empty
    /// support folder still goes.
    func testPackagedSupportFolderGoesWithoutAConfigFolder() throws {
        let fixture = try makePackagedFixture()
        try makeFile(fixture.support.appendingPathComponent("Data/Profiles/game.json"))
        XCTAssertTrue(AppFootprint.remove(AppFootprint.items(at: fixture.locations)).isEmpty)
        AppFootprint.removeEmptyFolders(at: fixture.locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
    }

    /// Beside a checkout nothing changes: `.local/config`, then `.local`.
    func testCheckoutLocationsRemoveTheSameFoldersAsBefore() throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.locations.supportFolder)
        try makeFile(fixture.preferences.appendingPathComponent("learning.json"))
        XCTAssertTrue(AppFootprint.remove(AppFootprint.items(at: fixture.locations)).isEmpty)
        AppFootprint.removeEmptyFolders(at: fixture.locations)
        let local = fixture.preferences.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
    }

    // MARK: - Fixtures

    private struct PackagedFixture {
        let support: URL
        var locations: AppFootprint.Locations
    }

    /// The locations `AppWorkspace` gives a packaged app: settings and the
    /// standard data folder in Application Support/TrailBridge VR.
    private func makePackagedFixture() throws -> PackagedFixture {
        let root = try makeTemporaryFolder()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bundled = root.appendingPathComponent(
            "Applications/TrailBridge VR.app/Contents/Resources/BasaltVR", isDirectory: true)
        for file in ["BasaltVR.support.json", "runtime/build/bin/basalt_openxr.dll",
                     "runtime/build/bin/basalt_openxr.json", "docs/BOTTLES.md"] {
            try makeFile(bundled.appendingPathComponent(file))
        }
        let workspace = AppWorkspace(repoRoot: bundled, environment: [:], home: home)
        XCTAssertTrue(workspace.isPackaged)
        let userCache = root.appendingPathComponent("var/C", isDirectory: true)
        let temporary = root.appendingPathComponent("var/T", isDirectory: true)
        for folder in [home.appendingPathComponent("Library/Application Support"), userCache, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return PackagedFixture(
            support: workspace.supportFolder,
            locations: AppFootprint.Locations(
                dataRoot: workspace.standardDataFolder, preferencesFolder: workspace.configFolder,
                supportFolder: workspace.supportFolder, bundleIdentifier: bundleID,
                home: home, userCacheDirectory: userCache, temporaryDirectory: temporary))
    }

    private struct Fixture {
        let data: URL
        let preferences: URL
        let home: URL
        let userCache: URL
        let temporary: URL
        var locations: AppFootprint.Locations
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTemporaryFolder()
        let data = root.appendingPathComponent("disk/TrailBridge/data", isDirectory: true)
        let preferences = root.appendingPathComponent("support/.local/config", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let userCache = root.appendingPathComponent("var/C", isDirectory: true)
        let temporary = root.appendingPathComponent("var/T", isDirectory: true)
        for folder in [home, userCache, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return Fixture(
            data: data, preferences: preferences, home: home, userCache: userCache, temporary: temporary,
            locations: AppFootprint.Locations(
                dataRoot: data, preferencesFolder: preferences, bundleIdentifier: bundleID,
                home: home, userCacheDirectory: userCache, temporaryDirectory: temporary))
    }

    private func makeFile(_ url: URL, bytes: Int = 16) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppFootprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
