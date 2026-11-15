// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

/// The disk holding the data folder goes away while the app's data layer
/// works on it. Each test creates a 200 MB APFS disk image under the
/// worktree's `.local/tmp`, mounts it (`nobrowse`), builds a data folder on
/// it, opens it as the app does, force-detaches the image, and keeps calling
/// the data layer. Every call must fail or come back empty, none may hang,
/// and nothing may be created where the disk was.
///
/// Skipped unless `TB_VANISH_PROBE=1`, because it mounts a disk image:
///
///     TB_VANISH_PROBE=1 ./scripts/trailbridge-dev.zsh swift test \
///         --package-path streamer --filter DataFolderDiskGoneTests
///
/// Two mount styles: under `/Volumes` (an external disk, a share mounted by
/// Finder; macOS removes the mount folder and a user cannot create one
/// there), and at a folder of the user's own (a share mounted by hand or by
/// autofs; the empty mount folder stays after the disk left, on the disk
/// underneath, and that is where a careless write would land).
final class DataFolderDiskGoneTests: XCTestCase {
    private var image: URL?
    private var mountPoint: URL?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TB_VANISH_PROBE"] == "1",
                          "mounts a disk image; set TB_VANISH_PROBE=1 to run")
    }

    override func tearDown() {
        // Always, also after a failure.
        if let mountPoint { _ = Self.hdiutil(["detach", "-force", mountPoint.path]) }
        if let image { try? FileManager.default.removeItem(at: image) }
        mountPoint = nil
        image = nil
    }

    // MARK: Cases

    func testIdleThenDiskGone_volumesMount() throws { try idle(custom: false) }
    func testIdleThenDiskGone_ownMountFolder() throws { try idle(custom: true) }
    func testDiskGoneDuringRepeatedSaves_volumesMount() throws { try saves(custom: false) }
    func testDiskGoneDuringRepeatedSaves_ownMountFolder() throws { try saves(custom: true) }
    func testDiskGoneDuringALargeCopy_volumesMount() throws { try copy(custom: false) }
    func testDiskGoneDuringALargeCopy_ownMountFolder() throws { try copy(custom: true) }

    private func idle(custom: Bool) throws {
        let label = custom ? "idle/own-folder" : "idle//Volumes"
        let scratch = try dataFolderScratch()
        let mount = try attach(in: scratch, custom: custom)
        let opened = try openDataFolder(on: mount, scratch: scratch)
        try detach()
        try afterwards(label, opened, mount: mount, scratch: scratch)
    }

    private func saves(custom: Bool) throws {
        let label = custom ? "saves/own-folder" : "saves//Volumes"
        let scratch = try dataFolderScratch()
        let mount = try attach(in: scratch, custom: custom)
        let opened = try openDataFolder(on: mount, scratch: scratch)
        let root = opened.data.root
        let preferences = opened.preferences
        let detached = LockedText()
        let detacher = Thread {
            Thread.sleep(forTimeInterval: 0.4)
            _ = Self.hdiutil(["detach", "-force", mount.path])
            detached.set("\(Date().timeIntervalSinceReferenceDate)")
        }
        detacher.start()
        let (outcome, _) = timed(90) {
            // The stores the app makes anew for each use, and the
            // preferences it holds from its start.
            let history = SessionHistoryStore(dataRoot: root)
            let marker = SessionMarkerStore(dataRoot: root)
            let trust = HeadsetTrustStore(dataRoot: root)
            let identity = SessionMarker.ProcessIdentity(BottleProcess(
                pid: 999_999, uid: 501, realUID: 501, executable: "/gone", startSeconds: 1, startMicroseconds: 2))
            var succeededBefore = 0, succeededAfter = 0, failedAfter = 0, iterations = 0
            var firstError = ""
            while true {
                iterations += 1
                let gone = !detached.get().isEmpty
                do {
                    try history.append(SessionRecord(profileName: "game", settings: StreamLaunchSettings()))
                    try marker.write(SessionMarker(app: identity, bottles: ["env"]))
                    try preferences.set(iterations, forKey: "test.counter")
                    try trust.setTrusted("Quest-\(iterations % 5)", trusted: true)
                    if gone { succeededAfter += 1 } else { succeededBefore += 1 }
                } catch {
                    if firstError.isEmpty { firstError = errorText(error) }
                    if gone { failedAfter += 1 }
                }
                if gone, let since = Double(detached.get()),
                   Date().timeIntervalSinceReferenceDate - since > 1.5 { break }
                if iterations > 200_000 { break }
            }
            return "\(iterations) rounds: \(succeededBefore) saved before the disk left, "
                + "\(succeededAfter) 'saved' AFTER it left, \(failedAfter) failed after; first error: \(firstError)"
        }
        XCTAssertFalse(outcome.hasPrefix("HANG"), outcome)
        XCTAssertTrue(outcome.contains(" 0 'saved' AFTER"),
                      "\(label): saves reported success after the disk left: \(outcome)")
        XCTAssertEqual(Self.contents(of: mount), custom ? "[] (empty mount folder)" : "absent",
                       "\(label): files were written in place of the missing disk")
        Self.clear(mount)
        try afterwards(label, opened, mount: mount, scratch: scratch)
    }

    private func copy(custom: Bool) throws {
        let label = custom ? "copy/own-folder" : "copy//Volumes"
        let scratch = try dataFolderScratch()
        let mount = try attach(in: scratch, custom: custom)
        let opened = try openDataFolder(on: mount, scratch: scratch)
        let source = scratch.appendingPathComponent("Big Game", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<16 {
            var generator = SystemRandomNumberGenerator()
            let seed = UInt8.random(in: 0...255, using: &generator)
            try Data(repeating: seed, count: 9 << 20)
                .write(to: source.appendingPathComponent("part\(index).pak"))
        }
        let manager = opened.manager
        let inventory = try manager.inventoryGameFolder(source)
        let detached = LockedText()
        let reached = LockedText()
        let (outcome, _) = timed(90) {
            attempt({
                try manager.copyGameFolder(
                    inventory, intoBottle: "env", folderName: "Big Game", reserveBytes: 0,
                    progress: { progress in
                        // The first report comes as the copy starts; the detach then
                        // runs beside it and lands while files are being written.
                        if detached.get().isEmpty {
                            detached.set("started at \(progress.copiedFiles) of \(progress.totalFiles) files")
                            Thread { _ = Self.hdiutil(["detach", "-force", mount.path]) }.start()
                        }
                        reached.set("\(progress.copiedFiles) of \(progress.totalFiles)")
                    })
            }) { "COPY REPORTED SUCCESS at \($0.path)" }
        }
        Self.waitUntilGone(mount, custom: custom)
        XCTAssertFalse(detached.get().isEmpty, "the detach never happened")
        XCTAssertTrue(outcome.hasPrefix("THROWS"), "\(label): \(outcome)")
        XCTAssertEqual(Self.contents(of: mount), custom ? "[] (empty mount folder)" : "absent",
                       "\(label): files were written in place of the missing disk")
        Self.clear(mount)
        try afterwards(label, opened, mount: mount, scratch: scratch)
    }

    // MARK: The data layer after the disk left

    /// What a running app holds from the moment it opened the data folder.
    private struct Opened {
        let data: FakeDataFolder
        /// The one manager of the app's run; it has seen the folder (`refresh()`).
        let manager: BottleManager
        let preferences: WorkspacePreferences
        let learning: LearningProgressStore
    }

    private func afterwards(_ label: String, _ opened: Opened, mount: URL, scratch: URL) throws {
        let data = opened.data
        let root = data.root
        let manager = opened.manager
        let source = scratch.appendingPathComponent("Small Game", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: source.appendingPathComponent("game.exe"))
        let control = scratch.appendingPathComponent("test.control")
        try Data("1 token".utf8).write(to: control)
        let identity = SessionMarker.ProcessIdentity(BottleProcess(
            pid: 999_999, uid: 501, realUID: 501, executable: "/gone", startSeconds: 1, startMicroseconds: 2))

        // (name, the outcome it must have, operation)
        let operations: [(String, String, () throws -> String)] = [
            ("DataFolderCheck.checkExisting (start, Settings)", "ok failure(BasaltManagerKit.DataFolderProblem.missing)",
             { "\(DataFolderCheck().checkExisting(root, opened: manager.openedDataFolder))" }),
            ("listBottles", "ok []", { "\(try manager.listBottles().map(\.name))" }),
            ("loadBottle", "THROWS", { try manager.loadBottle("env").name }),
            ("listProfiles", "ok []", { "\(try manager.listProfiles().map(\.name))" }),
            ("loadProfile", "THROWS", { try manager.loadProfile("game").name }),
            ("history.load", "ok 0 records", { "\(SessionHistoryStore(dataRoot: root).load().count) records" }),
            ("marker.load", "ok []", { "\(SessionMarkerStore(dataRoot: root).load()?.bottles ?? [])" }),
            ("recordings.list", "ok 0 recordings", { "\(DiagnosticRecordingStore(dataRoot: root).list().count) recordings" }),
            ("AppFootprint.items", "ok 0 items", {
                let items = AppFootprint.items(at: AppFootprint.Locations(
                    dataRoot: root, preferencesFolder: root.appendingPathComponent("config"),
                    bundleIdentifier: "test.none", home: scratch.appendingPathComponent("home"),
                    userCacheDirectory: nil, temporaryDirectory: scratch.appendingPathComponent("tmp")))
                return "\(items.count) items"
            }),
            ("BottleManager.prepare (every refresh())", "THROWS DataFolderUnavailable",
             { try manager.prepare(); return "PREPARED" }),
            ("saveProfile", "THROWS DataFolderUnavailable",
             { try manager.saveProfile(data.profile("game", bottle: "env")); return "SAVED" }),
            ("a manager that may not create the folder (a chosen folder at the next start)",
             "THROWS DataFolderUnavailable", {
                try BottleManager(root: root, repoRoot: data.repo, createsDataFolder: false).prepare()
                return "PREPARED"
            }),
            ("history.append (session end)", "THROWS", {
                "SAVED \(try SessionHistoryStore(dataRoot: root).append(SessionRecord(profileName: "game", settings: StreamLaunchSettings())).count)"
            }),
            ("marker.write (Play)", "THROWS", {
                try SessionMarkerStore(dataRoot: root).write(SessionMarker(app: identity, bottles: ["env"]))
                return "WRITTEN"
            }),
            ("trust.prepare (Wi-Fi Play)", "THROWS", {
                try HeadsetTrustStore(dataRoot: root).prepare()
                return "PREPARED"
            }),
            ("preferences.set (file on that disk)", "THROWS DiskNotConnected", {
                try opened.preferences.set("dark", forKey: "app.appearance")
                return "SAVED"
            }),
            ("learning.record (file on that disk)", "THROWS DiskNotConnected", {
                try opened.learning.recordQuickPathCompleted()
                return "SAVED"
            }),
            ("FrameTraceSession.rewrite (Play with recording)", "ok nil (untraced)", {
                var environment = ["BASALT_FRAME_TRACE": "1"]
                let session = FrameTraceSession.rewrite(
                    environment: &environment, dataRoot: root, prefix: data.prefix("env"), profile: "game")
                return session == nil ? "nil (untraced)" : "RESERVED \(session!.csv.lastPathComponent)"
            }),
            ("HeadsetSetup.directory(Tools/Android) (Headset page poll with adb)", "THROWS DataFolderUnavailable", {
                "CREATED \(try HeadsetSetup.directory("Tools/Android", in: root).lastPathComponent)"
            }),
            ("HeadsetSetup.directory(Downloads) (Install Steam)", "THROWS DataFolderUnavailable", {
                "CREATED \(try HeadsetSetup.directory("Downloads", in: root).lastPathComponent)"
            }),
            ("profileLaunchCommand (Play)", "THROWS", {
                _ = try manager.profileLaunchCommand("game", controlFile: control)
                return "BUILT"
            }),
            ("copyGameFolder (Add game)", "THROWS", {
                let inventory = try manager.inventoryGameFolder(source)
                return "COPIED \(try manager.copyGameFolder(inventory, intoBottle: "env", folderName: "Small", reserveBytes: 0).lastPathComponent)"
            }),
            ("DataFolderCheck.check (choose it again in Settings)", "ok failure(BasaltManagerKit.DataFolderProblem.missing)",
             { "\(DataFolderCheck().check(root, opened: manager.openedDataFolder))" }),
        ]
        for (name, expected, operation) in operations {
            let (outcome, _) = timed(30) { attempt(operation) }
            let left = Self.contents(of: mount)
            XCTAssertFalse(outcome.hasPrefix("HANG"), "\(label): \(name) hangs")
            XCTAssertTrue(outcome.hasPrefix(expected), "\(label): \(name): \(outcome), expected \(expected)")
            XCTAssertTrue(left == "absent" || left == "[] (empty mount folder)",
                          "\(label): \(name) created \(left) in place of the missing disk (\(outcome))")
            Self.clear(mount)
        }
        XCTAssertEqual(manager.openedDataFolder?.isStillThere, false, label)
        XCTAssertEqual(manager.openedDataFolder?.diskIsConnected, false, label)
    }

    // MARK: Disk image

    private func attach(in scratch: URL, custom: Bool) throws -> URL {
        let image = scratch.appendingPathComponent("TBDiskGone.dmg")
        self.image = image
        let name = "TBDiskGone\(Int.random(in: 1000...9999))"
        let created = Self.hdiutil(["create", "-size", "200m", "-fs", "APFS", "-volname", name,
                                    "-quiet", image.path])
        guard created.status == 0 else { throw BottleToolError("hdiutil create: \(created.output)") }
        let mount: URL
        let attached: (status: Int32, output: String)
        if custom {
            // hdiutil refuses a mount point of the user's own here; diskutil takes one.
            mount = scratch.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            attached = Self.run("/usr/sbin/diskutil", ["image", "attach", "--mountOptions", "nobrowse",
                                                       "--mountPoint", mount.path, image.path])
        } else {
            mount = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
            attached = Self.hdiutil(["attach", "-nobrowse", image.path])
        }
        guard attached.status == 0 else { throw BottleToolError("attach: \(attached.output)") }
        mountPoint = mount
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mount.path, isDirectory: &isDirectory) else {
            throw BottleToolError("the image is not mounted at \(mount.path): \(attached.output)")
        }
        return mount
    }

    private func detach() throws {
        guard let mountPoint else { return }
        let result = Self.hdiutil(["detach", "-force", mountPoint.path])
        guard result.status == 0 else { throw BottleToolError("hdiutil detach: \(result.output)") }
        self.mountPoint = nil
    }

    /// Builds a data folder on the disk and opens it as a running app has:
    /// one manager that has seen the folder, the preferences and the
    /// learning progress read once at the start.
    private func openDataFolder(on mount: URL, scratch: URL) throws -> Opened {
        let data = FakeDataFolder(root: mount.appendingPathComponent("TrailBridge Data", isDirectory: true),
                                  repo: scratch.appendingPathComponent("repo", isDirectory: true))
        try data.makeBottle("env")
        try data.manager.saveProfile(data.profile("game", bottle: "env"))
        try SessionHistoryStore(dataRoot: data.root).save((0..<3).map {
            SessionRecord(profileName: "game-\($0)", settings: StreamLaunchSettings())
        })
        try HeadsetTrustStore(dataRoot: data.root).setTrusted("Quest-3", trusted: true)
        let preferencesFile = data.root.appendingPathComponent("config/manager-preferences.json")
        try WorkspacePreferences(fileURL: preferencesFile).set("ru", forKey: "app.language")
        let manager = data.manager
        try manager.prepare()
        XCTAssertEqual(manager.openedDataFolder?.isStillThere, true)
        return Opened(
            data: data, manager: manager,
            preferences: WorkspacePreferences(fileURL: preferencesFile),
            learning: LearningProgressStore(fileURL: data.root.appendingPathComponent("config/learning.json")))
    }

    /// The detach may still be finishing when an operation has already failed:
    /// waits until the volume's content is gone and, under `/Volumes`, until
    /// macOS has removed the mount folder.
    private static func waitUntilGone(_ mount: URL, custom: Bool) {
        let files = FileManager.default
        for _ in 0..<100 {
            let content = files.fileExists(atPath: mount.appendingPathComponent(".fseventsd").path)
                || files.fileExists(atPath: mount.appendingPathComponent("TrailBridge Data/Bottles/env/bottle.json").path)
            if !content, custom || !files.fileExists(atPath: mount.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// What is at the mount path once the disk is gone.
    private static func contents(of mount: URL) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mount.path, isDirectory: &isDirectory) else { return "absent" }
        guard let enumerator = FileManager.default.enumerator(atPath: mount.path) else { return "unreadable" }
        let entries = (enumerator.allObjects as? [String] ?? []).sorted()
        return entries.isEmpty ? "[] (empty mount folder)" : "CREATED \(entries)"
    }

    /// Removes what an operation created in place of the disk, keeping the mount folder.
    private static func clear(_ mount: URL) {
        // Only ever inside a test's own scratch folder.
        guard mount.path.contains("/.local/tmp/data-folder-test-"), mount.lastPathComponent == "mnt",
              let names = try? FileManager.default.contentsOfDirectory(atPath: mount.path) else { return }
        for name in names { forceRemove(mount.appendingPathComponent(name)) }
    }

    private static func hdiutil(_ arguments: [String]) -> (status: Int32, output: String) {
        run("/usr/bin/hdiutil", arguments)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
