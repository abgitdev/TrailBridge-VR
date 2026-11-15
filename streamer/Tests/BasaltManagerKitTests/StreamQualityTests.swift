import XCTest
import BasaltManagerKit
import BasaltCore

final class StreamQualityTests: XCTestCase {
    func testRecommendationMapping() {
        let cases: [(String, UInt64, StreamQualityPreset, Bool)] = [
            ("Apple M1", 8, .balanced, false),
            ("Apple M1", 32, .balanced, false),
            ("Apple M2", 24, .balanced, false),
            ("Apple M3", 24, .balanced, false),
            ("Apple M2 Pro", 32, .high, false),
            ("Apple M4", 16, .balanced, false),
            ("Apple M4", 24, .quality, true),
            ("Apple M4", 32, .quality, true),
            ("Apple M4 Max", 64, .high, false),
            ("Apple M3 Ultra", 96, .maximum, false),
            ("Apple M5", 32, .maximum, false),
            ("Apple M6 Pro", 32, .maximum, false),
            ("Apple M10", 32, .maximum, false),
            ("Apple M2 Pro", 8, .balanced, false),
            ("Unknown", 32, .balanced, false),
        ]
        for (brand, gb, preset, tested) in cases {
            let recommendation = StreamQualityRecommendation.recommend(
                brand: brand, memoryBytes: gb * 1024 * 1024 * 1024)
            XCTAssertEqual(recommendation.preset, preset, brand)
            XCTAssertEqual(recommendation.isTested, tested, brand)
            XCTAssertEqual(recommendation.evidence,
                           tested ? "tested" : "estimate — not tested yet", brand)
            XCTAssertEqual(recommendation.settings.qualityPreset, preset, brand)
            XCTAssertEqual(recommendation.settings.codec, .hevc, brand)
        }
    }

    func testEachPresetGeneratesHEVCStreamerArguments() throws {
        let cases: [(StreamQualityPreset, String, Int, Int, Int, HeadsetFilterLevel)] = [
            (.performance, "performance", 896, 944, 30, .off),
            (.balanced, "balanced", 1152, 1216, 50, .off),
            (.quality, "quality", 1344, 1408, 80, .quality),
            (.high, "1536x1600", 1536, 1600, 80, .quality),
            (.maximum, "1680x1760", 1680, 1760, 80, .quality),
        ]
        for (preset, resolution, width, height, mbps, aa) in cases {
            var settings = StreamLaunchSettings()
            settings.fps = 120
            settings.latency = .ultra
            settings.questSharpening = .quality
            settings.selectQuality(preset)
            // 1680x1760 at 72 Hz is more than low-latency rate control keeps up with.
            var expected = ["--wired", "--fps", "72", "--mbps", String(mbps),
                            "--resolution", resolution, "--latency", "low",
                            "--low-latency-rc", preset == .maximum ? "off" : "on", "--codec", "hevc"]
            if aa != .off { expected += ["--quest-supersampling", "quality"] }
            expected += ["--game-audio", "mac"]
            XCTAssertEqual(settings.arguments, expected, preset.label)
            XCTAssertEqual(settings.resolution.perEyeResolution.width, width)
            XCTAssertEqual(settings.resolution.perEyeResolution.height, height)
            XCTAssertEqual(settings.questSupersampling, aa)
            XCTAssertEqual(settings.codec, .hevc)
            XCTAssertEqual(settings.qualityPreset, preset)
            XCTAssertTrue(preset.matches(settings))
            let parsed = try XCTUnwrap(StreamerOptions.parse(settings.arguments))
            XCTAssertEqual(parsed.codec, .hevc)
            XCTAssertEqual(parsed.megabits, mbps)
            XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONEncoder().encode(settings)), settings)
        }
    }

    func testIndividualEditsSwitchToCustom() {
        let edits: [(inout StreamLaunchSettings) -> Void] = [
            { $0.resolution = .high }, { $0.megabits = 85 },
            { $0.questSupersampling = .normal }, { $0.questSharpening = .normal },
            { $0.fps = 90 }, { $0.latency = .balanced },
            { $0.codec = .h264 },
        ]
        for edit in edits {
            var settings = StreamLaunchSettings()
            settings.selectQuality(.quality)
            edit(&settings)
            XCTAssertEqual(settings.qualityPreset, .custom)
            settings.selectQuality(.balanced)
            XCTAssertEqual(settings.qualityPreset, .balanced)
        }
    }

    func testCustomPreservesValuesAndSurvivesSaving() throws {
        var settings = StreamLaunchSettings()
        settings.selectQuality(.maximum)
        let arguments = settings.arguments
        settings.selectQuality(.custom)
        XCTAssertEqual(settings.arguments, arguments)
        XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self,
            from: JSONEncoder().encode(settings)).qualityPreset, .custom)
    }

    func testConnectionAndAudioDoNotChangeQuality() {
        var settings = StreamLaunchSettings()
        settings.selectQuality(.quality)
        settings.connection = .wifi
        settings.gameAudioChoice = .device("Test audio")
        settings.selectQuality(.high)
        XCTAssertEqual(settings.qualityPreset, .high)
        XCTAssertEqual(settings.connection, .wifi)
        XCTAssertEqual(Array(settings.arguments.suffix(3)), ["--audio-device", "Test audio", "--route-audio"])
    }

    func testBitrateStaysWithinWhatTheCodecKeepsDecodable() throws {
        var settings = StreamLaunchSettings()
        settings.megabits = 300
        XCTAssertTrue(settings.arguments.contains("300"))
        settings.codec = .hevc
        XCTAssertEqual(settings.megabits, 240)
        settings.codec = .h264
        XCTAssertEqual(settings.megabits, 240)

        // A value saved before the limit, or by hand, must not stop the launch.
        let saved = #"{"codec":"hevc","megabits":500}"#
        let decoded = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(saved.utf8))
        let mbps = try XCTUnwrap(decoded.arguments.firstIndex(of: "--mbps"))
        XCTAssertEqual(decoded.arguments[mbps + 1], "240")
        XCTAssertNoThrow(try StreamerOptions.parse(decoded.arguments))
    }

    func testLegacySettingsInferOnlyExactPresets() throws {
        let legacy = #"{"connection":"wifi","fps":90,"megabits":80,"resolution":"quality","latency":"ultra","audioDeviceName":"Test audio"}"#
        let decoded = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.qualityPreset, .custom)
        XCTAssertEqual(decoded.arguments, ["--wireless", "--fps", "90", "--mbps", "80",
            "--resolution", "quality", "--latency", "low", "--low-latency-rc", "on",
            "--audio-device", "Test audio", "--route-audio"])
        for latency in ["ultra", "balanced"] {
            let json = "{\"latency\":\"\(latency)\"}"
            let restored = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(json.utf8))
            XCTAssertEqual(restored.latency, .low)
            let latency = try XCTUnwrap(restored.arguments.firstIndex(of: "--latency"))
            XCTAssertEqual(restored.arguments[latency + 1], "low")
        }
        let minimal = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal, StreamLaunchSettings())
        XCTAssertEqual(minimal.qualityPreset, .custom)
        for preset in StreamQualityPreset.presets {
            var settings = StreamLaunchSettings()
            settings.selectQuality(preset)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            json.removeValue(forKey: "qualityPreset")
            let restored = try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored.qualityPreset, preset)
            XCTAssertEqual(restored.arguments, settings.arguments)
        }
    }

    func testAlmostMatchingLegacySettingsRemainCustom() throws {
        let edits: [(inout StreamLaunchSettings) -> Void] = [
            { s in s.fps = 90 },
            { s in s.questSharpening = .normal },
            { s in s.questSupersampling = .off },
            { s in s.megabits = 75 },
        ]
        for edit in edits {
            var settings = StreamLaunchSettings()
            settings.selectQuality(.quality)
            edit(&settings)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            json.removeValue(forKey: "qualityPreset")
            let restored = try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored.qualityPreset, .custom)
            XCTAssertEqual(restored.arguments, settings.arguments)
        }
    }

    func testSavedH264PresetsRemainCustomWithoutChangingValues() throws {
        for preset in StreamQualityPreset.presets {
            var settings = StreamLaunchSettings()
            settings.selectQuality(preset)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(settings)) as? [String: Any])
            json.removeValue(forKey: "codec")
            // Preserve the older preset bitrates when restoring saved settings.
            if preset == .high { json["megabits"] = 100 }
            if preset == .maximum { json["megabits"] = 120 }
            let decoded = try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.codec, .h264)
            XCTAssertEqual(decoded.qualityPreset, .custom)
            XCTAssertEqual(decoded.megabits, json["megabits"] as? Int)
            XCTAssertEqual(decoded.resolution, settings.resolution)
            XCTAssertEqual(decoded.questSupersampling, settings.questSupersampling)
            XCTAssertFalse(decoded.arguments.contains("--codec"))
            XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONEncoder().encode(decoded)), decoded)
        }
    }

    func testExplicitH264DecodesAsCustomEvenWithSavedPresetLabel() throws {
        let json = #"{"codec":"h264","megabits":80,"resolution":"quality","questSupersampling":"quality","qualityPreset":"quality"}"#
        let decoded = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.codec, .h264)
        XCTAssertEqual(decoded.qualityPreset, .custom)
        XCTAssertFalse(StreamQualityPreset.quality.matches(decoded))
    }

    func testGamePriorityIsOffByDefaultAndIndependentOfQuality() throws {
        var settings = StreamLaunchSettings()
        XCTAssertFalse(settings.gamePriorityHigh)
        // Settings saved before the option existed keep it off.
        let legacy = try JSONDecoder().decode(StreamLaunchSettings.self,
                                              from: Data(#"{"megabits":80}"#.utf8))
        XCTAssertFalse(legacy.gamePriorityHigh)

        settings.selectQuality(.quality)
        settings.gamePriorityHigh = true
        XCTAssertEqual(settings.qualityPreset, .quality)
        XCTAssertTrue(StreamQualityPreset.quality.matches(settings))
        // The streamer has no such flag: the app applies it to the game process.
        XCTAssertFalse(settings.arguments.contains { $0.localizedCaseInsensitiveContains("priority") })

        settings.selectQuality(.balanced)
        XCTAssertTrue(settings.gamePriorityHigh)
        let decoded = try JSONDecoder().decode(StreamLaunchSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.gamePriorityHigh)
        XCTAssertEqual(decoded.qualityPreset, .balanced)
    }
}
