import XCTest
@testable import BasaltManagerKit

final class LearningReadinessTests: XCTestCase {
    private typealias Row = LearningReadinessRow

    private func check(_ id: String, _ status: SetupCheckStatus, required: Bool = true) -> SetupCheck {
        SetupCheck(id: id, title: id, detail: "", status: status, required: required)
    }

    /// Everything in place: a ready Mac, a game, Wi-Fi, nothing running.
    private func readySnapshot() -> LearningReadinessSnapshot {
        var snapshot = LearningReadinessSnapshot()
        snapshot.setupChecks = [check("engine", .ready), check("adb", .actionNeeded, required: false)]
        snapshot.connection = .wifi
        snapshot.gameName = "BRUTALISTICK VR"
        return snapshot
    }

    private func session(
        _ connection: StreamConnectionMode, started: TimeInterval, streaming: TimeInterval?
    ) -> SessionRecord {
        var settings = StreamLaunchSettings()
        settings.connection = connection
        var record = SessionRecord(profileName: "Game", settings: settings,
                                   startedAt: Date(timeIntervalSince1970: started))
        record.streamingStartedAt = streaming.map(Date.init(timeIntervalSince1970:))
        return record
    }

    private func row(_ kind: Row.Kind, _ snapshot: LearningReadinessSnapshot) throws -> Row {
        try XCTUnwrap(LearningReadiness(snapshot).row(kind))
    }

    func testTheCardHasFourRowsInOrderAndOnlySoundIsOptional() {
        let readiness = LearningReadiness(LearningReadinessSnapshot())
        XCTAssertEqual(readiness.rows.map(\.kind), [.mac, .headset, .game, .audio])
        XCTAssertEqual(readiness.rows.filter(\.isOptional).map(\.kind), [.audio])
    }

    // MARK: - Mac

    func testMacIsCheckingUntilTheChecksArriveAndNeverReadyBefore() throws {
        let mac = try row(.mac, LearningReadinessSnapshot())
        XCTAssertEqual(mac.status, .checking)
        XCTAssertEqual(mac.detail, .checking)
    }

    func testMacCheckFailureWinsOverEarlierChecks() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.setupCheckFailed = true
        XCTAssertEqual(try row(.mac, snapshot).status, .failed)
        snapshot.setupChecks = [check("engine", .ready)]
        let mac = try row(.mac, snapshot)
        XCTAssertEqual(mac.status, .failed)
        XCTAssertEqual(mac.detail, .checkFailed)
    }

    func testMacIsReadyByTheSetupPagesRule() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.setupChecks = [
            check("engine", .ready), check("runtime", .ready),
            check("adb", .actionNeeded, required: false), check("audio", .unavailable, required: false),
        ]
        let mac = try row(.mac, snapshot)
        XCTAssertEqual(mac.status, .ready)
        XCTAssertEqual(mac.detail, .macReady)
    }

    func testMacCountsMissingRequiredSteps() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.setupChecks = [
            check("engine", .actionNeeded), check("runtime", .unavailable), check("mac", .ready),
            check("adb", .actionNeeded, required: false),
        ]
        let mac = try row(.mac, snapshot)
        XCTAssertEqual(mac.status, .missing)
        XCTAssertEqual(mac.detail, .macMissing(requiredSteps: 2))
    }

    // MARK: - Headset

    func testUSBHeadsetIsCheckingBeforeTheFirstPoll() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.connection = .wired
        // The model's placeholder before any poll must not read as a fact.
        snapshot.headsetStatus = HeadsetStatus(connection: .noTools)
        let headset = try row(.headset, snapshot)
        XCTAssertEqual(headset.status, .checking)
        XCTAssertEqual(headset.detail, .checking)
        XCTAssertEqual(headset.connection, .wired)
    }

    func testUSBHeadsetPollFailure() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.connection = .wired
        snapshot.headsetPolled = true
        snapshot.headsetPollFailed = true
        snapshot.headsetStatus = HeadsetStatus(connection: .connected, clientInstalled: true)
        let headset = try row(.headset, snapshot)
        XCTAssertEqual(headset.status, .failed)
        XCTAssertEqual(headset.detail, .checkFailed)
    }

    func testUSBHeadsetPollLeftOutIsNotChecking() throws {
        // During a session nothing asks adb: the row says so instead of
        // "Checking…", whatever an earlier poll answered.
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        for polled in [false, true] {
            var snapshot = LearningReadinessSnapshot()
            snapshot.connection = .wired
            snapshot.headsetPolled = polled
            snapshot.headsetPollSkipped = true
            snapshot.headsetStatus = HeadsetStatus(connection: .none)
            let headset = try row(.headset, snapshot)
            XCTAssertEqual(headset.status, .info)
            XCTAssertEqual(headset.detail, .usbNotChecked)
            XCTAssertEqual(headset.connection, .wired)
            XCTAssertEqual(headset.text, "Not checked")
        }
    }

    func testUSBHeadsetStatesAfterThePoll() throws {
        let cases: [(HeadsetStatus, Row.Status, Row.Detail)] = [
            (HeadsetStatus(connection: .noTools), .missing, .usbToolsMissing),
            (HeadsetStatus(connection: .none), .missing, .usbNotConnected),
            (HeadsetStatus(connection: .unauthorized), .missing, .usbApprovalNeeded),
            // The poll knows the stable ALVR package only, and Play accepts
            // the others: connected without it is neutral, never "missing".
            (HeadsetStatus(connection: .connected, clientInstalled: false), .info, .usbConnected),
            (HeadsetStatus(connection: .connected, clientInstalled: true), .ready, .usbConnected),
        ]
        for (status, expectedStatus, expectedDetail) in cases {
            var snapshot = LearningReadinessSnapshot()
            snapshot.connection = .wired
            snapshot.headsetPolled = true
            snapshot.headsetStatus = status
            let headset = try row(.headset, snapshot)
            XCTAssertEqual(headset.status, expectedStatus, "\(status.connection)")
            XCTAssertEqual(headset.detail, expectedDetail, "\(status.connection)")
        }
    }

    func testWiFiHeadsetIsNeverRedAndIgnoresTheUSBPoll() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.connection = .wifi
        for (polled, failed) in [(false, false), (true, false), (true, true)] {
            snapshot.headsetPolled = polled
            snapshot.headsetPollFailed = failed
            let headset = try row(.headset, snapshot)
            XCTAssertEqual(headset.status, .info)
            XCTAssertEqual(headset.detail, .wifiNotChecked)
            XCTAssertEqual(headset.connection, .wifi)
        }
    }

    func testWiFiHeadsetShowsTheLastSessionThatReachedStreaming() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.connection = .wifi
        snapshot.sessionHistory = [
            session(.wifi, started: 5_000, streaming: nil),      // newest attempt never streamed
            session(.wired, started: 4_000, streaming: 4_010),   // USB does not count
            session(.wifi, started: 3_000, streaming: 3_020),
            session(.wifi, started: 1_000, streaming: 1_020),
        ]
        let headset = try row(.headset, snapshot)
        XCTAssertEqual(headset.status, .info)
        XCTAssertEqual(headset.detail, .wifiLastSession(Date(timeIntervalSince1970: 3_020)))

        snapshot.sessionHistory = [session(.wifi, started: 5_000, streaming: nil),
                                   session(.wired, started: 4_000, streaming: 4_010)]
        XCTAssertEqual(try row(.headset, snapshot).detail, .wifiNotChecked)
    }

    // MARK: - Game and sound

    func testGameRow() throws {
        var snapshot = LearningReadinessSnapshot()
        let none = try row(.game, snapshot)
        XCTAssertEqual(none.status, .missing)
        XCTAssertEqual(none.detail, .noGame)
        XCTAssertNil(none.note)

        snapshot.gameName = "Blood Trail"
        for badge: OpenVRBadgeState? in [nil, .installed, OpenVRBadgeState.none] {
            snapshot.openVRBadge = badge
            let game = try row(.game, snapshot)
            XCTAssertEqual(game.status, .ready)
            XCTAssertEqual(game.detail, .game("Blood Trail"))
            XCTAssertEqual(game.text, "Blood Trail")
            XCTAssertNil(game.note)
        }
    }

    func testOpenVRLabelWarnsButDoesNotBlock() throws {
        var snapshot = readySnapshot()
        snapshot.openVRBadge = .needsSetup
        let readiness = LearningReadiness(snapshot)
        let game = try XCTUnwrap(readiness.row(.game))
        XCTAssertEqual(game.status, .ready)
        XCTAssertTrue(game.showsOpenVRNote)
        XCTAssertNotNil(game.note)
        XCTAssertEqual(readiness.primaryAction, .startQuickPath)
    }

    func testSoundRowShowsWhatTheSettingsShow() throws {
        var snapshot = LearningReadinessSnapshot()
        let off = try row(.audio, snapshot)
        XCTAssertEqual(off.status, .info)
        XCTAssertEqual(off.detail, .audioOff)

        snapshot.audioDeviceName = "BlackHole 2ch"
        snapshot.audioDeviceAvailable = true
        let on = try row(.audio, snapshot)
        XCTAssertEqual(on.status, .ready)
        XCTAssertEqual(on.detail, .audio("BlackHole 2ch"))
        XCTAssertEqual(on.text, "BlackHole 2ch")

        snapshot.audioDeviceAvailable = false
        let gone = try row(.audio, snapshot)
        XCTAssertEqual(gone.status, .missing)
        XCTAssertEqual(gone.detail, .audioUnavailable("BlackHole 2ch"))
    }

    func testSoundRowForTheMacsOwnAudio() throws {
        var snapshot = LearningReadinessSnapshot()
        snapshot.macAudio = true
        let mac = try row(.audio, snapshot)
        XCTAssertEqual(mac.status, .ready)
        XCTAssertEqual(mac.detail, .audio(L10n.string(.settingsMacAudio)))

        snapshot.macAudioSupported = false
        let old = try row(.audio, snapshot)
        XCTAssertEqual(old.status, .missing)
        XCTAssertEqual(old.detail, .audioUnavailable(L10n.string(.settingsMacAudio)))
        XCTAssertTrue(old.isOptional)
    }

    // MARK: - The main button

    func testStartsWhenNothingStandsInTheWay() {
        let readiness = LearningReadiness(readySnapshot())
        XCTAssertEqual(readiness.primaryAction, .startQuickPath)
        XCTAssertTrue(readiness.canStartQuickPath)
        XCTAssertTrue(readiness.primaryAction.isEnabled)
        XCTAssertNil(readiness.primaryAction.note)
    }

    func testSoundAndTheOtherHeadsetStatesNeverBlockTheStart() {
        var snapshot = readySnapshot()
        snapshot.connection = .wired
        snapshot.audioDeviceName = "Gone"
        snapshot.audioDeviceAvailable = false
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .startQuickPath) // not polled yet
        snapshot.headsetPolled = true
        for status in [HeadsetStatus(connection: .none), HeadsetStatus(connection: .unauthorized),
                       HeadsetStatus(connection: .connected),
                       HeadsetStatus(connection: .connected, clientInstalled: true)] {
            snapshot.headsetStatus = status
            XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .startQuickPath)
        }
        snapshot.headsetPollFailed = true
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .startQuickPath)
    }

    func testUSBWithoutToolsOpensTheHeadsetSection() {
        var snapshot = readySnapshot()
        snapshot.connection = .wired
        snapshot.headsetStatus = HeadsetStatus(connection: .noTools)

        // Only a fresh answer counts. Before the poll the status is a placeholder.
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .startQuickPath)
        snapshot.headsetPolled = true
        let readiness = LearningReadiness(snapshot)
        XCTAssertEqual(readiness.primaryAction, .open(.headset))
        XCTAssertFalse(readiness.canStartQuickPath)
        XCTAssertTrue(readiness.primaryAction.isEnabled)
        XCTAssertEqual(readiness.row(.headset)?.detail, .usbToolsMissing)

        // A poll that failed or was left out says nothing about the tools.
        var failed = snapshot
        failed.headsetPollFailed = true
        XCTAssertEqual(LearningReadiness(failed).primaryAction, .startQuickPath)
        var skipped = snapshot
        skipped.headsetPollSkipped = true
        XCTAssertEqual(LearningReadiness(skipped).primaryAction, .startQuickPath)
        // Wi-Fi needs no USB tools.
        var wifi = snapshot
        wifi.connection = .wifi
        XCTAssertEqual(LearningReadiness(wifi).primaryAction, .startQuickPath)

        // Earlier obstacles still come first.
        var noGame = snapshot
        noGame.gameName = nil
        XCTAssertEqual(LearningReadiness(noGame).primaryAction, .open(.library))
        var macMissing = snapshot
        macMissing.setupChecks = [check("engine", .actionNeeded)]
        XCTAssertEqual(LearningReadiness(macMissing).primaryAction, .open(.setup))
        var running = snapshot
        running.session = .live
        XCTAssertEqual(LearningReadiness(running).primaryAction, .open(.stream))
    }

    func testTheHeaderCheckAgainHidesWhileTheMainButtonIsCheckAgain() {
        var failed = readySnapshot()
        failed.setupCheckFailed = true
        XCTAssertEqual(LearningReadiness(failed).primaryAction, .recheck)
        XCTAssertFalse(LearningReadiness(failed).showsRecheckInHeader)

        var others = [readySnapshot(), LearningReadinessSnapshot()]
        var noGame = readySnapshot()
        noGame.gameName = nil
        others.append(noGame)
        var windowsApp = readySnapshot()
        windowsApp.session = .windowsApp
        others.append(windowsApp)
        // A session comes before the failed check: the main button is not "Check again".
        var failedInSession = failed
        failedInSession.session = .live
        others.append(failedInSession)
        for snapshot in others {
            let readiness = LearningReadiness(snapshot)
            XCTAssertNotEqual(readiness.primaryAction, .recheck)
            XCTAssertTrue(readiness.showsRecheckInHeader, "\(readiness.primaryAction)")
        }
    }

    func testEachMissingPieceBecomesTheNextRealAction() {
        var checking = readySnapshot()
        checking.setupChecks = []
        XCTAssertEqual(LearningReadiness(checking).primaryAction, .wait(.checking))
        XCTAssertFalse(LearningReadiness(checking).primaryAction.isEnabled)

        var failed = readySnapshot()
        failed.setupCheckFailed = true
        XCTAssertEqual(LearningReadiness(failed).primaryAction, .recheck)

        var missing = readySnapshot()
        missing.setupChecks = [check("engine", .actionNeeded)]
        XCTAssertEqual(LearningReadiness(missing).primaryAction, .open(.setup))

        var noGame = readySnapshot()
        noGame.gameName = nil
        XCTAssertEqual(LearningReadiness(noGame).primaryAction, .open(.library))

        var windowsApp = readySnapshot()
        windowsApp.session = .windowsApp
        XCTAssertEqual(LearningReadiness(windowsApp).primaryAction, .stopWindowsApp)

        var importing = readySnapshot()
        importing.importRunning = true
        XCTAssertEqual(LearningReadiness(importing).primaryAction, .wait(.importRunning))
        XCTAssertFalse(LearningReadiness(importing).primaryAction.isEnabled)

        for phase: LearningSessionPhase in [.starting, .live] {
            var running = readySnapshot()
            running.session = phase
            XCTAssertEqual(LearningReadiness(running).primaryAction, .open(.stream))
        }

        // An earlier failure is not a session: Play is offered again.
        var afterFailure = readySnapshot()
        afterFailure.session = .failed("boom")
        XCTAssertEqual(LearningReadiness(afterFailure).primaryAction, .startQuickPath)

        for readiness in [checking, failed, missing, noGame, windowsApp, importing].map(LearningReadiness.init) {
            XCTAssertFalse(readiness.canStartQuickPath)
        }
    }

    func testTheFirstObstacleDecides() {
        var snapshot = LearningReadinessSnapshot() // Mac checking, no game
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .wait(.checking))
        snapshot.setupChecks = [check("engine", .actionNeeded)]
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .open(.setup))
        snapshot.importRunning = true
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .wait(.importRunning))
        snapshot.session = .windowsApp
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .stopWindowsApp)
        snapshot.session = .starting
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .open(.stream))
    }

    // MARK: - Texts

    func testEnglishTexts() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en

        XCTAssertEqual(L10n.string(.learningTitle), "Learning")
        XCTAssertEqual(L10n.string(.learningReadyTitle), "Ready for VR")
        XCTAssertEqual(L10n.string(.learningQuickPathTitle), "How to Start VR Again")

        var snapshot = LearningReadinessSnapshot()
        snapshot.connection = .wired
        var readiness = LearningReadiness(snapshot)
        XCTAssertEqual(readiness.rows.map(\.title), ["Mac", "Headset", "Game", "Audio"])
        XCTAssertEqual(readiness.rows.map(\.text),
                       ["Checking…", "Checking…", "No games ready yet", "No game audio"])
        XCTAssertEqual(readiness.rows.map(\.caption), [nil, "USB Cable", nil, nil])

        snapshot.setupCheckFailed = true
        snapshot.headsetPolled = true
        snapshot.headsetPollFailed = true
        snapshot.audioDeviceName = "BlackHole 2ch"
        readiness = LearningReadiness(snapshot)
        XCTAssertEqual(readiness.rows.map(\.text),
                       ["Could not check", "Could not check", "No games ready yet",
                        "BlackHole 2ch (unavailable)"])

        snapshot.setupCheckFailed = false
        snapshot.headsetPollFailed = false
        snapshot.setupChecks = [check("engine", .actionNeeded), check("runtime", .actionNeeded)]
        let usbTexts: [(HeadsetStatus, String)] = [
            (HeadsetStatus(connection: .noTools), "USB tools needed"),
            (HeadsetStatus(connection: .none), "No headset connected by USB"),
            (HeadsetStatus(connection: .unauthorized), "USB debugging approval needed"),
            (HeadsetStatus(connection: .connected), "Headset connected by USB"),
            (HeadsetStatus(connection: .connected, clientInstalled: true), "Headset connected by USB"),
        ]
        for (status, text) in usbTexts {
            snapshot.headsetStatus = status
            XCTAssertEqual(try row(.headset, snapshot).text, text)
        }
        XCTAssertEqual(try row(.mac, snapshot).text, "Missing required steps: 2")

        snapshot.setupChecks = [check("engine", .ready)]
        XCTAssertEqual(try row(.mac, snapshot).text, "Ready")

        snapshot.connection = .wifi
        XCTAssertEqual(try row(.headset, snapshot).text, "Not checked")
        XCTAssertEqual(try row(.headset, snapshot).caption, L10n.string(.connectionWiFi))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        snapshot.sessionHistory = [session(.wifi, started: 1_799_999_000, streaming: 1_800_000_000)]
        XCTAssertEqual(try row(.headset, snapshot).text, "Last session: \(Row.dateText(date))")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(Row.dateText(date, timeZone: utc), "Jan 15, 08:00")
        // Month names come from the app's own table, not from the system's locale data.
        L10n.language = .ru
        let months = L10n.string(.streamHistoryMonths, language: .ru).components(separatedBy: "|")
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(Row.dateText(date, timeZone: utc), "15 \(months[0]), 08:00")
        L10n.language = .en

        snapshot.gameName = "Blood Trail"
        snapshot.openVRBadge = .needsSetup
        XCTAssertEqual(try row(.game, snapshot).note,
                       "This game is marked “SET UP OPENVR”. That is a guess from the game's files "
                        + "and does not stop the launch. If the game does not appear in the headset, "
                        + "click that label in “Library”. If a session is running, click “Stop” first.")
    }

    func testEnglishButtonTitlesAndNotes() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        let cases: [(LearningPrimaryAction, String, String?)] = [
            (.startQuickPath, "Start VR Step by Step", nil),
            (.open(.setup), "Open Setup", nil),
            (.open(.library), "Open Library", nil),
            (.open(.stream), "Open the Stream dashboard", "A VR session is already running."),
            (.open(.headset), "Open “Headset”", nil),
            (.stopWindowsApp, "Stop",
             "A Windows app is open: Steam or an installer. Stop it to start VR."),
            (.recheck, "Check Again", nil),
            (.wait(.checking), "Checking…", nil),
            (.wait(.importRunning), "Start VR Step by Step", "A game is being added. Wait until it finishes."),
        ]
        for (action, title, note) in cases {
            XCTAssertEqual(action.title, title)
            XCTAssertEqual(action.note, note)
        }
    }

    func testEveryLanguageFillsEveryRowAndButton() {
        let previous = L10n.language
        defer { L10n.language = previous }
        var full = readySnapshot()
        full.connection = .wired
        full.headsetPolled = true
        full.openVRBadge = .needsSetup
        full.sessionHistory = [session(.wifi, started: 1_000, streaming: 1_020)]
        var wifi = full
        wifi.connection = .wifi
        let actions: [LearningPrimaryAction] = [
            .startQuickPath, .open(.setup), .open(.library), .open(.stream), .open(.steam), .open(.headset),
            .stopWindowsApp, .recheck, .wait(.checking), .wait(.importRunning),
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for snapshot in [LearningReadinessSnapshot(), full, wifi] {
                for row in LearningReadiness(snapshot).rows {
                    XCTAssertFalse(row.title.isEmpty, "\(language)")
                    XCTAssertFalse(row.text.isEmpty, "\(language)")
                    XCTAssertFalse(row.text.contains("%"), "\(language).\(row.kind)")
                    if let note = row.note {
                        XCTAssertTrue(note.contains(L10n.string(.libraryOpenVRSetup)), "\(language)")
                        XCTAssertTrue(note.contains(L10n.string(.sidebarLibrary)), "\(language)")
                        XCTAssertTrue(note.contains(L10n.string(.commonStop)), "\(language)")
                        XCTAssertFalse(note.contains("%"), "\(language)")
                    }
                }
            }
            for action in actions {
                XCTAssertFalse(action.title.isEmpty, "\(language)")
                XCTAssertFalse(action.title.contains("%"), "\(language)")
            }
        }
    }

    // MARK: - While "Game" waits for a download

    /// Stopping Steam would break the download off, so the card does not
    /// offer "Stop" while the "Game" chapter waits for it.
    func testTheCardDoesNotOfferStopWhileSteamDownloadsTheGame() {
        var snapshot = readySnapshot()
        snapshot.gameName = nil
        snapshot.session = .windowsApp
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .stopWindowsApp)
        snapshot.gameDownloading = true
        let action = LearningReadiness(snapshot).primaryAction
        XCTAssertEqual(action, .wait(.gameDownload))
        XCTAssertFalse(action.isEnabled)
        XCTAssertFalse(LearningReadiness(snapshot).canStartQuickPath)
        // Only a Windows program in the session is a download; the flag
        // alone changes nothing.
        snapshot.session = .idle
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .open(.library))
        // A VR session still comes first.
        snapshot.session = .live
        XCTAssertEqual(LearningReadiness(snapshot).primaryAction, .open(.stream))

        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(action.title, "Start VR Step by Step")
        XCTAssertEqual(action.note, "Steam is downloading a game. Do not stop Steam or quit TrailBridge.")
        for language in AppLanguage.allCases {
            L10n.language = language
            XCTAssertFalse(action.title.isEmpty, "\(language)")
            XCTAssertFalse(action.note?.isEmpty ?? true, "\(language)")
        }
    }
}
