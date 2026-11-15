import XCTest
@testable import BasaltManagerKit
import BasaltBottleKit
import BasaltCore

final class ManagementModelsTests: XCTestCase {
    func testVideoCodecSettingsAreBackwardCompatibleAndOptInPerProfile() throws {
        let legacy = Data(#"{"fps":72,"megabits":80,"resolution":"quality"}"#.utf8)
        var settings = try JSONDecoder().decode(StreamLaunchSettings.self, from: legacy)
        XCTAssertEqual(settings.codec, .h264)
        settings.gameAudioChoice = .off
        let baselineArguments = settings.arguments
        XCTAssertFalse(baselineArguments.contains("--codec"))
        settings.codec = .hevc
        XCTAssertEqual(settings.arguments, baselineArguments + ["--codec", "hevc"])
        XCTAssertEqual(try StreamerOptions.parse(settings.arguments)?.codec, .hevc)
        XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self,
            from: JSONEncoder().encode(settings)), settings)
        let profiles = ["one": settings, "two": StreamLaunchSettings()]
        XCTAssertEqual(try JSONDecoder().decode([String: StreamLaunchSettings].self,
            from: JSONEncoder().encode(profiles)), profiles)
        settings.selectQuality(.balanced)
        XCTAssertEqual(settings.codec, .hevc)
        XCTAssertEqual(StreamLaunchSettings().codec, .h264)
        XCTAssertThrowsError(try JSONDecoder().decode(StreamLaunchSettings.self,
            from: Data(#"{"codec":"av1"}"#.utf8)))
    }

    func testSteamConnectionLogUsesLatestStateAfterSnapshot() {
        let old = "[2026-01-01] [Logged On, 4, 7] ready\n"
        let coldStart = "[2026-01-02] [Logged Off, 0, 0] starting\n"
        let ready = "[2026-01-02] [Logged On, 4, 7] ready\n"
        let oldData = Data(old.utf8)

        XCTAssertEqual(
            SteamConnectionLog.state(in: oldData + Data(coldStart.utf8),
                                     after: oldData.count),
            .loggedOff)
        XCTAssertEqual(
            SteamConnectionLog.state(
                in: oldData + Data((coldStart + ready).utf8),
                after: oldData.count),
            .loggedOn)
        XCTAssertEqual(
            SteamConnectionLog.state(in: Data(coldStart.utf8), after: 10_000),
            .loggedOff)
    }

    func testDetectsBeatSaberAndInfersLaunchSource() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let executable = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: executable)
        let bottle = makeBottle(name: "beat-saber", prefix: prefix)

        let games = GameDetector().detect(bottles: [bottle], profiles: [])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].title, "Beat Saber")
        XCTAssertEqual(games[0].source, .steam)
        XCTAssertEqual(games[0].executable,
                       #"C:\Program Files (x86)\Steam\steamapps\common\Beat Saber\Beat Saber.exe"#)
        XCTAssertNil(games[0].profileName)
    }

    func testProfileWinsOverDuplicateDetectedExecutable() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let executable = prefix.appendingPathComponent("drive_c/Games/Beat Saber/Beat Saber.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: executable)
        let bottle = makeBottle(name: "main", prefix: prefix)
        let profile = LaunchProfile(
            name: "my-beat-saber", bottleName: bottle.name, source: .direct,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#)

        let games = GameDetector().detect(bottles: [bottle], profiles: [profile])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].profileName, profile.name)
    }

    func testTwoBottlesWithOneNameDoNotStopDetection() throws {
        let temporary = try temporaryDirectory()
        let first = makeBottle(
            name: "main", prefix: temporary.appendingPathComponent("first/prefix", isDirectory: true))
        let second = makeBottle(
            name: "main", prefix: temporary.appendingPathComponent("second/prefix", isDirectory: true))
        let profile = LaunchProfile(
            name: "game", bottleName: "main", source: .direct, executable: #"C:\Games\game.exe"#)

        let games = GameDetector().detect(bottles: [first, second], profiles: [profile])

        XCTAssertEqual(games.map(\.profileName), ["game"])
        XCTAssertEqual(games.first?.hostExecutable?.path,
                       first.prefixPath + "/drive_c/Games/game.exe")
    }

    func testStoredTitleNamesTheTileAndOlderProfilesKeepTheirNames() throws {
        let temporary = try temporaryDirectory()
        let bottles = ["brutalistick-vr", "blood-trail", "beat-saber", "folder-games"].map {
            makeBottle(name: $0, prefix: temporary.appendingPathComponent("\($0)/prefix", isDirectory: true))
        }
        let common = #"C:\Program Files (x86)\Steam\steamapps\common\"#
        let profiles = [
            // The two working games' profiles have no title.
            LaunchProfile(
                name: "brutalistick-vr-steam", bottleName: "brutalistick-vr", source: .steam,
                executable: common + #"BrutalistickVR\BrutalistickVR.exe"#,
                environment: ["SteamAppId": "2669380", "SteamGameId": "2669380"],
                gameRoot: common + "BrutalistickVR"),
            LaunchProfile(
                name: "blood-trail-blood-trail", bottleName: "blood-trail", source: .steam,
                executable: common + #"Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe"#,
                environment: ["SteamAppId": "1032430", "SteamGameId": "1032430"],
                gameRoot: common + "Blood Trail"),
            LaunchProfile(
                name: "beat-saber-steam", bottleName: "beat-saber", source: .steam,
                executable: common + #"Beat Saber\Beat Saber.exe"#),
            // Games added from a folder carry the title the user typed.
            LaunchProfile(
                name: "hello-xr", bottleName: "folder-games", source: .direct,
                executable: #"C:\Games\hello-xr\khr_hello_xr_d3d11.exe"#,
                gameRoot: #"C:\Games\hello-xr"#, title: "  hello_xr  "),
            LaunchProfile(
                name: "beat-saber-folder", bottleName: "folder-games", source: .direct,
                executable: #"C:\Games\Beat Saber\Beat Saber.exe"#, title: "Beat Saber 1.45"),
            // A blank title falls back to the executable's name.
            LaunchProfile(
                name: "blank", bottleName: "folder-games", source: .direct,
                executable: #"C:\Games\Tool\Tool.exe"#, title: " \n "),
        ]

        let games = GameDetector().detect(bottles: bottles, profiles: profiles)
        let titles = Dictionary(uniqueKeysWithValues: games.compactMap { game in
            game.profileName.map { ($0, game.title) }
        })
        XCTAssertEqual(titles, [
            "brutalistick-vr-steam": "BrutalistickVR",
            "blood-trail-blood-trail": "BTVR-Win64-Shipping",
            "beat-saber-steam": "Beat Saber",
            "hello-xr": "hello_xr",
            "beat-saber-folder": "Beat Saber 1.45",
            "blank": "Tool",
        ])
        XCTAssertEqual(games.count, profiles.count)
    }

    func testWindowsPathsMapBackIntoBottle() {
        let bottle = makeBottle(
            name: "main", prefix: URL(fileURLWithPath: "/tmp/Basalt/prefix"))
        XCTAssertEqual(
            GameDetector.hostURL(for: #"C:\Games\Test.exe"#, bottle: bottle)?.path,
            "/tmp/Basalt/prefix/drive_c/Games/Test.exe")
        XCTAssertEqual(
            GameDetector.hostURL(for: #"Z:\Users\me\Game.exe"#, bottle: bottle)?.path,
            "/Users/me/Game.exe")
        XCTAssertNil(GameDetector.hostURL(for: #"D:\Game.exe"#, bottle: bottle))
    }

    func testDiscoversDefaultLegacyAndConfiguredBSManagerInstances() throws {
        let home = try temporaryDirectory()
        let defaultInstance = home.appendingPathComponent(
            "BSManager/BSInstances/1.40.8", isDirectory: true)
        let legacyInstance = home.appendingPathComponent(
            "Documents/BSManager/BSInstances/My Modded Copy", isDirectory: true)
        let customParent = home.appendingPathComponent("External Games", isDirectory: true)
        let customInstance = customParent.appendingPathComponent(
            "BSManager/BSInstances/1.39.1", isDirectory: true)
        for instance in [defaultInstance, legacyInstance, customInstance] {
            try FileManager.default.createDirectory(
                at: instance, withIntermediateDirectories: true)
            try Data([0x4d, 0x5a]).write(
                to: instance.appendingPathComponent("Beat Saber.exe"))
        }
        try Data().write(to: legacyInstance.appendingPathComponent("IPA.exe"))
        let metadata = #"{"id":"instance-id","store":"steam"}"#
        try Data(metadata.utf8).write(
            to: customInstance.appendingPathComponent("metadata.config"))
        let config = home.appendingPathComponent(
            "Library/Application Support/BSManager/config.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configData = try JSONSerialization.data(withJSONObject: [
            "installation-folder": customParent.path,
        ])
        try configData.write(to: config)

        let instances = BSManagerDiscovery(home: home).discover()

        XCTAssertEqual(instances.map(\.name), ["1.39.1", "1.40.8", "My Modded Copy"])
        XCTAssertEqual(instances.first { $0.name == "1.39.1" }?.metadataID, "instance-id")
        XCTAssertEqual(instances.first { $0.name == "1.39.1" }?.store, "steam")
        XCTAssertEqual(instances.first { $0.name == "My Modded Copy" }?.isModded, true)
        XCTAssertEqual(
            instances.first { $0.name == "1.40.8" }?.installationDirectory,
            home.appendingPathComponent("BSManager"))
    }

    func testDiscoversExplicitBSManagerParentVersionsFolderOrInstance() throws {
        let home = try temporaryDirectory()
        let parent = home.appendingPathComponent("Portable", isDirectory: true)
        let instance = parent.appendingPathComponent(
            "BSManager/BSInstances/Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(
            to: instance.appendingPathComponent("Beat Saber.exe"))
        try FileManager.default.createDirectory(
            at: instance.appendingPathComponent("Not A Game"), withIntermediateDirectories: true)

        let discovery = BSManagerDiscovery(home: home)

        XCTAssertEqual(discovery.discover(additionalLocations: [parent]).count, 1)
        XCTAssertEqual(
            discovery.discover(additionalLocations: [
                parent.appendingPathComponent("BSManager/BSInstances"),
            ]).count,
            1)
        XCTAssertEqual(discovery.discover(additionalLocations: [instance]).count, 1)
    }

    func testDiscoversBSManagerLauncherAndInstancesInsideManagedBottle() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let windowsHome = prefix.appendingPathComponent(
            "drive_c/users/steamuser", isDirectory: true)
        let launcher = windowsHome.appendingPathComponent(
            "AppData/Local/Programs/bs-manager/BSManager.exe")
        let instance = windowsHome.appendingPathComponent(
            "BSManager/BSInstances/1.40.8", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: instance, withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: launcher)
        try Data([0x4d, 0x5a]).write(
            to: instance.appendingPathComponent("Beat Saber.exe"))
        let bottle = makeBottle(name: "beat-saber", prefix: prefix)

        let installations = BSManagerInstallationDiscovery().discover(in: [bottle])
        let instances = BSManagerDiscovery(home: temporary).discover(bottles: [bottle])

        XCTAssertEqual(installations, [
            BSManagerInstallation(bottleName: bottle.name, executable: launcher),
        ])
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].bottleName, bottle.name)
        XCTAssertEqual(instances[0].name, "1.40.8")
    }

    func testStreamArgumentsAndLogMetricParsing() {
        var settings = StreamLaunchSettings()
        XCTAssertEqual(settings.connection, .wired)
        XCTAssertEqual(settings.fps, 72)
        XCTAssertEqual(settings.megabits, 30)
        XCTAssertEqual(settings.resolution, .quality)
        XCTAssertEqual(settings.latency, .low)
        settings.fps = 80
        settings.megabits = 18
        settings.resolution = .quality
        settings.latency = .ultra
        settings.gameAudioChoice = .device("BlackHole 2ch")
        XCTAssertEqual(settings.arguments, [
            "--wired", "--fps", "80", "--mbps", "18",
            "--resolution", "quality", "--latency", "low", "--low-latency-rc", "on",
            "--audio-device", "BlackHole 2ch", "--route-audio",
        ])
        settings.connection = .wifi
        XCTAssertEqual(settings.arguments.first, "--wireless")
        XCTAssertEqual(settings.connection.label, "Wireless (Wi-Fi)")

        let date = Date(timeIntervalSince1970: 10)
        let transport = StreamLogMetricsParser.parse(
            line: "  USB video send: 71.9 fps, 12.4 Mbps on wire", date: date)
        XCTAssertNil(transport?.fps)
        XCTAssertEqual(transport?.megabits, 12.4)
        XCTAssertNil(StreamLogMetricsParser.parse(
            line: "  USB audio send: 50 packets, 1.5 Mbps on wire", date: date))
        let quest = StreamLogMetricsParser.parse(
            line: "  Quest 72.0 fps; input→display latency: 49.2 ms average", date: date)
        XCTAssertEqual(quest?.fps, 72)
        XCTAssertEqual(quest?.latencyMilliseconds, 49.2)
        XCTAssertNil(StreamLogMetricsParser.parse(line: "tracking ready", date: date))
    }

    func testAppSessionsDoNotOpenTheRawStreamPort() throws {
        // Nothing in the app reads the streamer's TCP port for ffplay, and an
        // open port is one more thing a local process can lean on.
        var settings = StreamLaunchSettings()
        for connection in StreamConnectionMode.allCases {
            settings.connection = connection
            let arguments = settings.arguments
                + ["--runtime", "/fixture/runtime.control", "--trust-file", "/fixture/trust.json"]
            XCTAssertFalse(arguments.contains("--port"))
            XCTAssertFalse(arguments.contains("--bind"))
            XCTAssertEqual(try StreamerOptions.parse(arguments)?.opensDebugStream, false,
                           connection.rawValue)
        }
    }

    func testHeadsetFiltersAreOptInAndSettingsRemainBackwardCompatible() throws {
        let defaults = StreamLaunchSettings()
        XCTAssertEqual(defaults.arguments, [
            "--wired", "--fps", "72", "--mbps", "30", "--resolution", "quality", "--latency", "low",
            "--low-latency-rc", "on", "--game-audio", "mac",
        ])
        let legacy = Data(#"{"connection":"wifi","fps":90,"megabits":80,"resolution":"balanced","latency":"ultra","audioDeviceName":"Test"}"#.utf8)
        let decoded = try JSONDecoder().decode(StreamLaunchSettings.self, from: legacy)
        XCTAssertEqual(decoded.questSupersampling, .off)
        XCTAssertEqual(decoded.questSharpening, .off)
        XCTAssertEqual(decoded.fps, 90)
        XCTAssertEqual(decoded.connection, .wifi)
        XCTAssertEqual(decoded.megabits, 80)
        // Only "BlackHole 2ch" was ever picked automatically; this one stays.
        XCTAssertEqual(decoded.gameAudioChoice, .device("Test"))
        XCTAssertEqual(decoded.resolution, .balanced)
        XCTAssertEqual(decoded.latency, .low)
        XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self, from: Data("{}".utf8)), defaults)
        let dictionary = try JSONDecoder().decode([String: StreamLaunchSettings].self,
            from: Data("{\"game\":\(String(decoding: legacy, as: UTF8.self))}".utf8))
        XCTAssertEqual(dictionary["game"], decoded)
        var quiet = defaults
        quiet.gameAudioChoice = .off
        for level in HeadsetFilterLevel.allCases {
            var settings = quiet
            settings.questSupersampling = level
            settings.questSharpening = level
            settings.resolution = .maximum
            XCTAssertEqual(try JSONDecoder().decode(StreamLaunchSettings.self,
                from: JSONEncoder().encode(settings)), settings)
            if level != .off {
                XCTAssertEqual(Array(settings.arguments.suffix(4)), [
                    "--quest-supersampling", level.rawValue, "--quest-sharpening", level.rawValue,
                ])
            } else {
                XCTAssertFalse(settings.arguments.contains("--quest-supersampling"))
                XCTAssertFalse(settings.arguments.contains("--quest-sharpening"))
            }
            // 1680x1760 at 72 Hz: more than low-latency rate control keeps up with.
            let rateControl = try XCTUnwrap(settings.arguments.firstIndex(of: "--low-latency-rc"))
            XCTAssertEqual(settings.arguments[rateControl + 1], "off")
        }
        var oneFilter = quiet
        oneFilter.questSharpening = .normal
        XCTAssertEqual(Array(oneFilter.arguments.suffix(2)), ["--quest-sharpening", "normal"])
    }

    func testOpenCompositeOfficialURLsAndArtifactMetadata() {
        XCTAssertEqual(OpenCompositeDownload.officialURL(for: .x64).absoluteString,
            "https://znix.xyz/OpenComposite/download.php?arch=x64&branch=openxr")
        XCTAssertEqual(OpenCompositeDownload.officialURL(for: .x86).absoluteString,
            "https://znix.xyz/OpenComposite/download.php?arch=x86&branch=openxr")
        let artifact = OpenCompositeArtifact(file: URL(fileURLWithPath: "/fixture/openvr_api.dll"), data: Data("abc".utf8))
        XCTAssertEqual(artifact.size, 3)
        XCTAssertEqual(artifact.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testOpenCompositeIsPinnedToTheTestedBuilds() throws {
        XCTAssertEqual(OpenCompositeDownload.testedSHA256[.x64],
                       "827ad85f3606a4dc4a8f5561a8ca69e4c6c1b5d2b9cd3315a461b9270b08242c")
        XCTAssertEqual(OpenCompositeDownload.testedSHA256[.x86],
                       "096095dc592d606d7e085cc5780fac342d4a84174acb0d55a56f40b70e080a18")
        XCTAssertFalse(OpenCompositeDownload.isTested(Data("abc".utf8), architecture: .x64))
        let root = URL(fileURLWithPath: "/data", isDirectory: true)
        XCTAssertEqual(OpenCompositeDownload.cacheFile(architecture: .x86, dataRoot: root).path,
                       "/data/Downloads/OpenComposite/x86/openvr_api.dll")
    }

    func testResolutionPresetsMatchTheStreamerParser() throws {
        for preset in ResolutionSelection.allCases {
            XCTAssertEqual(preset.perEyeResolution, try PerEyeResolution.parse(preset.rawValue))
        }
        XCTAssertEqual(ResolutionSelection.quality.dimensions, "1344 × 1408")
        XCTAssertEqual(ResolutionSelection.performance.label, "Performance · 896 × 944")
        XCTAssertEqual(ResolutionSelection.high.label, "High · 1536 × 1600")
        XCTAssertEqual(ResolutionSelection.maximum.label, "Maximum · 1680 × 1760")
        XCTAssertEqual(ResolutionSelection.questNative.label, "Quest 3 native · 2064 × 2208")
        XCTAssertEqual(ResolutionSelection.questNative150.label, "Quest 3 native ×1.5 · 3072 × 3280")
        // Every choice is one the runtime accepts and recommends to the game.
        for preset in ResolutionSelection.allCases {
            XCTAssertLessThanOrEqual(preset.perEyeResolution.width, RuntimeLink.maximumViewWidth)
            XCTAssertLessThanOrEqual(preset.perEyeResolution.height, RuntimeLink.maximumViewHeight)
        }
    }

    /// "Auto" keeps low-latency rate control up to the stream size a Mac mini
    /// M4 keeps up with and asks for more frames above that; the person's
    /// own choice always wins.
    func testTheEncoderModeFollowsTheStreamSizeUnlessChosen() throws {
        func lowLatency(_ settings: StreamLaunchSettings) throws -> String {
            let index = try XCTUnwrap(settings.arguments.firstIndex(of: "--low-latency-rc"))
            return settings.arguments[index + 1]
        }
        var settings = StreamLaunchSettings()
        settings.codec = .hevc
        XCTAssertEqual(settings.encoderMode, .auto)
        for (resolution, fps, expected) in [
            (ResolutionSelection.quality, 72, "on"), (.quality, 90, "on"), (.quality, 120, "off"),
            (.high, 72, "on"), (.high, 90, "off"), (.maximum, 72, "off"),
            (.questNative, 72, "off"), (.performance, 120, "on"),
        ] {
            settings.resolution = resolution
            settings.fps = fps
            XCTAssertEqual(try lowLatency(settings), expected, "\(resolution.rawValue) at \(fps) Hz")
        }
        settings.resolution = .questNative150
        settings.encoderMode = .lowLatency
        XCTAssertEqual(try lowLatency(settings), "on")
        settings.resolution = .performance
        settings.fps = 72
        settings.encoderMode = .moreFrames
        XCTAssertEqual(try lowLatency(settings), "off")
        XCTAssertEqual(try StreamerOptions.parse(settings.arguments)?.lowLatencyRateControl, false)

        // Settings saved before the choice existed read as Auto; the choice is kept.
        let legacy = try JSONDecoder().decode(StreamLaunchSettings.self, from: Data(#"{"fps":90}"#.utf8))
        XCTAssertEqual(legacy.encoderMode, .auto)
        let restored = try JSONDecoder().decode(
            StreamLaunchSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(restored.encoderMode, .moreFrames)
        // Not a picture quality value: a preset stays selected.
        settings.selectQuality(.quality)
        settings.encoderMode = .lowLatency
        XCTAssertEqual(settings.qualityPreset, .quality)
    }

    func testExtractsLastActionableStreamerError() {
        let log = """
        Starting USB cable streamer…
        ALVR USB handshake attempt 1 failed; retrying…
        error: ALVR is paused behind the Quest lock screen. Put on the headset.
        (If this is a capture error, grant Screen Recording permission.)
        """
        XCTAssertEqual(
            StreamerLogFailure.message(in: log),
            "ALVR is paused behind the Quest lock screen. Put on the headset.")
        XCTAssertNil(StreamerLogFailure.message(in: "Starting…\n"))
    }

    func testSurfacesRefusedRuntimeConnection() {
        let line = RuntimeLink.connectionRefusedLogPrefix
            + "OpenXR runtime speaks control protocol v7, but this streamer speaks v9"
        XCTAssertEqual(
            RuntimeConnectionRefusal.message(in: line + "\n"),
            "The game's OpenXR runtime was refused: "
                + "OpenXR runtime speaks control protocol v7, but this streamer speaks v9")
        XCTAssertNil(RuntimeConnectionRefusal.message(in: RuntimeLink.connectionRefusedLogPrefix))
        XCTAssertNil(RuntimeConnectionRefusal.message(in: "OpenXR runtime disconnected"))
    }

    func testDiscoversWhiskyAndCrossOverBottlesWithFriendlyNames() throws {
        let home = try temporaryDirectory()
        let whisky = home.appendingPathComponent(
            "Library/Containers/com.isaacmarovitz.Whisky/Bottles/UUID", isDirectory: true)
        let crossover = home.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/Steam VR", isDirectory: true)
        for prefix in [whisky, crossover] {
            try FileManager.default.createDirectory(
                at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
            try Data().write(to: prefix.appendingPathComponent("system.reg"))
        }
        let metadata: [String: Any] = ["info": ["name": "My Whisky Games"]]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: metadata, format: .binary, options: 0)
        try plist.write(to: whisky.appendingPathComponent("Metadata.plist"))

        let bottles = ExternalBottleDiscovery(home: home).discover()

        XCTAssertEqual(bottles.map(\.name).sorted(), ["My Whisky Games", "Steam VR"])
        XCTAssertEqual(Set(bottles.map(\.origin)), Set([.whisky, .crossover]))
        XCTAssertTrue(bottles.allSatisfy { !$0.isManaged && !$0.isReadyForVR })
    }

    func testDiscoversInstalledSteamManifestAndArtwork() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("Bottle", isDirectory: true)
        let steam = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam", isDirectory: true)
        let steamApps = steam.appendingPathComponent("steamapps", isDirectory: true)
        let install = steamApps.appendingPathComponent("common/Beat Saber", isDirectory: true)
        let art = steam.appendingPathComponent(
            "appcache/librarycache/620980/library_600x900.jpg")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: steam.appendingPathComponent("steam.exe"))
        try Data([0xff, 0xd8]).write(to: art)
        let manifest = #"""
        "AppState"
        {
            "appid" "620980"
            "name" "Beat Saber"
            "installdir" "Beat Saber"
            "SizeOnDisk" "1655396478"
            "LastPlayed" "1000"
        }
        """#
        try Data(manifest.utf8).write(
            to: steamApps.appendingPathComponent("appmanifest_620980.acf"))
        let bottle = DiscoveredBottle(
            name: "Steam", origin: .crossover, prefix: prefix)

        let games = SteamLibraryDiscovery().discover(in: [bottle])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].appID, "620980")
        XCTAssertEqual(games[0].name, "Beat Saber")
        XCTAssertEqual(games[0].sizeOnDisk, 1_655_396_478)
        XCTAssertEqual(games[0].lastPlayed, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(games[0].artwork, art.standardizedFileURL)
        XCTAssertTrue(games[0].isKnownVRGame)
    }

    func testVDFParserHandlesEscapedWindowsPaths() {
        let vdf = #"""
        "path" "D:\\SteamLibrary"
        "path" "E:\\More Games"
        """#
        XCTAssertEqual(
            SteamLibraryDiscovery.values(for: "path", in: vdf),
            [#"D:\SteamLibrary"#, #"E:\More Games"#])
    }

    private func makeBottle(name: String, prefix: URL) -> ManagedBottle {
        let root = prefix.deletingLastPathComponent().appendingPathComponent("engine")
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: root.appendingPathComponent("bin/wine"),
            wineserverBinary: root.appendingPathComponent("bin/wineserver"),
            root: root, supportsBasaltDXMT: true)
        return ManagedBottle(
            name: name, engine: engine, prefix: prefix,
            engineRoot: root, wineBinary: root.appendingPathComponent("bin/wine"))
    }
}
