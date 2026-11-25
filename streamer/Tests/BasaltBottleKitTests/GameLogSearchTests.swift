// SPDX-License-Identifier: MIT
import XCTest
@testable import BasaltBottleKit

final class GameLogSearchTests: XCTestCase {
    // MARK: - Unity

    func testFindsTheUnityPlayerLogOfTheWineUserButNotOfPublic() throws {
        let prefix = try FakePrefix(test: self)
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let start = Date()
        let log = try prefix.write("users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/Player.log")
        // Public belongs to no one; a file there is not the game's.
        try prefix.write("users/Public/AppData/LocalLow/Example Studio/Electrician VR/Player.log")
        // Another game's folder beside it.
        try prefix.write("users/steamuser/AppData/LocalLow/Example Studio/Other Game/Player.log")

        let files = GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start)

        XCTAssertEqual(files.map(\.url.path), [log.path])
        XCTAssertEqual(files.map(\.engine), [.unity])
    }

    func testOnlyLogsWrittenSinceTheGameStartedCountAndTheRunBeforeComesFirst() throws {
        let prefix = try FakePrefix(test: self)
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let folder = "users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/"
        let start = Date(timeIntervalSinceNow: -60)
        let current = try prefix.write(folder + "Player.log", modified: start.addingTimeInterval(30))
        // The last session's log, which the player moved aside when it started.
        let previous = try prefix.write(folder + "Player-prev.log", modified: start.addingTimeInterval(-600))
        let search = GameLogSearch(prefix: prefix.prefix, executable: exe)

        XCTAssertEqual(search.files(since: start).map(\.url.path), [current.path])
        // A player that ran twice in one session: both runs, the first one first.
        try prefix.touch(previous, modified: start.addingTimeInterval(10))
        XCTAssertEqual(search.files(since: start).map(\.url.path), [previous.path, current.path])
        // A disk that keeps whole seconds may date a log just before the start.
        try prefix.touch(previous, modified: start.addingTimeInterval(-1))
        XCTAssertEqual(search.files(since: start).map(\.url.path), [previous.path, current.path])
        try prefix.touch(previous, modified: start.addingTimeInterval(-GameLogSearch.timeSlack - 1))
        XCTAssertEqual(search.files(since: start).map(\.url.path), [current.path])
        XCTAssertEqual(search.files(since: start.addingTimeInterval(60)), [])
    }

    func testOlderUnityVersionsWroteOutputLogInLocalLowOrBesideTheGame() throws {
        let prefix = try FakePrefix(test: self)
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let start = Date(timeIntervalSinceNow: -60)
        // Unity 2017.2 to 2018.
        let localLow = try prefix.write(
            "users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/output_log.txt",
            modified: start.addingTimeInterval(10))
        // Unity 5 to 2017.1, which needs no app.info.
        let beside = try prefix.write("Games/Electrician VR/ElectricianVR_Data/output_log.txt",
                                      modified: start.addingTimeInterval(20))
        let search = GameLogSearch(prefix: prefix.prefix, executable: exe)
        XCTAssertEqual(search.files(since: start).map(\.url.path), [localLow.path, beside.path])
        XCTAssertEqual(search.files(since: start).map(\.engine), [.unity, .unity])

        try FileManager.default.removeItem(at: beside.deletingLastPathComponent().appendingPathComponent("app.info"))
        try prefix.touch(localLow, modified: start.addingTimeInterval(-600))
        XCTAssertEqual(search.files(since: start).map(\.url.path), [beside.path])
    }

    func testALauncherUsesTheOnlyUnityPlayerBesideIt() throws {
        let prefix = try FakePrefix(test: self)
        let player = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let launcher = try prefix.write("Games/Electrician VR/Launcher.exe")
        let start = Date()
        let log = try prefix.write("users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/Player.log")
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: launcher).files(since: start)
            .map(\.url.path), [log.path])

        // Two players beside the launcher: neither is taken for it.
        let second = player.deletingLastPathComponent().appendingPathComponent("Benchmark_Data/app.info")
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Example Studio\nElectrician VR".utf8).write(to: second)
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: launcher).files(since: start), [])
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: player).files(since: start)
            .map(\.url.path), [log.path])
    }

    func testAppInfoNamesTheFolderAndNothingElse() throws {
        let prefix = try FakePrefix(test: self)
        let start = Date()
        try prefix.write("users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/Player.log")
        // Windows line ends, a byte order mark and the case of the executable.
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR",
                                       info: "\u{FEFF}Example Studio\r\nElectrician VR\r\n",
                                       executable: "ElectricianVR.EXE", dataFolder: "ElectricianVR_Data")
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start).count, 1)

        let info = exe.deletingLastPathComponent().appendingPathComponent("ElectricianVR_Data/app.info")
        let tooLarge = "Example Studio\nElectrician VR\n" + String(repeating: " ", count: GameLogSearch.maximumAppInfoBytes)
        for text in ["Example Studio", "../..\nElectrician VR", "Example Studio\nElectrician VR/../x", "", tooLarge] {
            try Data(text.utf8).write(to: info)
            XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [],
                           String(text.prefix(40)))
        }
        // Nor is an app.info that is a link read.
        try FileManager.default.removeItem(at: info)
        let elsewhere = prefix.root.appendingPathComponent("app.info")
        try Data("Example Studio\nElectrician VR".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: info, withDestinationURL: elsewhere)
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [])
    }

    // MARK: - Unreal

    func testFindsUnrealLogsInAppDataAndOnlyThenInTheGameFolder() throws {
        let prefix = try FakePrefix(test: self)
        let game = "Games/Blood Trail"
        let shipping = try prefix.write(game + "/BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe")
        let launcher = try prefix.write(game + "/BloodTrail.exe")
        try prefix.write(game + "/Engine/Binaries/Win64/CrashReportClient.exe")
        let start = Date(timeIntervalSinceNow: -60)
        let log = try prefix.write("users/steamuser/AppData/Local/BTVR/Saved/Logs/BTVR.log",
                                   modified: start.addingTimeInterval(20))
        // The last run's log, renamed when this one started.
        try prefix.write("users/steamuser/AppData/Local/BTVR/Saved/Logs/BTVR-backup-2026.11.20-10.00.00.log",
                         modified: start.addingTimeInterval(-3600))
        try prefix.write("users/steamuser/AppData/Local/BTVR/Saved/Logs/notes.txt")
        try prefix.write("users/steamuser/AppData/Local/Engine/Saved/Logs/Engine.log")
        // Beside the game, and older here than the log in AppData.
        let beside = try prefix.write(game + "/BTVR/Saved/Logs/BTVR.log", modified: start.addingTimeInterval(10))

        for exe in [shipping, launcher] {
            let files = GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start)
            XCTAssertEqual(files.map(\.url.path), [log.path], exe.lastPathComponent)
            XCTAssertEqual(files.map(\.engine), [.unreal], exe.lastPathComponent)
        }

        // A game that keeps its logs beside itself.
        try prefix.touch(log, modified: start.addingTimeInterval(-600))
        for exe in [shipping, launcher] {
            XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start)
                .map(\.url.path), [beside.path], exe.lastPathComponent)
        }
    }

    func testALauncherBesideSeveralProjectsTakesTheOneNamedLikeIt() throws {
        let prefix = try FakePrefix(test: self)
        let game = "Games/Blood Trail"
        let launcher = try prefix.write(game + "/BTVR.exe")
        try prefix.write(game + "/BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe")
        try prefix.write(game + "/Benchmark/Binaries/Win64/Benchmark-Win64-Shipping.exe")
        let start = Date()
        let log = try prefix.write("users/steamuser/AppData/Local/BTVR/Saved/Logs/BTVR.log")
        try prefix.write("users/steamuser/AppData/Local/Benchmark/Saved/Logs/Benchmark.log")

        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: launcher).files(since: start)
            .map(\.url.path), [log.path])
        // Named like neither: both are read.
        let other = try prefix.write(game + "/Play.exe")
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: other).files(since: start).count, 2)
    }

    // MARK: - Neither, and what is never read

    func testOtherGamesLinksAndPipesGiveNothing() throws {
        let prefix = try FakePrefix(test: self)
        let start = Date()
        let other = try prefix.write("Games/Custom/Custom.exe")
        try prefix.write("Games/Custom/custom.log")
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: other).files(since: start), [])

        // A log that is a link to a file elsewhere on the Mac is not read.
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let outside = prefix.root.appendingPathComponent("outside.log")
        try Data("private\n".utf8).write(to: outside)
        let folder = prefix.driveC.appendingPathComponent(
            "users/steamuser/AppData/LocalLow/Example Studio/Electrician VR", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Player.log"), withDestinationURL: outside)
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [])

        // Nor is a pipe, which would wait for a writer forever.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Player.log"))
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("Player.log").path, 0o600), 0)
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [])

        // Nor a log folder that is a link out of the prefix.
        let elsewhere = prefix.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("private\n".utf8).write(to: elsewhere.appendingPathComponent("Player.log"))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [])

        // A prefix without users has no logs to read.
        try FileManager.default.removeItem(at: prefix.driveC.appendingPathComponent("users"))
        XCTAssertEqual(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start), [])
    }

    func testALogIsCheckedAgainWhenItIsOpened() throws {
        let prefix = try FakePrefix(test: self)
        let exe = try prefix.unityGame(company: "Example Studio", product: "Electrician VR")
        let start = Date()
        let log = try prefix.write("users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/Player.log")
        let file = try XCTUnwrap(GameLogSearch(prefix: prefix.prefix, executable: exe).files(since: start).first)

        let opened = try XCTUnwrap(file.open())
        XCTAssertEqual(opened.size, 5)
        XCTAssertEqual(try opened.handle.readToEnd(), Data("line\n".utf8))

        // The same file must still have been written during this session.
        try prefix.touch(log, modified: start.addingTimeInterval(-60))
        XCTAssertNil(file.open())
        try prefix.touch(log, modified: start)
        XCTAssertNotNil(file.open())

        // A fresh regular file at the same path belongs to a different run.
        let moved = log.deletingLastPathComponent().appendingPathComponent("moved.log")
        try FileManager.default.moveItem(at: log, to: moved)
        try Data("new run\n".utf8).write(to: log)
        XCTAssertNil(file.open())

        // Swapped for a link after it was found.
        let outside = prefix.root.appendingPathComponent("outside.log")
        try Data("private\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)
        XCTAssertNil(file.open())

        // Moving the original file with its root cannot change the allowed root.
        try FileManager.default.removeItem(at: log)
        try FileManager.default.moveItem(at: moved, to: log)
        let movedRoot = prefix.root.appendingPathComponent("moved-prefix", isDirectory: true)
        try FileManager.default.moveItem(at: prefix.prefix, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: prefix.prefix, withDestinationURL: movedRoot)
        XCTAssertNil(file.open())
    }

    // MARK: - A profile's launch

    func testTheLaunchCommandSaysWhereTheGameWritesItsLog() throws {
        let steam = try SteamPrefix(test: self)
        let install = try steam.install(appID: "3256020", folder: "Electrician Simulator VR", files: [
            "Electrician Simulator VR.exe", "Electrician Simulator VR_Data/",
        ])
        let manager = try steam.manager(bottleName: "Steam")
        let control = steam.root.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)
        try manager.saveProfile(LaunchProfile(
            name: "steam", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#, arguments: ["-applaunch", "3256020"]))
        try manager.saveProfile(LaunchProfile(
            name: "direct", bottleName: "Steam", source: .direct,
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\Electrician Simulator VR\Electrician Simulator VR.exe"#))
        let expected = install.appendingPathComponent("Electrician Simulator VR.exe").standardizedFileURL.path

        for name in ["steam", "direct"] {
            let search = try XCTUnwrap(manager.profileLaunchCommand(name, controlFile: control).gameLog, name)
            XCTAssertEqual(search.executable.path, expected, name)
            XCTAssertEqual(search.prefix.path, steam.prefix.standardizedFileURL.path, name)
        }
        // A drive the prefix does not map is no path on this Mac.
        try manager.saveProfile(LaunchProfile(
            name: "elsewhere", bottleName: "Steam", source: .direct, executable: #"D:\Games\Game.exe"#))
        XCTAssertNil(try manager.profileLaunchCommand("elsewhere", controlFile: control).gameLog)
    }
}

/// A prefix with a Windows user, `steamuser`, and `Public`.
private struct FakePrefix {
    let root: URL
    let prefix: URL
    var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }

    init(test: XCTestCase) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltGameLogSearch-\(UUID().uuidString)", isDirectory: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        root = directory
        prefix = directory.appendingPathComponent("Bottles/game/prefix", isDirectory: true)
        for user in ["Public", "steamuser"] {
            try FileManager.default.createDirectory(
                at: driveC.appendingPathComponent("users/\(user)/AppData", isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    /// A file in drive_c, written now unless `modified` says otherwise.
    @discardableResult
    func write(_ path: String, modified: Date? = nil) throws -> URL {
        let url = driveC.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("line\n".utf8).write(to: url)
        if let modified { try touch(url, modified: modified) }
        return url
    }

    func touch(_ url: URL, modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// A Unity player: `Game.exe` beside `Game_Data/app.info`.
    func unityGame(company: String, product: String, info: String? = nil,
                   executable: String = "ElectricianVR.exe",
                   dataFolder: String = "ElectricianVR_Data") throws -> URL {
        let exe = try write("Games/Electrician VR/" + executable)
        let appInfo = exe.deletingLastPathComponent().appendingPathComponent(dataFolder + "/app.info")
        try FileManager.default.createDirectory(
            at: appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((info ?? "\(company)\n\(product)").utf8).write(to: appInfo)
        return exe
    }
}
