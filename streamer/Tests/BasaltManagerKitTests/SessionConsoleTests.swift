import XCTest
@testable import BasaltManagerKit

@MainActor
final class SessionConsoleTests: XCTestCase {
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
