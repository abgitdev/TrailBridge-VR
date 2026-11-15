// SPDX-License-Identifier: MIT
import XCTest
@testable import BasaltBottleKit

/// Environments keep working when the path of the data folder changes: the
/// disk is renamed, macOS mounts it as "Name 1", or the folder is moved.
/// `bottle.json` and the launch profiles store absolute paths; they are
/// brought to the current data folder when read. A `bottle.json` still cannot
/// point the app outside its own bottle directory, and a data folder whose
/// path did not change loads exactly the stored values.
final class MovedDataFolderTests: XCTestCase {
    private let files = FileManager.default

    // MARK: Moved data folder

    func testEnvironmentsLoadAfterTheDataFolderIsRenamed() throws {
        let scratch = try makeScratchFolder()
        let old = WorkingGamesData(root: scratch.appendingPathComponent("Old Disk/TrailBridge Data"))
        try old.build()
        let metadata = try WorkingGames.bottles.map { try Data(contentsOf: old.metadata($0)) }
        let moved = try old.move(to: scratch.appendingPathComponent("Old Disk 1/Moved/Data"))
        let manager = moved.manager()

        for (name, bytes) in zip(WorkingGames.bottles, metadata) {
            let bottle = try manager.loadBottle(name)
            XCTAssertEqual(bottle.prefixPath, moved.prefix(name).path)
            XCTAssertEqual(bottle.engineRootPath, moved.engine(name).path)
            XCTAssertEqual(bottle.wineBinaryPath, moved.wine(name).path)
            XCTAssertTrue(bottle.isReadyForVR)
            XCTAssertEqual(bottle.engineID, BottleEngineDiscovery.pinnedDXMTEngineID)
            // What a bottle created in the new place stores.
            XCTAssertEqual(bottle.prefixPath, ManagedBottle(
                name: name, engine: moved.pinnedEngine(name),
                prefix: try manager.paths.bottleDirectory(name)
                    .appendingPathComponent("prefix", isDirectory: true),
                engineRoot: moved.engine(name), wineBinary: moved.wine(name)).prefixPath)
            // Resolved in memory: reading changes nothing on disk.
            XCTAssertEqual(try Data(contentsOf: moved.metadata(name)), bytes)
        }
        // The Library, game detection and Steam discovery read the list.
        XCTAssertEqual(try manager.listBottles(),
                       try WorkingGames.bottles.sorted().map { try manager.loadBottle($0) })
        XCTAssertFalse(files.fileExists(atPath: old.root.path), "something wrote to the old path")
    }

    func testLaunchProfilesOfAMovedEnvironmentStartTheGameInTheNewFolder() throws {
        let scratch = try makeScratchFolder()
        let old = WorkingGamesData(root: scratch.appendingPathComponent("Old Disk/TrailBridge Data"))
        try old.build()
        let stored = try old.profiles()
        let moved = try old.move(to: scratch.appendingPathComponent("New Disk/TrailBridge Data"))
        let runner = RefusingWineRunner()
        let manager = moved.manager(runner: runner)
        let control = scratch.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        for profile in stored {
            let name = profile.bottleName
            let command = try manager.profileLaunchCommand(profile.name, controlFile: control)
            XCTAssertEqual(command.executable.path, moved.wine(name).path)
            XCTAssertEqual(command.environment["WINEPREFIX"], moved.prefix(name).path)
            XCTAssertEqual(command.arguments, [profile.executable])
            // The Windows path of the game names an existing file of the new prefix,
            // and the game starts in that file's folder.
            let game = WorkingGamesData.hostURL(profile.executable, prefix: URL(
                fileURLWithPath: try XCTUnwrap(command.environment["WINEPREFIX"])))
            XCTAssertTrue(files.fileExists(atPath: game.path))
            XCTAssertEqual(command.currentDirectory?.path, game.deletingLastPathComponent().path)
            XCTAssertEqual(command.environment["TMPDIR"],
                           moved.bottle(name).appendingPathComponent("host/tmp").path)
            XCTAssertEqual(command.environment["XDG_CACHE_HOME"],
                           moved.bottle(name).appendingPathComponent("host/cache").path)
            XCTAssertEqual(try manager.prefixCommand(forProfile: profile.name)
                .environment["WINEPREFIX"], moved.prefix(name).path)
            // The profile file itself is read as stored.
            XCTAssertEqual(try manager.loadProfile(profile.name), profile)
        }
        XCTAssertEqual(try manager.openVRTargets(profileName: "brutalistick-vr-steam").map(\.path),
                       [moved.openVRDLL.path])
        XCTAssertEqual(runner.calls, [])
        XCTAssertFalse(files.fileExists(atPath: old.root.path), "something wrote to the old path")
    }

    /// `bottle.json` already has the new paths (saved by the app after the
    /// move, or edited by hand), the profiles still have the old ones.
    func testAStaleProfileStillPointsIntoItsOwnEnvironment() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Disk/Data"))
        try data.build()
        let manager = data.manager()
        let elsewhere = "/Volumes/Old Disk/Data"
        let game = "drive_c/Program Files (x86)/Steam/steamapps/common/BrutalistickVR"
        let outside = scratch.appendingPathComponent("BSManager/Instance", isDirectory: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.saveProfile(LaunchProfile(
            name: "stale", bottleName: "brutalistick-vr", source: .steam,
            executable: WorkingGames.profiles[0].executable,
            workingDirectory: "\(elsewhere)/Bottles/brutalistick-vr/prefix/\(game)",
            gameRoot: "\(elsewhere)/Bottles/brutalistick-vr/prefix/\(game)"))
        // A folder that never was inside the environment stays as the user set it.
        try manager.saveProfile(LaunchProfile(
            name: "outside", bottleName: "brutalistick-vr", source: .direct,
            executable: WorkingGames.profiles[0].executable, workingDirectory: outside.path))
        // Another environment's prefix is not this one's.
        try manager.saveProfile(LaunchProfile(
            name: "other", bottleName: "brutalistick-vr", source: .direct,
            executable: WorkingGames.profiles[0].executable,
            workingDirectory: "\(elsewhere)/Bottles/blood-trail/prefix/drive_c"))
        let control = scratch.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        XCTAssertEqual(
            try manager.profileLaunchCommand("stale", controlFile: control).currentDirectory?.path,
            data.prefix("brutalistick-vr").appendingPathComponent(game).path)
        XCTAssertEqual(try manager.openVRTargets(profileName: "stale").map(\.path),
                       [data.openVRDLL.path])
        XCTAssertEqual(
            try manager.profileLaunchCommand("outside", controlFile: control).currentDirectory?.path,
            outside.path)
        XCTAssertEqual(
            try manager.profileLaunchCommand("other", controlFile: control).currentDirectory?.path,
            "\(elsewhere)/Bottles/blood-trail/prefix/drive_c")
    }

    /// The app saves `bottle.json` when it changes the bottle (here: the
    /// runtime gets registered). That save, an atomic replace made after the
    /// bottle loaded, is what records the new paths.
    func testTheNextSaveOfAMovedBottleRecordsTheNewPaths() throws {
        let scratch = try makeScratchFolder()
        let old = WorkingGamesData(root: scratch.appendingPathComponent("Old Disk/Data"))
        try old.build(runtimeInstalled: false)
        let moved = try old.move(to: scratch.appendingPathComponent("New Disk/Data"))
        let bin = moved.repo.appendingPathComponent("runtime/build/bin", isDirectory: true)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: bin.appendingPathComponent("basalt_openxr.dll"))
        try Data("{}".utf8).write(to: bin.appendingPathComponent("basalt_openxr.json"))
        let manager = moved.manager(runner: AcceptingRunner())

        let synced = try manager.syncRuntime(in: "blood-trail")
        XCTAssertTrue(synced.runtimeInstalled)
        let text = try String(contentsOf: moved.metadata("blood-trail"), encoding: .utf8)
        XCTAssertTrue(text.contains(#""prefixPath" : "\#(moved.prefix("blood-trail").path)""#))
        XCTAssertTrue(text.contains(#""engineRootPath" : "\#(moved.engine("blood-trail").path)""#))
        XCTAssertTrue(text.contains(#""wineBinaryPath" : "\#(moved.wine("blood-trail").path)""#))
        XCTAssertFalse(text.contains(old.root.path + "/"))
        XCTAssertEqual(try manager.loadBottle("blood-trail"), synced)
        XCTAssertTrue(files.fileExists(atPath: moved.prefix("blood-trail")
            .appendingPathComponent("drive_c/basalt/runtime/basalt_openxr.dll").path))

        // Deleting a moved environment removes it, and only it, in the new place.
        try manager.deleteBottle("brutalistick-vr")
        XCTAssertFalse(files.fileExists(atPath: moved.bottle("brutalistick-vr").path))
        XCTAssertEqual(try manager.listBottles().map(\.name), ["blood-trail"])
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["blood-trail-blood-trail"])
        XCTAssertFalse(files.fileExists(atPath: old.root.path), "something wrote to the old path")
    }

    // MARK: Wine's user-folder links

    func testUserFolderLinksOfAMovedEnvironmentAreRepointed() throws {
        let scratch = try makeScratchFolder()
        let old = WorkingGamesData(root: scratch.appendingPathComponent("Old Disk/Data"))
        try old.build()
        let name = "blood-trail"
        let foreign = scratch.appendingPathComponent("Elsewhere/Saved", isDirectory: true)
        try files.createDirectory(at: foreign, withIntermediateDirectories: true)
        try old.makeUserFolderLinks(name)
        try old.makeUserFolderLinks("brutalistick-vr")
        // A game's save written through the link before the move.
        try files.createDirectory(at: old.userHome(name).appendingPathComponent("Documents/My Games"),
                                  withIntermediateDirectories: true)
        try Data("save".utf8).write(to: old.userHome(name)
            .appendingPathComponent("Documents/My Games/slot1.sav"))
        let others = [
            ("Saved Games", foreign.path),
            ("Dangling", scratch.appendingPathComponent("Gone/host/folders/Documents").path),
            ("Other Bottle", old.hostFolder("brutalistick-vr", "Documents").path),
            ("Relative", "../Public"),
        ]
        for (link, target) in others {
            try files.createSymbolicLink(
                atPath: old.userHome(name).appendingPathComponent(link).path,
                withDestinationPath: target)
        }
        let moved = try old.move(to: scratch.appendingPathComponent("New Disk/Data"))
        let home = moved.userHome(name)
        XCTAssertFalse(files.fileExists(atPath: home.appendingPathComponent("Documents").path),
                       "the link should dangle after the move")

        let runner = RefusingWineRunner()
        _ = try moved.manager(runner: runner).applicationLaunchCommand(
            bottleName: name, executable: #"C:\windows\notepad.exe"#)

        for folder in WorkingGamesData.userFolders {
            XCTAssertEqual(
                try files.destinationOfSymbolicLink(atPath: home.appendingPathComponent(folder).path),
                moved.hostFolder(name, folder).path)
        }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(
            "Documents/My Games/slot1.sav"), encoding: .utf8), "save")
        for (link, target) in others {
            XCTAssertEqual(
                try files.destinationOfSymbolicLink(atPath: home.appendingPathComponent(link).path),
                target)
        }
        // A real folder stays a folder, and no work name is left behind.
        XCTAssertNil(try? files.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent("AppData").path))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: home.path).sorted(),
                       (WorkingGamesData.userFolders + others.map(\.0) + ["AppData"]).sorted())
        // The environment that was not started keeps its old links.
        XCTAssertEqual(
            try files.destinationOfSymbolicLink(atPath: moved.userHome("brutalistick-vr")
                .appendingPathComponent("Documents").path),
            old.hostFolder("brutalistick-vr", "Documents").path)
        XCTAssertEqual(runner.calls, [])
        XCTAssertFalse(files.fileExists(atPath: old.root.path), "something wrote to the old path")
    }

    func testCurrentUserFolderLinksAreNotRewritten() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Data"))
        try data.build()
        let name = "blood-trail"
        try data.makeUserFolderLinks(name)
        let home = data.userHome(name)
        // A real folder where a link could be, and a link to somewhere else.
        try files.removeItem(at: home.appendingPathComponent("Music"))
        try files.createDirectory(at: home.appendingPathComponent("Music"),
                                  withIntermediateDirectories: false)
        try files.removeItem(at: home.appendingPathComponent("Videos"))
        try files.createSymbolicLink(atPath: home.appendingPathComponent("Videos").path,
                                     withDestinationPath: scratch.appendingPathComponent("Movies").path)
        let manager = data.manager()
        // The first command makes the bottle's host folders; links are judged after it.
        _ = try manager.applicationLaunchCommand(bottleName: name, executable: "notepad.exe")
        let before = try linkStates(in: home)
        XCTAssertEqual(before.count, WorkingGamesData.userFolders.count + 2)

        _ = try manager.applicationLaunchCommand(bottleName: name, executable: "notepad.exe")
        _ = try manager.prefixCommand(forProfile: "blood-trail-blood-trail")
        XCTAssertEqual(try linkStates(in: home), before)
    }

    /// A `users` folder reached through a link is not this bottle's to change,
    /// even when the links in it have the shape of a moved data folder.
    func testLinksBehindALinkedUsersFolderAreNotTouched() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Data"))
        try data.build()
        let name = "blood-trail"
        let outside = scratch.appendingPathComponent("Elsewhere/users/ada", isDirectory: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        let stale = "/Volumes/Old Disk/Data/Bottles/\(name)/host/folders/Documents"
        try files.createSymbolicLink(atPath: outside.appendingPathComponent("Documents").path,
                                     withDestinationPath: stale)
        try files.createSymbolicLink(
            at: data.prefix(name).appendingPathComponent("drive_c/users"),
            withDestinationURL: outside.deletingLastPathComponent())
        // The same for a user's own folder that is a link.
        let other = "brutalistick-vr"
        try files.createDirectory(at: data.userHome(other).deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.createSymbolicLink(at: data.userHome(other), withDestinationURL: outside)

        _ = try data.manager().applicationLaunchCommand(bottleName: name, executable: "notepad.exe")
        _ = try data.manager().applicationLaunchCommand(bottleName: other, executable: "notepad.exe")
        XCTAssertEqual(try files.destinationOfSymbolicLink(
            atPath: outside.appendingPathComponent("Documents").path), stale)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: outside.path), ["Documents"])
    }

    /// Every entry of `folder` with its own inode, modification time and, for
    /// a link, target, plus the folder's own: any rewrite changes one of them.
    private func linkStates(in folder: URL) throws -> [String: String] {
        var states = [String: String]()
        for entry in try files.contentsOfDirectory(atPath: folder.path) + ["."] {
            var info = stat()
            XCTAssertEqual(lstat(folder.appendingPathComponent(entry).path, &info), 0)
            let target = try? files.destinationOfSymbolicLink(
                atPath: folder.appendingPathComponent(entry).path)
            states[entry] = "\(info.st_ino) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) "
                + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec) \(target ?? "-")"
        }
        return states
    }

    // MARK: Unchanged path

    func testAnUnchangedDataFolderLoadsExactlyTheStoredValues() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Game Disk/Data"))
        try data.build()
        let profiles = try data.profiles()
        let manager = data.manager()
        let control = scratch.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let before = try snapshot(data.root)

        var stored = [ManagedBottle]()
        for name in WorkingGames.bottles {
            let written = try decoder.decode(
                ManagedBottle.self, from: Data(contentsOf: data.metadata(name)))
            stored.append(written)
            let bottle = try manager.loadBottle(name)
            XCTAssertEqual(bottle, written)
            XCTAssertEqual(bottle.prefixPath, "\(data.root.path)/Bottles/\(name)/prefix")
            XCTAssertEqual(bottle.engineRootPath, "\(data.root.path)/Bottles/\(name)/engine")
            XCTAssertEqual(bottle.wineBinaryPath, "\(data.root.path)/Bottles/\(name)/engine/bin/wine")
        }
        XCTAssertEqual(try manager.listBottles(), stored.sorted { $0.name < $1.name })
        XCTAssertEqual(try manager.listProfiles(), profiles.sorted { $0.name < $1.name })
        XCTAssertEqual(try snapshot(data.root), before)

        for profile in profiles {
            let bottle = try XCTUnwrap(stored.first { $0.name == profile.bottleName })
            let command = try manager.profileLaunchCommand(profile.name, controlFile: control)
            XCTAssertEqual(command.executable, URL(fileURLWithPath: bottle.wineBinaryPath))
            XCTAssertEqual(command.environment["WINEPREFIX"], bottle.prefixPath)
            XCTAssertEqual(command.currentDirectory, URL(
                fileURLWithPath: try XCTUnwrap(profile.workingDirectory), isDirectory: true))
            XCTAssertEqual(command.arguments, [profile.executable])
        }
        // A launch makes the bottle's host folders and nothing else: the
        // metadata and the profiles keep their bytes.
        let after = try snapshot(data.root)
        for (path, entry) in before where path.hasSuffix(".json") {
            XCTAssertEqual(after[path], entry, path)
        }
        XCTAssertEqual(before.keys.filter { $0.hasSuffix(".json") }.count, 4)
        XCTAssertEqual(try manager.openVRTargets(profileName: "brutalistick-vr-steam").map(\.path),
                       [data.openVRDLL.path])
    }

    /// A stored path that names the current place in another spelling loaded
    /// as written before, and still does.
    func testAStoredPathInAnotherSpellingIsKeptAsWritten() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Data"))
        try data.build()
        let spelled = data.prefix("blood-trail").path + "/"
        try data.writeMetadata("blood-trail", prefix: spelled)
        XCTAssertEqual(try data.manager().loadBottle("blood-trail").prefixPath, spelled)
        XCTAssertEqual(try data.manager().listBottles().first?.prefixPath, spelled)
    }

    // MARK: A bottle.json cannot point outside its own bottle

    func testBottleMetadataCannotPointOutsideItsOwnDirectory() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Data"))
        try data.build()
        let manager = data.manager()
        let name = "blood-trail"
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        for folder in ["prefix/drive_c", "engine/bin", "Bottles/\(name)/prefix/drive_c",
                       "Bottles/\(name)/engine/bin"] {
            try files.createDirectory(at: elsewhere.appendingPathComponent(folder),
                                      withIntermediateDirectories: true)
        }
        for wine in ["engine/bin/wine", "Bottles/\(name)/engine/bin/wine"] {
            try WorkingGamesData.writeWine(elsewhere.appendingPathComponent(wine))
        }
        func assertRefused(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try manager.loadBottle(name), message, file: file, line: line)
            XCTAssertThrowsError(try manager.prefixCommand(forProfile: "blood-trail-blood-trail"),
                                 message, file: file, line: line)
        }

        try data.writeMetadata(name, prefix: elsewhere.appendingPathComponent("prefix").path)
        assertRefused("a prefix outside the data folder")
        try data.writeMetadata(name, prefix: data.prefix("brutalistick-vr").path)
        assertRefused("another bottle's prefix")
        try data.writeMetadata(name, prefix: data.bottle(name).path)
        assertRefused("the bottle directory itself")
        try data.writeMetadata(name, prefix: data.prefix(name).path + "/drive_c")
        assertRefused("a folder below the prefix")
        try data.writeMetadata(name, engineRoot: elsewhere.appendingPathComponent("engine").path,
                               wine: elsewhere.appendingPathComponent("engine/bin/wine").path)
        assertRefused("an engine outside the bottle")
        try data.writeMetadata(name, wine: elsewhere.appendingPathComponent("engine/bin/wine").path)
        assertRefused("a Wine outside the bottle")
        try data.writeMetadata(name, wine: data.engine(name).appendingPathComponent("bin/other").path)
        assertRefused("another program of the engine")

        // Paths that look like this bottle's under another root are the form a
        // moved data folder leaves. They load, as the bottle's own directory:
        // the folder they name is never used.
        let lookalike = elsewhere.appendingPathComponent("Bottles/\(name)")
        try data.writeMetadata(
            name, prefix: lookalike.appendingPathComponent("prefix").path,
            engineRoot: lookalike.appendingPathComponent("engine").path,
            wine: lookalike.appendingPathComponent("engine/bin/wine").path)
        let bottle = try manager.loadBottle(name)
        XCTAssertEqual(bottle.prefixPath, data.prefix(name).path)
        XCTAssertEqual(bottle.engineRootPath, data.engine(name).path)
        XCTAssertEqual(bottle.wineBinaryPath, data.wine(name).path)
        let command = try manager.prefixCommand(forProfile: "blood-trail-blood-trail")
        XCTAssertEqual(command.environment["WINEPREFIX"], data.prefix(name).path)
        XCTAssertEqual(command.executable.path, data.wine(name).path)

        // The bottle's own prefix must not be a link that leads outside.
        try data.writeMetadata(name)
        XCTAssertNoThrow(try manager.loadBottle(name))
        try files.removeItem(at: data.prefix(name))
        try files.createSymbolicLink(at: data.prefix(name),
                                     withDestinationURL: elsewhere.appendingPathComponent("prefix"))
        assertRefused("a prefix that is a link out of the data folder")
    }

    // MARK: Shared engine

    func testASharedEngineGetsThePathsDiscoveryGivesItNow() throws {
        let scratch = try makeScratchFolder()
        let data = WorkingGamesData(root: scratch.appendingPathComponent("Data"))
        try data.build()
        let manager = BottleManager(root: data.root, repoRoot: data.repo,
                                    fileManager: ToolkitFileManager(),
                                    runner: RefusingWineRunner())
        let toolkit = ToolkitFileManager.root
        let name = "blood-trail"

        // Stored where the engine used to be.
        try data.writeMetadata(
            name, kind: "gptk", engineID: "gptk-2",
            engineRoot: "/Applications/Old Toolkit.app/Contents/Resources/wine",
            wine: "/Applications/Old Toolkit.app/Contents/Resources/wine/bin/wine64")
        var bottle = try manager.loadBottle(name)
        XCTAssertEqual(bottle.engineRootPath, toolkit)
        XCTAssertEqual(bottle.wineBinaryPath, toolkit + "/bin/wine64")
        XCTAssertEqual(bottle.prefixPath, data.prefix(name).path)
        XCTAssertEqual(try manager.listBottles().first { $0.name == name }, bottle)

        // Stored where it is: unchanged.
        try data.writeMetadata(name, kind: "gptk", engineID: "gptk-2",
                               engineRoot: toolkit, wine: toolkit + "/bin/wine64")
        bottle = try manager.loadBottle(name)
        XCTAssertEqual(bottle.engineRootPath, toolkit)
        XCTAssertEqual(bottle.wineBinaryPath, toolkit + "/bin/wine64")

        // An engine the app does not find is never taken from the file.
        try data.writeMetadata(name, kind: "whisky", engineID: "not-installed",
                               engineRoot: toolkit, wine: toolkit + "/bin/wine64")
        XCTAssertThrowsError(try manager.loadBottle(name))
    }
}

/// A data folder with the two working environments, each with its own cloned
/// engine, `bottle.json` in the bytes the app writes, the games' files, and
/// the profiles `SteamInstallation.gameProfile` made.
private struct WorkingGamesData {
    let root: URL
    var repo: URL { root.deletingLastPathComponent().appendingPathComponent("repo") }

    func bottle(_ name: String) -> URL { root.appendingPathComponent("Bottles/\(name)") }
    func prefix(_ name: String) -> URL { bottle(name).appendingPathComponent("prefix") }
    func engine(_ name: String) -> URL { bottle(name).appendingPathComponent("engine") }
    func wine(_ name: String) -> URL { engine(name).appendingPathComponent("bin/wine") }
    func metadata(_ name: String) -> URL { bottle(name).appendingPathComponent("bottle.json") }
    var openVRDLL: URL {
        prefix("brutalistick-vr").appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/BrutalistickVR/"
                + "BrutalistickVR_Data/Plugins/x86_64/openvr_api.dll")
    }

    /// The folders Wine links from a user's Windows profile to the host.
    static let userFolders = ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"]

    func userHome(_ name: String) -> URL {
        prefix(name).appendingPathComponent("drive_c/users/ada", isDirectory: true)
    }

    func hostFolder(_ name: String, _ folder: String) -> URL {
        bottle(name).appendingPathComponent("host/folders/\(folder)")
    }

    /// What Wine leaves in a prefix made under this root: absolute links to
    /// the bottle's host folders, beside real folders.
    func makeUserFolderLinks(_ name: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: userHome(name).appendingPathComponent("AppData"),
                                  withIntermediateDirectories: true)
        for folder in Self.userFolders {
            try files.createDirectory(at: hostFolder(name, folder),
                                      withIntermediateDirectories: true)
            try files.createSymbolicLink(
                atPath: userHome(name).appendingPathComponent(folder).path,
                withDestinationPath: hostFolder(name, folder).path)
        }
    }

    func manager(runner: any BottleCommandRunning = RefusingWineRunner()) -> BottleManager {
        BottleManager(root: root, repoRoot: repo, runner: runner)
    }

    func pinnedEngine(_ name: String) -> BottleEngine {
        BottleEngine(id: BottleEngineDiscovery.pinnedDXMTEngineID, kind: .pinned,
                     wineBinary: wine(name),
                     wineserverBinary: engine(name).appendingPathComponent("bin/wineserver"),
                     root: engine(name), supportsBasaltDXMT: true)
    }

    /// The host file of a `C:\` path.
    static func hostURL(_ windowsPath: String, prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c").appendingPathComponent(
            windowsPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/"))
    }

    static func writeWine(_ url: URL) throws {
        try Data("#!/bin/sh\nexit 71\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `bottle.json` as the app's encoder writes it; a nil path is the
    /// bottle's own under this root.
    func writeMetadata(_ name: String, kind: String = "pinned",
                       engineID: String = BottleEngineDiscovery.pinnedDXMTEngineID,
                       prefix: String? = nil, engineRoot: String? = nil, wine: String? = nil,
                       runtimeInstalled: Bool = true) throws {
        try Data("""
            {
              "createdAt" : "2026-09-22T10:13:20Z",
              "dxmtInstalled" : true,
              "engineID" : "\(engineID)",
              "engineKind" : "\(kind)",
              "engineRootPath" : "\(engineRoot ?? self.engine(name).path)",
              "formatVersion" : 1,
              "name" : "\(name)",
              "prefixPath" : "\(prefix ?? self.prefix(name).path)",
              "runtimeInstalled" : \(runtimeInstalled),
              "wineBinaryPath" : "\(wine ?? self.wine(name).path)"
            }
            """.utf8).write(to: metadata(name))
    }

    func build(runtimeInstalled: Bool = true) throws {
        let files = FileManager.default
        try files.createDirectory(at: repo, withIntermediateDirectories: true)
        let manager = manager()
        try manager.prepare()
        for name in WorkingGames.bottles {
            try files.createDirectory(at: engine(name).appendingPathComponent("bin"),
                                      withIntermediateDirectories: true)
            try files.createDirectory(at: prefix(name).appendingPathComponent("drive_c"),
                                      withIntermediateDirectories: true)
            try Self.writeWine(wine(name))
            try Self.writeWine(engine(name).appendingPathComponent("bin/wineserver"))
            try writeMetadata(name, runtimeInstalled: runtimeInstalled)
        }
        for stored in WorkingGames.profiles {
            let game = Self.hostURL(stored.executable, prefix: prefix(stored.bottleName))
            try files.createDirectory(at: game.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: game)
            var profile = stored
            profile.workingDirectory = game.deletingLastPathComponent().path
            try manager.saveProfile(profile)
        }
        try files.createDirectory(at: openVRDLL.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: openVRDLL)
    }

    /// The profiles as their files store them.
    func profiles() throws -> [LaunchProfile] {
        try WorkingGames.profiles.map { profile in
            try JSONDecoder().decode(LaunchProfile.self, from: Data(contentsOf: root
                .appendingPathComponent("Profiles/\(profile.name).json")))
        }
    }

    /// Moves the data folder as a rename of the disk or of a parent folder
    /// does, leaving nothing at the old path.
    func move(to destination: URL) throws -> WorkingGamesData {
        let files = FileManager.default
        let moved = WorkingGamesData(root: destination)
        try files.createDirectory(at: destination.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.moveItem(at: root, to: destination)
        try files.moveItem(at: repo, to: moved.repo)
        try files.removeItem(at: root.deletingLastPathComponent())
        return moved
    }
}

/// Stands in for Wine and accepts every command.
private final class AcceptingRunner: BottleCommandRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        CommandOutput(status: 0, output: "")
    }
}

/// Reports Game Porting Toolkit 2 as installed, so discovery offers `gptk-2`.
private final class ToolkitFileManager: FileManager, @unchecked Sendable {
    static let root = "/Applications/Game Porting Toolkit 2.app/Contents/Resources/wine"

    override func isExecutableFile(atPath path: String) -> Bool {
        path == Self.root + "/bin/wine64" || path == Self.root + "/bin/wineserver"
            || super.isExecutableFile(atPath: path)
    }
}
