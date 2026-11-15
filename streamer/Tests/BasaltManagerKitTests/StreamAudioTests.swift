import XCTest
import BasaltCore
import BasaltManagerKit

final class StreamAudioTests: XCTestCase {
    private let blackHole = GameAudioDevice(id: 1, name: "BlackHole 2ch", sampleRate: 44_100)
    private let microphone = GameAudioDevice(id: 2, name: "Microphone", sampleRate: 48_000)

    func testMacAudioIsTheDefaultAndReachesTheStreamer() throws {
        var settings = StreamLaunchSettings()
        settings.selectQuality(.quality)
        XCTAssertEqual(settings.gameAudioChoice, .mac)
        settings.applyAudioDefault(devices: [microphone, blackHole], macAudioSupported: true)
        XCTAssertEqual(settings.gameAudioChoice, .mac)
        XCTAssertEqual(settings.qualityPreset, .quality)
        XCTAssertEqual(Array(settings.arguments.suffix(2)), ["--game-audio", "mac"])
        let parsed = try XCTUnwrap(StreamerOptions.parse(settings.arguments))
        XCTAssertTrue(parsed.captureMacAudio)
        XCTAssertNil(parsed.audioDeviceName)
        XCTAssertFalse(parsed.routeAudioToCaptureDevice)
        XCTAssertEqual(try roundTrip(settings), settings)
    }

    func testOlderMacSwitchesToStereoBlackHoleOnceItIsInstalled() throws {
        var settings = StreamLaunchSettings()
        settings.applyAudioDefault(devices: [
            microphone, GameAudioDevice(id: 3, name: "BlackHole 16ch", sampleRate: 48_000),
        ], macAudioSupported: false)
        settings.applyAudioDefault(devices: [], macAudioSupported: false)
        // Nothing to switch to yet: the choice waits instead of turning Off.
        XCTAssertEqual(settings.gameAudioChoice, .mac)
        XCTAssertEqual(try roundTrip(settings).gameAudioChoice, .mac)

        settings.applyAudioDefault(devices: [
            GameAudioDevice(id: 4, name: "blackhole 2CH", sampleRate: 48_000),
        ], macAudioSupported: false)
        XCTAssertEqual(settings.gameAudioChoice, .device("blackhole 2CH"))
        XCTAssertEqual(Array(settings.arguments.suffix(3)),
                       ["--audio-device", "blackhole 2CH", "--route-audio"])
        let parsed = try XCTUnwrap(StreamerOptions.parse(settings.arguments))
        XCTAssertEqual(parsed.audioDeviceName, "blackhole 2CH")
        XCTAssertTrue(parsed.routeAudioToCaptureDevice)
        XCTAssertFalse(parsed.captureMacAudio)
    }

    func testChosenDeviceAndOffSurviveSavingPresetsAndRefresh() throws {
        var settings = StreamLaunchSettings()
        settings.gameAudioChoice = .device("BlackHole 2ch")
        settings = try roundTrip(settings)
        settings.selectQuality(.maximum)
        settings.applyAudioDefault(devices: [blackHole], macAudioSupported: true)
        XCTAssertEqual(settings.gameAudioChoice, .device("BlackHole 2ch"))

        settings.applyAudioDefault(devices: [blackHole], macAudioSupported: false)
        XCTAssertEqual(settings.gameAudioChoice, .device("BlackHole 2ch"))

        settings.gameAudioChoice = .off
        settings = try roundTrip(settings)
        settings.applyAudioDefault(devices: [blackHole], macAudioSupported: false)
        XCTAssertEqual(settings.gameAudioChoice, .off)
        XCTAssertFalse(settings.arguments.contains("--audio-device"))
        XCTAssertFalse(settings.arguments.contains("--route-audio"))
        XCTAssertFalse(settings.arguments.contains("--game-audio"))
    }

    func testOlderSettingsMoveToMacAudioUnlessThePersonChose() throws {
        let cases: [(String, GameAudioChoice)] = [
            ("{}", .mac),
            (#"{"audioDeviceName":null}"#, .mac),
            // The previous build picked "BlackHole 2ch" by itself, and nothing else.
            (#"{"audioDeviceName":"BlackHole 2ch"}"#, .mac),
            (#"{"audioDeviceName":"blackhole 2CH","audioChoiceMade":false}"#, .mac),
            (#"{"audioDeviceName":"BlackHole 16ch"}"#, .device("BlackHole 16ch")),
            (#"{"audioDeviceName":"Loopback Audio","audioChoiceMade":false}"#, .device("Loopback Audio")),
            (#"{"audioDeviceName":"BlackHole 2ch","audioChoiceMade":true}"#, .device("BlackHole 2ch")),
            (#"{"audioDeviceName":"Missing device","audioChoiceMade":true}"#, .device("Missing device")),
            (#"{"audioChoiceMade":true}"#, .off),
            (#"{"audioDeviceName":"","audioChoiceMade":true}"#, .off),
            (#"{"gameAudio":"device"}"#, .off),
            (#"{"gameAudio":"off","audioDeviceName":"BlackHole 2ch"}"#, .off),
            (#"{"gameAudio":"mac","audioDeviceName":"BlackHole 2ch"}"#, .mac),
        ]
        for (json, expected) in cases {
            let settings = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.gameAudioChoice, expected, json)
        }
    }

    func testPastSessionsKeepTheAudioTheyUsed() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[StreamLaunchSettings.recordedSessionKey] = true
        let cases: [(String, GameAudioChoice)] = [
            (#"{"audioDeviceName":"BlackHole 2ch","audioChoiceMade":false}"#, .device("BlackHole 2ch")),
            (#"{"audioDeviceName":"BlackHole 2ch","audioChoiceMade":true}"#, .device("BlackHole 2ch")),
            ("{}", .off),
            (#"{"gameAudio":"mac","audioChoiceMade":false}"#, .mac),
        ]
        for (json, expected) in cases {
            let settings = try decoder.decode(StreamLaunchSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.gameAudioChoice, expected, json)
        }
    }

    func testThePreviousBuildReadsTheSameChoiceBack() throws {
        func written(_ choice: GameAudioChoice) throws -> [String: Any] {
            var settings = StreamLaunchSettings()
            settings.gameAudioChoice = choice
            let data = try JSONEncoder().encode(settings)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let mac = try written(.mac)
        XCTAssertEqual(mac["gameAudio"] as? String, "mac")
        XCTAssertNil(mac["audioDeviceName"])
        XCTAssertEqual(mac["audioChoiceMade"] as? Bool, false)

        let device = try written(.device("BlackHole 2ch"))
        XCTAssertEqual(device["gameAudio"] as? String, "device")
        XCTAssertEqual(device["audioDeviceName"] as? String, "BlackHole 2ch")
        XCTAssertEqual(device["audioChoiceMade"] as? Bool, true)

        let off = try written(.off)
        XCTAssertEqual(off["gameAudio"] as? String, "off")
        XCTAssertNil(off["audioDeviceName"])
        XCTAssertEqual(off["audioChoiceMade"] as? Bool, true)
    }

    func testEmptyDeviceNameOmitsAudioArguments() {
        var settings = StreamLaunchSettings()
        settings.gameAudioChoice = .device("")
        XCTAssertFalse(settings.arguments.contains("--audio-device"))
        XCTAssertFalse(settings.arguments.contains("--route-audio"))
        XCTAssertFalse(settings.arguments.contains("--game-audio"))
    }

    func testChoiceLabels() {
        XCTAssertFalse(GameAudioChoice.mac.label?.isEmpty ?? true)
        XCTAssertEqual(GameAudioChoice.device("BlackHole 2ch").label, "BlackHole 2ch")
        XCTAssertNil(GameAudioChoice.off.label)
    }

    private func roundTrip(_ settings: StreamLaunchSettings) throws -> StreamLaunchSettings {
        try JSONDecoder().decode(StreamLaunchSettings.self, from: JSONEncoder().encode(settings))
    }
}
