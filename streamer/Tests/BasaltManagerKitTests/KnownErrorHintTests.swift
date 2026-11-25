// SPDX-License-Identifier: MIT
import XCTest
import BasaltCore
@testable import BasaltManagerKit

@MainActor
final class KnownErrorHintTests: XCTestCase {
    /// Nothing is read from the Mac the tests run on.
    private let redactor = DiagnosticRedactor(
        homeDirectory: "/Users/example", userName: "example", dataFolder: nil, appFolder: nil,
        hostNames: [], volumeNames: [])

    /// Electrician Simulator VR's Player.log when it could not open its intro video.
    private let videoError = """
        WindowsVideoMedia error 0xc00d36bb while reading C:/Program Files (x86)/Steam/steamapps/common/Electrician Simulator VR/ElectricianVR_Data/sharedassets0.resource

        Context: CreateObjectFromByteStream
        Error details: Unexpected error.
        """
    /// Unity's Mono when P/Invoke cannot load the plugin.
    private let openVRNotLoaded = "DllNotFoundException: openvr_api assembly:<unknown assembly> type:<unknown type> member:(null)"
    /// The runtime refuses the API version Unity asks for first
    /// (runtime/pe/runtime.cpp); Unity then asks for 1.0.
    private let apiVersionRefused = "Basalt OpenXR: unsupported application API version 1.1.45 (runtime supports OpenXR 1.0)"
    /// The streamer's line for the runtime's accepted Hello.
    private let runtimeConnected = "OpenXR runtime connected (session 1, Apple M4 Pro (DXMT v0.61-basalt))"
    /// Wine's server prints this on a segmentation fault (server/signal.c).
    private let wineserverCrash = "wineserver crashed, please enable coredumps (ulimit -c unlimited) and restart."

    // MARK: - The rules

    func testAVideoTheGameCouldNotPlaySendsToSetupOnlyWithoutGStreamer() {
        let gameLog = excerpt("Initialize engine version: 6000.0.58f2\n" + videoError)
        XCTAssertEqual(Recording(gStreamer: .missing).hints(gameLog: gameLog), [.modelHintVideoWithoutGStreamer])
        XCTAssertEqual(Recording().hints(gameLog: gameLog), [.modelHintVideoMediaFoundation])
        XCTAssertEqual(Recording(gStreamer: .installed(version: nil)).hints(gameLog: gameLog),
                       [.modelHintVideoMediaFoundation])
        // A Unity player started with `-logFile -` writes its log to its output.
        let output = Recording(gStreamer: .missing)
        output.print(videoError + "\n", by: .game)
        XCTAssertEqual(output.hints(), [.modelHintVideoWithoutGStreamer])
        // Steam's output is not the game's, and a game that never started played no video.
        let steam = Recording(gStreamer: .missing)
        steam.print(videoError + "\n", by: .steam)
        XCTAssertEqual(steam.hints(), [])
        XCTAssertEqual(Recording(gStreamer: nil).hints(gameLog: gameLog), [])
    }

    func testOpenVRThatCouldNotStartSuggestsOpenComposite() {
        let lines = [
            openVRNotLoaded,
            // Unity's built-in VR support when OpenVR finds no SteamVR.
            #"VR: OpenVR Error! OpenVR failed initialization with error code VRInitError_Init_PathRegistryNotFound: "Installation path could not be located (110)"!"#,
            // The SteamVR Unity plugin; the log keeps its rich-text tags.
            "<b>[SteamVR]</b> Initialization failed. Please verify that you have SteamVR installed, "
                + "your hmd is functioning, and OpenVR Loader is checked in the XR Plugin Management "
                + "section of Project Settings.",
        ]
        for line in lines {
            XCTAssertEqual(Recording().hints(gameLog: excerpt(line)), [.modelHintOpenVR], line)
        }
        // In the game's own output too, the app's own line about OpenVR
        // support aside.
        let output = Recording()
        output.appLine(L10n.string(.modelOpenVRReinstalled))
        XCTAssertEqual(output.hints(), [])
        let game = Recording()
        game.appLine(L10n.string(.modelOpenVRReinstalled))
        game.print(openVRNotLoaded + "\n", by: .game)
        XCTAssertEqual(game.hints(), [.modelHintOpenVR])
        // Another plugin that Unity could not load is not this.
        XCTAssertEqual(Recording().hints(gameLog: excerpt("DllNotFoundException: GfxPluginNativeRenderer")), [])
    }

    func testAnOpenXRStartTheRuntimeRefusedIsHintedOnlyWhenNoRuntimeConnected() {
        // What the runtime prints to the game's output as it refuses
        // xrCreateInstance (runtime/pe/runtime.cpp).
        let refusals = [
            "Basalt OpenXR: xrCreateInstance rejected an invalid application or engine name",
            "Basalt OpenXR: unsupported enabled extension 'XR_KHR_vulkan_enable2'",
            "Basalt OpenXR: null enabled extension name at index 1",
            "Basalt OpenXR: D3D11 runtime support is unavailable",
        ]
        for line in refusals {
            let output = Recording()
            output.print(line + "\n", by: .game)
            XCTAssertEqual(output.hints(), [.modelHintOpenXR], line)
            XCTAssertEqual(Recording().hints(gameLog: excerpt(line)), [.modelHintOpenXR], line)
            let connected = Recording()
            connected.print(line + "\n", by: .game)
            connected.print(runtimeConnected + "\n", by: .streamer)
            XCTAssertEqual(connected.hints(gameLog: excerpt(line)), [], line)
        }
        // The words the rule is named for, with a result. Engines word such a
        // line differently, and no engine's wording is pinned here.
        XCTAssertEqual(Recording().hints(gameLog: excerpt("[XR] xrCreateInstance failed: XR_ERROR_RUNTIME_UNAVAILABLE")),
                       [.modelHintOpenXR])
        // Other lines of the runtime are not a failed start.
        let other = Recording()
        other.print("Basalt OpenXR: right system button pressed\n", by: .game)
        XCTAssertEqual(other.hints(), [])
    }

    func testTrailBridgesOwnSmokeClientsThatCouldNotStartOpenXRAreHinted() {
        let lines = [
            // fail() in runtime/tests/d3d11_runtime_smoke.cpp, after xrCreateInstance.
            "FAIL: xrCreateInstance(D3D11) returned XrResult -2",
            // runtime/tests/loader_smoke.cpp.
            "FAIL: loader xrCreateInstance returned -2",
        ]
        for line in lines {
            let never = Recording()
            never.print(line + "\n", by: .game)
            XCTAssertEqual(never.hints(), [.modelHintOpenXR], line)
            let connected = Recording()
            connected.print(line + "\n", by: .game)
            connected.print(runtimeConnected + "\n", by: .streamer)
            XCTAssertEqual(connected.hints(), [], line)
        }
        // A result that is no failure is not one.
        let succeeded = Recording()
        succeeded.print("xrCreateInstance(D3D11) returned XrResult 0\n", by: .game)
        XCTAssertEqual(succeeded.hints(), [])
    }

    func testAnUnsupportedAPIVersionIsNoErrorWhenTheSessionCameUpAfterIt() {
        // Electrician Simulator VR ran after Unity fell back to OpenXR 1.0.
        let cameUp = Recording()
        cameUp.print(apiVersionRefused + "\n", by: .game)
        cameUp.print(runtimeConnected + "\n", by: .streamer)
        XCTAssertEqual(cameUp.hints(gameLog: excerpt("Initialize engine version: 6000.0.58f2\n" + apiVersionRefused)), [])
        // Nothing came up after it.
        let never = Recording()
        never.print(apiVersionRefused + "\n", by: .game)
        XCTAssertEqual(never.hints(), [.modelHintOpenXR])
    }

    func testTheRuntimeConnectingAfterTheGameEndedStillCounts() {
        // The game's output closes and the session stops before the
        // streamer's line about the Hello is read; it still counts.
        let late = Recording()
        late.print(apiVersionRefused + "\n", by: .game)
        late.close(.game)
        late.print(runtimeConnected + "\n", by: .streamer)
        late.close(.streamer)
        XCTAssertEqual(late.hints(gameLog: excerpt(apiVersionRefused)), [])
        // Only the streamer can say it: the game's output cannot.
        let claimed = Recording()
        claimed.print(apiVersionRefused + "\n" + runtimeConnected + "\n", by: .game)
        XCTAssertEqual(claimed.hints(), [.modelHintOpenXR])
    }

    func testACrashedWineserverIsHintedFromWineOutput() {
        for printer in [KnownErrorScanner.Printer.game, .steam] {
            let recording = Recording()
            recording.print("\(wineserverCrash)\n", by: printer)
            recording.appLine(L10n.string(.modelGameExited, "0"))
            XCTAssertEqual(recording.hints(), [.modelHintWineCrashed], "\(printer)")
        }
        // Only at the start of a line of Wine's own; never from the game's log.
        let quoted = Recording()
        quoted.print(#"Loading C:\Games\wineserver crashed\data.pak"# + "\n", by: .game)
        quoted.print(wineserverCrash + "\n", by: .streamer)
        XCTAssertEqual(quoted.hints(gameLog: excerpt(wineserverCrash)), [])
    }

    // MARK: - What is read

    func testTheAppsOwnLinesAreNeverRead() {
        // The manager's launch line quotes an executable path, which can hold anything.
        let path = #"C:\Games\wineserver crashed\DllNotFoundException openvr_api\WindowsVideoMedia error.exe"#
        let recording = Recording(gStreamer: .missing)
        recording.appLine(L10n.string(.modelSteamDirectLaunch, path))
        recording.appLine(wineserverCrash + "\n" + openVRNotLoaded + "\n" + apiVersionRefused)
        XCTAssertTrue(recording.console.log.contains(path), recording.console.log)
        XCTAssertEqual(recording.hints(), [])
    }

    func testOnlyTheExcerptsContentLinesAreRead() throws {
        // A header names a folder of the game's own choosing; the notes are
        // the excerpt's own.
        let label = #"C:\users\steamuser\AppData\LocalLow\DllNotFoundException openvr_api\WindowsVideoMedia error\Player.log"#
        let lines = (0..<400).map { "frame \($0)" }.joined(separator: "\n")
        let text = GameLogExcerpt(logs: [GameLogExcerpt.Log(engine: .unity, label: label, text: lines, unreadBytes: 4096)],
                                  redactedWith: redactor, wineMayBeRunning: true).text
        for marker in ["DllNotFoundException openvr_api", "[… earlier lines not read: 4096 bytes …]",
                       "[… 200 lines skipped …]", "may still have been running"] {
            XCTAssertTrue(text.contains(marker), "\(marker) in \(text)")
        }
        let marked = GameLogExcerpt(sources: [], text: text)
        XCTAssertEqual(KnownErrorScanner.contentLines(of: marked).first, "frame 200")
        XCTAssertEqual(KnownErrorScanner.contentLines(of: marked).count, 200)
        XCTAssertEqual(Recording(gStreamer: .missing).hints(gameLog: marked), [])
        // Every note the excerpt writes is left out, and nothing else.
        let notes = [GameLogExcerpt.skipped(1), GameLogExcerpt.skipped(12), GameLogExcerpt.unread(1 << 30),
                     GameLogExcerpt.omitted(20_000), L10n.string(.recordingGameLogPossiblyIncomplete, language: .en)]
        let content = ["[1 line skipped]", "==> not a header", "WindowsVideoMedia error 0xc00d36bb"]
        XCTAssertEqual(KnownErrorScanner.contentLines(of: GameLogExcerpt(
            sources: [], text: (notes + content).joined(separator: "\n") + "\n")).map(String.init), content)
        XCTAssertEqual(Recording(gStreamer: .missing).hints(gameLog: excerpt(videoError)),
                       [.modelHintVideoWithoutGStreamer])
    }

    func testHarmlessGStreamerNoiseGivesNoHint() {
        let pygobject = #"** (wine:39619): CRITICAL **: 11:21:56.465: pygobject initialization failed: could not import gobject (error was: ModuleNotFoundError("No module named 'gi'"))"#
        let videoCaps = "(wine:40051): GStreamer-Video-CRITICAL **: 11:22:28.693: "
            + "gst_video_info_from_caps: assertion 'gst_caps_is_fixed (caps)' failed"
        // As the session log gets them once GStreamer is installed: the first
        // between empty "steam:" and "game:" lines, and the repeat total the
        // console adds when the game's output closes. A game's own log can
        // have them too.
        func record(_ recording: Recording) {
            recording.print("\n" + pygobject + "\n", by: .steam)
            recording.print("\n" + videoCaps + "\n\n" + videoCaps + "\n", by: .game)
            recording.close(.game)
        }
        let gameLog = excerpt([pygobject, videoCaps, videoCaps].joined(separator: "\n"))
        let recording = Recording(gStreamer: .missing)
        record(recording)
        let total = "game: " + L10n.string(.modelGStreamerWarningRepeats, "gst_video_info_from_caps", Int64(1))
        XCTAssertTrue(recording.console.log.hasSuffix(total + "\n"), recording.console.log)
        XCTAssertEqual(recording.hints(gameLog: gameLog), [])

        // Rules that would take every one of these lines pass over them, and
        // still take a line that is not one.
        let rules = [KnownErrorHint("CRITICAL|failed|repeats", reads: .wine, key: .modelHintWineCrashed),
                     KnownErrorHint("CRITICAL|failed", reads: .game, key: .modelHintOpenVR)]
        let wide = Recording(rules: rules)
        record(wide)
        XCTAssertEqual(wide.hints(gameLog: gameLog), [])
        let other = Recording(rules: rules)
        record(other)
        other.print("(wine:40051): GLib-CRITICAL **: a source failed\n", by: .steam)
        XCTAssertEqual(other.hints(), [.modelHintWineCrashed])
    }

    func testEachHintOnceInTheOrderOfTheRules() {
        let recording = Recording(gStreamer: .missing)
        recording.print([wineserverCrash, "Basalt OpenXR: D3D11 runtime support is unavailable", wineserverCrash,
                         openVRNotLoaded].joined(separator: "\n") + "\n", by: .game)
        XCTAssertEqual(recording.hints(gameLog: excerpt([openVRNotLoaded, videoError, videoError].joined(separator: "\n"))),
                       [.modelHintVideoWithoutGStreamer, .modelHintOpenVR, .modelHintOpenXR, .modelHintWineCrashed])
        // Given once: the session is done with.
        XCTAssertNil(recording.scanner.finish(recording.session))
        recording.print(wineserverCrash + "\n", by: .game)
        XCTAssertNil(recording.scanner.finish(recording.session))
        // Two rules for one hint give it once.
        let twice = Recording(rules: [KnownErrorHint("^wineserver crashed", reads: .wine, key: .modelHintWineCrashed),
                                      KnownErrorHint("restart", reads: .wine, key: .modelHintWineCrashed)])
        twice.print(wineserverCrash + "\n", by: .steam)
        XCTAssertEqual(twice.hints(), [.modelHintWineCrashed])
    }

    func testEachSessionKeepsItsOwnOutput() throws {
        var scanner = KnownErrorScanner()
        let root = URL(fileURLWithPath: "/Users/example/TrailBridge", isDirectory: true)
        let first = UUID(), second = UUID()
        let firstGame = NSObject(), secondGame = NSObject(), utility = NSObject()
        scanner.begin(first, dataRoot: root)
        scanner.attach(ObjectIdentifier(firstGame), printer: .game, to: first)
        scanner.begin(second, dataRoot: root.appendingPathComponent("other"))
        scanner.attach(ObjectIdentifier(secondGame), printer: .game, to: second)
        XCTAssertEqual(scanner.unfinished, [first, second])

        // The first session's game still prints after the second has taken the log over.
        scanner.read(["game: " + wineserverCrash], from: ObjectIdentifier(firstGame))
        scanner.read([wineserverCrash], from: ObjectIdentifier(utility))
        let secondHints = try XCTUnwrap(scanner.finish(second))
        XCTAssertEqual(secondHints.hints.map(\.key), [])
        XCTAssertEqual(secondHints.dataRoot, root.appendingPathComponent("other"))
        // A closed pipe's identity may come back for one no session attached.
        XCTAssertTrue(scanner.isReading(first))
        scanner.close(ObjectIdentifier(firstGame))
        XCTAssertFalse(scanner.isReading(first))
        scanner.read(["game: " + openVRNotLoaded], from: ObjectIdentifier(firstGame))
        XCTAssertEqual(scanner.unfinished, [first])
        XCTAssertEqual(scanner.finish(first)?.hints.map(\.key), [.modelHintWineCrashed])
        XCTAssertEqual(scanner.unfinished, [])

        // A pipe that does not close in time is not read once the session stops reading.
        let third = UUID(), thirdGame = NSObject()
        scanner.begin(third, dataRoot: root)
        scanner.attach(ObjectIdentifier(thirdGame), printer: .game, to: third)
        scanner.stopReading(third)
        XCTAssertFalse(scanner.isReading(third))
        scanner.read(["game: " + wineserverCrash], from: ObjectIdentifier(thirdGame))
        XCTAssertEqual(scanner.finish(third)?.hints.map(\.key), [])
        withExtendedLifetime((firstGame, secondGame, utility, thirdGame)) {}
    }

    // MARK: - The hints

    func testHintsNameThePlacesAsTheAppNamesThem() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            for rule in KnownErrorHint.rules {
                let text = rule.text
                XCTAssertFalse(text.contains("%") || text.contains("\n"), "\(language).\(rule.key): \(text)")
                for place in rule.places {
                    XCTAssertTrue(text.contains(L10n.string(place)), "\(language).\(rule.key): \(place)")
                }
            }
        }
        let gStreamer = try XCTUnwrap(KnownErrorHint.rules.first { $0.key == .modelHintVideoWithoutGStreamer })
        let openVR = try XCTUnwrap(KnownErrorHint.rules.first { $0.key == .modelHintOpenVR })
        L10n.language = .en
        XCTAssertEqual(gStreamer.text, "The game could not play a video because GStreamer is not installed. "
                       + "Open “Setup” and click “Get GStreamer…”.")
        // The game card's menu item is there even when no openvr_api.dll is
        // left for “SET UP OPENVR” to point at.
        XCTAssertEqual(openVR.text, "The game could not start OpenVR. SteamVR games need OpenComposite: "
                       + "in “Library”, open the game card's ⋯ menu and choose “OpenVR Support…”. "
                       + "If no openvr_api.dll is found there, first restore the game's own copy, "
                       + "for example by verifying the game's files in Steam.")
        L10n.language = .ru
        XCTAssertEqual(gStreamer.text, "Игра не смогла воспроизвести видео: GStreamer не установлен. "
                       + "Откройте «Подготовка» и нажмите «Скачать GStreamer…».")
    }

    func testTheSessionRecordKeepsItsHints() throws {
        let store = SessionHistoryStore(file: try temporaryDirectory().appendingPathComponent("history.json"))
        let record = SessionRecord(profileName: "electrician", settings: StreamLaunchSettings())
        try store.append(record)
        XCTAssertNil(store.load().first?.hints)

        let hints = KnownErrorHint.rules.prefix(2).map(\.text)
        try store.update(record.id) { $0.hints = hints }
        XCTAssertEqual(store.load().first?.hints, hints)
    }

    // MARK: - Helpers

    /// The excerpt of a Unity player's log as the app keeps it.
    private func excerpt(_ playerLog: String) -> GameLogExcerpt {
        GameLogExcerpt(logs: [GameLogExcerpt.Log(
            engine: .unity, label: #"C:\users\steamuser\AppData\LocalLow\Example Studio\Electrician VR\Player.log"#,
            text: playerLog)], redactedWith: redactor)
    }
}

/// One session as the app records it: what its processes print reaches the
/// session console and then the scanner, as `appendLog` and `finishLog`
/// pass it on; the app's own lines come without a pipe.
@MainActor
private final class Recording {
    let console = SessionConsole()
    var scanner: KnownErrorScanner
    let session = UUID()
    private let pipes: [KnownErrorScanner.Printer: NSObject] = [.streamer: NSObject(), .steam: NSObject(), .game: NSObject()]

    /// `gStreamer` as the game found it when it started; nil when it never did.
    init(gStreamer: GStreamerInstallation? = .installed(version: "1.28.1"), rules: [KnownErrorHint]? = nil) {
        scanner = rules.map(KnownErrorScanner.init(rules:)) ?? KnownErrorScanner()
        scanner.begin(session, dataRoot: URL(fileURLWithPath: "/Users/example/TrailBridge", isDirectory: true))
        for (printer, pipe) in pipes { scanner.attach(ObjectIdentifier(pipe), printer: printer, to: session) }
        if let gStreamer { scanner.gameStarted(in: session, gStreamer: gStreamer) }
    }

    func print(_ output: String, by printer: KnownErrorScanner.Printer) {
        let source = ObjectIdentifier(pipes[printer]!)
        scanner.read(console.append(output, from: source, prefix: printer.rawValue), from: source)
    }

    func close(_ printer: KnownErrorScanner.Printer) {
        let source = ObjectIdentifier(pipes[printer]!)
        scanner.read(console.finish(source, prefix: printer.rawValue), from: source)
        scanner.close(source)
    }

    func appLine(_ line: String) {
        scanner.read(console.append(line.hasSuffix("\n") ? line : line + "\n"), from: nil)
    }

    /// The session's hints once its game's own log has been read.
    func hints(gameLog: GameLogExcerpt? = nil) -> [L10nKey] {
        scanner.read(gameLog: gameLog, of: session)
        return scanner.finish(session)?.hints.map(\.key) ?? []
    }
}
