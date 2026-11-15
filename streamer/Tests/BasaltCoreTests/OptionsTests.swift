import XCTest
@testable import BasaltCore

final class OptionsTests: XCTestCase {
    func testCodecSelectionDefaultsValidationAndFallbackOptIn() throws {
        let defaults = try XCTUnwrap(StreamerOptions.parse([]))
        XCTAssertEqual(defaults.codec, .h264)
        XCTAssertFalse(defaults.allowHEVCRateControlFallback)
        for codec in VideoCodec.allCases {
            let options = try XCTUnwrap(StreamerOptions.parse(["--codec", codec.rawValue]))
            XCTAssertEqual(options.codec, codec)
            XCTAssertTrue(options.lowLatencyRateControl)
            XCTAssertFalse(options.allowHEVCRateControlFallback)
        }
        XCTAssertTrue(try XCTUnwrap(StreamerOptions.parse([
            "--codec", "hevc", "--allow-hevc-rc-fallback"])).allowHEVCRateControlFallback)
        XCTAssertEqual(try StreamerOptions.parse(["--codec", "HEVC"])?.codec, .hevc)
        for args in [["--codec"], ["--codec", "av1"], ["--codec", "h265"], ["--codec", ""]] {
            XCTAssertThrowsError(try StreamerOptions.parse(args))
        }
        XCTAssertTrue(StreamerOptions.usage.contains("--codec <h264|hevc>"))
        XCTAssertTrue(StreamerOptions.usage.contains("--allow-hevc-rc-fallback"))
    }

    func testDefaultsAreLocalOnly() throws {
        let options = try XCTUnwrap(StreamerOptions.parse([]))
        XCTAssertEqual(options.port, 9999)
        XCTAssertEqual(options.fps, 72)
        XCTAssertEqual(options.megabits, 30)
        XCTAssertEqual(options.perEyeResolution, .quality)
        XCTAssertEqual(options.latencyPreset, .low)
        XCTAssertEqual(options.encoderPriority, .speed)
        XCTAssertTrue(options.lowLatencyRateControl)
        XCTAssertEqual(options.questSupersampling, .off)
        XCTAssertEqual(options.questSharpening, .off)
        XCTAssertEqual(options.bindHost, "127.0.0.1")
        XCTAssertTrue(options.bindIsLoopback)
        XCTAssertFalse(options.discover)
        XCTAssertFalse(options.wired)
        XCTAssertNil(options.audioDeviceName)
        XCTAssertFalse(options.routeAudioToCaptureDevice)
        XCTAssertFalse(options.listAudioDevices)
    }

    func testAllFlags() throws {
        let options = try XCTUnwrap(StreamerOptions.parse(
            ["--port", "8000", "--fps", "72", "--mbps", "40",
             "--resolution", "quality", "--latency", "ultra",
             "--bind", "0.0.0.0", "--discover",
             "--audio-device", "BlackHole 2ch", "--route-audio"]))
        XCTAssertEqual(options.port, 8000)
        XCTAssertEqual(options.fps, 72)
        XCTAssertEqual(options.megabits, 40)
        XCTAssertEqual(options.perEyeResolution, .quality)
        XCTAssertEqual(options.latencyPreset, .ultra)
        XCTAssertEqual(options.bindHost, "0.0.0.0")
        XCTAssertFalse(options.bindIsLoopback)
        XCTAssertTrue(options.discover)
        XCTAssertFalse(options.wired)
        XCTAssertEqual(options.audioDeviceName, "BlackHole 2ch")
        XCTAssertTrue(options.routeAudioToCaptureDevice)
    }

    func testHelpReturnsNil() throws {
        XCTAssertNil(try StreamerOptions.parse(["--help"]))
        XCTAssertNil(try StreamerOptions.parse(["-h"]))
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--frobnicate"]))
    }

    func testWiredModeIsExclusiveWithDiscovery() throws {
        let wired = try XCTUnwrap(StreamerOptions.parse(["--wired"]))
        XCTAssertTrue(wired.wired)
        XCTAssertFalse(wired.discover)
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--discover"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--wireless"]))
    }

    func testWirelessFlagAndLegacyDiscoveryAlias() throws {
        let wireless = try XCTUnwrap(StreamerOptions.parse(["--wireless"]))
        XCTAssertTrue(wireless.discover)
        XCTAssertFalse(wireless.wired)

        let legacy = try XCTUnwrap(StreamerOptions.parse(["--discover"]))
        XCTAssertEqual(legacy, wireless)
    }

    func testAudioRequiresHeadsetModeAndListDoesNot() throws {
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--audio-device", "BlackHole 2ch"]))
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--wired", "--audio-device", " "]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--route-audio"]))
        let options = try XCTUnwrap(StreamerOptions.parse(["--list-audio-devices"]))
        XCTAssertTrue(options.listAudioDevices)
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--port"]))
    }

    func testNonNumericValueThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--fps", "fast"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--port", "-1"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--mbps", "0"]))
    }

    func testRejectsValuesOutsideOperationalRanges() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--fps", "241"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--mbps", "301"]))
        XCTAssertNoThrow(try StreamerOptions.parse(["--fps", "240", "--mbps", "300"]))
    }

    func testBitrateLimitFollowsTheCodec() throws {
        // HEVC above 240 Mbps declares level 7.x, which decoders could not read.
        XCTAssertNoThrow(try StreamerOptions.parse(["--codec", "hevc", "--mbps", "240"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--mbps", "241", "--codec", "hevc"])) {
            XCTAssertTrue("\($0)".contains("at most 240"), "\($0)")
        }
        XCTAssertEqual(try StreamerOptions.parse(["--mbps", "300"])?.megabits, 300)
        XCTAssertEqual(VideoCodec.hevc.maximumMegabits, 240)
        XCTAssertEqual(VideoCodec.h264.maximumMegabits, 300)
    }

    func testBindRequiresIPAddress() throws {
        XCTAssertThrowsError(try StreamerOptions.parse(["--bind", "example.com"]))
        let v6 = try XCTUnwrap(StreamerOptions.parse(["--bind", "::1"]))
        XCTAssertTrue(v6.bindIsLoopback)
    }

    func testResolutionPresetsAndCustomDimensions() throws {
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "performance"])?.perEyeResolution,
                       .performance)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "BALANCED"])?.perEyeResolution,
                       .balanced)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "quality"])?.perEyeResolution,
                       .quality)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "1680X1760"])?.perEyeResolution,
                       try PerEyeResolution(width: 1_680, height: 1_760))
    }

    func testRejectsInvalidResolutionsAndLatencyPreset() {
        for value in ["unknown", "1920", "1920x", "0x1080", "511x512", "512x513",
                      "128x128", "8192x8192"] {
            XCTAssertThrowsError(try StreamerOptions.parse(["--resolution", value]), value)
        }
        XCTAssertThrowsError(try StreamerOptions.parse(["--latency", "extreme"]))
    }

    func testEncoderPriorityValues() throws {
        for (value, expected) in [("speed", EncoderPriority.speed), ("QUALITY", .quality)] {
            XCTAssertEqual(try StreamerOptions.parse(["--encoder-priority", value])?.encoderPriority,
                           expected)
        }
    }

    func testLowLatencyRateControlValues() throws {
        XCTAssertEqual(try StreamerOptions.parse(["--low-latency-rc", "ON"])?.lowLatencyRateControl, true)
        XCTAssertEqual(try StreamerOptions.parse(["--low-latency-rc", "off"])?.lowLatencyRateControl, false)
    }

    func testQuestPostProcessingValues() throws {
        for (value, expected) in [("off", QuestPostProcessingLevel.off), ("normal", .normal),
                                  ("QUALITY", .quality)] {
            let supersampling = try XCTUnwrap(StreamerOptions.parse(["--quest-supersampling", value]))
            XCTAssertEqual(supersampling.questSupersampling, expected)
            XCTAssertEqual(supersampling.questSharpening, .off)
            let sharpening = try XCTUnwrap(StreamerOptions.parse(["--quest-sharpening", value]))
            XCTAssertEqual(sharpening.questSharpening, expected)
            XCTAssertEqual(sharpening.questSupersampling, .off)
        }
    }

    func testQualitySwitchesAreIndependentAndCompose() throws {
        let defaults = try XCTUnwrap(StreamerOptions.parse([]))
        XCTAssertEqual(try StreamerOptions.parse([
            "--encoder-priority", "speed", "--low-latency-rc", "on",
            "--quest-supersampling", "off", "--quest-sharpening", "off"]), defaults)
        var expected = defaults
        expected.encoderPriority = .quality
        XCTAssertEqual(try StreamerOptions.parse(["--encoder-priority", "quality"]), expected)
        expected = defaults
        expected.lowLatencyRateControl = false
        XCTAssertEqual(try StreamerOptions.parse(["--low-latency-rc", "off"]), expected)
        expected.encoderPriority = .quality
        expected.questSupersampling = .normal
        expected.questSharpening = .quality
        XCTAssertEqual(try StreamerOptions.parse([
            "--encoder-priority", "quality", "--low-latency-rc", "off",
            "--quest-supersampling", "normal", "--quest-sharpening", "quality"]), expected)
    }

    func testQualitySwitchesRejectMissingAndInvalidValues() {
        for flag in ["--encoder-priority", "--low-latency-rc",
                     "--quest-supersampling", "--quest-sharpening"] {
            XCTAssertThrowsError(try StreamerOptions.parse([flag]), flag)
            for invalid in ["", "invalid", "true", "1", "--fps"] {
                XCTAssertThrowsError(try StreamerOptions.parse([flag, invalid]), "\(flag) \(invalid)")
            }
            XCTAssertTrue(StreamerOptions.usage.contains(flag))
        }
    }

    func testRawStreamPortOpensForTheDemoAndOnlyOnRequestInAHeadsetSession() throws {
        // The desktop demo and a runtime-only run serve ffplay as before.
        XCTAssertEqual(try StreamerOptions.parse([])?.opensDebugStream, true)
        XCTAssertEqual(try StreamerOptions.parse(["--runtime", "x.control"])?.opensDebugStream, true)
        // A headset session has no reader for the port: what the app passes.
        for connection in ["--wireless", "--wired"] {
            let app = [connection, "--fps", "72", "--mbps", "30", "--resolution", "quality",
                       "--latency", "low", "--runtime", "x.control", "--trust-file", "trust.json"]
            XCTAssertEqual(try StreamerOptions.parse(app)?.opensDebugStream, false, connection)
            XCTAssertEqual(try StreamerOptions.parse(app + ["--port", "9999"])?.opensDebugStream,
                           true, connection)
            XCTAssertEqual(try StreamerOptions.parse(app + ["--bind", "127.0.0.1"])?.opensDebugStream,
                           true, connection)
        }
    }
}
