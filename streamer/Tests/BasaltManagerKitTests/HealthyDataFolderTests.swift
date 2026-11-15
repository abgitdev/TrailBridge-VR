// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

/// A healthy data folder — two environments with their own pinned engine,
/// `blood-trail` and `brutalistick-vr`, one game each, no symbolic links on
/// the way — loads unchanged: the same lists, the same paths, the same launch
/// command, nothing reported as damaged, and not a byte of its files changed.
final class HealthyDataFolderTests: XCTestCase {
    func testAHealthyDataFolderLoadsUnchanged() throws {
        let scratch = try dataFolderScratch()
        let data = FakeDataFolder(root: scratch.appendingPathComponent(".local/data", isDirectory: true),
                                  repo: scratch)
        let root = data.root
        let names = ["blood-trail", "brutalistick-vr"]
        for name in names {
            try data.makeBottle(name)
            try data.manager.saveProfile(LaunchProfile(
                name: name, bottleName: name, source: .steam,
                executable: #"C:\Program Files (x86)\Steam\steamapps\common\Game\Game.exe"#,
                environment: ["SteamAppId": "1"], gameRoot: #"C:\Program Files (x86)\Steam\steamapps\common\Game"#,
                title: name))
        }
        let history = SessionHistoryStore(dataRoot: root)
        try history.save(names.map { SessionRecord(profileName: $0, settings: StreamLaunchSettings()) })
        let trust = HeadsetTrustStore(dataRoot: root)
        try trust.setTrusted("Quest-3", trusted: true)
        let preferencesFile = scratch.appendingPathComponent(".local/config/manager-preferences.json")
        let seed = WorkspacePreferences(fileURL: preferencesFile)
        try seed.set("ru", forKey: "app.language")
        try seed.set("brutalistick-vr", forKey: "BasaltVR.preferredProfile")
        let metadata = names.flatMap { [data.bottleJSON($0), data.profileJSON($0)] }
            + [history.file, trust.file, preferencesFile]
        let before = try metadata.map { try Data(contentsOf: $0) }

        // The start: no saved folder, so the default one, used as it is.
        let preferences = WorkspacePreferences(fileURL: preferencesFile)
        XCTAssertNil(preferences.loadError)
        XCTAssertFalse(preferences.isUnreadable(String.self, forKey: "BasaltVR.dataRoot"))
        XCTAssertEqual(preferences.string(forKey: "app.language"), "ru")
        let start = DataFolderStart.choose(
            environment: root.path, saved: preferences.string(forKey: "BasaltVR.dataRoot"), repoRoot: scratch)
        XCTAssertEqual(start, DataFolderStart(folder: root, source: .standard))
        XCTAssertEqual(DataFolderStart.resolved(start.folder).path, root.path, "no link: the same path")
        XCTAssertNil(DataFolderCheck.pathProblem(root))
        guard case .success = DataFolderCheck().checkExisting(root) else { return XCTFail() }

        // What every refresh does.
        let manager = BottleManager(root: DataFolderStart.resolved(start.folder), repoRoot: scratch,
                                    runner: data.runner)
        try manager.prepare()
        let bottles = try manager.listBottles()
        XCTAssertEqual(bottles.map(\.name), names)
        XCTAssertEqual(try manager.listProfiles().map(\.name), names)
        XCTAssertEqual(try manager.listDamagedBottles(), [])
        XCTAssertEqual(try manager.listDamagedProfiles(), [])
        XCTAssertEqual(history.load().map(\.profileName), names)
        XCTAssertEqual(try trust.load(), ["Quest-3"])
        XCTAssertEqual(SessionMarkerStore(dataRoot: root).read(), .absent)
        XCTAssertEqual(manager.openedDataFolder?.isStillThere, true)

        let control = scratch.appendingPathComponent("test.control")
        try Data("1 token".utf8).write(to: control)
        for (name, listed) in zip(names, bottles) {
            let bottle = try manager.loadBottle(name)
            XCTAssertEqual(bottle, listed)
            XCTAssertEqual(bottle.prefixPath, data.prefix(name).path)
            XCTAssertEqual(bottle.engineRootPath, data.bottleDirectory(name).appendingPathComponent("engine").path)
            XCTAssertEqual(bottle.wineBinaryPath, data.bottleDirectory(name).appendingPathComponent("engine/bin/wine").path)
            XCTAssertTrue(bottle.isReadyForVR)

            // Play, as far as the command.
            let command = try manager.profileLaunchCommand(name, controlFile: control)
            XCTAssertEqual(command.executable.path, bottle.wineBinaryPath)
            XCTAssertEqual(command.arguments, [#"C:\Program Files (x86)\Steam\steamapps\common\Game\Game.exe"#])
            XCTAssertEqual(command.droppedEnvironment, [])
            let host = data.bottleDirectory(name).appendingPathComponent("host")
            var expected = [
                "SteamAppId": "1", "WINEPREFIX": bottle.prefixPath, "WINEARCH": "win64", "WINEDEBUG": "-all",
                "MVK_CONFIG_LOG_LEVEL": "0", "DXMT_BASALT_IOSURFACE": "1",
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                "BASALT_CONTROL": "Z:" + control.path.replacingOccurrences(of: "/", with: #"\"#),
            ]
            for (key, folder) in [("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                                  ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")] {
                expected[key] = host.appendingPathComponent(folder).path
            }
            XCTAssertEqual(command.environment, expected)
            // The file that keeps Wine out of the Mac's own folders, as before.
            let userDirectories = try String(
                contentsOf: host.appendingPathComponent("config/user-dirs.dirs"), encoding: .utf8)
            XCTAssertEqual(userDirectories, [
                ("DESKTOP", "Desktop"), ("DOCUMENTS", "Documents"), ("DOWNLOAD", "Downloads"),
                ("PICTURES", "Pictures"), ("MUSIC", "Music"), ("VIDEOS", "Videos"), ("TEMPLATES", "Templates"),
            ].map { "XDG_\($0.0)_DIR=\"\(host.path)/folders/\($0.1)\"\n" }.joined())
        }

        // The Headset page, Wi-Fi Play, a recorded launch, the end of a session.
        XCTAssertEqual(try HeadsetSetup.directory("Tools/Android", in: root).path,
                       root.appendingPathComponent("Tools/Android").path)
        try trust.prepare()
        var environment = ["BASALT_FRAME_TRACE": "1"]
        XCTAssertNotNil(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: root, prefix: data.prefix(names[0]), profile: names[0]))
        try preferences.set("dark", forKey: "app.appearance")
        try preferences.set(String?.none, forKey: "app.appearance")
        XCTAssertEqual(try history.append(SessionRecord(profileName: "blood-trail", settings: StreamLaunchSettings()))
            .map(\.profileName), ["blood-trail"] + names)

        // Not a byte of the environments, the games or the trust list changed,
        // and the settings hold what they held.
        let after = try metadata.map { try Data(contentsOf: $0) }
        for (index, file) in metadata.enumerated() where file != history.file && file != preferencesFile {
            XCTAssertEqual(after[index], before[index], file.lastPathComponent)
        }
        XCTAssertEqual(try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: preferencesFile)),
                       try JSONDecoder().decode([String: Data].self, from: before[metadata.count - 1]))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [
            "Bottles", "Profiles", "SessionHistory.json", "TrustedHeadsets.json", "Tools", "Diagnostics",
        ], "nothing set aside, nothing else created")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(
            atPath: preferencesFile.deletingLastPathComponent().path)), ["manager-preferences.json"])
    }
}
