import XCTest
@testable import BasaltManagerKit

@MainActor
final class SessionConsoleTests: XCTestCase {
    private let pygobjectWarning = #"** (wine:39619): CRITICAL **: 11:21:56.465: pygobject initialization failed: could not import gobject (error was: ModuleNotFoundError("No module named 'gi'"))"#
    private let videoCapsWarning = "(wine:40051): GStreamer-Video-CRITICAL **: 11:22:28.693: gst_video_info_from_caps: assertion 'gst_caps_is_fixed (caps)' failed"

    func testMissingGStreamerWarnsOncePerSession() throws {
        let console = SessionConsole()
        console.restart(with: "Starting the game…\n")
        XCTAssertNil(console.gStreamerWarning(for: .installed(version: nil)))
        let warning = try XCTUnwrap(console.gStreamerWarning(for: .missing))
        XCTAssertTrue(warning.contains(PinnedWine.gStreamerPackageURL.absoluteString))
        XCTAssertTrue(warning.hasSuffix("\n"))
        XCTAssertNil(console.gStreamerWarning(for: .missing))
        XCTAssertEqual(console.log, "Starting the game…\n")

        console.restart()
        XCTAssertEqual(console.gStreamerWarning(for: .missing), warning)
    }

    func testDeviceErrorFinalPartialLineIsCountedAndSourceCanBeReused() {
        let console = SessionConsole()
        let game = NSObject()
        let source = ObjectIdentifier(game)
        let error = "err:   Device error at frame 1: page fault"
        _ = console.append(error + "\n" + error, from: source, prefix: "game: ")
        XCTAssertEqual(console.finish(source, prefix: "game: "), [
            "game: err:   Device error: suppressed 1 repeated command buffer failures",
            "game: err:   Device error: suppressed 1 repeated command buffer failures (total)",
        ])
        XCTAssertTrue(console.finish(source, prefix: "game: ").isEmpty)
        XCTAssertEqual(console.append(error + "\n", from: source, prefix: "game: "),
                       ["game: " + error])
    }

    func testDeviceErrorFloodKeepsCompilerFailureAndFirstGPUError() {
        let console = SessionConsole()
        let game = NSObject()
        let source = ObjectIdentifier(game)
        _ = console.append("err:   Failed to create PSO: compiler interrupted\n", from: source, prefix: "game: ")
        _ = console.append("err:   Device error at fra", from: source, prefix: "game: ")
        _ = console.append("me 42: page fault\r\n", from: source, prefix: "game: ")
        for frame in 43..<10_043 {
            _ = console.append("err:   Device error at frame \(frame): submissions ignored\n",
                               from: source, prefix: "game: ")
        }
        XCTAssertTrue(console.log.hasPrefix("game: err:   Failed to create PSO:"))
        XCTAssertTrue(console.log.contains("game: err:   Device error at frame 42: page fault\n"))
        XCTAssertFalse(console.log.contains("submissions ignored"))
        XCTAssertLessThan(console.log.utf8.count, 3_000)
        XCTAssertEqual(console.finish(source, prefix: "game: "),
                       ["game: err:   Device error: suppressed 10000 repeated command buffer failures (total)"])
    }

    func testDeviceErrorSuppressionIsPerSourceAndResetsForNewSession() {
        let console = SessionConsole()
        let first = NSObject(), second = NSObject()
        let error = "err:   Device error at frame 1: page fault\n"
        _ = console.append(error + error, from: ObjectIdentifier(first), prefix: "game: ")
        XCTAssertEqual(console.append(error, from: ObjectIdentifier(second), prefix: "other: "),
                       ["other: " + error.trimmingCharacters(in: .newlines)])
        // Other error families and ordinary text must remain untouched.
        XCTAssertEqual(console.append("err:   Failed to create compute PSO\nDevice error at frame 2\n"),
                       ["err:   Failed to create compute PSO", "Device error at frame 2"])
        console.restart()
        XCTAssertEqual(console.append(error, from: ObjectIdentifier(first)),
                       [error.trimmingCharacters(in: .newlines)])
    }

    func testGStreamerWarningsKeepTheFirstLineAndCountRepeatsAtEOF() {
        let console = SessionConsole(), steam = NSObject(), game = NSObject()
        let steamSource = ObjectIdentifier(steam), gameSource = ObjectIdentifier(game)
        let pygobjectRepeat = pygobjectWarning.replacingOccurrences(of: "39619", with: "410")
            .replacingOccurrences(of: "11:21:56.465", with: "15:02:04.019")
        let videoCapsRepeat = videoCapsWarning.replacingOccurrences(of: "40051", with: "42")
            .replacingOccurrences(of: "11:22:28.693", with: "01:00:00.007")
        let steamTotal = "steam: " + L10n.string(.modelGStreamerWarningRepeats, "pygobject", Int64(1))
        let gameTotal = "game: " + L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(2))

        XCTAssertEqual(console.append("\r\n", from: steamSource, prefix: "steam: "), [])
        XCTAssertEqual(console.append(pygobjectWarning + "\r\n", from: steamSource, prefix: "steam: "),
                       ["steam: " + pygobjectWarning])
        XCTAssertEqual(console.append("\r\n" + pygobjectRepeat + "\r\n\r\n", from: steamSource, prefix: "steam: "), [])
        XCTAssertEqual(console.append(videoCapsWarning + "\n", from: gameSource, prefix: "game: "),
                       ["game: " + videoCapsWarning])
        XCTAssertEqual(console.append(videoCapsRepeat + "\nLoading level\n" + videoCapsRepeat,
                                      from: gameSource, prefix: "game: "),
                       ["game: Loading level"])
        XCTAssertEqual(console.finish(steamSource, prefix: "steam: "), ["steam: ", steamTotal])
        XCTAssertEqual(console.finish(gameSource, prefix: "game: "), [gameTotal])
        XCTAssertEqual(console.finish(gameSource, prefix: "game: "), [])
        XCTAssertEqual(console.log, [
            "steam: " + pygobjectWarning, "game: " + videoCapsWarning,
            "game: Loading level", "steam: ", steamTotal, gameTotal,
        ].joined(separator: "\n") + "\n")
    }

    func testGStreamerWarningTypesAndSourcesAreCountedIndependently() {
        let console = SessionConsole(), steam = NSObject(), game = NSObject()
        let steamSource = ObjectIdentifier(steam), gameSource = ObjectIdentifier(game)
        let warnings = pygobjectWarning + "\n" + videoCapsWarning + "\n"
        XCTAssertEqual(console.append(warnings + warnings, from: steamSource, prefix: "steam: "),
                       ["steam: " + pygobjectWarning, "steam: " + videoCapsWarning])
        XCTAssertEqual(console.append(warnings, from: gameSource, prefix: "game: "),
                       ["game: " + pygobjectWarning, "game: " + videoCapsWarning])
        XCTAssertEqual(console.finish(gameSource, prefix: "game: "), [])
        XCTAssertEqual(console.finish(steamSource, prefix: "steam: "), [
            "steam: " + L10n.string(.modelGStreamerWarningRepeats, "pygobject", Int64(1)),
            "steam: " + L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(1)),
        ])

        _ = console.append(warnings + warnings, from: steamSource, prefix: "steam: ")
        console.restart()
        XCTAssertEqual(console.append(warnings, from: steamSource, prefix: "steam: "),
                       ["steam: " + pygobjectWarning, "steam: " + videoCapsWarning])
        XCTAssertEqual(console.finish(steamSource, prefix: "steam: "), [])
    }

    func testGStreamerWarningFilterKeepsUnrelatedBlankLinesAndErrors() {
        let console = SessionConsole(), steam = NSObject(), game = NSObject(), wine = NSObject()
        let steamSource = ObjectIdentifier(steam), gameSource = ObjectIdentifier(game)
        let wineSource = ObjectIdentifier(wine)
        let unrelatedError = videoCapsWarning.replacingOccurrences(of: "gst_caps_is_fixed", with: "gst_caps_is_empty")
        _ = console.append("Updating\n\n", from: steamSource, prefix: "steam: ")
        XCTAssertEqual(console.append("\n" + videoCapsWarning + "\n\n", from: gameSource, prefix: "game: "),
                       ["game: " + videoCapsWarning])
        XCTAssertEqual(console.append("Ready\n", from: steamSource, prefix: "steam: "), ["steam: ", "steam: Ready"])
        XCTAssertEqual(console.append(unrelatedError + "\n\n", from: gameSource, prefix: "game: "),
                       ["game: ", "game: " + unrelatedError])
        XCTAssertEqual(console.finish(gameSource, prefix: "game: "), ["game: "])
        XCTAssertEqual(console.append("\t\n  \n  " + pygobjectWarning + "\n", from: wineSource, prefix: "wine: "),
                       ["wine: \t", "wine:   " + pygobjectWarning])
        XCTAssertEqual(console.append("\n"), [""])
    }

    func testGStreamerWarningsTolerateGLibHeadersAndPygobjectErrorDetails() {
        let console = SessionConsole(), pipe = NSObject()
        let source = ObjectIdentifier(pipe)
        let pygobjectVariant = "** (wine64:42): CRITICAL **: "
            + "pygobject initialization failed: could not import gobject (error was: ImportError('binding unavailable'))"
        let capsVariant = videoCapsWarning.replacingOccurrences(of: "wine:40051", with: "wine64-preloader:42")
        let capsWithoutTimestamp = videoCapsWarning.replacingOccurrences(of: "wine:40051", with: "process:7")
            .replacingOccurrences(of: "11:22:28.693: ", with: "")

        XCTAssertEqual(console.append(pygobjectWarning + "\n" + pygobjectVariant + "\n", from: source, prefix: "wine: "),
                       ["wine: " + pygobjectWarning])
        XCTAssertEqual(console.append(capsVariant + "\n" + capsWithoutTimestamp + "\n", from: source, prefix: "wine: "),
                       ["wine: " + capsVariant])
        XCTAssertEqual(console.openRepeatTotals, [
            "wine: " + L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(1)),
            "wine: " + L10n.string(.modelGStreamerWarningRepeats, "pygobject", Int64(1)),
        ].sorted())
    }

    func testKnownHarmlessNoiseRecognizesPrefixedWarningsAndLocalizedTotals() {
        let previous = L10n.language
        defer { L10n.language = previous }
        XCTAssertTrue(SessionConsole.isKnownHarmlessNoise(pygobjectWarning))
        XCTAssertTrue(SessionConsole.isKnownHarmlessNoise("wine: \t" + videoCapsWarning))
        XCTAssertFalse(SessionConsole.isKnownHarmlessNoise("wine: " +
            videoCapsWarning.replacingOccurrences(of: "gst_caps_is_fixed", with: "gst_caps_is_empty")))
        XCTAssertFalse(SessionConsole.isKnownHarmlessNoise("game: GStreamer could not open the video"))
        let totals = AppLanguage.allCases.map { language in
            L10n.language = language
            return L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(9_999))
        }
        L10n.language = .en
        for total in totals {
            XCTAssertTrue(SessionConsole.isKnownHarmlessNoise(total), total)
            XCTAssertTrue(SessionConsole.isKnownHarmlessNoise("other: " + total), total)
        }
    }

    func testGStreamerFloodKeepsOneWarningAndTheExactOpenAndFinalTotal() {
        let console = SessionConsole(), pipe = NSObject()
        let source = ObjectIdentifier(pipe)
        let first = "game: " + videoCapsWarning + "\n"
        let total = "game: " + L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(9_999))
        XCTAssertEqual(console.openRepeatTotals, [])
        _ = console.append("\n" + videoCapsWarning + "\n", from: source, prefix: "game: ")
        XCTAssertEqual(console.openRepeatTotals, [])
        for _ in 1..<10_000 {
            _ = console.append("\n" + videoCapsWarning + "\n", from: source, prefix: "game: ")
        }
        XCTAssertEqual(console.openRepeatTotals, [total])
        XCTAssertEqual(console.diagnosticLog, first + total)
        XCTAssertEqual(console.log, first)
        XCTAssertEqual(console.finish(source), [total])
        XCTAssertEqual(console.openRepeatTotals, [])
        XCTAssertEqual(console.log, first + total + "\n")
        XCTAssertEqual(console.diagnosticLog, console.log)
    }

    func testTranscriptRetainsGStreamerWarningsAndIncludesTheFinalTotal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.console.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))

        let console = SessionConsole(), steam = NSObject()
        let source = ObjectIdentifier(steam)
        let repeatedWarning = pygobjectWarning.replacingOccurrences(of: "39619", with: "410")
        console.restart(transcriptURL: path)
        console.registerOutputSource(source)
        _ = console.append("\n" + pygobjectWarning + "\n\n" + repeatedWarning + "\n", from: source, prefix: "steam: ")
        let closed = expectation(description: "writer closed after EOF")
        console.closeTranscript { closed.fulfill() }
        let total = "steam: " + L10n.string(.modelGStreamerWarningRepeats, "pygobject", Int64(1))
        XCTAssertEqual(console.finish(source, prefix: "steam: "), [total])
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(try String(contentsOf: path), [
            "steam: ", "steam: " + pygobjectWarning, "steam: ", "steam: " + repeatedWarning, total,
        ].joined(separator: "\n") + "\n")
    }

    func testReconnectStatusParsesCompleteStreamerLinesAndClears() {
        let console = SessionConsole()
        _ = console.append("Headset disconnected; waiting for it to recon")
        XCTAssertFalse(console.headsetDisconnected)
        _ = console.append("nect…\n")
        XCTAssertTrue(console.headsetDisconnected)
        _ = console.append("Headset reconnected\n", prefix: "game: ")
        XCTAssertTrue(console.headsetDisconnected)
        _ = console.append("Headset reconnected\n")
        XCTAssertFalse(console.headsetDisconnected)
        _ = console.append("Headset disconnected; waiting for it to reconnect…\n")
        console.restart()
        XCTAssertFalse(console.headsetDisconnected)
    }
    func testReturnsLinesCompletedAcrossChunks() {
        let console = SessionConsole()
        XCTAssertEqual(console.append("Quest 72"), [])
        XCTAssertEqual(console.append(".0 fps\nencoder"), ["Quest 72.0 fps"])
        XCTAssertEqual(console.append(" ready\n"), ["encoder ready"])
        XCTAssertEqual(console.log, "Quest 72.0 fps\nencoder ready\n")
        XCTAssertEqual(console.latestLine, "encoder ready")
    }

    func testKeepsOnePartialLinePerSource() {
        let console = SessionConsole()
        let streamer = NSObject(), game = NSObject()
        XCTAssertEqual(console.append("Quest 7", from: ObjectIdentifier(streamer)), [])
        XCTAssertEqual(console.append("loading\r\nfra", from: ObjectIdentifier(game),
                                      prefix: "game: "), ["game: loading"])
        XCTAssertEqual(console.append("2.0 fps\n", from: ObjectIdentifier(streamer)),
                       ["Quest 72.0 fps"])
        XCTAssertEqual(console.append("me\nnext\n", from: ObjectIdentifier(game),
                                      prefix: "game: "), ["game: frame", "game: next"])
        XCTAssertEqual(console.log, "game: loading\nQuest 72.0 fps\ngame: frame\ngame: next\n")
    }

    func testFlushesAClosedSourceAndCapsAPendingLine() {
        let console = SessionConsole()
        let pipe = ObjectIdentifier(NSObject())
        XCTAssertEqual(console.append("fatal: no headset", from: pipe), [])
        XCTAssertEqual(console.finish(pipe), ["fatal: no headset"])
        XCTAssertEqual(console.finish(pipe), [])
        XCTAssertEqual(console.log, "fatal: no headset\n")

        let flood = String(repeating: "x", count: SessionConsole.maximumPartialLineBytes + 1)
        XCTAssertEqual(console.append(flood, from: pipe), [flood])
        XCTAssertEqual(console.append("tail\n", from: pipe), ["tail"])
    }

    func testTrimsWholeLinesFromTheFront() {
        let console = SessionConsole()
        let line = String(repeating: "x", count: 99) + "\n"
        for index in 0..<1_000 {
            _ = console.append(index == 999 ? "last\n" : line)
        }
        let bytes = console.log.utf8.count
        XCTAssertLessThanOrEqual(bytes, SessionConsole.maximumLogBytes)
        XCTAssertGreaterThanOrEqual(bytes, SessionConsole.retainedLogBytes - line.utf8.count)
        XCTAssertTrue(console.log.hasPrefix(line), "the log must start on a line boundary")
        XCTAssertEqual(console.latestLine, "last")
    }

    func testRestartClearsOutputAndOptionallySamples() {
        let console = SessionConsole()
        _ = console.append("partial")
        console.record(StreamMetricSample(fps: 72))
        console.restart(with: "Launching winecfg…\n", clearingSamples: false)
        XCTAssertEqual(console.log, "Launching winecfg…\n")
        XCTAssertEqual(console.samples.count, 1)
        // The partial line from before the restart is gone.
        XCTAssertEqual(console.append("done\n"), ["done"])

        console.restart()
        XCTAssertEqual(console.log, "")
        XCTAssertTrue(console.samples.isEmpty)
        XCTAssertNil(console.latestLine)
    }

    func testChartsShowARecentWindowOfAllSamples() {
        let console = SessionConsole()
        for index in 0..<(SessionConsole.chartWindow + 10) {
            console.record(StreamMetricSample(fps: Double(index)))
        }
        XCTAssertEqual(console.samples.count, SessionConsole.chartWindow + 10)
        XCTAssertEqual(console.recentSamples.count, SessionConsole.chartWindow)
        XCTAssertEqual(console.recentSamples.first?.fps, 10)
    }
}
