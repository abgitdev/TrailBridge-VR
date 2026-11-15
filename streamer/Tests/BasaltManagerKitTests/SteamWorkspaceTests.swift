import XCTest
@testable import BasaltManagerKit
import BasaltBottleKit

final class SteamWorkspaceTests: XCTestCase {
    func testSignInInstallsCEFCompatibilityBeforeAnyGameProfileExists() throws {
        let repo = try temporaryDirectory()
        let root = repo.appendingPathComponent("data")
        let directory = root.appendingPathComponent("Bottles/Steam")
        let prefix = directory.appendingPathComponent("prefix")
        let engineRoot = directory.appendingPathComponent("engine")
        let wine = engineRoot.appendingPathComponent("bin/wine")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        let helper = steam.deletingLastPathComponent()
            .appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
        let artifact = repo.appendingPathComponent("runtime/build/bin/steamwebhelper_compat.exe")
        let original = Data([0x4d, 0x5a, 0x10])
        let shim = Data([0x4d, 0x5a]) + Data("steamwebhelper.basalt-original.exe".utf16.flatMap {
            [UInt8($0 & 0xff), UInt8($0 >> 8)]
        })
        for file in [wine, steam, helper, artifact] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try original.write(to: file)
        }
        try shim.write(to: artifact)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = BottleEngine(id: "test", kind: .pinned, wineBinary: wine,
                                  wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
                                  root: engineRoot, supportsBasaltDXMT: true)
        let managed = ManagedBottle(name: "Steam", engine: engine, prefix: prefix,
                                    engineRoot: engineRoot, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(managed).write(to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(root: root, repoRoot: repo)
        let bottle = DiscoveredBottle(name: "Steam", origin: .managed, prefix: prefix, managed: managed)
        let command = try SteamInstallation.signInCommand(bottle: bottle, manager: manager)
        XCTAssertEqual(command.arguments, [
            #"C:\Program Files (x86)\Steam\steam.exe"#,
            "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
        ])
        XCTAssertEqual(try Data(contentsOf: helper), shim)
        XCTAssertEqual(try Data(contentsOf: helper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")), original)
        _ = try SteamInstallation.signInCommand(bottle: bottle, manager: manager)
        XCTAssertEqual(try Data(contentsOf: helper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")), original)
    }

    func testTargetProfilesOwnGameProcessAndRejectMissingOrExternalFiles() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix")
        let bottle = DiscoveredBottle(name: "target", origin: .managed, prefix: prefix)
        for (id, relative) in [
            ("2669380", "BrutalistickVR.exe"),
            ("1032430", "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe"),
        ] {
            let directory = prefix.appendingPathComponent("drive_c/Games/\(id)")
            let executable = directory.appendingPathComponent(relative)
            let game = SteamGame(appID: id, name: "Test", bottle: bottle,
                                 installDirectory: directory,
                                 steamExecutable: prefix.appendingPathComponent("drive_c/Steam/steam.exe"),
                                 artwork: nil, sizeOnDisk: nil, lastPlayed: nil)
            XCTAssertThrowsError(try SteamInstallation.gameProfile(named: id, game: game, prefix: prefix))
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x4d, 0x5a]).write(to: executable)
            let profile = try SteamInstallation.gameProfile(named: id, game: game, prefix: prefix)
            XCTAssertEqual(profile.source, .steam)
            XCTAssertEqual(profile.executable, BottleManager.winePath(for: executable, prefix: prefix))
            XCTAssertEqual(profile.arguments, [])
            XCTAssertEqual(profile.environment["SteamAppId"], id)
            XCTAssertEqual(profile.gameRoot, BottleManager.winePath(for: directory, prefix: prefix))

            let outside = temporary.appendingPathComponent("external-\(id).exe")
            try FileManager.default.moveItem(at: executable, to: outside)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
            XCTAssertThrowsError(try SteamInstallation.gameProfile(named: id, game: game, prefix: prefix))
        }
    }

    func testPreferencesSurviveRestartAndPreserveDamagedFile() throws {
        let file = try temporaryDirectory().appendingPathComponent("config/preferences.json")
        let preferences = WorkspacePreferences(fileURL: file)
        try preferences.set("brutalistick-vr", forKey: "profile")
        try preferences.set(true, forKey: "vrOnly")
        let reopened = WorkspacePreferences(fileURL: file)
        XCTAssertEqual(reopened.string(forKey: "profile"), "brutalistick-vr")
        XCTAssertEqual(reopened.value(forKey: "vrOnly") as Bool?, true)
        try reopened.set(Optional<String>.none, forKey: "profile")
        XCTAssertNil(WorkspacePreferences(fileURL: file).string(forKey: "profile"))

        let damaged = Data("incomplete settings".utf8)
        try damaged.write(to: file)
        let broken = WorkspacePreferences(fileURL: file)
        XCTAssertNotNil(broken.loadError)
        XCTAssertThrowsError(try broken.set(false, forKey: "vrOnly"))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testSteamClientIsDetectedWithoutGamesAndExternalLaunchIsRefused() throws {
        let prefix = try temporaryDirectory()
        let executable = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: executable)
        XCTAssertEqual(SteamInstallation.executable(in: prefix), executable)
        let bottle = DiscoveredBottle(name: "Source", origin: .whisky, prefix: prefix)
        XCTAssertTrue(SteamLibraryDiscovery().discover(in: bottle).isEmpty)
        let manager = BottleManager(root: prefix.appendingPathComponent("managed"), repoRoot: prefix)
        XCTAssertThrowsError(try SteamInstallation.signInCommand(bottle: bottle, manager: manager))
        XCTAssertEqual(try Data(contentsOf: executable), Data([0x4d, 0x5a]))
    }

}
