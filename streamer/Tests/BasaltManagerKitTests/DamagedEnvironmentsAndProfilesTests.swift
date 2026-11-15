// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltManagerKit

/// An environment whose `bottle.json`, or a game whose profile, cannot be
/// read is listed as such, with its name and the reason, instead of
/// vanishing while its name stays taken; and it can be moved to the Trash.
final class DamagedEnvironmentsAndProfilesTests: XCTestCase {
    private func dataFolder() throws -> FakeDataFolder {
        let scratch = try dataFolderScratch()
        let data = FakeDataFolder(root: scratch.appendingPathComponent("Data", isDirectory: true),
                                  repo: scratch.appendingPathComponent("repo", isDirectory: true))
        try data.makeBottle("env")
        try data.makeBottle("other")
        try data.manager.saveProfile(data.profile("game", bottle: "env"))
        try data.manager.saveProfile(data.profile("second", bottle: "other"))
        return data
    }

    private func replace(_ key: String, with value: Any?, in file: URL) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object[key] = value
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    /// Stands in for the Trash: a folder of the test's own.
    private func trash(in data: FakeDataFolder) -> (URL) throws -> Void {
        let trash = data.root.deletingLastPathComponent().appendingPathComponent("Trash", isDirectory: true)
        return { item in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item, to: trash.appendingPathComponent(item.lastPathComponent))
        }
    }

    private func trashed(in data: FakeDataFolder) -> [String] {
        let trash = data.root.deletingLastPathComponent().appendingPathComponent("Trash")
        return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
    }

    func testAnEnvironmentWhoseDescriptionIsDamagedIsListedWithItsNameAndReason() throws {
        let data = try dataFolder()
        try replace("dxmtInstalled", with: "yes", in: data.bottleJSON("env"))
        let bytes = try Data(contentsOf: data.bottleJSON("env"))
        let manager = data.manager

        XCTAssertEqual(try manager.listBottles().map(\.name), ["other"])
        let damaged = try manager.listDamagedBottles()
        XCTAssertEqual(damaged.map(\.name), ["env"])
        XCTAssertEqual(damaged.first?.file.path, data.bottleJSON("env").path)
        XCTAssertEqual(damaged.first?.reason, .damaged("'dxmtInstalled' has the wrong type"))
        XCTAssertThrowsError(try manager.loadBottle("env")) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Managed bottle 'env' cannot be read: the file is damaged ('dxmtInstalled' has the wrong type)")
        }
        // The name stays taken, as before; nothing was written.
        XCTAssertThrowsError(try manager.createBottle(name: "env", engineID: "any"))
        XCTAssertEqual(try Data(contentsOf: data.bottleJSON("env")), bytes)

        try replace("dxmtInstalled", with: true, in: data.bottleJSON("env"))
        try replace("engineID", with: nil, in: data.bottleJSON("env"))
        XCTAssertEqual(try manager.listDamagedBottles().first?.reason, .damaged("'engineID' is missing"))
        try Data("{ not json".utf8).write(to: data.bottleJSON("env"))
        XCTAssertEqual(try manager.listDamagedBottles().first?.reason, .damaged("not valid JSON"))
    }

    /// Before, such an environment was "does not exist", which it is not.
    func testAnEnvironmentWhoseDescriptionCannotBeOpenedIsDamagedNotMissing() throws {
        let data = try dataFolder()
        let file = data.bottleJSON("env")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let manager = data.manager
        XCTAssertEqual(try manager.listBottles().map(\.name), ["other"])
        let damaged = try XCTUnwrap(try manager.listDamagedBottles().first)
        guard case .unreadable = damaged.reason else { return XCTFail("\(damaged.reason)") }
        XCTAssertThrowsError(try manager.loadBottle("env")) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Managed bottle 'env' cannot be read: "),
                          error.localizedDescription)
        }
        XCTAssertThrowsError(try manager.loadBottle("never-made")) { error in
            XCTAssertEqual(error.localizedDescription, "Managed bottle 'never-made' does not exist")
        }
    }

    func testAFolderWithoutADescriptionIsNotAnEnvironmentAndIsNotListed() throws {
        let data = try dataFolder()
        try FileManager.default.createDirectory(
            at: data.root.appendingPathComponent("Bottles/half-made/prefix"), withIntermediateDirectories: true)
        // A copy made in Finder still says "env" inside.
        try FileManager.default.copyItem(at: data.bottleDirectory("env"),
                                         to: data.root.appendingPathComponent("Bottles/env copy"))
        XCTAssertEqual(try data.manager.listBottles().map(\.name), ["env", "other"])
        XCTAssertEqual(try data.manager.listDamagedBottles(), [])
        XCTAssertEqual(try data.manager.listDamagedProfiles(), [])
    }

    func testRemovingADamagedEnvironmentMovesItsFolderAndItsGamesProfilesToTheTrash() throws {
        let data = try dataFolder()
        try Data("{ not json".utf8).write(to: data.bottleJSON("env"))
        let manager = data.manager
        let damaged = try XCTUnwrap(try manager.listDamagedBottles().first)

        // Only what is listed as damaged, and never through a link.
        let healthy = DamagedItem(name: "other", file: data.bottleJSON("other"), reason: .damaged("x"))
        XCTAssertThrowsError(try manager.removeDamaged(healthy, trash: trash(in: data)))
        let elsewhere = DamagedItem(name: "x", file: data.root.deletingLastPathComponent()
            .appendingPathComponent("bottle.json"), reason: .damaged("x"))
        XCTAssertThrowsError(try manager.removeDamaged(elsewhere, trash: trash(in: data)))
        XCTAssertEqual(trashed(in: data), [])

        try manager.removeDamaged(damaged, trash: trash(in: data))
        XCTAssertEqual(trashed(in: data), ["env", "game.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.bottleDirectory("env").path))
        XCTAssertEqual(try manager.listBottles().map(\.name), ["other"])
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["second"])
        XCTAssertEqual(try manager.listDamagedBottles(), [])
    }

    func testADamagedEnvironmentReachedThroughALinkIsNotRemoved() throws {
        let data = try dataFolder()
        let outside = data.root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: outside.appendingPathComponent("bottle.json"))
        try FileManager.default.createSymbolicLink(
            at: data.root.appendingPathComponent("Bottles/linked"), withDestinationURL: outside)
        let manager = data.manager
        let damaged = try XCTUnwrap(try manager.listDamagedBottles().first { $0.name == "linked" })
        XCTAssertThrowsError(try manager.removeDamaged(damaged, trash: trash(in: data)))
        XCTAssertEqual(trashed(in: data), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("bottle.json").path))
    }

    /// "Add game" used to pick the name of a profile the Library did not
    /// show, and fail with "already exists".
    func testAProfileThatCannotBeReadIsListedAndItsNameStaysTaken() throws {
        let data = try dataFolder()
        try replace("arguments", with: "one string", in: data.profileJSON("game"))
        let bytes = try Data(contentsOf: data.profileJSON("game"))
        let manager = data.manager

        XCTAssertEqual(try manager.listProfiles().map(\.name), ["second"])
        let damaged = try manager.listDamagedProfiles()
        XCTAssertEqual(damaged.map(\.name), ["game"])
        XCTAssertEqual(damaged.first?.file.path, data.profileJSON("game").path)
        XCTAssertEqual(damaged.first?.reason, .damaged("'arguments' has the wrong type"))
        XCTAssertThrowsError(try manager.loadProfile("game")) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Launch profile 'game' cannot be read: the file is damaged ('arguments' has the wrong type)")
        }
        XCTAssertThrowsError(try manager.loadProfile("never-made")) { error in
            XCTAssertEqual(error.localizedDescription, "Launch profile 'never-made' does not exist")
        }

        let taken = try manager.listProfiles().map(\.name) + damaged.map(\.name)
        let name = ProfileNaming.unique("Game", existing: taken)
        XCTAssertEqual(name, "game-2")
        try manager.saveNewProfile(data.profile(name, bottle: "env"))
        XCTAssertEqual(try Data(contentsOf: data.profileJSON("game")), bytes, "nothing was written over it")

        try manager.removeDamaged(damaged[0], trash: trash(in: data))
        XCTAssertEqual(trashed(in: data), ["game.json"])
        XCTAssertEqual(try manager.listDamagedProfiles(), [])
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["game-2", "second"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.bottleDirectory("env").path),
                      "the game's files and its environment stay")
    }

    /// `listProfiles` used to list a profile that `loadProfile` then refused at Play.
    func testAProfileOfAnotherFormatVersionIsListedAsDamagedNotAsAGame() throws {
        let data = try dataFolder()
        try replace("formatVersion", with: 2, in: data.profileJSON("game"))
        let manager = data.manager
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["second"])
        XCTAssertEqual(try manager.listDamagedProfiles().map(\.reason), [.unsupportedVersion(2)])
        XCTAssertThrowsError(try manager.loadProfile("game"))
        XCTAssertEqual(DamagedItem.Reason.unsupportedVersion(2).detail, "unsupported metadata version 2")
    }

    func testAHealthyDataFolderHasNothingDamaged() throws {
        let data = try dataFolder()
        XCTAssertEqual(try data.manager.listDamagedBottles(), [])
        XCTAssertEqual(try data.manager.listDamagedProfiles(), [])
        XCTAssertEqual(try data.manager.listBottles().map(\.name), ["env", "other"])
        XCTAssertEqual(try data.manager.listProfiles().map(\.name), ["game", "second"])
    }

    // MARK: - What a profile may pass to the game

    /// `DYLD_*` and `LD_*` in a profile would make the loader run code from
    /// a path of the profile's choosing inside Wine.
    func testLoaderVariablesOfAProfileNeverReachTheGame() throws {
        let data = try dataFolder()
        var profile = data.profile("loader", bottle: "env")
        profile.environment = [
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "DYLD_LIBRARY_PATH": "/tmp", "LD_PRELOAD": "/tmp/evil.so",
            "WINEDEBUG": "+loaddll", "MY_DYLD_NOTE": "kept", "dyld_lowercase": "kept",
        ]
        try data.manager.saveProfile(profile)
        let bytes = try Data(contentsOf: data.profileJSON("loader"))
        let control = data.root.deletingLastPathComponent().appendingPathComponent("test.control")
        try Data("1 token".utf8).write(to: control)

        let command = try data.manager.profileLaunchCommand("loader", controlFile: control)
        XCTAssertEqual(command.droppedEnvironment, ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD"])
        XCTAssertTrue(command.environment.keys.allSatisfy { !$0.hasPrefix("DYLD_") && !$0.hasPrefix("LD_") },
                      "\(command.environment.keys.sorted())")
        XCTAssertEqual(command.environment["WINEDEBUG"], "+loaddll")
        XCTAssertEqual(command.environment["MY_DYLD_NOTE"], "kept")
        XCTAssertEqual(command.environment["dyld_lowercase"], "kept")
        XCTAssertEqual(try Data(contentsOf: data.profileJSON("loader")), bytes, "the profile file is not changed")

        // An ordinary profile drops nothing.
        XCTAssertEqual(try data.manager.profileLaunchCommand("game", controlFile: control).droppedEnvironment, [])
        let (kept, dropped) = BottleManager.withoutLoaderVariables(["A": "1", "LD_X": "2"])
        XCTAssertEqual(kept, ["A": "1"])
        XCTAssertEqual(dropped, ["LD_X"])
    }
}
