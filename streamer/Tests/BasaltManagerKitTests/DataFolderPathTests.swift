// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

/// A data folder whose path holds spaces, quotes, `$`, backticks, `;`,
/// emoji, Cyrillic, NFC/NFD forms, a 250-character component, a leading `-`,
/// or is reached through a symbolic link, works in every step from making an
/// environment to deleting it; one whose path holds a line break or a
/// backslash is refused when it is chosen and when it is opened. Game names
/// of the same kinds never become bottle or profile names. Wine never runs:
/// where a command would be built, the built command is checked.
final class DataFolderPathTests: XCTestCase {
    static let names: [(label: String, name: String)] = [
        ("space", "sp ace  dir"),
        ("single-quote", "it's"),
        ("double-quote", "say \"hi\""),
        ("dollar", "cash$HOME$(id)${X}"),
        ("backtick", "tick`id`"),
        ("semicolon", "a;b&c|d>e"),
        ("newline", "line1\nline2"),
        ("emoji", "games🎮👨‍👩‍👧"),
        ("non-latin", "ゲーム VR"),
        ("nfc", "caf\u{e9}"),
        ("nfd", "cafe\u{301}"),
        ("long-250", String(repeating: "x", count: 250)),
        ("leading-dash", "-rf"),
        ("backslash", "back\\slash"),
        ("percent-hash", "100%25#?&=+"),
        ("colon", "a:b"),
        ("trailing-space", "trail "),
    ]

    /// The two kinds Wine cannot work with: a line break splits
    /// `user-dirs.dirs`, and a backslash in a folder name names another
    /// place once the path is written the Windows way.
    static let refused: Set<String> = ["newline", "backslash"]

    func testEveryStepWorksInADataFolderWithAnUnusualPath() throws {
        for (label, name) in Self.names where !Self.refused.contains(label) {
            let scratch = try dataFolderScratch()
            // As the app makes it: from a saved path, BASALT_DATA_DIR or the folder panel.
            let root = URL(fileURLWithPath: scratch.path + "/" + name + "/Data", isDirectory: true)
            try exercise(label, root: root, openedAs: root, scratch: scratch, weird: name)
        }
    }

    func testAPathWithALineBreakOrABackslashIsRefusedAndNothingIsCreated() throws {
        for (label, name) in Self.names where Self.refused.contains(label) {
            let scratch = try dataFolderScratch()
            let root = URL(fileURLWithPath: scratch.path + "/" + name + "/Data", isDirectory: true)
            // Choosing it in Settings.
            XCTAssertEqual(DataFolderCheck().check(root), .failure(.unsupportedPath), label)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [], label)
            // Opening one that is already there (a saved path, BASALT_DATA_DIR).
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            XCTAssertEqual(DataFolderCheck().checkExisting(root), .failure(.unsupportedPath), label)
            XCTAssertEqual(DataFolderCheck().check(root), .failure(.unsupportedPath), label)
            XCTAssertEqual(DataFolderCheck.pathProblem(root), .unsupportedPath, label)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], label)
        }
        // A folder reached through a link whose target has such a name.
        let scratch = try dataFolderScratch()
        let real = URL(fileURLWithPath: scratch.path + "/back\\slash/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("plain")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(DataFolderCheck().checkExisting(link), .failure(.unsupportedPath))
        XCTAssertEqual(DataFolderCheck().check(link), .failure(.unsupportedPath))
        // Every other unusual path is fine, the joiner inside an emoji included.
        for (label, name) in Self.names where !Self.refused.contains(label) {
            XCTAssertNil(DataFolderCheck.pathProblem(URL(fileURLWithPath: "/data/" + name)), label)
        }
        XCTAssertEqual(DataFolderCheck.pathProblem(URL(fileURLWithPath: "/data/tab\there")), .unsupportedPath)
        XCTAssertEqual(DataFolderCheck.pathProblem(URL(fileURLWithPath: "/data/line\u{2028}separator")),
                       .unsupportedPath)
        XCTAssertFalse(DataFolderProblem.unsupportedPath.message.isEmpty)
    }

    /// The same folders with the root URL built by `appendingPathComponent`,
    /// which percent-encodes `;` differently from `URL(fileURLWithPath:)`:
    /// two unequal URLs of one folder. `loadBottle` compares paths.
    func testDataFolderURLBuiltByAppendingAComponent() throws {
        for (label, name) in Self.names where ["semicolon", "percent-hash", "space", "non-latin"].contains(label) {
            let scratch = try dataFolderScratch()
            let root = scratch.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
            let data = FakeDataFolder(root: root, repo: scratch.appendingPathComponent("repo"))
            try data.makeBottle("env")
            let outcome = attempt({ try data.manager.loadBottle("env").name })
            XCTAssertTrue(outcome.hasPrefix("ok"), "\(label): \(outcome)")
        }
    }

    func testDataFolderReachedThroughASymbolicLink() throws {
        let scratch = try dataFolderScratch()
        let real = scratch.appendingPathComponent("real/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("link-to-data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try exercise("symlinked-root", root: real, openedAs: link, scratch: scratch, weird: "Plain")
        // The app itself works with the resolved path once the folder is open.
        XCTAssertEqual(DataFolderStart.resolved(link).path, real.path)
        XCTAssertEqual(DataFolderStart.resolved(real).path, real.path)
        let missing = scratch.appendingPathComponent("not-there/Data")
        XCTAssertEqual(DataFolderStart.resolved(missing).path, missing.path)
    }

    /// A link in a folder above the data folder, as with a folder under
    /// `/tmp` or a home folder that is a link.
    func testDataFolderBelowASymbolicLink() throws {
        let scratch = try dataFolderScratch()
        let real = scratch.appendingPathComponent("real disk", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("Games")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try exercise("below-a-link", root: real.appendingPathComponent("Data", isDirectory: true),
                     openedAs: link.appendingPathComponent("Data", isDirectory: true),
                     scratch: scratch, weird: "Plain")
    }

    /// The system's own links: `/tmp` and `/var` lead into `/private`, and a
    /// path under them is spelled with or without `/private` depending on
    /// who made it. The test's temporary folder is such a path.
    func testDataFolderUnderTheSystemTemporaryFolderInEitherSpelling() throws {
        let short = try temporaryDirectory()
        XCTAssertFalse(short.path.hasPrefix("/private/"), short.path)
        let long = URL(fileURLWithPath: "/private" + short.path, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: long.path), "the same folder")
        for (label, base) in [("var", short), ("private-var", long)] {
            let scratch = URL(fileURLWithPath: base.path + "/" + label, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let root = URL(fileURLWithPath: scratch.path + "/Data", isDirectory: true)
            try exercise(label, root: root, openedAs: root, scratch: scratch, weird: "Plain")
            // As the app opens it: one spelling, whichever it was given.
            XCTAssertEqual(DataFolderStart.resolved(root).path, short.path + "/" + label + "/Data")
        }
        let given = URL(fileURLWithPath: long.path + "/as-opened/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: given, withIntermediateDirectories: true)
        let resolved = DataFolderStart.resolved(given)
        try exercise("resolved", root: resolved, openedAs: resolved,
                     scratch: resolved.deletingLastPathComponent(), weird: "Plain")
    }

    /// A link inside the data folder that points out of it is still refused,
    /// and nothing is created behind it.
    func testALinkInsideTheDataFolderThatPointsOutIsRefused() throws {
        let scratch = try dataFolderScratch()
        let data = FakeDataFolder(root: scratch.appendingPathComponent("Data", isDirectory: true),
                                  repo: scratch.appendingPathComponent("repo", isDirectory: true))
        try data.makeBottle("env")
        try data.manager.saveProfile(data.profile("game", bottle: "env"))
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func isEmpty() throws -> Bool { try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty }

        for name in ["Tools", "Downloads", "Diagnostics"] {
            try FileManager.default.createSymbolicLink(
                at: data.root.appendingPathComponent(name), withDestinationURL: outside)
        }
        XCTAssertThrowsError(try HeadsetSetup.directory("Tools/Android", in: data.root)) {
            XCTAssertEqual(($0 as? BottleToolError)?.message, HeadsetSetup.outsideDataFolder)
        }
        XCTAssertThrowsError(try HeadsetSetup.directory("Downloads", in: data.root))
        var environment = ["BASALT_FRAME_TRACE": "1"]
        XCTAssertNil(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: data.root, prefix: data.prefix("env"), profile: "game"))
        XCTAssertTrue(try isEmpty())

        // The environment's own storage, before anything of it exists.
        try FileManager.default.createSymbolicLink(
            at: data.bottleDirectory("env").appendingPathComponent("host"), withDestinationURL: outside)
        let control = scratch.appendingPathComponent("test.control")
        try Data("1 token".utf8).write(to: control)
        XCTAssertThrowsError(try data.manager.profileLaunchCommand("game", controlFile: control)) {
            XCTAssertEqual(($0 as? BottleToolError)?.message,
                           "Bottle storage resolves outside the managed data folder")
        }
        XCTAssertTrue(try isEmpty())
    }

    /// The folder was made under the NFC spelling and is opened under NFD
    /// (as a path typed, pasted or saved by another program can be), and back.
    func testDataFolderOpenedUnderAnotherUnicodeNormalForm() throws {
        for (label, made, opened) in [("nfc-made-nfd-opened", "caf\u{e9}", "cafe\u{301}"),
                                      ("nfd-made-nfc-opened", "cafe\u{301}", "caf\u{e9}")] {
            let scratch = try dataFolderScratch()
            let root = scratch.appendingPathComponent(made).appendingPathComponent("Data", isDirectory: true)
            let other = scratch.appendingPathComponent(opened).appendingPathComponent("Data", isDirectory: true)
            try exercise(label, root: root, openedAs: other, scratch: scratch, weird: "Plain")
        }
    }

    /// Four 250-character components: longer than PATH_MAX (1024).
    func testDataFolderPathLongerThanPathMax() throws {
        let scratch = try dataFolderScratch()
        var path = scratch
        for letter in ["a", "b", "c", "d"] {
            path.appendPathComponent(String(repeating: letter, count: 250), isDirectory: true)
        }
        let root = path.appendingPathComponent("Data", isDirectory: true)
        let data = FakeDataFolder(root: root, repo: scratch.appendingPathComponent("repo"))
        let (made, _) = timed { attempt({ try data.makeBottle("env") }) { _ in "made" } }
        XCTAssertTrue(made.hasPrefix("THROWS"), made)
        let (listed, _) = timed { attempt({ try data.manager.listBottles().map(\.name) }) }
        XCTAssertEqual(listed, "ok []")
        let (history, _) = timed {
            attempt({ try SessionHistoryStore(dataRoot: root).append(
                SessionRecord(profileName: "p", settings: StreamLaunchSettings())).count })
        }
        XCTAssertTrue(history.hasPrefix("THROWS"), history)
        XCTAssertEqual(DataFolderCheck().check(root, usingSubfolder: false), .failure(.cannotCreate))
        // Clean errors, and nothing was left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    /// Game titles and folder names of the same hostile kinds.
    func testGameNamesWithHostileCharacters() throws {
        for (label, name) in Self.names {
            let slug = ProfileNaming.slug(name)
            let valid = (try? BottleName.validate(slug, kind: "profile name")) != nil
            let asProfile = (try? BottleName.validate(name, kind: "profile name")) != nil
            XCTAssertTrue(valid, "\(label): the slug '\(slug)' is not a valid profile name")
            XCTAssertFalse(asProfile, "\(label): accepted as a bottle or profile name")
        }
    }

    // MARK: One data folder

    private func exercise(_ label: String, root: URL, openedAs opened: URL, scratch: URL,
                          weird: String) throws {
        let files = FileManager.default
        let made = FakeDataFolder(root: root, repo: scratch.appendingPathComponent("repo \(weird)", isDirectory: true))
        let data = FakeDataFolder(root: opened, repo: made.repo)
        func step(_ name: String, _ expectation: String = "", _ body: @escaping () throws -> String) {
            let (outcome, _) = timed(30) { attempt(body) }
            XCTAssertTrue(outcome.hasPrefix("ok"), "\(label): \(name): \(outcome) \(expectation)")
        }
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw BottleToolError("MISMATCH " + message()) }
        }

        step("make environment") { try made.makeBottle("env"); return "" }
        step("listBottles") {
            let names = try data.manager.listBottles().map(\.name)
            try require(names == ["env"], "listed \(names)")
            return "\(names)"
        }
        step("loadBottle") {
            let bottle = try data.manager.loadBottle("env")
            try require(bottle.prefixPath == data.prefix("env").path,
                        "prefix \(bottle.prefixPath) is not \(data.prefix("env").path)")
            return "prefix under the opened path"
        }
        step("saveProfile + listProfiles") {
            try data.manager.saveProfile(data.profile("game", bottle: "env"))
            let names = try data.manager.listProfiles().map(\.name)
            try require(names == ["game"], "listed \(names)")
            return "\(names)"
        }
        // File names stay under 255 bytes; the hostile part is the folder.
        let short = weird.utf8.count > 100 ? "long" : weird
        let control = URL(fileURLWithPath: opened.deletingLastPathComponent().path + "/control \(short).control")
        step("profileLaunchCommand (argv, environment)") {
            try Data("1 token".utf8).write(to: control)
            let command = try data.manager.profileLaunchCommand("game", controlFile: control)
            try require(command.executable.path == data.bottleDirectory("env")
                .appendingPathComponent("engine/bin/wine").path, "executable \(command.executable.path)")
            try require(command.arguments == [#"C:\Games\Test\game.exe"#], "argv \(command.arguments)")
            try require(command.environment["WINEPREFIX"] == data.prefix("env").path,
                        "WINEPREFIX \(command.environment["WINEPREFIX"] ?? "nil")")
            for key in ["XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "TMPDIR"] {
                let value = command.environment[key] ?? ""
                var isDirectory: ObjCBool = false
                try require(files.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue,
                            "\(key)=\(value) is no folder")
            }
            return "argv and environment exact"
        }
        step("BASALT_CONTROL maps back to the control file") {
            let command = try data.manager.profileLaunchCommand("game", controlFile: control)
            let windows = command.environment["BASALT_CONTROL"] ?? ""
            // What Wine does with Z:\…: every backslash is a separator.
            try require(windows.hasPrefix("Z:"), "not on Z: — \(windows)")
            let host = String(windows.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
            try require(host == control.standardizedFileURL.path,
                        "Wine would open \(host.debugDescription), the file is \(control.path.debugDescription)")
            return "round trip exact"
        }
        let userDirs = data.bottleDirectory("env").appendingPathComponent("host/config/user-dirs.dirs")
        step("user-dirs.dirs as Wine's parser reads it") {
            let text = try String(contentsOf: userDirs, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            try require(lines.count == 7, "\(lines.count) lines instead of 7")
            for line in lines {
                // XDG_<NAME>_DIR="<value with \\ and \" escaped>"
                guard let equals = line.firstIndex(of: "="), line.hasPrefix("XDG_"),
                      line[line.index(after: equals)...].hasPrefix("\""), line.hasSuffix("\"") else {
                    throw BottleToolError("MISMATCH malformed line \(line.debugDescription)")
                }
                var value = ""
                var escaped = false
                for character in line[line.index(equals, offsetBy: 2)...].dropLast() {
                    if escaped || character != "\\" { value.append(character); escaped = false } else { escaped = true }
                }
                var isDirectory: ObjCBool = false
                try require(files.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue,
                            "\(value.debugDescription) is no folder")
            }
            return "7 entries, each an existing folder"
        }
        // The format is a shell fragment; `$` and backticks in it are escaped.
        step("user-dirs.dirs sourced by /bin/sh") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", #". "$1"; printf %s "$XDG_DOCUMENTS_DIR""#, "sh", userDirs.path]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent-test-home"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let expected = data.bottleDirectory("env").appendingPathComponent("host/folders/Documents").path
            // The same folder; `/var/…` may be written `/private/var/…`.
            try require(output == expected || "/private" + output == expected,
                        "a shell reads \(output.debugDescription), expected \(expected.debugDescription)")
            return "same folder"
        }
        step("frame trace: reserve and list") {
            var environment = ["BASALT_FRAME_TRACE": "1"]
            guard let session = FrameTraceSession.rewrite(
                environment: &environment, dataRoot: opened, prefix: data.prefix("env"), profile: "game") else {
                throw BottleToolError("MISMATCH no recording was reserved (the launch is silently untraced)")
            }
            try require(files.fileExists(atPath: session.csv.path), "no CSV at \(session.csv.path)")
            let listed = DiagnosticRecordingStore(dataRoot: opened).list().count
            try require(listed == 1, "\(listed) recordings listed")
            // The path the game gets, as Wine maps Z:\… back to the Mac.
            let windows = environment["BASALT_FRAME_TRACE"] ?? ""
            let host = String(windows.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
            try require(windows.hasPrefix("Z:") && host == session.csv.path,
                        "the game would write \(host.debugDescription), the app reads \(session.csv.path.debugDescription)")
            return "reserved, listed, and the game's path is the app's"
        }
        step("history, marker, trust, preferences") {
            let history = try SessionHistoryStore(dataRoot: opened).append(
                SessionRecord(profileName: "game", settings: StreamLaunchSettings()))
            try require(SessionHistoryStore(dataRoot: opened).load().count == history.count, "history reload")
            let trust = HeadsetTrustStore(dataRoot: opened)
            try trust.setTrusted("Quest-3", trusted: true)
            try require(try trust.load() == ["Quest-3"], "trust reload")
            let preferences = WorkspacePreferences(
                fileURL: opened.appendingPathComponent("config/manager-preferences.json"))
            try preferences.set(opened.path, forKey: "BasaltVR.dataRoot")
            let again = WorkspacePreferences(fileURL: preferences.fileURL).string(forKey: "BasaltVR.dataRoot")
            try require(again == opened.path, "saved data folder reads back as \(again.debugDescription)")
            let start = DataFolderStart.choose(environment: nil, saved: again, repoRoot: data.repo)
            try require(start.folder.standardizedFileURL.path == opened.standardizedFileURL.path,
                        "start folder \(start.folder.path.debugDescription)")
            return "all round trips exact"
        }
        step("HeadsetSetup.directory(Tools/Android)") {
            let directory = try HeadsetSetup.directory("Tools/Android", in: opened)
            try require(files.fileExists(atPath: directory.path), "not created")
            return "created"
        }
        step("DataFolderCheck") {
            let existing = DataFolderCheck().checkExisting(opened)
            let chosen = DataFolderCheck().check(opened)
            guard case .success = existing, case .success(let verdict) = chosen else {
                throw BottleToolError("MISMATCH existing=\(existing) chosen=\(chosen)")
            }
            return "ok; folder used: \(verdict.folder.path == opened.standardizedFileURL.path ? "the same" : verdict.folder.path)"
        }
        step("copy a game folder with the same name") {
            let source = URL(fileURLWithPath: scratch.path + "/source \(short)", isDirectory: true)
            let weird = short
            try files.createDirectory(at: source.appendingPathComponent(weird), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: source.appendingPathComponent(weird).appendingPathComponent("game \(weird).exe"))
            let inventory = try data.manager.inventoryGameFolder(source)
            if !inventory.isCopyable {
                return "refused before copying: \(inventory.rejected.map { "\($0.reason)" })"
            }
            let name = GameFolderName.isValid(weird) ? weird : "Plain"
            let copied = try data.manager.copyGameFolder(
                inventory, intoBottle: "env", folderName: name, reserveBytes: 0)
            let file = copied.appendingPathComponent(weird).appendingPathComponent("game \(weird).exe")
            try require(files.fileExists(atPath: file.path), "the copied file is missing")
            let windows = BottleManager.winePath(for: file, prefix: data.prefix("env"))
            return "copied as '\(name)'; Windows path \(windows.debugDescription)"
        }
        step("AppFootprint.items") {
            let items = AppFootprint.items(at: AppFootprint.Locations(
                dataRoot: opened, preferencesFolder: opened.appendingPathComponent("config"),
                bundleIdentifier: "test.none", home: scratch.appendingPathComponent("home"),
                userCacheDirectory: nil, temporaryDirectory: scratch.appendingPathComponent("tmp")))
            let outside = items.filter { !$0.url.resolvingSymlinksInPath().path.hasPrefix(
                root.resolvingSymlinksInPath().path) }
            try require(outside.isEmpty, "lists \(outside.map(\.url.path)) outside the data folder")
            try require(!items.isEmpty, "lists nothing")
            return "\(items.count) item(s): \(items.map { $0.url.lastPathComponent })"
        }
        step("createBottle argv (pinned engine clone)") {
            let wineRoot = data.repo.appendingPathComponent(
                "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine")
            try files.createDirectory(at: wineRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try files.createDirectory(at: wineRoot.appendingPathComponent("lib/wine/x86_64-unix"),
                                      withIntermediateDirectories: true)
            for tool in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"] {
                try Data("#!/bin/sh\nexit 71\n".utf8).write(to: wineRoot.appendingPathComponent(tool))
                try files.setAttributes([.posixPermissions: 0o755],
                                        ofItemAtPath: wineRoot.appendingPathComponent(tool).path)
            }
            _ = try? data.manager.createBottle(name: "second", engineID: BottleEngineDiscovery.pinnedDXMTEngineID)
            let calls = data.runner.calls
            try require(calls.count == 1 && calls[0].count == 4 && calls[0][0] == "/bin/cp" && calls[0][1] == "-cR",
                        "commands \(calls)")
            try require(calls[0][2].hasPrefix("/") && calls[0][3].hasPrefix("/"), "relative operands \(calls[0])")
            try require(!files.fileExists(atPath: data.bottleDirectory("second").path),
                        "the half-made environment stayed")
            return "cp -cR <abs> <abs>; failed create left nothing"
        }
        step("deleteBottle") {
            try data.manager.deleteBottle("env")
            try require(!files.fileExists(atPath: made.bottleDirectory("env").path), "the environment stayed")
            try require(files.fileExists(atPath: made.root.appendingPathComponent("SessionHistory.json").path),
                        "something else went too")
            return "removed, the rest stays"
        }
    }
}
