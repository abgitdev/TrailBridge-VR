// SPDX-License-Identifier: MIT
import XCTest
@testable import BasaltBottleKit

final class FrameTraceSessionTests: XCTestCase {
    func testRewriteOnlyAcceptsLiteralOptInAndCreatesPrivateUniqueSessionFiles() throws {
        let root = try temporaryDirectory()
        let prefix = root.appendingPathComponent("prefix")
        for value in [nil, "", "0", "yes", "2", "some.csv"] as [String?] {
            var env = ["KEEP": "value"]
            env["BASALT_FRAME_TRACE"] = value
            XCTAssertNil(FrameTraceSession.rewrite(environment: &env, dataRoot: root, prefix: prefix, profile: "test"))
            XCTAssertEqual(env, ["KEEP": "value"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Diagnostics").path))
        var env = ["BASALT_FRAME_TRACE": "1", "KEEP": "value"]
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let session = try XCTUnwrap(FrameTraceSession.rewrite(environment: &env, dataRoot: root,
            prefix: prefix, profile: "test", now: date))
        XCTAssertEqual(session.csv.deletingLastPathComponent().path,
                       root.appendingPathComponent("Diagnostics").path)
        XCTAssertEqual(session.csv.deletingLastPathComponent(), DiagnosticsStorage.directory(dataRoot: root))
        XCTAssertEqual(env["BASALT_FRAME_TRACE"], BottleManager.winePath(for: session.csv, prefix: prefix))
        XCTAssertEqual(env["KEEP"], "value")
        XCTAssertTrue(session.csv.lastPathComponent.hasPrefix("20250101T000000."))
        XCTAssertTrue(session.csv.lastPathComponent.hasSuffix("Z-test.csv"))
        for file in [session.csv, session.console] {
            XCTAssertEqual(try Data(contentsOf: file).count, 0)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: session.csv.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        env["BASALT_FRAME_TRACE"] = "1"
        let second = try XCTUnwrap(FrameTraceSession.rewrite(environment: &env, dataRoot: root,
            prefix: prefix, profile: "test", now: date))
        XCTAssertNotEqual(session.csv, second.csv)
    }

    /// The data folder may be reached through a link (a folder under `/tmp`,
    /// a home folder that is a link, a link to a disk): the recording goes
    /// to the folder the link leads to.
    func testADataRootReachedThroughASymlinkRecordsInTheRealFolder() throws {
        // The data root itself, then a folder above it.
        for (linked, dataRoot, real) in [("data", "data", "outside"), ("parent", "parent/data", "outside/data")] {
            let root = try temporaryDirectory()
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(
                at: outside.appendingPathComponent("data"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(linked), withDestinationURL: outside)
            let opened = root.appendingPathComponent(dataRoot)
            var env = ["BASALT_FRAME_TRACE": "1"]
            let session = try XCTUnwrap(FrameTraceSession.rewrite(
                environment: &env, dataRoot: opened, prefix: root, profile: "test"), linked)
            // Named by the path the folder was opened under, found in the real one.
            XCTAssertEqual(session.csv.deletingLastPathComponent().path,
                           opened.appendingPathComponent("Diagnostics").path)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent(real).appendingPathComponent("Diagnostics").path).sorted(),
                [session.console.lastPathComponent, session.csv.lastPathComponent].sorted())
            let fd = DiagnosticsStorage.open(dataRoot: opened, create: false)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { close(fd) }
        }
    }

    func testSymlinkAtTheDiagnosticsFolderIsRefused() throws {
        let optIns: [[String: String]] = [
            ["BASALT_FRAME_TRACE": "1"], ["BASALT_RECORD_VIDEO": "1"],
            ["BASALT_FRAME_TRACE": "1", "BASALT_RECORD_VIDEO": "1"],
        ]
        for optIn in optIns {
            // A link inside the data folder that points out of it.
            for (linked, dataRoot) in [("data/Diagnostics", "data")] {
                let root = try temporaryDirectory()
                let outside = root.appendingPathComponent("outside")
                try FileManager.default.createDirectory(
                    at: outside.appendingPathComponent("data"), withIntermediateDirectories: true)
                let link = root.appendingPathComponent(linked)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                for settings in [false, true] {
                    var env = settings ? [:] : optIn
                    XCTAssertNil(FrameTraceSession.rewrite(
                        environment: &env, dataRoot: root.appendingPathComponent(dataRoot),
                        prefix: root, profile: "test", tracesFrames: settings, recordsVideo: settings))
                    XCTAssertNil(env["BASALT_FRAME_TRACE"])
                    XCTAssertNil(env["BASALT_RECORD_VIDEO"])
                }
                XCTAssertLessThan(DiagnosticsStorage.open(
                    dataRoot: root.appendingPathComponent(dataRoot), create: false), 0)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["data"])
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(
                    atPath: outside.appendingPathComponent("data").path).isEmpty)
            }
        }
    }

    func testStorageNeverCreatesTheDataRootAndOnlyCreatesTheFolderOnRequest() throws {
        let root = try temporaryDirectory()
        let missing = root.appendingPathComponent("missing")
        var env = ["BASALT_FRAME_TRACE": "1"]
        XCTAssertNil(FrameTraceSession.rewrite(environment: &env, dataRoot: missing, prefix: root, profile: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertLessThan(DiagnosticsStorage.open(dataRoot: root, create: false), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Diagnostics").path))
        let created = DiagnosticsStorage.open(dataRoot: root, create: true)
        XCTAssertGreaterThanOrEqual(created, 0)
        close(created)
        let mode = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("Diagnostics").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let existing = DiagnosticsStorage.open(dataRoot: root, create: false)
        XCTAssertGreaterThanOrEqual(existing, 0)
        close(existing)
        XCTAssertGreaterThan(try XCTUnwrap(DiagnosticsStorage.freeBytes(dataRoot: root)), 0)
    }

    func testAppSettingsAndProfileVariablesEachTurnRecordingOn() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        // (profile variables, app frames, app video, video allowed) -> (frames, video)
        let cases: [(env: [String: String], frames: Bool, video: Bool, allowed: Bool, expect: (Bool, Bool)?)] = [
            ([:], false, false, true, nil),
            ([:], true, false, true, (true, false)),
            ([:], false, true, true, (false, true)),
            ([:], true, true, true, (true, true)),
            (["BASALT_FRAME_TRACE": "1"], false, true, true, (true, true)),
            (["BASALT_RECORD_VIDEO": "1"], true, false, true, (true, true)),
            (["BASALT_FRAME_TRACE": "1"], true, false, true, (true, false)),
            // Not a literal 1: the variable adds nothing, the app's setting still counts.
            (["BASALT_FRAME_TRACE": "yes", "BASALT_RECORD_VIDEO": "0"], false, true, true, (false, true)),
            // The free-space guard withholds the video from either source and keeps the trace.
            (["BASALT_RECORD_VIDEO": "1"], true, true, false, (true, false)),
            (["BASALT_FRAME_TRACE": "1", "BASALT_RECORD_VIDEO": "1"], false, false, false, (true, false)),
            (["BASALT_RECORD_VIDEO": "1"], false, true, false, nil),
        ]
        for (index, item) in cases.enumerated() {
            let root = try temporaryDirectory()
            let prefix = root.appendingPathComponent("prefix")
            var env = item.env.merging(["KEEP": "value"]) { current, _ in current }
            let session = FrameTraceSession.rewrite(
                environment: &env, dataRoot: root, prefix: prefix, profile: "test",
                tracesFrames: item.frames, recordsVideo: item.video, videoAllowed: item.allowed, now: date)
            XCTAssertNil(env["BASALT_RECORD_VIDEO"], "\(index)")
            XCTAssertEqual(env["KEEP"], "value", "\(index)")
            guard let expect = item.expect else {
                XCTAssertNil(session, "\(index)")
                XCTAssertNil(env["BASALT_FRAME_TRACE"], "\(index)")
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Diagnostics").path), "\(index)")
                continue
            }
            let recorded = try XCTUnwrap(session, "\(index)")
            XCTAssertEqual(recorded.tracesFrames, expect.0, "\(index)")
            XCTAssertEqual(recorded.recordsVideo, expect.1, "\(index)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: recorded.csv.path), expect.0, "\(index)")
            XCTAssertEqual(env["BASALT_FRAME_TRACE"],
                           expect.0 ? BottleManager.winePath(for: recorded.csv, prefix: prefix) : nil, "\(index)")
            XCTAssertEqual(recorded.recording(codecExtension: "hevc")?.deletingLastPathComponent().path,
                           expect.1 ? root.appendingPathComponent("Diagnostics").path : nil, "\(index)")
        }
    }

    func testTraceAndVideoAreIndependentOptIns() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        func rewrite(_ values: [String: String], root: URL) -> (FrameTraceSession?, [String: String]) {
            var env = values.merging(["KEEP": "value"]) { current, _ in current }
            let session = FrameTraceSession.rewrite(environment: &env, dataRoot: root,
                prefix: root.appendingPathComponent("prefix"), profile: "test", now: date)
            return (session, env)
        }
        func sessionFiles(_ root: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("Diagnostics").path).sorted()
        }

        // Neither: nothing is created, and a non-literal value of either is still removed.
        let neitherRoot = try temporaryDirectory()
        let neither: [[String: String]] = [
            [:], ["BASALT_RECORD_VIDEO": "0"], ["BASALT_RECORD_VIDEO": "yes"],
            ["BASALT_RECORD_VIDEO": "video.hevc"], ["BASALT_FRAME_TRACE": "0", "BASALT_RECORD_VIDEO": ""],
        ]
        for values in neither {
            let (session, env) = rewrite(values, root: neitherRoot)
            XCTAssertNil(session)
            XCTAssertEqual(env, ["KEEP": "value"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: neitherRoot.appendingPathComponent("Diagnostics").path))

        // Trace only: the CSV and transcript exist, no video is requested.
        let traceRoot = try temporaryDirectory()
        let (traceSession, traceEnv) = rewrite(["BASALT_FRAME_TRACE": "1"], root: traceRoot)
        let trace = try XCTUnwrap(traceSession)
        XCTAssertTrue(trace.tracesFrames)
        XCTAssertFalse(trace.recordsVideo)
        XCTAssertEqual(trace.transcript, trace.console)
        XCTAssertNil(trace.recording(codecExtension: "hevc"))
        XCTAssertEqual(traceEnv["BASALT_FRAME_TRACE"],
                       BottleManager.winePath(for: trace.csv, prefix: traceRoot.appendingPathComponent("prefix")))
        XCTAssertNil(traceEnv["BASALT_RECORD_VIDEO"])
        XCTAssertEqual(traceEnv["KEEP"], "value")
        XCTAssertEqual(try sessionFiles(traceRoot), [trace.console.lastPathComponent, trace.csv.lastPathComponent].sorted())

        // Video only: a private directory and a path, but no file and no game variable.
        let videoRoot = try temporaryDirectory()
        let (videoSession, videoEnv) = rewrite(["BASALT_RECORD_VIDEO": "1"], root: videoRoot)
        let video = try XCTUnwrap(videoSession)
        XCTAssertFalse(video.tracesFrames)
        XCTAssertTrue(video.recordsVideo)
        XCTAssertNil(video.transcript)
        let recording = try XCTUnwrap(video.recording(codecExtension: "hevc"))
        XCTAssertEqual(recording, video.video(codecExtension: "hevc"))
        XCTAssertTrue(recording.lastPathComponent.hasPrefix("20250101T000000."))
        XCTAssertTrue(recording.lastPathComponent.hasSuffix("Z-test.hevc"))
        XCTAssertEqual(recording.deletingLastPathComponent().path,
                       videoRoot.appendingPathComponent("Diagnostics").path)
        XCTAssertEqual(videoEnv, ["KEEP": "value"])
        XCTAssertEqual(try sessionFiles(videoRoot), [])
        let mode = try FileManager.default.attributesOfItem(
            atPath: recording.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        // A name already used by a traced launch is never reused for a recording.
        let traced = try XCTUnwrap(rewrite(["BASALT_FRAME_TRACE": "1"], root: videoRoot).0)
        let videoAfter = try XCTUnwrap(rewrite(["BASALT_RECORD_VIDEO": "1"], root: videoRoot).0)
        XCTAssertNotEqual(videoAfter.csv, traced.csv)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoAfter.csv.path))

        // Both: the trace files exist and the recording shares their name.
        let bothRoot = try temporaryDirectory()
        let (bothSession, bothEnv) = rewrite(["BASALT_FRAME_TRACE": "1", "BASALT_RECORD_VIDEO": "1"], root: bothRoot)
        let both = try XCTUnwrap(bothSession)
        XCTAssertTrue(both.tracesFrames)
        XCTAssertTrue(both.recordsVideo)
        XCTAssertEqual(both.transcript, both.console)
        XCTAssertEqual(both.recording(codecExtension: "h264"),
                       both.csv.deletingPathExtension().appendingPathExtension("h264"))
        XCTAssertEqual(bothEnv["BASALT_FRAME_TRACE"],
                       BottleManager.winePath(for: both.csv, prefix: bothRoot.appendingPathComponent("prefix")))
        XCTAssertNil(bothEnv["BASALT_RECORD_VIDEO"])
        XCTAssertEqual(try sessionFiles(bothRoot), [both.console.lastPathComponent, both.csv.lastPathComponent].sorted())
    }

    func testLaunchCommandNeverPassesTheRecordingOptInToTheGame() throws {
        let repo = try temporaryDirectory()
        let root = repo.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        var bottle = ManagedBottle(name: "Test", engine: BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true),
            prefix: prefix, engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(root: root, repoRoot: repo)
        let control = repo.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let cases: [(name: String, environment: [String: String], traces: Bool, records: Bool)] = [
            ("neither", ["GAME_MODE": "test"], false, false),
            ("trace", ["GAME_MODE": "test", "BASALT_FRAME_TRACE": "1"], true, false),
            ("video", ["GAME_MODE": "test", "BASALT_RECORD_VIDEO": "1"], false, true),
            ("both", ["GAME_MODE": "test", "BASALT_FRAME_TRACE": "1", "BASALT_RECORD_VIDEO": "1"], true, true),
        ]
        for item in cases {
            try manager.saveProfile(LaunchProfile(name: item.name, bottleName: "Test", source: .direct,
                executable: #"C:\Games\Game.exe"#, environment: item.environment))
            // The app reserves the session first, then builds the game command with it.
            let prepared = try manager.prepareFrameTrace(forProfile: item.name)
            XCTAssertEqual(prepared?.tracesFrames ?? false, item.traces, item.name)
            XCTAssertEqual(prepared?.recordsVideo ?? false, item.records, item.name)
            if !item.traces && !item.records { XCTAssertNil(prepared, item.name) }
            // The second command is basaltctl's path, which reserves its own session.
            let commands = try [
                manager.profileLaunchCommand(item.name, controlFile: control, frameTrace: prepared),
                manager.profileLaunchCommand(item.name, controlFile: control),
            ]
            for command in commands {
                XCTAssertNil(command.environment["BASALT_RECORD_VIDEO"], item.name)
                XCTAssertEqual(command.environment["GAME_MODE"], "test", item.name)
                if item.traces {
                    let csv = try XCTUnwrap(command.frameTrace?.csv, item.name)
                    XCTAssertEqual(command.environment["BASALT_FRAME_TRACE"],
                                   BottleManager.winePath(for: csv, prefix: prefix), item.name)
                } else {
                    XCTAssertNil(command.environment["BASALT_FRAME_TRACE"], item.name)
                }
            }
            if let prepared {
                XCTAssertEqual(commands[0].frameTrace, prepared, item.name)
                // Recordings live under the data root, never under the repository root.
                XCTAssertEqual(prepared.csv.deletingLastPathComponent().path,
                               root.appendingPathComponent("Diagnostics").path, item.name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".local").path))

        // The app's own settings record without any variable in the profile,
        // and the game still gets only the reserved CSV path.
        let settingsCases: [(frames: Bool, video: Bool, allowed: Bool, traces: Bool, records: Bool)] = [
            (true, false, true, true, false), (false, true, true, false, true),
            (true, true, true, true, true), (true, true, false, true, false),
        ]
        for item in settingsCases {
            let prepared = try XCTUnwrap(manager.prepareFrameTrace(
                forProfile: "neither", tracesFrames: item.frames, recordsVideo: item.video,
                videoAllowed: item.allowed))
            XCTAssertEqual(prepared.tracesFrames, item.traces)
            XCTAssertEqual(prepared.recordsVideo, item.records)
            let command = try manager.profileLaunchCommand("neither", controlFile: control, frameTrace: prepared)
            XCTAssertNil(command.environment["BASALT_RECORD_VIDEO"])
            XCTAssertEqual(command.environment["BASALT_FRAME_TRACE"],
                           item.traces ? BottleManager.winePath(for: prepared.csv, prefix: prefix) : nil)
            XCTAssertEqual(command.frameTrace, prepared)
        }
        XCTAssertNil(try manager.prepareFrameTrace(forProfile: "neither", recordsVideo: true, videoAllowed: false))
        // The profile file is never rewritten by a recording choice.
        XCTAssertEqual(try manager.loadProfile("neither").environment, ["GAME_MODE": "test"])
    }

    private func temporaryDirectory() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".local/tmp/frame-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
