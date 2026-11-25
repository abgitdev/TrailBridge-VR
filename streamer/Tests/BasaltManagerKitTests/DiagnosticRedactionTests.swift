import XCTest
@testable import BasaltManagerKit
import BasaltCore

/// What a person may paste in public (the copied or saved session log, the
/// diagnostic report) names no person, Mac, disk, headset or network.
final class DiagnosticRedactionTests: XCTestCase {
    private static let appFolder = "/Volumes/Game Disk/Apps/trailbridge-vr"
    private static let dataFolder = appFolder + "/.local/data"

    /// Nothing is read from the Mac the tests run on.
    private func makeRedactor(
        home: String = "/Users/ada", user: String = "ada",
        dataFolder: String? = nil, appFolder: String? = nil,
        hostNames: [String] = [], volumeNames: [String] = []
    ) -> DiagnosticRedactor {
        DiagnosticRedactor(
            homeDirectory: home, userName: user, dataFolder: dataFolder, appFolder: appFolder,
            hostNames: hostNames, volumeNames: volumeNames)
    }

    func testReplacesDiskNamesAndKeepsTheRestOfThePath() {
        let redactor = makeRedactor(volumeNames: ["Macintosh HD", "Game Disk", "Мой диск"])
        let expected = [
            "/Volumes/Game Disk/Games/Blood Trail/BloodTrail.exe":
                "/Volumes/[disk]/Games/Blood Trail/BloodTrail.exe",
            "The disk /Volumes/Game Disk is not available":
                "The disk /Volumes/[disk] is not available",
            "/Volumes/Мой диск/Steam/steamapps/common/Brutalistick VR":
                "/Volumes/[disk]/Steam/steamapps/common/Brutalistick VR",
            // The same name as the file system may spell it (decomposed).
            "/Volumes/Мой диск/Steam".decomposedStringWithCanonicalMapping:
                "/Volumes/[disk]/Steam",
            // A disk that is not connected now: its name ends at the next slash.
            "cannot open /Volumes/Ada Lovelace SSD/TrailBridge/Bottles/vr":
                "cannot open /Volumes/[disk]/TrailBridge/Bottles/vr",
            "share /Volumes/ada mounted": "share /Volumes/[disk] mounted",
            #""folder" : "/Volumes/Ada's Old SSD","#: #""folder" : "/Volumes/[disk]","#,
            // Two paths on one line stay two paths.
            "tried /Volumes/Games and /usr/local/bin": "tried /Volumes/[disk] and /usr/local/bin",
            "'/Volumes/Games' is missing; using /Users/Shared/Steam":
                "'/Volumes/[disk]' is missing; using /Users/Shared/Steam",
            // Wine spells host paths with a drive letter and backslashes,
            // doubled in its own debug strings and again in JSON.
            #"Z:\Volumes\Game Disk\Games\BloodTrail.exe"#:
                #"Z:\Volumes\[disk]\Games\BloodTrail.exe"#,
            #"L"Z:\\Volumes\\Game Disk\\Games""#: #"L"Z:\\Volumes\\[disk]\\Games""#,
            #"Z:\\\\Volumes\\\\Game Disk\\\\Games"#: #"Z:\\\\Volumes\\\\[disk]\\\\Games"#,
            "file:///Volumes/Game%20Disk/Games/Blood%20Trail":
                "file:///Volumes/[disk]/Games/Blood%20Trail",
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }
    }

    func testNamesTheDataAndAppFoldersInsteadOfTheirPaths() {
        let redactor = makeRedactor(dataFolder: Self.dataFolder + "/", appFolder: Self.appFolder)
        let expected = [
            Self.dataFolder + "/Bottles/brutalistick-vr/prefix/drive_c/Games/Brutalistick VR":
                "[data folder]/Bottles/brutalistick-vr/prefix/drive_c/Games/Brutalistick VR",
            "Data folder: " + Self.dataFolder: "Data folder: [data folder]",
            Self.appFolder + "/runtime/build/bin/basalt_openxr.dll":
                "[app folder]/runtime/build/bin/basalt_openxr.dll",
            #"Z:\Volumes\Game Disk\Apps\trailbridge-vr\.local\data\Tools\adb.log"#:
                #"[data folder]\Tools\adb.log"#,
            "file:///Volumes/Game%20Disk/Apps/trailbridge-vr/.local/data/Diagnostics":
                "file://[data folder]/Diagnostics",
            // A neighbour is another folder, and the disk is still unnamed.
            Self.dataFolder + "-old/Bottles": "[app folder]/.local/data-old/Bottles",
            Self.appFolder + "-backup/runtime":
                "/Volumes/[disk]/Apps/trailbridge-vr-backup/runtime",
            "The disk /Volumes/Game Disk is not available":
                "The disk /Volumes/[disk] is not available",
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }
    }

    func testRedactsUserNamesInWineJSONAndURLForms() {
        let redactor = makeRedactor()
        let expected = [
            "/Users/ada/Library/Application Support/Игры/Blood Trail/save 1.dat":
                "~/Library/Application Support/Игры/Blood Trail/save 1.dat",
            #"Z:\Users\ada\Downloads\Steam Setup.exe"#: #"Z:\Users\[user]\Downloads\Steam Setup.exe"#,
            #"C:\users\ada\AppData\Local\Blood Trail"#: #"C:\users\[user]\AppData\Local\Blood Trail"#,
            // A Wine debug string as JSON holds it: four backslashes each.
            #"L\"C:\\\\users\\\\ada\\\\AppData\""#: #"L\"C:\\\\users\\\\[user]\\\\AppData\""#,
            "file:///Users/ada/Library/Logs/a%20b.log": "file://~/Library/Logs/a%20b.log",
            // Another account, or a bottle copied from another Mac.
            "/Users/adam/Games/file": "/Users/[user]/Games/file",
            #"C:\users\Иван\Documents"#: #"C:\users\[user]\Documents"#,
            // The per-user temporary folder is as good as a name.
            "/private/var/folders/8k/2x4zr1tn0ld5xq_wq8kzk9mh0000gn/T/BasaltVR-command-1.log":
                "/private/var/folders/[user]/T/BasaltVR-command-1.log",
            // Shared folders name nobody.
            "/Users/Shared/Steam/steamapps": "/Users/Shared/Steam/steamapps",
            #"C:\users\Public\Documents\Steam"#: #"C:\users\Public\Documents\Steam"#,
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }

        let spaced = makeRedactor(home: "/Users/Иван Петров", user: "Иван Петров")
        XCTAssertEqual(
            spaced.redact("/Users/Иван Петров/Library/Application Support/BasaltVR"),
            "~/Library/Application Support/BasaltVR")
        XCTAssertEqual(
            spaced.redact("file:///Users/%D0%98%D0%B2%D0%B0%D0%BD%20%D0%9F%D0%B5%D1%82%D1%80%D0%BE%D0%B2/Library"),
            "file://~/Library")
        XCTAssertEqual(
            spaced.redact(#"C:\users\Иван Петров\Saved Games\Blood Trail"#),
            #"C:\users\[user]\Saved Games\Blood Trail"#)
    }

    /// A game's own log, written inside its Wine prefix: Unity prints
    /// Windows paths with forward slashes, Unreal names the Windows user and
    /// computer, which Wine takes from the Mac.
    func testRedactsWindowsPathsAndNamesInAGamesOwnLog() {
        let redactor = makeRedactor(hostNames: ["Adas-Mac-mini"])
        let expected = [
            "Logging to C:/users/ada/AppData/LocalLow/Example Studio/Game/Player.log":
                "Logging to C:/users/[user]/AppData/LocalLow/Example Studio/Game/Player.log",
            // A bottle made on another Mac or by another app.
            "C:/users/steamuser/AppData/Local/BTVR/Saved/Logs/BTVR.log":
                "C:/users/[user]/AppData/Local/BTVR/Saved/Logs/BTVR.log",
            #"C:\Users\crossover\AppData\LocalLow\Game"#: #"C:\Users\[user]\AppData\LocalLow\Game"#,
            // The Mac's own folders through Wine's Z: drive, either way round.
            #"Z:\Users\ada\Games\Game.exe"#: #"Z:\Users\[user]\Games\Game.exe"#,
            "Z:/Users/ada/Games/Game.exe": "Z:/Users/[user]/Games/Game.exe",
            "Z:/Users/bob/Games/Game.exe": "Z:/Users/[user]/Games/Game.exe",
            #"Z:\\Users\\ada\\Games"#: #"Z:\\Users\\[user]\\Games"#,
            "C:/users/Public/Documents/Game": "C:/users/Public/Documents/Game",
            "[2026.11.25-10.00.00:000][  0]LogInit: Computer: ADAS-MAC-MINI":
                "[2026.11.25-10.00.00:000][  0]LogInit: Computer: [host]",
            // Windows keeps 15 characters of a longer name.
            "[2026.11.25-10.00.00:000][  0]LogInit: Computer: IVANS-MACBOOK-P":
                "[2026.11.25-10.00.00:000][  0]LogInit: Computer: [host]",
            "[2026.11.25-10.00.00:000][  0]LogInit: User: ada":
                "[2026.11.25-10.00.00:000][  0]LogInit: User: [user]",
            "LogInit: User: steamuser": "LogInit: User: [user]",
            // A name with a space or in quotes is replaced whole.
            #"C:\users\Jane Doe\AppData\Local\BTVR"#: #"C:\users\[user]\AppData\Local\BTVR"#,
            "C:/Users/Jane Doe/AppData/Local/BTVR": "C:/Users/[user]/AppData/Local/BTVR",
            #"Z:\Users\Jane O'Brien (Work)\Games"#: #"Z:\Users\[user]\Games"#,
            #"L"C:\\users\\Jane Doe\\Saved""#: #"L"C:\\users\\[user]\\Saved""#,
            "| C:\\users\\Jane Doe | ok |": "| C:\\users\\[user] | ok |",
            #"LogInit: User: "Jane Doe""#: "LogInit: User: [user]",
            "LogInit: User: Jane Doe": "LogInit: User: [user]",
            "LogInit: Computer: 'Jane Doe's Mac'\nLogInit: CPU Page size=4096":
                "LogInit: Computer: [host]\nLogInit: CPU Page size=4096",
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }
    }

    /// The exact lines of BasaltStreamer/App.swift and
    /// BasaltCore/GameAudioCapture.swift that print a CoreAudio device name.
    func testRedactsAudioDeviceNamesInStreamerLines() {
        let redactor = makeRedactor()
        let expected = [
            "Game audio output routed to BlackHole 2ch for this session":
                "Game audio output routed to BlackHole for this session",
            "Game audio capture ready: Ivan's iPhone Microphone, 48000 Hz stereo PCM16":
                "Game audio capture ready: [audio device], 48000 Hz stereo PCM16",
            "  game audio: BlackHole 2ch, 48 kHz stereo PCM16":
                "  game audio: BlackHole, 48 kHz stereo PCM16",
            "Restored Mac audio output to AirPods Pro — Иван":
                "Restored Mac audio output to [audio device]",
            #"Restored Mac audio output to Ada's 27" Display"#:
                "Restored Mac audio output to [audio device]",
            "No real Mac audio output found; output remains on BlackHole 16ch":
                "No real Mac audio output found; output remains on BlackHole",
            "Game audio: BASALT_GAME_AUDIO=mac replaces Ivan's Loopback with the Mac's own output":
                "Game audio: BASALT_GAME_AUDIO=mac replaces [audio device] with the Mac's own output",
            "error: No CoreAudio input device contains 'BlackHole 2ch'; "
                + "available: MacBook Pro Microphone, Ivan's iPhone Microphone":
                "error: No CoreAudio input device contains 'BlackHole'; "
                + "available: [audio device], [audio device]",
            "error: Audio device name 'Air' is ambiguous: AirPods Ивана, MacBook Air Microphone":
                "error: Audio device name '[audio device]' is ambiguous: [audio device], [audio device]",
            "error: Could not set 'Ivan's Mixer' to 48000 Hz (CoreAudio status 560947818). "
                + "Check Audio MIDI Setup.":
                "error: Could not set '[audio device]' to 48000 Hz (CoreAudio status 560947818). "
                + "Check Audio MIDI Setup.",
            "error: 'Ivan's Mixer' did not switch to 48000 Hz within 2 seconds. "
                + "Check Audio MIDI Setup before starting game audio.":
                "error: '[audio device]' did not switch to 48000 Hz within 2 seconds. "
                + "Check Audio MIDI Setup before starting game audio.",
            "error: CoreAudio input 'Ivan's Mixer' cannot also receive application output":
                "error: CoreAudio input '[audio device]' cannot also receive application output",
            "error: CoreAudio input 'Ivan's Mixer' is not available to AVFoundation":
                "error: CoreAudio input '[audio device]' is not available to AVFoundation",
            "error: Could not open 'Ivan's Mixer': Cannot use the device. "
                + "Grant Microphone access to the terminal if macOS requests it":
                "error: Could not open '[audio device]': Cannot use the device. "
                + "Grant Microphone access to the terminal if macOS requests it",
            "error: Could not attach 'Ivan's Mixer' to audio capture":
                "error: Could not attach '[audio device]' to audio capture",
            "error: Could not configure PCM output for 'Ivan's Mixer'":
                "error: Could not configure PCM output for '[audio device]'",
            "error: Could not start audio capture from 'Ivan's Mixer'":
                "error: Could not start audio capture from '[audio device]'",
            // --list-audio-devices
            "Ivan's iPhone Microphone\t48000 Hz": "[audio device]\t48000 Hz",
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }
        // Every line of a log is seen, not only the first or the last.
        let log = expected.keys.sorted().joined(separator: "\n") + "\n"
        let redacted = redactor.redact(log)
        for name in ["Ivan", "Иван", "AirPods", "MacBook", "Mixer", "Display", "2ch", "16ch"] {
            XCTAssertFalse(redacted.contains(name), name)
        }
        XCTAssertEqual(redacted.components(separatedBy: "\n").count, expected.count + 1)
    }

    func testRedactsHeadsetHostAndNetworkIdentifiers() {
        let redactor = makeRedactor(hostNames: ["Ada’s Mac mini", "Adas-Mac-mini"])
        let expected = [
            "USB Quest TESTQUEST00001 is authorized; adb control/video forwards are ready.":
                "USB Quest [serial] is authorized; adb control/video forwards are ready.",
            // A serial of an unusual shape is still one in this line.
            "USB Quest emulator-5554 is authorized; adb control/video forwards are ready.":
                "USB Quest [serial] is authorized; adb control/video forwards are ready.",
            "TESTQUEST00001\tdevice": "[serial]\tdevice",
            "ALVR control accepted by 'Ivan's Quest 3': StreamConfig sent, "
                + "StartStream sent, and Quest replied StreamReady.":
                "ALVR control accepted by '[headset]': StreamConfig sent, "
                + "StartStream sent, and Quest replied StreamReady.",
            "Headset request: 4242.client.alvr at 192.168.1.37":
                "Headset request: [headset].client.alvr at [ipv4]",
            "  ALVR UDP video stream connected to 192.168.1.37:9944; sending H.264 desktop frames.":
                "  ALVR UDP video stream connected to [ipv4]:9944; sending H.264 desktop frames.",
            "Client connected: 10.0.0.12:51522": "Client connected: [ipv4]:51522",
            "Client connected: [fe80::1c2b:3aff:fe4d:5e6f%en0]:51522": "Client connected: [[ipv6]]:51522",
            "peer 2001:0db8:85a3:0000:0000:8a2e:0370:7334 answered": "peer [ipv6] answered",
            "wlan0 link/ether A4:83:E7:12:34:56 brd ff:ff:ff:ff:ff:ff": "wlan0 link/ether [mac] brd [mac]",
            "Wi-Fi SSID: Ivanov-Home-5G": "Wi-Fi SSID: [wifi]",
            #"wlan0: SSID="Ivanov Home", RSSI -52 dBm"#: #"wlan0: SSID="[wifi]", RSSI -52 dBm"#,
            "env USER=ada LOGNAME=ada COMPUTERNAME=ADAS-MAC TERM=xterm":
                "env USER=[user] LOGNAME=[user] COMPUTERNAME=[redacted] TERM=xterm",
            "Bonjour name Adas-Mac-mini.local, computer Ada’s Mac mini (ADAS-MAC-MINI)":
                "Bonjour name [host].local, computer [host] ([host])",
            #"C:\Program Files (x86)\Steam\userdata\123456789\620980\remote"#:
                #"C:\Program Files (x86)\Steam\userdata\[steamid]\620980\remote"#,
            "steam: owner 76561198012345678 [U:1:12345678]": "steam: owner [steamid] [steamid]",
        ]
        for (text, redacted) in expected {
            XCTAssertEqual(redactor.redact(text), redacted)
        }
    }

    func testRedactsSteamIDsAndCompleteIdentityValues() {
        let redactor = makeRedactor()
        let log = #"""
            Steam owner 76561190000000000, 76561200000000000, STEAM_0:0:0, STEAM_5:1:42, [U:1:0]
            Username: Jane Doe
            User name: Jane "JJ" Doe
            Account: Jane O'Brien; personal
            Login: CORP\Robert Example
            Nickname and Username: "Jane" Doe
            Persona name=Jane Doe
            Serial number: Example 42
            Next line
            """#
        XCTAssertEqual(redactor.redact(log), """
            Steam owner [steamid], [steamid], [steamid], [steamid], [steamid]
            Username: [redacted]
            User name: [redacted]
            Account: [redacted]
            Login: [redacted]
            Nickname and Username: [redacted]
            Persona name=[redacted]
            Serial number: [redacted]
            Next line
            """)
        let otherNumbers = "AppID 3256020, counters 7656120000000000 and 765612000000000000"
        XCTAssertEqual(redactor.redact(otherNumbers), otherNumbers)
        XCTAssertEqual(redactor.redact(#""Account: \"Jane\" Doe\nNext line""#),
                       #""Account: [redacted]\nNext line""#)
    }

    func testKeepsUsefulDiagnosticContent() {
        let redactor = makeRedactor(
            dataFolder: Self.dataFolder, appFolder: Self.appFolder,
            hostNames: ["Ada’s Mac mini"], volumeNames: ["Game Disk"])
        let lines = [
            "Preparing Blood Trail in brutalistick-vr…",
            "  stream settings: 1832x1920 per eye, low latency",
            "  headset capabilities: 2064x2208 per eye; refresh 72, 80, 90, 120 Hz",
            "ALVR negotiated 2064x2208 @ 90 Hz; keeping encoder 1832x1920 @ 72 Hz",
            "  Quest 72.0 fps, input→display latency: 51.2 ms",
            "  video send: 148.4 Mbps on wire, HEVC",
            "  game audio: the Mac's own output (see the Game audio lines)",
            "  game audio: disabled (pass --game-audio mac or --audio-device 'BlackHole 2ch')",
            "Game audio: capturing the Mac's own output (all apps except TrailBridge), "
                + "48000 Hz stereo PCM16; Mac speakers stay silent during the session. "
                + "Tap 48000 Hz 2 ch, clock built-in output",
            "No CoreAudio input devices found.",
            "error: Steam is open but not signed in.",
            "OpenXR runtime connected (session 7, D3D11)",
            "OpenXR runtime connection refused: protocol 3 is older than 4",
            "Wine 11.10 with DXMT v0.80-basalt.1, TrailBridge VR 0.4.2 (build 57)",
            #"C:\Program Files (x86)\Steam\steamapps\common\Blood Trail\BloodTrail.exe -applaunch 1032430"#,
            #"C:\Games\Brutalistick VR\Brutalistick VR.exe exited with status 0"#,
            "recording Diagnostics/20260101T120000.123456Z-blood-trail.hevc at 1832x1920",
            "listening on 127.0.0.1:9944 and [::1]:9943",
            "/Applications/Steam.app and /usr/local/bin/wine",
        ]
        for line in lines {
            XCTAssertEqual(redactor.redact(line), line)
        }
    }

    @MainActor func testExportedSessionLogIsRedactedAndTheScreenLogIsNot() {
        let console = SessionConsole()
        _ = console.append("""
            Preparing Blood Trail in blood-trail…
            USB Quest TESTQUEST00001 is authorized; adb control/video forwards are ready.
            Game audio output routed to BlackHole 2ch for this session
            ALVR control accepted by 'Quest 3': StreamConfig sent, StartStream sent, and Quest replied StreamReady.
              ALVR TCP video stream connected through USB at 127.0.0.1:9944; tracking uplink ready; sending H.264 frames.
            Client connected: 192.168.1.20:51522
            0024:err:module:import_dll Z:\\Volumes\\Game Disk\\TrailBridge\\data\\Bottles\\blood-trail\\prefix\\drive_c\\users\\ada\\Temp\\x.dll not found
            wine: '/Users/ada/Games/Blood Trail' is not a prefix
              Quest 72.0 fps, input→display latency: 51.2 ms
            Restored Mac audio output to Ada's AirPods Pro

            """)
        let redactor = makeRedactor(
            dataFolder: "/Volumes/Game Disk/TrailBridge/data", volumeNames: ["Game Disk"])
        let exported = console.exportedLog(redactedWith: redactor)

        XCTAssertEqual(exported, """
            Preparing Blood Trail in blood-trail…
            USB Quest [serial] is authorized; adb control/video forwards are ready.
            Game audio output routed to BlackHole for this session
            ALVR control accepted by '[headset]': StreamConfig sent, StartStream sent, and Quest replied StreamReady.
              ALVR TCP video stream connected through USB at 127.0.0.1:9944; tracking uplink ready; sending H.264 frames.
            Client connected: [ipv4]:51522
            0024:err:module:import_dll [data folder]\\Bottles\\blood-trail\\prefix\\drive_c\\users\\[user]\\Temp\\x.dll not found
            wine: '~/Games/Blood Trail' is not a prefix
              Quest 72.0 fps, input→display latency: 51.2 ms
            Restored Mac audio output to [audio device]

            """)
        // The person's own screen keeps the full text.
        XCTAssertTrue(console.log.contains("USB Quest TESTQUEST00001 is authorized"))
        XCTAssertTrue(console.log.contains("Ada's AirPods Pro"))
        XCTAssertTrue(console.log.contains("/Users/ada/Games"))
    }
}
