// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

/// Every file the app reads from its data folder or its preferences folder,
/// broken in thirteen ways, through the real loaders and then through the
/// write the app makes next. What must hold for each: no hang, and the
/// person's bytes are never lost without a word. A file the app cannot read
/// stays as it is and the app says so; a session history that is not one is
/// set aside under a `.damaged-<time>` name before a new one is started; only
/// the marker of a running session, which is of no use once it does not
/// read, is removed. The behaviours of each file have their own tests beside
/// this table (SessionHistoryTests, WorkspacePreferencesTests, and so on).
final class DamagedFilesTests: XCTestCase {
    enum Damage: String, CaseIterable {
        case empty, truncated, randomBytes, wrongTypes, missingKeys, extraKeys
        case huge100MB, deep10000, nonUTF8, directory, symlinkOutside, symlinkLoop, unreadable
    }

    /// What is at the file's path after the app's next write.
    enum Kept {
        /// Exactly what was there.
        case untouched
        /// A new file; the old bytes are beside it under a `.damaged-` name.
        case setAside
        /// Nothing: the file was of no use and was removed on purpose.
        case removed
        /// The file loaded, or is one of the link cases the app replaces
        /// with a regular file (a known, separate question).
        case unchecked
    }

    /// One file under test with its real loader and the write the app makes next.
    final class Target {
        let name: String
        let file: URL
        var valid = Data()
        var wrongTypes = Data()
        var missingKeys = Data()
        var extraKeys = Data()
        /// Appended after `valid` until the file is 100 MB.
        var filler = Data(repeating: 0x20, count: 1 << 20)
        var load: () -> String = { "" }
        var write: () -> String = { "" }
        var kept: (Damage) -> Kept = { _ in .unchecked }
        /// True when the app said that it could not read the file.
        var reported: () -> Bool = { true }
        /// Seconds a load may take.
        var loadLimit: TimeInterval = 10

        init(name: String, file: URL) {
            self.name = name
            self.file = file
        }
    }

    /// The kinds after which a file is not what the app wrote.
    static let notReadable: Set<Damage> = [
        .empty, .truncated, .randomBytes, .wrongTypes, .missingKeys, .deep10000, .nonUTF8,
    ]

    // MARK: One test per kind of damage

    func testEmptyFile() throws { try run(.empty) }
    func testTruncatedFile() throws { try run(.truncated) }
    func testRandomBytes() throws { try run(.randomBytes) }
    func testWrongTypes() throws { try run(.wrongTypes) }
    func testMissingRequiredKeys() throws { try run(.missingKeys) }
    func testExtraUnknownKeys() throws { try run(.extraKeys) }
    func testHundredMegabyteFile() throws { try run(.huge100MB) }
    func testTenThousandLevelsOfNesting() throws { try run(.deep10000) }
    func testNonUTF8Bytes() throws { try run(.nonUTF8) }
    func testDirectoryWhereAFileIsExpected() throws { try run(.directory) }
    func testSymlinkToAFileOutsideTheDataFolder() throws { try run(.symlinkOutside) }
    func testSymlinkLoop() throws { try run(.symlinkLoop) }
    func testFileWithoutReadPermission() throws { try run(.unreadable) }

    private func run(_ damage: Damage) throws {
        for make in builders {
            let scratch = try dataFolderScratch()
            let target = try make(scratch)
            let outside = scratch.appendingPathComponent("outside-\(target.file.lastPathComponent)")
            try install(damage, target, outside: outside)
            let before = fileState(target.file)
            let bytesBefore = try? Data(contentsOf: target.file)
            let outsideBefore = fileState(outside)

            let (loaded, seconds) = timed(60) { target.load() }
            let (written, _) = timed(60) { target.write() }

            let after = fileState(target.file)
            let context = "\(target.name)/\(damage.rawValue): loaded “\(loaded)”, then “\(written)”"
            XCTAssertFalse(loaded.hasPrefix("HANG"), context)
            XCTAssertFalse(written.hasPrefix("HANG"), context)
            XCTAssertLessThan(seconds, target.loadLimit, context)
            if damage == .symlinkOutside {
                XCTAssertEqual(outsideBefore, fileState(outside),
                               "a write went through the link to a file outside. \(context)")
            }
            switch target.kept(damage) {
            case .untouched:
                XCTAssertEqual(before, after, "the file was changed. \(context)")
                XCTAssertTrue(target.reported(), "the app did not say that it cannot read the file. \(context)")
            case .setAside:
                let folder = target.file.deletingLastPathComponent()
                let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                    .filter { DamagedFile.isSetAside($0, of: target.file.lastPathComponent) }
                XCTAssertEqual(copies.count, 1, "not set aside exactly once. \(context)")
                XCTAssertEqual(try copies.first.map { try Data(contentsOf: folder.appendingPathComponent($0)) },
                               bytesBefore, "the bytes set aside are not the old ones. \(context)")
                XCTAssertNotEqual(before, after, context)
            case .removed:
                XCTAssertEqual(after, "absent", context)
            case .unchecked:
                break
            }
        }
    }

    private func install(_ damage: Damage, _ target: Target, outside: URL) throws {
        let files = FileManager.default
        let file = target.file
        try? files.removeItem(at: file)
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch damage {
        case .empty:
            try Data().write(to: file)
        case .truncated:
            try target.valid.prefix(target.valid.count * 2 / 3).write(to: file)
        case .randomBytes:
            var generator = SystemRandomNumberGenerator()
            try Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: file)
        case .wrongTypes:
            try target.wrongTypes.write(to: file)
        case .missingKeys:
            try target.missingKeys.write(to: file)
        case .extraKeys:
            try target.extraKeys.write(to: file)
        case .huge100MB:
            XCTAssertTrue(files.createFile(atPath: file.path, contents: target.valid))
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            var written = target.valid.count
            while written < 100 << 20 {
                try handle.write(contentsOf: target.filler)
                written += target.filler.count
            }
            try handle.close()
        case .deep10000:
            try (Data(repeating: UInt8(ascii: "["), count: 10_000)
                 + Data(repeating: UInt8(ascii: "]"), count: 10_000)).write(to: file)
        case .nonUTF8:
            // Bytes that are no UTF-8 inside the first string (JSON) or field (CSV).
            var bytes = target.valid
            let at = (bytes.firstIndex(of: UInt8(ascii: "\"")) ?? bytes.startIndex) + 1
            bytes.insert(contentsOf: [0xFF, 0xFE, 0xE9], at: at)
            try bytes.write(to: file)
        case .directory:
            try files.createDirectory(at: file, withIntermediateDirectories: true)
            try Data("user's own file".utf8).write(to: file.appendingPathComponent("keep-me.txt"))
        case .symlinkOutside:
            try target.valid.write(to: outside)
            try files.createSymbolicLink(at: file, withDestinationURL: outside)
        case .symlinkLoop:
            let other = file.appendingPathExtension("loop")
            try? files.removeItem(at: other)
            try files.createSymbolicLink(atPath: file.path, withDestinationPath: other.path)
            try files.createSymbolicLink(atPath: other.path, withDestinationPath: file.path)
        case .unreadable:
            try target.valid.write(to: file)
            try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }
    }

    // MARK: The files

    private var builders: [(URL) throws -> Target] {
        [preferences, learning, history, marker, trust, bottle, profile, trace]
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BottleToolError("not a JSON object")
        }
        return object
    }

    /// The kinds after which neither preference file is a JSON object.
    private static let notAnObject: Set<Damage> = [
        .empty, .truncated, .randomBytes, .deep10000, .nonUTF8, .directory, .unreadable,
    ]

    /// `manager-preferences.json`: language, appearance, the chosen data
    /// folder, stream settings per game. The app writes it on every change.
    /// While it does not read, nothing is written over it.
    private func preferences(_ scratch: URL) throws -> Target {
        let file = scratch.appendingPathComponent("config/manager-preferences.json")
        let target = Target(name: "manager-preferences.json", file: file)
        let seed = WorkspacePreferences(fileURL: file)
        try seed.set("/Volumes/Chosen Disk/TrailBridge Data", forKey: "BasaltVR.dataRoot")
        try seed.set("ru", forKey: "app.language")
        try seed.set(true, forKey: "library.vrOnly")
        target.valid = try Data(contentsOf: file)
        var values = try object(target.valid)
        let language = values["app.language"]!
        target.wrongTypes = try json(["BasaltVR.dataRoot": 5, "app.language": language])
        target.missingKeys = try json([String: Any]())
        values["future.setting"] = Data(#"{"a":1}"#.utf8).base64EncodedString()
        target.extraKeys = try json(values)

        var loaded: WorkspacePreferences?
        target.load = {
            let preferences = WorkspacePreferences(fileURL: file)
            loaded = preferences
            return "loadError=\(preferences.loadError.map(errorText) ?? "none")"
                + "; language=\(preferences.string(forKey: "app.language") ?? "nil")"
        }
        target.write = {
            guard let loaded else { return "not loaded" }
            return attempt({ try loaded.set("dark", forKey: "app.appearance") }) { "saved" }
        }
        target.kept = { Self.notAnObject.contains($0) ? .untouched : .unchecked }
        target.reported = { loaded?.loadError != nil }
        return target
    }

    /// `learning.json`, beside the preferences.
    private func learning(_ scratch: URL) throws -> Target {
        let file = scratch.appendingPathComponent("config/learning.json")
        let target = Target(name: "learning.json", file: file)
        let seed = LearningProgressStore(fileURL: file)
        try seed.recordQuickPathCompleted(at: Date(timeIntervalSince1970: 1_790_000_000))
        try seed.recordFirstRunAnswer(.later, at: Date(timeIntervalSince1970: 1_790_000_000))
        target.valid = try Data(contentsOf: file)
        var values = try object(target.valid)
        target.wrongTypes = try json(["progress": 7, "firstRun": values["firstRun"]!])
        target.missingKeys = try json([String: Any]())
        values["future"] = Data("1".utf8).base64EncodedString()
        target.extraKeys = try json(values)

        var loaded: LearningProgressStore?
        target.load = {
            let store = LearningProgressStore(fileURL: file)
            loaded = store
            return "damaged=\(store.isDamaged); quickPathCompleted=\(store.progress.quickPathCompleted)"
        }
        target.write = {
            guard let loaded else { return "not loaded" }
            return attempt({ try loaded.recordFirstRunAnswer(.start) }) { "saved" }
        }
        target.kept = { Self.notAnObject.contains($0) ? .untouched : .unchecked }
        target.reported = { loaded?.isDamaged == true }
        return target
    }

    /// `SessionHistory.json` in the data folder; appended when a session ends.
    private func history(_ scratch: URL) throws -> Target {
        let root = scratch.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionHistoryStore(dataRoot: root)
        let target = Target(name: "SessionHistory.json", file: store.file)
        try store.save((0..<3).map {
            SessionRecord(profileName: "game-\($0)", settings: StreamLaunchSettings(),
                          startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double($0)))
        })
        target.valid = try Data(contentsOf: store.file)
        var document = try object(target.valid)
        target.wrongTypes = try json(["formatVersion": "one", "sessions": "none"])
        var withoutVersion = document
        withoutVersion.removeValue(forKey: "formatVersion")
        target.missingKeys = try json(withoutVersion)
        // Written by a newer version of the app.
        document["formatVersion"] = 2
        document["futureTopLevel"] = ["a": 1]
        target.extraKeys = try json(document)

        var refused = false
        target.load = { "\(store.load().count) of 3 records" }
        target.write = {
            let outcome = attempt({
                try store.append(SessionRecord(profileName: "new", settings: StreamLaunchSettings()))
            }) { "history now holds \($0.count) record(s)" }
            refused = outcome.hasPrefix("THROWS")
            return outcome
        }
        target.kept = { damage in
            if Self.notReadable.contains(damage) { return .setAside }
            return [.unreadable, .directory, .extraKeys].contains(damage) ? .untouched : .unchecked
        }
        target.reported = { refused }
        return target
    }

    /// `ActiveSession.json`: what an earlier app instance left running. One
    /// that was read and is no marker is removed; one that could not be read
    /// may be a good marker and stays for the next start.
    private func marker(_ scratch: URL) throws -> Target {
        let root = scratch.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionMarkerStore(dataRoot: root)
        let target = Target(name: "ActiveSession.json", file: store.file)
        // An app that is gone: the pid of nothing.
        let gone = try JSONDecoder().decode(SessionMarker.ProcessIdentity.self, from: Data(
            #"{"pid":999999,"startSeconds":1,"startMicroseconds":2,"executable":"/gone/TrailBridge"}"#.utf8))
        try store.write(SessionMarker(app: gone, bottles: ["env-a", "env-b"]))
        target.valid = try Data(contentsOf: store.file)
        var values = try object(target.valid)
        target.wrongTypes = try json(["app": values["app"]!, "bottles": "env-a"])
        var withoutBottles = values
        withoutBottles.removeValue(forKey: "bottles")
        target.missingKeys = try json(withoutBottles)
        values["future"] = ["x": 1]
        target.extraKeys = try json(values)

        target.load = { "environments to stop: \(store.load()?.bottles ?? [])" }
        target.write = {
            // What the next start does with it, with no real process touched.
            var stopped = [String]()
            let cleanup = LeftoverSession.cleanUp(
                in: store, access: NoProcesses(), audio: NoAudio(),
                stopWine: { name, _ in stopped.append(name) })
            return "cleanUp=\(cleanup == nil ? "nil" : "ran"); Wine stopped in \(stopped)"
        }
        target.kept = { damage in
            if Self.notReadable.contains(damage) { return .removed }
            return [.unreadable, .directory, .symlinkLoop].contains(damage) ? .untouched : .unchecked
        }
        return target
    }

    /// `TrustedHeadsets.json`: the headsets approved for Wi-Fi.
    private func trust(_ scratch: URL) throws -> Target {
        let root = scratch.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HeadsetTrustStore(dataRoot: root)
        let file = store.file
        let target = Target(name: "TrustedHeadsets.json", file: file)
        try store.setTrusted("Quest-3", trusted: true)
        try store.setTrusted("Pico-4", trusted: true)
        target.valid = try Data(contentsOf: file)
        target.wrongTypes = try json(["Quest-3": true])
        target.missingKeys = try json([String]())
        target.extraKeys = try json(["Quest-3", "Pico-4", "a-hostname-that-is-longer-than-thirty-two-bytes"])

        var unreadable = false
        target.load = {
            let listed = attempt({ try store.load() })
            unreadable = (try? store.load()) == nil
            let accepted = HeadsetBeaconGate(file: file)
                .accept(hostname: "Quest-3", ip: "192.168.1.5") { _ in }
            return "\(listed); streamer accepts Quest-3: \(accepted)"
        }
        target.write = {
            attempt({ try store.prepare() }) { "prepare ok" } + "; "
                + attempt({ try store.setTrusted("New-HMD", trusted: true) }) { "approved" }
        }
        target.kept = { damage in
            // Not `.nonUTF8`: that breaks one name, which is left out, and
            // the list loads with the other.
            let whole: Set<Damage> = [.empty, .truncated, .randomBytes, .wrongTypes, .deep10000,
                                      .directory, .unreadable]
            return whole.contains(damage) ? .untouched : .unchecked
        }
        target.reported = { unreadable }
        return target
    }

    /// `Bottles/<name>/bottle.json`. Nothing the app does next writes it.
    private func bottle(_ scratch: URL) throws -> Target {
        let data = FakeDataFolder(root: scratch.appendingPathComponent("data", isDirectory: true),
                                  repo: scratch.appendingPathComponent("repo", isDirectory: true))
        try data.makeBottle("env")
        try data.makeBottle("other")
        let file = data.bottleJSON("env")
        let target = Target(name: "Bottles/env/bottle.json", file: file)
        target.valid = try Data(contentsOf: file)
        var values = try object(target.valid)
        var wrong = values
        wrong["dxmtInstalled"] = "yes"
        target.wrongTypes = try json(wrong)
        var missing = values
        missing.removeValue(forKey: "engineID")
        target.missingKeys = try json(missing)
        values["futureField"] = ["a": [1, 2]]
        target.extraKeys = try json(values)

        var listed = [String](), damaged = [String]()
        target.load = {
            let manager = data.manager
            listed = (try? manager.listBottles().map(\.name)) ?? []
            damaged = (try? manager.listDamagedBottles().map(\.name)) ?? []
            let load = attempt({ try manager.loadBottle("env") }) { "ready=\($0.isReadyForVR)" }
            return "listed \(listed); cannot be read \(damaged); loadBottle \(load)"
        }
        target.write = {
            let manager = data.manager
            let create = attempt({
                try manager.createBottle(name: "env", engineID: BottleEngineDiscovery.pinnedDXMTEngineID)
            }) { _ in "created" }
            let save = attempt({ try manager.saveProfile(data.profile("game", bottle: "env")) }) { "saved" }
            return "create same name: \(create); save a profile for it: \(save)"
        }
        target.kept = { _ in .untouched }
        // Either it is an environment, or it is shown as one that cannot be read.
        target.reported = { listed.contains("env") != damaged.contains("env") && listed.contains("other") }
        return target
    }

    /// `Profiles/<name>.json`. "Add game" must still find a free name.
    private func profile(_ scratch: URL) throws -> Target {
        let data = FakeDataFolder(root: scratch.appendingPathComponent("data", isDirectory: true),
                                  repo: scratch.appendingPathComponent("repo", isDirectory: true))
        try data.makeBottle("env")
        try data.manager.saveProfile(data.profile("game", bottle: "env"))
        try data.manager.saveProfile(data.profile("second", bottle: "env"))
        let file = data.profileJSON("game")
        let target = Target(name: "Profiles/game.json", file: file)
        target.valid = try Data(contentsOf: file)
        var values = try object(target.valid)
        var wrong = values
        wrong["arguments"] = "one string"
        target.wrongTypes = try json(wrong)
        var missing = values
        missing.removeValue(forKey: "arguments")
        target.missingKeys = try json(missing)
        values["futureField"] = "x"
        target.extraKeys = try json(values)

        var listed = [String](), damaged = [String](), added = false
        target.load = {
            let manager = data.manager
            listed = (try? manager.listProfiles().map(\.name)) ?? []
            damaged = (try? manager.listDamagedProfiles().map(\.name)) ?? []
            let load = attempt({ try manager.loadProfile("game") }) { "title=\($0.title ?? "nil")" }
            return "listed \(listed); cannot be read \(damaged); loadProfile \(load)"
        }
        target.write = {
            // "Add game" picks a name no profile has, readable or not.
            let name = ProfileNaming.unique("Game", existing: listed + damaged)
            let outcome = attempt({ try data.manager.saveNewProfile(data.profile(name, bottle: "env")) }) { "added" }
            added = outcome.hasPrefix("ok")
            return "add game as '\(name)': \(outcome)"
        }
        target.kept = { _ in .untouched }
        target.reported = {
            listed.contains("game") != damaged.contains("game") && listed.contains("second") && added
        }
        return target
    }

    /// A frame-trace CSV under `Diagnostics`, as the Diagnostics page lists
    /// and summarises it. Its only writer here is the person's own "delete".
    private func trace(_ scratch: URL) throws -> Target {
        let root = scratch.appendingPathComponent("data", isDirectory: true)
        let store = DiagnosticRecordingStore(dataRoot: root)
        let file = store.directory.appendingPathComponent("20260101T000000.000000Z-game.csv")
        let target = Target(name: "Diagnostics/….csv", file: file)
        let header = "type,text,frame,wait_enter,wait_exit,begin,end_enter,end_exit,gpu_fence_wait\n"
        func row(_ frame: Int) -> String {
            let start = frame * 13_889
            return "frame,,\(frame),\(start),\(start + 2000),\(start + 2100),\(start + 9000),\(start + 9500),100\n"
        }
        target.valid = Data((header + (1...200).map(row).joined()).utf8)
        target.filler = Data((1...8000).map(row).joined().utf8)
        target.wrongTypes = Data((header
            + "frame,,one,two,three,four,five,six,seven\n"
            + "frame,,1,99999999999999999999999999999,-9223372036854775808,1,1,1,1\n"
            + "frame,,9223372036854775807,9223372036854775807,9223372036854775807,1,1,1,1\n"
            + "late,,-1,0,0,0,0,0,9223372036854775807\n").utf8)
        target.missingKeys = Data(("type,frame,wait_enter\n" + "frame,1,5\nframe,2\n").utf8)
        target.extraKeys = Data((header.dropLast() + ",future\n"
            + (1...200).map { row($0).dropLast() + ",9\n" }.joined()).utf8)

        // A 100 MB trace is read whole: about 13 s in a debug build.
        target.loadLimit = 60
        target.load = {
            let recordings = store.list()
            let summary = FrameTraceSummary.load(file)
            return "\(recordings.count) recording(s) listed; summary \(summary.map { "\($0.intervals) intervals" } ?? "nil")"
        }
        target.write = {
            attempt({ try store.deleteAll() }) { "delete all removed \($0) file(s)" }
        }
        return target
    }
}

private struct NoProcesses: BottleProcessAccess {
    var currentPID: Int32 { 1 }
    var currentUID: UInt32 { 501 }
    func processes() throws -> [BottleProcess] { [] }
    func signal(_ signal: Int32, process: BottleProcess) -> Bool { false }
    func pause() {}
    func isRunning(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) throws -> Bool { false }
}

private struct NoAudio: AudioOutputAccess {
    func defaultOutputUID() -> String? { nil }
    func setDefaultOutput(uid: String) -> Bool { false }
}
