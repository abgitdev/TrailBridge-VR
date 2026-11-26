import XCTest
@testable import BasaltManagerKit

final class LearningTopicTests: XCTestCase {
    private var previousLanguage = AppLanguage.en

    override func setUp() {
        super.setUp()
        previousLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = previousLanguage
        super.tearDown()
    }

    private func facts(_ change: (inout LearningTopicFacts) -> Void = { _ in }) -> LearningTopicFacts {
        var facts = LearningTopicFacts()
        facts.section = .learning
        change(&facts)
        return facts
    }

    private func tour(
        _ topic: LearningTopic, _ change: (inout LearningTopicFacts) -> Void = { _ in }
    ) -> LearningTopicTour {
        LearningTopicTour(topic: topic, facts: facts(change))
    }

    private func shown(_ tour: LearningTopicTour, file: StaticString = #filePath,
                       line: UInt = #line) throws -> LearningTopicPresentation {
        try XCTUnwrap(tour.presentation, file: file, line: line)
    }

    private func feed(_ tour: inout LearningTopicTour, _ change: (inout LearningTopicFacts) -> Void) {
        var facts = tour.facts
        change(&facts)
        tour.handle(.facts(facts))
    }

    // MARK: - The Learning page's lists

    func testThePageListsThreeTroubleTopicsAndThreeUnderMore() {
        XCTAssertEqual(LearningTopic.Group.trouble.topics, [.launchFailed, .noSound, .report])
        XCTAssertEqual(LearningTopic.Group.more.topics, [.interface, .graphics, .connection])
        XCTAssertEqual(LearningTopic.Group.trouble.title, "If something does not work")
        XCTAssertEqual(LearningTopic.Group.more.title, "More")
        XCTAssertEqual(LearningTopic.allCases.map(\.title), [
            "The launch failed", "No sound in the headset", "Getting help",
            "The interface", "Graphics", "Connection",
        ])
        XCTAssertEqual(LearningTopic.launchFailed.purpose,
                       "Where the cause is written and where the “How to Fix” button is.")
        XCTAssertEqual(LearningTopic.showTitle, "Show")
    }

    func testEveryTopicHasANameAndAPurposeInEveryLanguage() {
        for language in AppLanguage.allCases {
            L10n.language = language
            for topic in LearningTopic.allCases {
                XCTAssertFalse(topic.title.isEmpty, "\(language) \(topic)")
                XCTAssertFalse(topic.purpose.isEmpty, "\(language) \(topic)")
                XCTAssertFalse(topic.purpose.contains("%"), "\(language) \(topic): \(topic.purpose)")
            }
            // The "Connection" topic is called what its switch is called.
            XCTAssertEqual(LearningTopic.connection.title, L10n.string(.streamConnection))
            XCTAssertTrue(LearningTopic.launchFailed.purpose.contains(L10n.string(.learningHowToFix)))
        }
    }

    // MARK: - The launch failed

    func testLaunchFailedShowsWhereTheCauseIsAndThenTheFixButton() throws {
        var tour = tour(.launchFailed)
        XCTAssertEqual(tour.steps, [.failedCause, .failedFix])
        var hint = try shown(tour)
        XCTAssertEqual(hint.label, "The launch failed · step 1 of 2")
        XCTAssertEqual(hint.text, "If a launch fails, the cause is written here, in “Stream”, under this label.")
        XCTAssertEqual(hint.target, .streamStatus)
        XCTAssertEqual(hint.section, .stream)
        XCTAssertEqual(hint.buttons, [.next])
        XCTAssertNil(hint.list)

        tour.handle(.next)
        hint = try shown(tour)
        XCTAssertEqual(hint.label, "The launch failed · step 2 of 2")
        XCTAssertEqual(hint.text,
                       "For common failures a “How to Fix” button appears under the cause. It says what to press.")
        // No failure is on screen, so there is no button to point at.
        XCTAssertNil(hint.target)
        XCTAssertEqual(hint.buttons, [.back, .done])
    }

    /// The list under the second hint is the seven causes "How to fix"
    /// knows, by the names their advice has: nothing is written twice.
    func testTheKnownFailuresAreListedByTheirAdviceTitles() throws {
        for language in AppLanguage.allCases {
            L10n.language = language
            var tour = tour(.launchFailed)
            tour.handle(.next)
            let list = try XCTUnwrap(try shown(tour).list, "\(language)")
            XCTAssertEqual(list.title, L10n.string(.learningFailedKnownCauses))
            XCTAssertEqual(list.items.count, 7)
            XCTAssertEqual(list.items, LaunchFailureCause.allCases.map {
                LaunchFailureAdvice(cause: $0, context: LaunchFailureContext(connection: .wifi)).title
            }, "\(language)")
        }
    }

    func testAKnownFailureOnScreenIsNamedAndItsButtonOutlined() throws {
        var tour = tour(.launchFailed) {
            $0.session = .failed("x")
            $0.knownFailure = .clientMissing
        }
        tour.handle(.next)
        let hint = try shown(tour)
        XCTAssertEqual(hint.target, .streamHowToFix)
        XCTAssertEqual(hint.text,
                       "The cause now is “ALVR is not on the headset”. Click “How to Fix” under "
                       + "it: the hint says what to do.")
        XCTAssertNil(hint.list)
        // The failure goes: the button is no longer there to point at.
        feed(&tour) {
            $0.session = .idle
            $0.knownFailure = nil
        }
        XCTAssertNil(try shown(tour).target)
        XCTAssertNotNil(try shown(tour).list)
    }

    // MARK: - No sound in the headset

    func testNoSoundWalksTheListTheWindowAndBlackHole() throws {
        var tour = tour(.noSound)
        XCTAssertEqual(tour.steps, [.soundChoice, .soundFront, .soundBlackHole])
        var hint = try shown(tour)
        XCTAssertEqual(hint.label, "No sound in the headset · step 1 of 3")
        XCTAssertEqual(hint.text,
                       "Check the “Game audio” list. The usual choice is “Mac audio”. A change "
                       + "takes effect at the next launch.")
        XCTAssertEqual(hint.target, .settingsGameAudio)
        XCTAssertEqual(hint.section, .settings)

        tour.handle(.next)
        hint = try shown(tour)
        XCTAssertEqual(hint.text,
                       "The game's window must be in front on the Mac: without that, games go silent. "
                       + "TrailBridge brings it back by itself while you leave the Mac alone.")
        XCTAssertNil(hint.target)
        XCTAssertEqual(hint.buttons, [.back, .next])

        tour.handle(.next)
        hint = try shown(tour)
        XCTAssertEqual(hint.text,
                       "The fallback is BlackHole. It is installed separately: “Get BlackHole…” "
                       + "below, then restart the Mac and choose it in the list.")
        XCTAssertEqual(hint.target, .settingsGameAudio)
        XCTAssertEqual(hint.buttons, [.back, .done])
    }

    /// "Get BlackHole…" is on the page only while BlackHole is missing.
    func testAnInstalledBlackHoleIsOnlyToBeChosen() throws {
        var tour = tour(.noSound) { $0.blackHoleInstalled = true }
        tour.handle(.next)
        tour.handle(.next)
        let text = try shown(tour).text
        XCTAssertEqual(text,
                       "The fallback is BlackHole: choose it in this list if there is no sound with “Mac audio”.")
        XCTAssertFalse(text.contains(L10n.string(.settingsGetBlackHole)))
    }

    // MARK: - Getting help

    func testTheReportHintCarriesTheNoteAboutPersonalData() throws {
        var tour = tour(.report)
        let hint = try shown(tour)
        // One hint: no "step 1 of 1".
        XCTAssertEqual(hint.label, "Getting help")
        XCTAssertEqual(hint.text,
                       "Need help? Click “Create report…”. Personal data is replaced with labels. "
                       + "Look through the report before you send it.")
        XCTAssertEqual(hint.target, .settingsCreateReport)
        XCTAssertEqual(hint.section, .settings)
        XCTAssertEqual(hint.buttons, [.done])
        tour.handle(.next)
        XCTAssertTrue(tour.isOver)
        XCTAssertTrue(tour.isCompleted)
    }

    /// Diagnostic recording is a tool for finding faults and is easy to
    /// leave on: no topic sends anyone to it.
    func testNoTopicTeachesDiagnosticRecording() {
        let recordingKeys: [L10nKey] = [
            .recordingTitle, .recordingFrames, .recordingVideo, .recordingOpen, .sidebarDiagnostics,
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for hint in everyHint() {
                for key in recordingKeys {
                    XCTAssertFalse(hint.text.localizedCaseInsensitiveContains(L10n.string(key)),
                                   "\(language) \(hint.id): \(hint.text)")
                }
            }
        }
        // Every hint lives in the sidebar, on Stream or on Settings.
        for target in LearningTopicTarget.allCases {
            XCTAssertTrue([nil, .stream, .settings].contains(target.section), "\(target)")
        }
        for step in LearningTopicTour.Step.allCases {
            XCTAssertTrue([nil, .stream, .settings].contains(step.section), "\(step)")
        }
    }

    // MARK: - The interface

    func testTheInterfaceTopicIsTwoHintsInTheSidebar() throws {
        var tour = tour(.interface)
        XCTAssertEqual(tour.steps, [.interfaceStream, .interfaceCard])
        var hint = try shown(tour)
        XCTAssertEqual(hint.label, "The interface · step 1 of 2")
        XCTAssertEqual(hint.text, "Games are started and sessions are watched here. Click “Stream”.")
        XCTAssertEqual(hint.target, .sidebarStream)
        // The sidebar is on every page: no section is opened for the user.
        XCTAssertNil(hint.section)
        XCTAssertEqual(hint.buttons, [.next])

        tour.handle(.next)
        hint = try shown(tour)
        XCTAssertEqual(hint.text,
                       "This card always shows whether VR is running. During a game it has a “Stop” button.")
        XCTAssertEqual(hint.target, .sidebarSession)
        XCTAssertNil(hint.section)
        XCTAssertEqual(hint.buttons, [.back, .done])
    }

    func testOpeningStreamCountsTheFirstInterfaceHintByItself() {
        var tour = tour(.interface)
        feed(&tour) { $0.section = .library }
        XCTAssertEqual(tour.step, .interfaceStream)
        feed(&tour) { $0.section = .stream }
        XCTAssertEqual(tour.step, .interfaceCard)
    }

    func testAStreamSectionThatWasAlreadyOpenDoesNotCount() {
        var tour = tour(.interface) { $0.section = .stream }
        feed(&tour) { $0.recommendedPresetSelected = true }
        XCTAssertEqual(tour.step, .interfaceStream)
        // Left and opened again: now it was the user's doing.
        feed(&tour) { $0.section = .settings }
        feed(&tour) { $0.section = .stream }
        XCTAssertEqual(tour.step, .interfaceCard)
    }

    func testBackNeverJumpsForwardAgain() throws {
        var tour = tour(.interface)
        feed(&tour) { $0.section = .stream }
        XCTAssertEqual(tour.step, .interfaceCard)
        tour.handle(.back)
        XCTAssertEqual(tour.step, .interfaceStream)
        XCTAssertTrue(tour.isRevisit)
        feed(&tour) { $0.section = .library }
        feed(&tour) { $0.section = .stream }
        XCTAssertEqual(tour.step, .interfaceStream)
        XCTAssertEqual(try shown(tour).id, "topic-interfaceStream-again")
        tour.handle(.next)
        XCTAssertEqual(tour.step, .interfaceCard)
        // Back on the first hint does nothing.
        tour.handle(.back)
        tour.handle(.back)
        XCTAssertEqual(tour.step, .interfaceStream)
    }

    // MARK: - Graphics

    func testGraphicsIsOneActionInTheChaptersOwnWords() throws {
        var tour = tour(.graphics)
        XCTAssertEqual(tour.steps, [.graphicsRecommended])
        var hint = try shown(tour)
        XCTAssertEqual(hint.label, "Graphics")
        XCTAssertEqual(hint.target, .settingsUseRecommended)
        XCTAssertEqual(hint.section, .settings)
        XCTAssertEqual(hint.text, L10n.string(.learningOptionsRecommended, "Use recommended"))
        XCTAssertEqual(hint.buttons, [.done])
        // The button was pressed: the same hint says so.
        feed(&tour) {
            $0.section = .settings
            $0.recommendedPresetSelected = true
        }
        hint = try shown(tour)
        XCTAssertEqual(hint.id, "topic-graphicsRecommended")
        XCTAssertEqual(hint.text, L10n.string(.learningOptionsRecommendedSet, "Use recommended"))
        XCTAssertNil(hint.section)
    }

    // MARK: - Connection

    func testConnectionSaysWhenToChooseWhich() throws {
        L10n.language = .ru
        let wifi = L10n.string(.connectionWiFi, language: .ru, arguments: [])
        let usb = L10n.string(.connectionUSB, language: .ru, arguments: [])
        let title = L10n.string(.streamConnection, language: .ru, arguments: [])
        let label = L10n.string(.learningChapterStepLabel, language: .ru, arguments: [title, Int64(1), Int64(2)])
        var tour = tour(.connection)
        XCTAssertEqual(tour.steps, [.connectionWiFi, .connectionUSB])
        var hint = try shown(tour)
        XCTAssertEqual(hint.label, label)
        XCTAssertEqual(hint.text, L10n.string(.learningConnectionWiFi, language: .ru, arguments: [wifi]))
        XCTAssertEqual(hint.target, .settingsConnection)
        XCTAssertEqual(hint.section, .settings)
        tour.handle(.next)
        hint = try shown(tour)
        XCTAssertEqual(hint.text, L10n.string(.learningConnectionUSB, language: .ru, arguments: [usb]))
        XCTAssertEqual(hint.target, .settingsConnection)
        XCTAssertEqual(hint.buttons, [.back, .done])

        L10n.language = .en
        XCTAssertEqual(try shown(tour).text,
                       "USB Cable — when the router is weak or far away: the picture stays smoother, "
                       + "without network stutter.")
        tour.handle(.back)
        XCTAssertEqual(try shown(tour).text,
                       "Wi-Fi — no cable. Choose it when the router is strong (Wi-Fi 6E or 7) and "
                       + "close, in the same room.")
    }

    // MARK: - A game with its own settings

    /// The Settings page changes nothing for such a game: each topic that
    /// points there says where the game's own setting is.
    func testAGameWithItsOwnSettingsGetsOneMoreHint() throws {
        let own: (inout LearningTopicFacts) -> Void = { $0.gameWithOwnSettings = "Blood Trail" }
        XCTAssertEqual(tour(.noSound, own).steps, [.soundChoice, .soundOwn, .soundFront, .soundBlackHole])
        XCTAssertEqual(tour(.graphics, own).steps, [.graphicsRecommended, .graphicsOwn])
        XCTAssertEqual(tour(.connection, own).steps, [.connectionWiFi, .connectionUSB, .connectionOwn])
        XCTAssertEqual(tour(.report, own).steps, [.report])
        XCTAssertEqual(tour(.interface, own).steps, [.interfaceStream, .interfaceCard])

        var tour = tour(.graphics, own)
        XCTAssertEqual(try shown(tour).buttons, [.next])
        tour.handle(.next)
        let hint = try shown(tour)
        XCTAssertEqual(hint.label, "Graphics · step 2 of 2")
        XCTAssertEqual(hint.text,
                       "“Blood Trail” has its own settings: “Quality” is changed for it in "
                       + "“Change…”, then “Stream Settings for …”.")
        XCTAssertNil(hint.target)
        XCTAssertEqual(hint.buttons, [.back, .done])

        var sound = self.tour(.noSound, own)
        sound.handle(.next)
        XCTAssertTrue(try shown(sound).text.contains("“Game audio” is changed for it"))
        var connection = self.tour(.connection, own)
        connection.handle(.next)
        connection.handle(.next)
        XCTAssertTrue(try shown(connection).text.contains("“Connection” is changed for it"))
    }

    func testAHintAboutOwnSettingsGoesWhenTheGameLosesThem() throws {
        var tour = tour(.graphics) { $0.gameWithOwnSettings = "Blood Trail" }
        tour.handle(.next)
        XCTAssertEqual(tour.step, .graphicsOwn)
        feed(&tour) { $0.gameWithOwnSettings = nil }
        XCTAssertEqual(tour.step, .graphicsRecommended)
        XCTAssertEqual(try shown(tour).buttons, [.done])

        var sound = self.tour(.noSound) { $0.gameWithOwnSettings = "Blood Trail" }
        sound.handle(.next)
        XCTAssertEqual(sound.step, .soundOwn)
        feed(&sound) { $0.gameWithOwnSettings = nil }
        XCTAssertEqual(sound.step, .soundFront)
    }

    // MARK: - The end

    func testCloseEndsATopicWithoutCompletingIt() {
        var tour = tour(.noSound)
        tour.handle(.next)
        tour.handle(.close)
        XCTAssertTrue(tour.isOver)
        XCTAssertFalse(tour.isCompleted)
        XCTAssertNil(tour.presentation)
        // Nothing moves a topic that is over.
        tour.handle(.next)
        tour.handle(.back)
        XCTAssertTrue(tour.isOver)
    }

    /// A VR launch takes it from there: the strip is let go, as advice is.
    func testAVRLaunchEndsATopic() {
        for topic in LearningTopic.allCases {
            var tour = tour(topic)
            feed(&tour) { $0.session = .starting }
            XCTAssertTrue(tour.isOver, "\(topic)")
            XCTAssertFalse(tour.isCompleted, "\(topic)")
        }
    }

    /// "No sound" is asked while the game runs: a topic may be read then.
    /// It only shows text, and nothing in it asks the headset.
    func testATopicCanBeReadWhileASessionIsLiveOrHasFailed() throws {
        for session in [LearningSessionPhase.live, .failed("x"), .windowsApp, .starting] {
            var tour = tour(.noSound) { $0.session = session }
            XCTAssertEqual(tour.step, .soundChoice, "\(session)")
            feed(&tour) { $0.section = .settings }
            XCTAssertEqual(tour.step, .soundChoice, "\(session)")
            tour.handle(.next)
            XCTAssertEqual(tour.step, .soundFront, "\(session)")
        }
    }

    // MARK: - Every hint

    private func everyFacts() -> [LearningTopicFacts] {
        var all = [LearningTopicFacts]()
        for section in [LearningDestination.learning, .stream, .settings] {
            for game in [nil, "A Very Long Game Name That Goes On And On"] as [String?] {
                for failure in [nil] + LaunchFailureCause.allCases.map(Optional.some) {
                    for flag in [false, true] {
                        var facts = LearningTopicFacts()
                        facts.section = section
                        facts.gameWithOwnSettings = game
                        facts.knownFailure = failure
                        facts.session = failure == nil ? .idle : .failed("x")
                        facts.recommendedPresetSelected = flag
                        facts.blackHoleInstalled = flag
                        all.append(facts)
                    }
                }
            }
        }
        return all
    }

    /// Every hint of every topic, in the current language.
    private func everyHint() -> [LearningTopicPresentation] {
        var hints = [LearningTopicPresentation]()
        for facts in everyFacts() {
            for topic in LearningTopic.allCases {
                var tour = LearningTopicTour(topic: topic, facts: facts)
                var guardCount = 0
                while let hint = tour.presentation, guardCount < 10 {
                    hints.append(hint)
                    tour.handle(.next)
                    guardCount += 1
                }
                XCTAssertTrue(tour.isCompleted, "\(topic)")
            }
        }
        return hints
    }

    /// The strip holds 160 characters. Every hint keeps to that in all ten
    /// tables, with real names put in.
    func testNoHintIsLongerThanTheStripHoldsInAnyLanguage() {
        XCTAssertEqual(SetupTour.hintLimit, 160)
        for language in AppLanguage.allCases {
            L10n.language = language
            let hints = everyHint()
            XCTAssertGreaterThan(Set(hints.map(\.text)).count, 20, "\(language)")
            for hint in hints {
                XCTAssertLessThanOrEqual(hint.text.count, SetupTour.hintLimit,
                                         "\(language) \(hint.id): \(hint.text)")
                XCTAssertFalse(hint.text.isEmpty, "\(language) \(hint.id)")
                XCTAssertFalse(hint.text.contains("%"), "\(language) \(hint.id): \(hint.text)")
                XCTAssertFalse(hint.label.isEmpty, "\(language) \(hint.id)")
                XCTAssertFalse(hint.label.contains("%"), "\(language) \(hint.id): \(hint.label)")
                XCTAssertLessThanOrEqual(hint.buttons.count, 2, "\(language) \(hint.id)")
                XCTAssertEqual(hint.buttons.filter { $0 == hint.primaryButton }.count, 1)
                for button in hint.buttons {
                    XCTAssertFalse(hint.title(of: button).isEmpty, "\(language) \(hint.id)")
                }
                for item in hint.list?.items ?? [] {
                    XCTAssertFalse(item.isEmpty, "\(language) \(hint.id)")
                    XCTAssertFalse(item.contains("%"), "\(language) \(hint.id): \(item)")
                }
            }
        }
    }

    /// A hint names a control by the control's own text, in every language.
    func testHintsNameControlsWithTheControlsOwnTextInEveryLanguage() throws {
        let named: [(LearningTopic, Int, [L10nKey])] = [
            (.launchFailed, 0, [.sidebarStream]),
            (.launchFailed, 1, [.learningHowToFix]),
            (.noSound, 0, [.settingsGameAudio, .settingsMacAudio]),
            (.noSound, 2, [.settingsGetBlackHole]),
            (.report, 0, [.settingsCreateReport]),
            (.interface, 0, [.sidebarStream]),
            (.interface, 1, [.commonStop]),
            (.graphics, 0, [.settingsUseRecommended]),
            (.connection, 0, [.connectionWiFi]),
            (.connection, 1, [.connectionUSB]),
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for (topic, index, keys) in named {
                var tour = tour(topic)
                for _ in 0..<index { tour.handle(.next) }
                let text = try shown(tour).text
                for key in keys {
                    XCTAssertTrue(text.contains(L10n.string(key)), "\(language) \(topic) \(index): \(text)")
                }
            }
            var own = tour(.noSound) { $0.gameWithOwnSettings = "Blood Trail" }
            own.handle(.next)
            let text = try shown(own).text
            for part in ["Blood Trail", L10n.string(.settingsGameAudio), L10n.string(.streamAdjust)] {
                XCTAssertTrue(text.contains(part), "\(language): \(text)")
            }
            XCTAssertEqual(try shown(own).title(of: .back), L10n.string(.commonBack))
            XCTAssertEqual(try shown(own).title(of: .next), L10n.string(.commonNext))
            XCTAssertEqual(try shown(own).title(of: .done), L10n.string(.sheetDone))
        }
    }

    /// A section is opened for a newly shown hint only, and never for a
    /// hint whose section is open already.
    func testOnlyANewHintOpensItsSection() throws {
        var tour = tour(.noSound)
        var hint = try shown(tour)
        XCTAssertEqual(hint.opensSection(afterShowing: nil), .settings)
        XCTAssertNil(hint.opensSection(afterShowing: hint.id))
        feed(&tour) { $0.section = .settings }
        hint = try shown(tour)
        XCTAssertNil(hint.opensSection(afterShowing: nil))
        // The user walks away: the same hint does not pull them back.
        feed(&tour) { $0.section = .library }
        XCTAssertNil(try shown(tour).opensSection(afterShowing: hint.id))
        // The next hint does ask for its page again.
        tour.handle(.next)
        XCTAssertEqual(try shown(tour).opensSection(afterShowing: hint.id), .settings)
    }

    func testEveryStepHasItsOwnHintId() {
        var ids = Set<String>()
        for topic in LearningTopic.allCases {
            var tour = tour(topic) { $0.gameWithOwnSettings = "Blood Trail" }
            while let hint = tour.presentation {
                XCTAssertTrue(ids.insert(hint.id).inserted, hint.id)
                tour.handle(.next)
            }
        }
        XCTAssertEqual(ids.count, LearningTopicTour.Step.allCases.count)
    }

    // MARK: - "?" badges

    func testThereAreExactlyFourBadgesBesideTheirControls() {
        XCTAssertEqual(LearningHelpBadge.allCases, [.connection, .quality, .gameAudio, .openVR])
        XCTAssertEqual(LearningHelpBadge.allCases.map(\.controlTitle),
                       ["Connection", "Quality", "Game audio", "OpenVR support"])
        XCTAssertEqual(LearningHelpBadge.quality.label, "What is this: Quality")
    }

    func testEnglishBadgeTexts() {
        XCTAssertEqual(LearningHelpBadge.connection.text,
                       "Wi-Fi — no cable. Choose it when the router is strong (Wi-Fi 6E or 7) and "
                       + "close, in the same room. USB Cable — when the router is weak or far away: "
                       + "the picture stays smoother, without network stutter.")
        XCTAssertEqual(LearningHelpBadge.quality.text,
                       "Higher quality means a sharper picture and more work for the Mac. If you are "
                       + "not sure, click “Use recommended”.")
        XCTAssertEqual(LearningHelpBadge.gameAudio.text,
                       "Where the game's sound for the headset comes from. The usual choice is "
                       + "“Mac audio”; BlackHole is the fallback.")
        XCTAssertEqual(LearningHelpBadge.openVR.text,
                       "The plug-in lets a game made for SteamVR run without SteamVR. Turn it on when "
                       + "the game's label says “SET UP OPENVR”.")
    }

    func testBadgesAreShortAndNameControlsInEveryLanguage() {
        let named: [LearningHelpBadge: [L10nKey]] = [
            .connection: [.connectionWiFi, .connectionUSB],
            .quality: [.settingsUseRecommended],
            .gameAudio: [.settingsMacAudio],
            .openVR: [.libraryOpenVRSetup],
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for badge in LearningHelpBadge.allCases {
                let text = badge.text
                XCTAssertFalse(text.isEmpty, "\(language) \(badge)")
                XCTAssertFalse(text.contains("%"), "\(language) \(badge): \(text)")
                XCTAssertLessThanOrEqual(text.count, 240, "\(language) \(badge): \(text)")
                XCTAssertTrue(badge.label.contains(badge.controlTitle), "\(language) \(badge)")
                for key in named[badge] ?? [] {
                    XCTAssertTrue(text.contains(L10n.string(key)), "\(language) \(badge): \(text)")
                }
            }
            // The badge and the topic say the same about the connection.
            var tour = tour(.connection)
            let first = tour.presentation?.text ?? "-"
            tour.handle(.next)
            let second = tour.presentation?.text ?? "-"
            XCTAssertTrue(LearningHelpBadge.connection.text.hasPrefix(first), "\(language)")
            XCTAssertTrue(LearningHelpBadge.connection.text.hasSuffix(second), "\(language)")
        }
    }
}
