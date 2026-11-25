// SPDX-License-Identifier: MIT
import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

final class DiagnosticRecordingTests: XCTestCase {
    // MARK: - Settings

    func testBothRecordingsAreOffByDefault() throws {
        let settings = DiagnosticRecordingSettings()
        XCTAssertFalse(settings.recordsFrames)
        XCTAssertFalse(settings.recordsVideo)
        XCTAssertFalse(settings.isEnabled)
        // A stored value from a build that knew neither key is still off.
        let decoded = try JSONDecoder().decode(DiagnosticRecordingSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, settings)
        let partial = try JSONDecoder().decode(
            DiagnosticRecordingSettings.self, from: Data(#"{"recordsVideo":true}"#.utf8))
        XCTAssertEqual(partial, DiagnosticRecordingSettings(recordsVideo: true))
    }

    func testChoicesPersistInTheAppPreferencesKeyedByProfileName() throws {
        let file = try temporaryDirectory().appendingPathComponent("manager-preferences.json")
        let key = "BasaltVR.diagnosticRecording.v1"
        // Nothing stored: no game records.
        XCTAssertNil(WorkspacePreferences(fileURL: file).data(forKey: key))

        let choices = [
            "brutalistick": DiagnosticRecordingSettings(recordsFrames: true),
            "blood-trail": DiagnosticRecordingSettings(recordsFrames: true, recordsVideo: true),
        ]
        try WorkspacePreferences(fileURL: file).set(JSONEncoder().encode(choices), forKey: key)

        let stored = try XCTUnwrap(WorkspacePreferences(fileURL: file).data(forKey: key))
        let loaded = try JSONDecoder().decode([String: DiagnosticRecordingSettings].self, from: stored)
        XCTAssertEqual(loaded, choices)
        XCTAssertEqual(loaded["other-game"] ?? DiagnosticRecordingSettings(), DiagnosticRecordingSettings())
    }

    func testProfileVariablesCountOnlyAsTheLiteralOne() {
        XCTAssertEqual(DiagnosticRecordingSettings(profileEnvironment: [:]), DiagnosticRecordingSettings())
        XCTAssertEqual(
            DiagnosticRecordingSettings(profileEnvironment: ["BASALT_FRAME_TRACE": "1"]),
            DiagnosticRecordingSettings(recordsFrames: true))
        XCTAssertEqual(
            DiagnosticRecordingSettings(profileEnvironment: ["BASALT_RECORD_VIDEO": "1"]),
            DiagnosticRecordingSettings(recordsVideo: true))
        for value in ["", "0", "yes", "true", "2", "trace.csv"] {
            XCTAssertFalse(DiagnosticRecordingSettings(
                profileEnvironment: ["BASALT_FRAME_TRACE": value, "BASALT_RECORD_VIDEO": value]).isEnabled, value)
        }
    }

    func testEitherSourceTurnsARecordingOn() {
        let off = DiagnosticRecordingSettings()
        let frames = DiagnosticRecordingSettings(recordsFrames: true)
        let video = DiagnosticRecordingSettings(recordsVideo: true)
        XCTAssertEqual(off.union(off), off)
        XCTAssertEqual(frames.union(off), frames)
        XCTAssertEqual(off.union(video), video)
        XCTAssertEqual(frames.union(video), DiagnosticRecordingSettings(recordsFrames: true, recordsVideo: true))

        let roomy: Int64 = 100_000_000_000
        func plan(_ settings: DiagnosticRecordingSettings, _ environment: [String: String]) -> [Bool] {
            let plan = DiagnosticRecordingPlan(settings: settings, profileEnvironment: environment, freeBytes: roomy)
            XCTAssertFalse(plan.videoSkippedForLowSpace)
            return [plan.recordsFrames, plan.recordsVideo]
        }
        XCTAssertEqual(plan(off, [:]), [false, false])
        XCTAssertEqual(plan(frames, [:]), [true, false])
        XCTAssertEqual(plan(off, ["BASALT_FRAME_TRACE": "1"]), [true, false])
        XCTAssertEqual(plan(video, [:]), [false, true])
        XCTAssertEqual(plan(off, ["BASALT_RECORD_VIDEO": "1"]), [false, true])
        XCTAssertEqual(plan(frames, ["BASALT_RECORD_VIDEO": "1"]), [true, true])
        XCTAssertEqual(plan(video, ["BASALT_FRAME_TRACE": "1"]), [true, true])
        XCTAssertEqual(plan(off, ["BASALT_FRAME_TRACE": "0", "BASALT_RECORD_VIDEO": "yes"]), [false, false])
    }

    func testVideoDiskUseFollowsTheBitrate() {
        XCTAssertEqual(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: 50), 375)
        XCTAssertEqual(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: 30), 225)
        XCTAssertEqual(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: 200), 1500)
        XCTAssertEqual(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: 15), 113)
        XCTAssertEqual(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: 0), 0)
    }

    // MARK: - Free-space guard

    func testLowFreeSpaceSkipsOnlyTheVideo() {
        // The app uses the streamer recorder's own threshold, 20 GiB.
        XCTAssertEqual(DiagnosticRecordingPlan.minimumFreeBytesForVideo, 20 << 30)
        let threshold = DiagnosticRecordingPlan.minimumFreeBytesForVideo
        let both = DiagnosticRecordingSettings(recordsFrames: true, recordsVideo: true)

        let low = DiagnosticRecordingPlan(settings: both, profileEnvironment: [:], freeBytes: threshold - 1)
        XCTAssertTrue(low.recordsFrames)
        XCTAssertFalse(low.recordsVideo)
        XCTAssertTrue(low.videoSkippedForLowSpace)

        let enough = DiagnosticRecordingPlan(settings: both, profileEnvironment: [:], freeBytes: threshold)
        XCTAssertTrue(enough.recordsFrames)
        XCTAssertTrue(enough.recordsVideo)
        XCTAssertFalse(enough.videoSkippedForLowSpace)

        // The developer variable is held back the same way.
        let variable = DiagnosticRecordingPlan(
            settings: DiagnosticRecordingSettings(),
            profileEnvironment: ["BASALT_FRAME_TRACE": "1", "BASALT_RECORD_VIDEO": "1"], freeBytes: 1)
        XCTAssertTrue(variable.recordsFrames)
        XCTAssertFalse(variable.recordsVideo)
        XCTAssertTrue(variable.videoSkippedForLowSpace)

        // Nothing to skip, so nothing to report.
        let framesOnly = DiagnosticRecordingPlan(
            settings: DiagnosticRecordingSettings(recordsFrames: true), profileEnvironment: [:], freeBytes: 0)
        XCTAssertTrue(framesOnly.recordsFrames)
        XCTAssertFalse(framesOnly.recordsVideo)
        XCTAssertFalse(framesOnly.videoSkippedForLowSpace)

        // An unknown amount does not block the recording.
        let unknown = DiagnosticRecordingPlan(settings: both, profileEnvironment: [:], freeBytes: nil)
        XCTAssertTrue(unknown.recordsVideo)
        XCTAssertFalse(unknown.videoSkippedForLowSpace)
    }

    func testSkippedVideoStillReservesTheFrameTrace() throws {
        let root = try symlinkFreeDirectory()
        let plan = DiagnosticRecordingPlan(
            settings: DiagnosticRecordingSettings(recordsFrames: true, recordsVideo: true),
            profileEnvironment: [:], freeBytes: 1_000_000_000)
        var environment = [String: String]()
        let session = try XCTUnwrap(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: root, prefix: root.appendingPathComponent("prefix"),
            profile: "game", tracesFrames: plan.recordsFrames, recordsVideo: plan.recordsVideo,
            videoAllowed: !plan.videoSkippedForLowSpace))
        XCTAssertTrue(session.tracesFrames)
        XCTAssertNotNil(session.transcript)
        XCTAssertNil(session.recording(codecExtension: "hevc"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.csv.path))
    }

    // MARK: - Listing and deleting

    func testListsRecordingsNewestFirstWithTheirFiles() throws {
        let root = try symlinkFreeDirectory()
        let store = DiagnosticRecordingStore(dataRoot: root)
        XCTAssertEqual(store.directory.path, root.appendingPathComponent("Diagnostics").path)
        XCTAssertEqual(store.list(), [])

        let older = try record(in: root, profile: "blood-trail", at: 1_735_689_600, frames: true, video: nil)
        let newer = try record(in: root, profile: "brutalistick.vr", at: 1_735_693_200.25, frames: true, video: "hevc")
        let videoOnly = try record(in: root, profile: "game", at: 1_735_690_000, frames: false, video: "h264")
        try write("frame data", to: older.csv)
        try write("log", to: older.console)
        try write(String(repeating: "v", count: 1000), to: newer.video(codecExtension: "hevc"))
        try write("index", to: newer.video(codecExtension: "hevc").appendingPathExtension("index.csv"))
        try write("vv", to: videoOnly.video(codecExtension: "h264"))

        // Not recordings: an unrelated file, a folder, and a link named like a recording.
        let folder = store.directory
        try write("note", to: folder.appendingPathComponent("notes.txt"))
        try write("x", to: folder.appendingPathComponent("20250101T000000.000000Z-.csv"))
        try write("x", to: folder.appendingPathComponent("20251301T000000.000000Z-game.csv"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("20250101T000000.000000Z-folder.csv"), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.csv")
        try write("outside", to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("20250101T000000.000000Z-link.csv"), withDestinationURL: outside)

        let listed = store.list()
        XCTAssertEqual(listed.map(\.profileName), ["brutalistick.vr", "game", "blood-trail"])
        XCTAssertEqual(listed.map(\.id), [newer, videoOnly, older].map {
            $0.csv.deletingPathExtension().lastPathComponent
        })
        XCTAssertEqual(listed[0].startedAt.timeIntervalSince1970, 1_735_693_200.25, accuracy: 0.000_01)
        XCTAssertEqual(listed[2].startedAt, Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(listed[0].files.map(\.kind), [.frames, .sessionLog, .video, .videoIndex])
        XCTAssertEqual(listed[0].files.map(\.bytes), [0, 0, 1000, 5])
        XCTAssertEqual(listed[0].totalBytes, 1005)
        XCTAssertEqual(listed[1].files.map(\.kind), [.video])
        XCTAssertEqual(listed[1].files.map(\.url), [videoOnly.video(codecExtension: "h264")])
        XCTAssertNil(listed[1].frames)
        XCTAssertEqual(listed[2].files.map(\.kind), [.frames, .sessionLog])
        XCTAssertEqual(listed[2].frames?.url, older.csv)
        XCTAssertEqual(listed[2].totalBytes, 13)
        XCTAssertEqual(listed.reduce(0) { $0 + $1.totalBytes }, 1020)
        // Written long after its 2025 name: the duration runs to the last write.
        XCTAssertGreaterThan(listed[2].duration, 0)
        XCTAssertEqual(listed[2].duration,
                       try XCTUnwrap(listed[2].files.map(\.modified).max()).timeIntervalSince(listed[2].startedAt))
    }

    func testDeletesOneRecordingOrAllAndNothingElse() throws {
        let root = try symlinkFreeDirectory()
        let store = DiagnosticRecordingStore(dataRoot: root)
        // Nothing to delete yet, and no folder appears.
        XCTAssertEqual(try store.deleteAll(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))

        let first = try record(in: root, profile: "one", at: 1_735_689_600, frames: true, video: "hevc")
        _ = try record(in: root, profile: "two", at: 1_735_689_700, frames: true, video: nil)
        let third = try record(in: root, profile: "three", at: 1_735_689_800, frames: true, video: nil)
        try write("video", to: first.video(codecExtension: "hevc"))
        let note = store.directory.appendingPathComponent("notes.txt")
        try write("note", to: note)
        let outside = root.appendingPathComponent("outside.csv")
        try write("outside", to: outside)
        let link = store.directory.appendingPathComponent("20250101T000000.000000Z-one.console.log.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let listed = store.list()
        XCTAssertEqual(listed.map(\.profileName), ["three", "two", "one"])
        // A file written after the listing still goes with its recording.
        let index = first.video(codecExtension: "hevc").appendingPathExtension("index.csv")
        try write("index", to: index)
        try store.delete(listed[2])
        for file in [first.csv, first.console, first.video(codecExtension: "hevc"), index] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertEqual(store.list().map(\.profileName), ["three", "two"])
        // Deleting it again is not an error.
        XCTAssertNoThrow(try store.delete(listed[2]))

        // A session still being written keeps its files.
        let keeping = third.csv.deletingPathExtension().lastPathComponent
        XCTAssertEqual(try store.deleteAll(keeping: [keeping]), 2)
        XCTAssertEqual(store.list().map(\.id), [keeping])
        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertEqual(store.list(), [])

        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "note")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testASymlinkedFolderIsNeitherListedNorEmptied() throws {
        let root = try symlinkFreeDirectory()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("20250101T000000.000000Z-game.csv")
        try write("keep", to: victim)
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("Diagnostics"), withDestinationURL: outside)

        let store = DiagnosticRecordingStore(dataRoot: data)
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(try store.deleteAll(), 0)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
        // The summary reader refuses a link as well.
        let link = root.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        XCTAssertNil(FrameTraceSummary.load(link))
    }

    func testRecordingNamesAreParsedStrictly() throws {
        let stem = "20250101T000000.250000Z-my.game_1"
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".csv")?.stem, stem)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".csv")?.kind, .frames)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".console.log")?.kind, .sessionLog)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".game.log")?.kind, .gameLog)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".game.log")?.stem, stem)
        // A profile may end in ".game" or ".console" itself.
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".game.console.log")?.stem, stem + ".game")
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".console.game.log")?.stem, stem + ".console")
        XCTAssertNil(DiagnosticRecordingStore.parse(fileName: stem + ".log"))
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".hevc")?.kind, .video)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".h264")?.kind, .video)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".hevc.index.csv")?.kind, .videoIndex)
        XCTAssertEqual(DiagnosticRecordingStore.parse(fileName: stem + ".hevc.index.csv")?.stem, stem)
        XCTAssertNil(DiagnosticRecordingStore.parse(fileName: stem + ".txt"))
        XCTAssertNil(DiagnosticRecordingStore.parse(fileName: ".csv"))

        let name = try XCTUnwrap(DiagnosticRecordingStore.parse(stem: stem))
        XCTAssertEqual(name.profile, "my.game_1")
        XCTAssertEqual(name.startedAt.timeIntervalSince1970, 1_735_689_600.25, accuracy: 0.000_01)
        for bad in [
            "20250101T000000.250000Z-", "20250101T000000.250000Z", "20250101T000000.250000Z-a/b",
            "20250101X000000.250000Z-game", "2025010aT000000.250000Z-game", "20250230T000000.250000Z-game",
            "20250101T250000.250000Z-game", "game", "",
        ] {
            XCTAssertNil(DiagnosticRecordingStore.parse(stem: bad), bad)
        }
    }

    // MARK: - Summary

    func testSummaryAtSeventyTwoHertzMatchesTheReferenceRules() throws {
        // Period 13.889 ms: late from 16.667 ms, very late from 26.389 ms,
        // GPU from 13.9 ms, a thread from 8 ms.
        var trace = SyntheticTrace()
        for _ in 0..<5 { trace.frame(interval: 13_889) }
        trace.frame(interval: 17_000, gameThread: 7_900)           // other: the thread is just under
        trace.late(frame: trace.lastFrame, gpuFenceWait: 13_850)   // just under: not the GPU
        trace.frame(interval: 28_000, gameThread: 9_000)           // game thread, very late
        trace.late(frame: trace.lastFrame, gpuFenceWait: 13_950)
        trace.frame(interval: 17_000, gameThread: 8_100)           // the GPU wins over the game thread
        trace.frame(interval: 13_889)

        let summary = try XCTUnwrap(FrameTraceSummary.parse(trace.data))
        XCTAssertEqual(summary.intervals, 8)
        XCTAssertEqual(summary.framePeriodMicroseconds, 13_889)
        XCTAssertEqual(summary.duration, 0.131_445, accuracy: 1e-9)
        XCTAssertEqual(summary.framesPerSecond, 8 / 0.131_445, accuracy: 1e-6)
        XCTAssertEqual(summary.lateShare, 3.0 / 8)
        XCTAssertEqual(summary.veryLateShare, 1.0 / 8)
        XCTAssertEqual(summary.longestPauseMicroseconds, 28_000)
        XCTAssertEqual(summary.lateCauses, FrameTraceSummary.Causes(gpu: 1, gameThread: 1, other: 1))
        XCTAssertEqual(summary.lateFrames, 3)
    }

    func testSummaryScalesItsThresholdsToAnotherRefreshRate() throws {
        // Period 10 ms (not 72 Hz): late from 12 ms, very late from 19 ms,
        // GPU from 10.008 ms, a thread from 5.76 ms. At the 72 Hz constants
        // (17 ms, 27 ms, 13.9 ms, 8 ms) only one of these frames would be late.
        var trace = SyntheticTrace()
        trace.comment("clock_monotonic_us=1000")
        for _ in 0..<3 { trace.frame(interval: 10_000) }
        trace.late(frame: trace.lastFrame, gpuFenceWait: 12_000)   // counted for the next frame too
        trace.frame(interval: 10_000)
        trace.frame(interval: 15_000)                              // GPU, from the frame before
        trace.frame(interval: 10_000)
        trace.event("head_tracking_valid")
        trace.frame(interval: 10_000)
        trace.frame(interval: 20_000, gameThread: 9_000)           // game thread, very late
        trace.frame(interval: 10_000, renderThread: 6_000)
        trace.frame(interval: 13_000)                              // render thread, from the frame before
        trace.frame(interval: 12_500)                              // other
        // Skipped whole: too few fields, then a field that is not a number.
        // Read as frames they would stretch the session to nine seconds.
        trace.raw("frame,98,9000000")
        trace.raw(SyntheticTrace.columns.map { column in
            switch column {
            case "type": "frame"
            case "text": ""
            case "frame": "99"
            case "wait_exit": "9000000"
            case "end_exit": "9000100"
            case "left_width": "wide"
            default: "0"
            }
        }.joined(separator: ","))
        trace.late(frame: 3, gpuFenceWait: -1)                     // unknown: does not replace 12 ms
        trace.incompleteFrame(interval: 10_000)                    // breaks the run of consecutive frames
        trace.frame(interval: 10_000)
        trace.partialLine("frame,14,123")

        let summary = try XCTUnwrap(FrameTraceSummary.parse(trace.data))
        XCTAssertEqual(summary.intervals, 10)
        XCTAssertEqual(summary.framePeriodMicroseconds, 10_000)
        XCTAssertEqual(summary.duration, 0.1405, accuracy: 1e-9)
        XCTAssertEqual(summary.framesPerSecond, 10 / 0.1405, accuracy: 1e-6)
        XCTAssertEqual(summary.lateShare, 0.4)
        XCTAssertEqual(summary.veryLateShare, 0.1)
        XCTAssertEqual(summary.longestPauseMicroseconds, 20_000)
        XCTAssertEqual(summary.lateCauses,
                       FrameTraceSummary.Causes(gpu: 1, gameThread: 1, renderThread: 1, other: 1))
        XCTAssertEqual(summary.lateFrames, 4)
    }

    func testSummarySkipsRowsWithNumbersOutOfRangeInsteadOfTrapping() throws {
        // Frames 1...3, 10 ms apart, from 1,000,000 us.
        var clean = SyntheticTrace()
        for _ in 0..<3 { clean.frame(interval: 10_000) }
        let expected = try XCTUnwrap(FrameTraceSummary.parse(clean.data))
        XCTAssertEqual(expected.intervals, 2)

        func frameRow(_ number: Int64, waitEnter: Int64 = 0, waitExit: Int64,
                      begin: Int64 = 0, endEnter: Int64 = 0) -> String {
            let values = ["frame": number, "wait_enter": waitEnter, "wait_exit": waitExit,
                          "begin": begin, "end_enter": endEnter, "end_exit": 1]
            return SyntheticTrace.columns.map { column in
                switch column {
                case "type": "frame"
                case "text": ""
                default: String(values[column] ?? 0)
                }
            }.joined(separator: ",")
        }
        let damaged = [
            // Between frames 1 and 2: its number plus one overflows.
            frameRow(.max, waitExit: 1_000_001),
            // The frame before frame 1: EndFrame minus BeginFrame overflows.
            frameRow(0, waitExit: 999_999, begin: -1, endEnter: .max),
            // The frame after frame 3: its WaitFrame minus frame 3's EndFrame overflows.
            frameRow(4, waitEnter: -.max, waitExit: 2_000_000),
            // The frame after frame 3, 292,000 years later: no overflow here,
            // but a pause the Diagnostics page could not round.
            frameRow(4, waitExit: .max),
        ]
        for row in damaged {
            var trace = clean
            trace.raw(row)
            XCTAssertEqual(FrameTraceSummary.parse(trace.data), expected, row)
        }
    }

    func testSummaryNeedsTwoConsecutiveCompletedFrames() {
        XCTAssertNil(FrameTraceSummary.parse(Data()))
        XCTAssertNil(FrameTraceSummary.parse(Data("# trailbridge_frame_trace_version=1\n".utf8)))
        XCTAssertNil(FrameTraceSummary.parse(Data("type,frame\nframe,1\n".utf8)))
        var header = SyntheticTrace()
        XCTAssertNil(FrameTraceSummary.parse(header.data))
        header.frame(interval: 10_000)
        XCTAssertNil(FrameTraceSummary.parse(header.data))
        var gap = SyntheticTrace()
        gap.frame(interval: 10_000)
        gap.incompleteFrame(interval: 10_000)
        gap.frame(interval: 10_000)
        XCTAssertNil(FrameTraceSummary.parse(gap.data))
        header.frame(interval: 10_000)
        XCTAssertEqual(FrameTraceSummary.parse(header.data)?.intervals, 1)
        XCTAssertEqual(FrameTraceSummary.parse(header.data)?.lateFrames, 0)
    }

    func testSummaryIsCachedUntilTheFileChanges() throws {
        let root = try symlinkFreeDirectory()
        let session = try record(in: root, profile: "game", at: 1_735_689_600, frames: true, video: nil)
        var trace = SyntheticTrace()
        for _ in 0..<4 { trace.frame(interval: 10_000) }
        try trace.data.write(to: session.csv)
        let store = DiagnosticRecordingStore(dataRoot: root)
        let cache = FrameTraceSummaryCache()

        let listed = try XCTUnwrap(store.list().first?.frames)
        XCTAssertEqual(cache.summary(for: listed)?.intervals, 3)
        // Same size and date: the cached answer, even though the file is gone.
        try FileManager.default.removeItem(at: session.csv)
        XCTAssertEqual(cache.summary(for: listed)?.intervals, 3)

        trace.frame(interval: 10_000)
        try trace.data.write(to: session.csv)
        let changed = try XCTUnwrap(store.list().first?.frames)
        XCTAssertNotEqual(changed.bytes, listed.bytes)
        XCTAssertEqual(cache.summary(for: changed)?.intervals, 4)
        cache.keep(only: [])
        try FileManager.default.removeItem(at: session.csv)
        XCTAssertNil(cache.summary(for: changed))
    }

    // MARK: - Helpers

    /// The storage walk refuses symlinks, and the system temporary folder is
    /// reached through one, so these tests use the project's own.
    private func symlinkFreeDirectory() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".local/tmp/diagnostic-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func record(in root: URL, profile: String, at time: TimeInterval,
                        frames: Bool, video: String?) throws -> FrameTraceSession {
        var environment = [String: String]()
        let session = try XCTUnwrap(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: root, prefix: root.appendingPathComponent("prefix"),
            profile: profile, tracesFrames: frames, recordsVideo: video != nil,
            now: Date(timeIntervalSince1970: time)))
        if let video {
            // The streamer creates the video itself.
            try write("", to: session.video(codecExtension: video))
        }
        return session
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}

/// Builds a frame CSV in the runtime's format (`runtime/pe/frame_trace.cpp`).
private struct SyntheticTrace {
    static let columns = [
        "type", "frame", "timestamp", "text", "wait_enter", "budget_wait", "wait_exit", "predicted_display",
        "begin", "end_enter", "end_exit", "end_display_time", "end_result", "layer_count",
        "projection_layers", "quad_layers", "other_layers", "haveFrameViews", "controlFrameReady",
        "left_swapchain", "left_image", "left_slice", "left_width", "left_height",
        "right_swapchain", "right_image", "right_slice", "right_width", "right_height",
        "head_tracked", "head_age", "left_active", "left_age", "right_active", "right_age",
        "gpu_fence_wait", "consume_wait", "control_frame",
    ]

    private var lines = [
        "# trailbridge_frame_trace_version=1",
        "# missing_timestamp=0; unknown_duration_or_state=-1; incomplete_frame has no successful EndFrame",
        SyntheticTrace.columns.joined(separator: ","),
    ]
    private var tail = ""
    private(set) var lastFrame: Int64 = 0
    private var waitExit: Int64 = 1_000_000
    /// When the previous frame's EndFrame returned, plus the game thread's time after it.
    private var nextWaitEnter: Int64 = 999_500

    var data: Data { Data((lines.joined(separator: "\n") + "\n" + tail).utf8) }

    /// A completed frame `interval` after the previous one. `renderThread` is
    /// its BeginFrame-to-EndFrame time; `gameThread` is the time from the
    /// previous frame's EndFrame to this frame's WaitFrame.
    mutating func frame(interval: Int64, renderThread: Int64 = 1_000, gameThread: Int64 = 500,
                        completed: Bool = true) {
        if lastFrame > 0 {
            waitExit += interval
            nextWaitEnter += gameThread - 500
        }
        lastFrame += 1
        let begin = waitExit + 100
        let endEnter = begin + renderThread
        let endExit = endEnter + 200
        row("frame", [
            "frame": lastFrame, "timestamp": nextWaitEnter, "wait_enter": nextWaitEnter, "wait_exit": waitExit,
            "begin": begin, "end_enter": endEnter, "end_exit": completed ? endExit : 0,
            "end_result": completed ? 0 : -1, "left_width": 2064, "left_height": 2272,
            "gpu_fence_wait": -1, "consume_wait": -1,
        ], text: completed ? "" : "incomplete_frame")
        nextWaitEnter = endExit + 500
    }

    mutating func incompleteFrame(interval: Int64) {
        frame(interval: interval, completed: false)
    }

    mutating func late(frame: Int64, gpuFenceWait: Int64) {
        row("late", ["frame": frame, "timestamp": waitExit, "gpu_fence_wait": gpuFenceWait, "consume_wait": -1])
    }

    mutating func event(_ text: String) {
        row("event", ["timestamp": waitExit], text: text)
    }

    mutating func comment(_ text: String) { lines.append("# " + text) }
    mutating func raw(_ line: String) { lines.append(line) }
    mutating func partialLine(_ text: String) { tail = text }

    private mutating func row(_ type: String, _ values: [String: Int64], text: String = "") {
        lines.append(Self.columns.map { column in
            switch column {
            case "type": type
            case "text": text
            default: String(values[column] ?? 0)
            }
        }.joined(separator: ","))
    }
}
