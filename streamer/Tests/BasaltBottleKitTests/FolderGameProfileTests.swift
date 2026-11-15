// SPDX-License-Identifier: MIT
import XCTest
@testable import BasaltBottleKit

/// The profile format around the optional `title`, `saveNewProfile`, and a
/// game added from a folder starting without any Steam step. The two working
/// Steam games keep byte-identical profile files.
final class FolderGameProfileTests: XCTestCase {
    /// The manager's encoder output for `WorkingGames.profiles`, recorded
    /// before the `title` field existed.
    private let workingProfileBytes = [
        #"""
        {
          "arguments" : [

          ],
          "bottleName" : "brutalistick-vr",
          "environment" : {
            "SteamAppId" : "2669380",
            "SteamGameId" : "2669380"
          },
          "executable" : "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BrutalistickVR\\BrutalistickVR.exe",
          "formatVersion" : 1,
          "gameRoot" : "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BrutalistickVR",
          "name" : "brutalistick-vr-steam",
          "source" : "steam",
          "workingDirectory" : "/Data/Bottles/brutalistick-vr/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/BrutalistickVR"
        }
        """#,
        #"""
        {
          "arguments" : [

          ],
          "bottleName" : "blood-trail",
          "environment" : {
            "BASALT_TOUCH_GRIP_PITCH_DEGREES" : "15",
            "SteamAppId" : "1032430",
            "SteamGameId" : "1032430"
          },
          "executable" : "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Blood Trail\\BTVR\\Binaries\\Win64\\BTVR-Win64-Shipping.exe",
          "formatVersion" : 1,
          "gameRoot" : "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Blood Trail",
          "name" : "blood-trail-blood-trail",
          "source" : "steam",
          "workingDirectory" : "/Data/Bottles/blood-trail/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Blood Trail/BTVR/Binaries/Win64"
        }
        """#,
    ]

    func testWorkingGameProfilesKeepTheirBytes() throws {
        let fixture = try GameFolderFixture(self)
        for bottle in WorkingGames.bottles { try fixture.makeBottle(bottle) }
        for (profile, expected) in zip(WorkingGames.profiles, workingProfileBytes) {
            let file = try fixture.manager.paths.profileFile(profile.name)
            try fixture.manager.saveProfile(profile)
            XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), expected)
            // Loading and saving again, as the profile editor does, keeps the bytes.
            try fixture.manager.saveProfile(try fixture.manager.loadProfile(profile.name))
            XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), expected)
            XCTAssertNil(try fixture.manager.loadProfile(profile.name).title)
        }
        fixture.assertWineNeverRan()
    }

    func testTitleIsOptionalAndLeftOutOfTheFileWhenNil() throws {
        // Saved before the field existed.
        let legacy = Data(#"""
            {"formatVersion":1,"name":"lab","bottleName":"test","source":"direct",\#
            "executable":"C:\\Lab.exe","arguments":[],"environment":{}}
            """#.utf8)
        let old = try JSONDecoder().decode(LaunchProfile.self, from: legacy)
        XCTAssertNil(old.title)
        XCTAssertEqual(old.executable, #"C:\Lab.exe"#)
        XCTAssertNil(old.gameRoot)

        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let untitled = LaunchProfile(
            name: "untitled", bottleName: "hello-xr", source: .direct,
            executable: #"C:\Games\untitled\game.exe"#)
        XCTAssertNil(untitled.title)
        try fixture.manager.saveNewProfile(untitled)
        let untitledFile = try Data(contentsOf: fixture.manager.paths.profileFile("untitled"))
        XCTAssertFalse(String(decoding: untitledFile, as: UTF8.self).contains(#""title""#))
        XCTAssertEqual(try fixture.manager.loadProfile("untitled"), untitled)

        let titled = LaunchProfile(
            name: "titled", bottleName: "hello-xr", source: .direct,
            executable: #"C:\Games\hello-xr\khr_hello_xr_d3d11.exe"#,
            gameRoot: #"C:\Games\hello-xr"#, title: "hello_xr")
        try fixture.manager.saveNewProfile(titled)
        let titledFile = try Data(contentsOf: fixture.manager.paths.profileFile("titled"))
        XCTAssertTrue(String(decoding: titledFile, as: UTF8.self).contains(#""title" : "hello_xr""#))
        XCTAssertEqual(try fixture.manager.loadProfile("titled"), titled)
        XCTAssertEqual(try fixture.manager.listProfiles().map(\.title), ["hello_xr", nil])
        XCTAssertEqual(LaunchProfile.currentFormatVersion, 1)
        XCTAssertEqual(titled.formatVersion, 1)
        fixture.assertWineNeverRan()
    }

    func testSaveNewProfileNeverReplacesAnExistingProfile() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("brutalistick-vr")
        try fixture.makeBottle("hello-xr")
        let working = try XCTUnwrap(WorkingGames.profiles.first)
        try fixture.manager.saveProfile(working)
        let file = try fixture.manager.paths.profileFile(working.name)
        let before = try Data(contentsOf: file)

        var intruder = LaunchProfile(
            name: working.name, bottleName: "hello-xr", source: .direct,
            executable: #"C:\Games\hello-xr\khr_hello_xr_d3d11.exe"#, title: "hello_xr")
        XCTAssertThrowsError(try fixture.manager.saveNewProfile(intruder)) { error in
            XCTAssertEqual(error as? BottleToolError,
                           BottleToolError("Launch profile 'brutalistick-vr-steam' already exists"))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        if pathconf(fixture.manager.paths.profiles.path, _PC_CASE_SENSITIVE) == 0 {
            // A case-insensitive volume holds one file for both spellings.
            intruder.name = "Brutalistick-VR-Steam"
            XCTAssertThrowsError(try fixture.manager.saveNewProfile(intruder))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }

        // Checked like saveProfile, and nothing is written for a bad profile.
        let invalid = [
            LaunchProfile(name: "../escape", bottleName: "hello-xr", source: .direct,
                          executable: #"C:\x.exe"#),
            LaunchProfile(name: "orphan", bottleName: "missing", source: .direct,
                          executable: #"C:\x.exe"#),
            LaunchProfile(name: "empty", bottleName: "hello-xr", source: .direct, executable: ""),
        ]
        for profile in invalid {
            XCTAssertThrowsError(try fixture.manager.saveNewProfile(profile), profile.name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.manager.paths.profiles.path), ["brutalistick-vr-steam.json"])

        intruder.name = "hello-xr"
        try fixture.manager.saveNewProfile(intruder)
        XCTAssertEqual(try fixture.manager.loadProfile("hello-xr"), intruder)
        XCTAssertEqual(try Data(contentsOf: file), before)
        fixture.assertWineNeverRan()
    }

    func testAGameAddedFromAFolderStartsDirectlyWithoutSteam() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let folder = fixture.games("hello-xr").appendingPathComponent("hello-xr", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sampleBytes(1024, seed: 9).write(to: folder.appendingPathComponent("khr_hello_xr_d3d11.exe"))
        let executable = #"C:\Games\hello-xr\khr_hello_xr_d3d11.exe"#
        let arguments = ["--graphics", "D3D11", "--space", "Local"]
        try fixture.manager.saveNewProfile(LaunchProfile(
            name: "hello-xr", bottleName: "hello-xr", source: .direct,
            executable: executable, arguments: arguments, workingDirectory: folder.path,
            gameRoot: #"C:\Games\hello-xr"#, title: "hello_xr"))

        XCTAssertNil(try fixture.manager.steamBootstrapCommand(forProfile: "hello-xr"))
        XCTAssertNil(try fixture.manager.installSteamWebHelperCompatibility(forProfile: "hello-xr"))
        XCTAssertNil(try fixture.manager.steamConnectionLogURL(forProfile: "hello-xr"))

        let control = fixture.scratch.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)
        let command = try fixture.manager.profileLaunchCommand("hello-xr", controlFile: control)
        XCTAssertEqual(command.arguments, [executable] + arguments)
        XCTAssertNil(command.environment["SteamAppId"])
        XCTAssertNil(command.environment["SteamGameId"])
        XCTAssertEqual(command.currentDirectory?.path, folder.path)
        XCTAssertEqual(command.environment["WINEPREFIX"], fixture.prefix("hello-xr").path)
        XCTAssertEqual(command.environment["DXMT_BASALT_IOSURFACE"], "1")
        fixture.assertWineNeverRan()
    }
}
