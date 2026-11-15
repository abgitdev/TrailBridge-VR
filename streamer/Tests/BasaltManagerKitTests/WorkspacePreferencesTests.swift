// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltManagerKit

/// `manager-preferences.json` when it is damaged, in part or as a whole.
final class WorkspacePreferencesTests: XCTestCase {
    private static let dataRootKey = "BasaltVR.dataRoot"

    private func file() throws -> URL {
        try temporaryDirectory().appendingPathComponent("config/manager-preferences.json")
    }

    /// The file as the app writes it, with one entry replaced by `entry`.
    private func write(_ file: URL, replacing key: String, with entry: Any) throws {
        let seed = WorkspacePreferences(fileURL: file)
        try seed.set("/Volumes/Chosen Disk/TrailBridge Data", forKey: Self.dataRootKey)
        try seed.set("ru", forKey: "app.language")
        try seed.set(true, forKey: "library.vrOnly")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object[key] = entry
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    /// One wrong value used to fail the whole file: language, appearance and
    /// stream settings fell back to defaults and nothing could be saved.
    func testOneBadEntryDoesNotHideTheOthersAndIsWrittenBackAsItIs() throws {
        let file = try file()
        try write(file, replacing: "future.setting", with: ["a": [1, 2]])
        let preferences = WorkspacePreferences(fileURL: file)
        XCTAssertNil(preferences.loadError)
        XCTAssertEqual(preferences.string(forKey: "app.language"), "ru")
        XCTAssertEqual(preferences.string(forKey: Self.dataRootKey), "/Volumes/Chosen Disk/TrailBridge Data")
        XCTAssertEqual(preferences.value(forKey: "library.vrOnly"), true)
        XCTAssertNil(preferences.data(forKey: "future.setting"))

        // Saving works, and the entry this version cannot read survives it.
        try preferences.set("dark", forKey: "app.appearance")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["future.setting"] as? [String: [Int]], ["a": [1, 2]])
        let reopened = WorkspacePreferences(fileURL: file)
        XCTAssertEqual(reopened.string(forKey: "app.appearance"), "dark")
        XCTAssertEqual(reopened.string(forKey: "app.language"), "ru")
    }

    /// A data folder entry that cannot be read is not the same as none: the
    /// app must not quietly open the default folder in its place.
    func testALostDataFolderEntryIsToldFromOneNeverMade() throws {
        let file = try file()
        XCTAssertFalse(WorkspacePreferences(fileURL: file).isUnreadable(String.self, forKey: Self.dataRootKey))

        try write(file, replacing: Self.dataRootKey, with: 5)
        var preferences = WorkspacePreferences(fileURL: file)
        XCTAssertNil(preferences.loadError)
        XCTAssertNil(preferences.string(forKey: Self.dataRootKey))
        XCTAssertTrue(preferences.isUnreadable(String.self, forKey: Self.dataRootKey))
        XCTAssertEqual(preferences.string(forKey: "app.language"), "ru", "the other settings still load")
        XCTAssertFalse(preferences.isUnreadable(String.self, forKey: "app.language"))
        XCTAssertFalse(preferences.isUnreadable(String.self, forKey: "never.set"))

        // The right kind of entry holding the wrong kind of value.
        try write(file, replacing: Self.dataRootKey, with: Data("[1,2]".utf8).base64EncodedString())
        preferences = WorkspacePreferences(fileURL: file)
        XCTAssertTrue(preferences.isUnreadable(String.self, forKey: Self.dataRootKey))

        // Choosing the folder again repairs the entry.
        try preferences.set("/Volumes/Other/Data", forKey: Self.dataRootKey)
        let reopened = WorkspacePreferences(fileURL: file)
        XCTAssertEqual(reopened.string(forKey: Self.dataRootKey), "/Volumes/Other/Data")
        XCTAssertFalse(reopened.isUnreadable(String.self, forKey: Self.dataRootKey))
        XCTAssertEqual(reopened.string(forKey: "app.language"), "ru")
    }

    /// A file that is not a settings file at all is never written over; the
    /// error names it; set aside, it is kept under another name and settings
    /// save again.
    func testAFileThatCannotBeReadIsKeptUntilItIsSetAsideAndThenSettingsSaveAgain() throws {
        for damaged in ["{ not json", "", "[1, 2, 3]", "\"text\""] {
            let file = try file()
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(damaged.utf8).write(to: file)
            let preferences = WorkspacePreferences(fileURL: file)
            let error = try XCTUnwrap(preferences.loadError as? WorkspacePreferences.Unreadable, damaged)
            XCTAssertEqual(error.file, file)
            XCTAssertTrue(error.localizedDescription.contains("manager-preferences.json"), error.localizedDescription)
            XCTAssertNil(preferences.string(forKey: Self.dataRootKey))
            XCTAssertThrowsError(try preferences.set("dark", forKey: "app.appearance"), damaged) {
                XCTAssertTrue($0 is WorkspacePreferences.Unreadable)
            }
            XCTAssertEqual(try Data(contentsOf: file), Data(damaged.utf8), "kept as it is")

            let moved = try preferences.setAside(now: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(moved.lastPathComponent, "manager-preferences.damaged-20270115T080000Z.json")
            XCTAssertEqual(moved.deletingLastPathComponent().path, file.deletingLastPathComponent().path)
            XCTAssertEqual(try Data(contentsOf: moved), Data(damaged.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertNil(preferences.loadError)

            try preferences.set("dark", forKey: "app.appearance")
            let reopened = WorkspacePreferences(fileURL: file)
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(reopened.string(forKey: "app.appearance"), "dark")
            XCTAssertEqual(try Data(contentsOf: moved), Data(damaged.utf8), "the old file stays beside it")
        }
    }

    func testAFileThatCannotBeOpenedIsUnreadableToo() throws {
        let file = try file()
        try WorkspacePreferences(fileURL: file).set("ru", forKey: "app.language")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let preferences = WorkspacePreferences(fileURL: file)
        XCTAssertTrue(preferences.loadError is WorkspacePreferences.Unreadable)
        XCTAssertThrowsError(try preferences.set("en", forKey: "app.language"))
    }

    /// What a healthy file holds is written exactly as before: every value
    /// as base64 text, nothing else.
    func testAHealthyFileKeepsItsFormat() throws {
        let file = try file()
        let preferences = WorkspacePreferences(fileURL: file)
        try preferences.set("ru", forKey: "app.language")
        try preferences.set(["a": 1], forKey: "numbers")
        let stored = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        XCTAssertEqual(stored["app.language"], Data(#""ru""#.utf8))
        XCTAssertEqual(Set(stored.keys), ["app.language", "numbers"])
        try preferences.set(String?.none, forKey: "numbers")
        XCTAssertEqual(try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file)),
                       ["app.language": Data(#""ru""#.utf8)])
    }

    /// The folder is made on the first save, and made again when it was
    /// only removed (removing the app clears it while the app still runs).
    func testTheFolderIsMadeOnTheFirstSaveAndAgainAfterItWasRemoved() throws {
        let file = try temporaryDirectory().appendingPathComponent(".local/config/manager-preferences.json")
        let preferences = WorkspacePreferences(fileURL: file)
        try preferences.set("ru", forKey: "app.language")
        try FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
        try preferences.set("en", forKey: "app.language")
        XCTAssertEqual(WorkspacePreferences(fileURL: file).string(forKey: "app.language"), "en")
    }

    func testProblemsHaveTheirOwnTextInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        let file = try file()
        for language in AppLanguage.allCases {
            L10n.language = language
            let texts = [WorkspacePreferences.Unreadable(file: file, reason: "x").localizedDescription,
                         WorkspacePreferences.DiskNotConnected(file: file).localizedDescription]
            XCTAssertEqual(Set(texts).count, 2, "\(language)")
            for text in texts { XCTAssertTrue(text.contains("manager-preferences.json"), "\(language)") }
        }
    }
}
