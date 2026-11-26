import XCTest
@testable import BasaltManagerKit

final class LearningProgramTests: XCTestCase {
    private typealias Status = LearningProgramRow.Status

    private func statuses(_ facts: LearningFacts) -> [Status] {
        LearningProgram(facts).rows.map(\.status)
    }

    private func withEnglish(_ body: () throws -> Void) rethrows {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        try body()
    }

    // MARK: - Statuses

    func testTheProgramHasFiveChaptersInTheRecommendedOrder() {
        XCTAssertEqual(LearningProgram(LearningFacts()).rows.map(\.chapter),
                       [.mac, .headset, .game, .firstLaunch, .launchOptions])
        XCTAssertEqual(LearningChapter.allCases.count, 5)
    }

    /// Before the first refresh nothing is known, and nothing is "done".
    func testEmptyFactsShowNothingDone() {
        let program = LearningProgram(LearningFacts())
        XCTAssertEqual(program.rows.map(\.status), [
            .notStarted, .notStarted, .blocked(by: .mac), .blocked(by: .mac), .blocked(by: .game),
        ])
        XCTAssertEqual(program.doneCount, 0)
        XCTAssertEqual(program.nextChapter, .mac)
    }

    /// An empty list of checks is never a ready Mac, whatever else is there.
    func testAnEmptyCheckListIsNeverDone() {
        var facts = LearningFixture.returning
        facts.setupChecks = []
        XCTAssertFalse(facts.macReady)
        XCTAssertFalse(facts.isDone(.mac))
        XCTAssertEqual(LearningProgram(facts).row(.mac)?.status, .notStarted)
        // Only optional checks, all ready: still nothing required was seen
        // missing, and the list is not empty, so the Setup page's rule holds.
        facts.setupChecks = [SetupCheck(id: "screen", title: "", detail: "", status: .ready, required: false)]
        XCTAssertTrue(facts.isDone(.mac))
    }

    func testMacIsDoneByTheSetupPagesRule() {
        XCTAssertTrue(LearningFixture.newcomer.isDone(.mac))
        // A missing optional part does not count.
        XCTAssertTrue(LearningFixture.newcomer.with {
            $0.setupChecks = LearningFixture.checks(missing: ["adb", "audio", "screen"])
        }.isDone(.mac))
        for id in ["wine", "runtime", "dxmt"] {
            XCTAssertFalse(LearningFixture.newcomer.with {
                $0.setupChecks = LearningFixture.checks(missing: [id])
            }.isDone(.mac), id)
        }
        XCTAssertFalse(LearningFixture.newcomer.with {
            $0.setupChecks = LearningFixture.checks(unsupportedMac: true)
        }.isDone(.mac))
    }

    func testPartialFacts() {
        // A Mac where nothing is built: the Mac is next, the headset is free.
        XCTAssertEqual(statuses(LearningFixture.unbuiltMac), [
            .notStarted, .notStarted, .blocked(by: .mac), .blocked(by: .mac), .blocked(by: .game),
        ])
        // A ready Mac, nothing else.
        let newcomer = LearningProgram(LearningFixture.newcomer)
        XCTAssertEqual(newcomer.rows.map(\.status), [
            .done, .notStarted, .notStarted, .blocked(by: .game), .blocked(by: .game),
        ])
        XCTAssertEqual(newcomer.nextChapter, .headset)
        XCTAssertEqual(newcomer.doneCount, 1)
        // A game, no session yet.
        let withGame = LearningProgram(LearningFixture.withGame)
        XCTAssertEqual(withGame.rows.map(\.status), [.done, .notStarted, .done, .notStarted, .notStarted])
        XCTAssertEqual(withGame.nextChapter, .headset)
        XCTAssertEqual(withGame.doneCount, 2)
    }

    func testFullFacts() {
        var facts = LearningFixture.returning
        XCTAssertEqual(statuses(facts), [.done, .done, .done, .done, .notStarted])
        XCTAssertEqual(LearningProgram(facts).nextChapter, .launchOptions)
        facts.chapters[.launchOptions].completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let program = LearningProgram(facts)
        XCTAssertEqual(program.rows.map(\.status), Array(repeating: .done, count: 5))
        XCTAssertEqual(program.doneCount, 5)
        XCTAssertNil(program.nextChapter)
    }

    func testFirstMacBlocksGameAndFirstLaunchButNotTheHeadset() {
        let facts = LearningFixture.unbuiltMac
        XCTAssertNil(facts.blocker(of: .mac))
        XCTAssertNil(facts.blocker(of: .headset))
        XCTAssertEqual(facts.blocker(of: .game), .mac)
        XCTAssertEqual(facts.blocker(of: .firstLaunch), .mac)
        XCTAssertEqual(facts.blocker(of: .launchOptions), .game)
        // A blocked chapter has no button, and is never the next one.
        let program = LearningProgram(facts)
        XCTAssertNil(program.row(.game)?.action)
        XCTAssertNil(program.row(.firstLaunch)?.action)
        XCTAssertEqual(program.nextChapter, .mac)
        withEnglish {
            XCTAssertEqual(program.row(.game)?.statusText, "First: Mac")
            XCTAssertEqual(program.row(.launchOptions)?.statusText, "First: Game")
        }
    }

    /// "Game" does not wait for "Headset": a download takes hours.
    func testGameCanStartBeforeTheHeadset() {
        let program = LearningProgram(LearningFixture.newcomer)
        XCTAssertEqual(program.row(.headset)?.status, .notStarted)
        XCTAssertEqual(program.row(.game)?.status, .notStarted)
        XCTAssertEqual(program.row(.game)?.action, .start)
        // "First launch" needs the game, not the headset chapter: a headset
        // set up by hand over Wi-Fi leaves no fact behind before it streams.
        XCTAssertEqual(LearningProgram(LearningFixture.withGame).row(.firstLaunch)?.action, .start)
    }

    // MARK: - Headset

    func testHeadsetIsDoneByASessionTheChaptersRecordOrTheTestedALVROnTheCable() {
        let base = LearningFixture.newcomer
        XCTAssertFalse(base.isDone(.headset))
        // The placeholder before the Headset page has asked, and no headset.
        XCTAssertFalse(base.with { $0.headsetConnection = .noTools }.isDone(.headset))
        XCTAssertFalse(base.with { $0.headsetConnection = .none }.isDone(.headset))
        // Connected over USB with ALVR on it: done. Without ALVR there is
        // still something to install.
        XCTAssertFalse(base.with { $0.headsetConnection = .connected }.isDone(.headset))
        XCTAssertTrue(base.with(LearningFixture.headsetReady).isDone(.headset))
        // Only the tested version counts: another one is still to replace,
        // and one whose version the headset did not tell is not known.
        XCTAssertFalse(base.with(LearningFixture.headset(.connected, client: "20.11.0")).isDone(.headset))
        XCTAssertFalse(base.with(LearningFixture.headset(.connected)).with {
            $0.headsetClientInstalled = true
        }.isDone(.headset))
        // The debugging prompt is still unanswered: not done, whatever an
        // earlier look at the headset said about ALVR.
        XCTAssertFalse(base.with { $0.headsetConnection = .unauthorized }.isDone(.headset))
        for connection in [HeadsetStatus.Connection.unauthorized, .none, .noTools] {
            XCTAssertFalse(base.with {
                $0.headsetConnection = connection
                $0.headsetClientInstalled = true
                $0.headsetClientVersion = PinnedHeadsetDownload.testedALVR.version
            }.isDone(.headset), "\(connection)")
        }
        // The chapter was walked to its end: done, cable or no cable, and
        // whatever the page sees of ALVR. A chapter only under way is not.
        let walked = base.with { $0.chapters[.headset].completedAt = Date(timeIntervalSince1970: 1) }
        XCTAssertTrue(walked.isDone(.headset))
        XCTAssertTrue(walked.with(LearningFixture.headset(.none)).isDone(.headset))
        XCTAssertEqual(LearningProgram(walked).row(.headset)?.action, .review)
        XCTAssertEqual(LearningProgram(walked).nextChapter, .game)
        XCTAssertFalse(base.with {
            $0.chapters[.headset].pausedStep = SetupTour.Step.headsetOpenALVR.rawValue
        }.isDone(.headset))
        // A session that reached streaming; one that only started does not count.
        XCTAssertFalse(base.with { $0.sessionHistory = [LearningFixture.session(streamed: false)] }
            .isDone(.headset))
        XCTAssertTrue(base.with { $0.sessionHistory = [LearningFixture.session(streamed: true)] }
            .isDone(.headset))
        // The quick path's record survives a cleared history.
        XCTAssertTrue(base.with { $0.progress.quickPathCompleted = true }.isDone(.headset))
    }

    /// The chapter has steps of its own, so its row starts it, returns to
    /// its step or reviews it, like any other row.
    func testTheHeadsetRowStartsResumesAndReviews() {
        XCTAssertTrue(SetupTour.hasSteps(.headset))
        XCTAssertEqual(SetupTour.stepCount(of: .headset), 7)
        for facts in [LearningFacts(), LearningFixture.unbuiltMac, LearningFixture.newcomer] {
            let row = LearningProgram(facts).row(.headset)
            XCTAssertEqual(row?.status, .notStarted)
            XCTAssertEqual(row?.action, .start)
            XCTAssertNotNil(SetupTour(chapter: .headset, mode: .firstPass, facts: facts))
        }
        var paused = LearningFixture.newcomer
        paused.chapters[.headset].pausedStep = SetupTour.Step.headsetCable.rawValue
        XCTAssertEqual(LearningProgram(paused).row(.headset)?.status, .paused(step: 4, of: 7))
        XCTAssertEqual(LearningProgram(paused).row(.headset)?.action, .resume)
        // Stopped on the opening card, which has no number: the first step.
        paused.chapters[.headset].pausedStep = SetupTour.Step.headsetIntro.rawValue
        XCTAssertEqual(LearningProgram(paused).row(.headset)?.status, .paused(step: 1, of: 7))
        // Done by the facts: a review, whatever the record says.
        for facts in [LearningFixture.returning, paused.with(LearningFixture.headsetReady)] {
            XCTAssertEqual(LearningProgram(facts).row(.headset)?.status, .done)
            XCTAssertEqual(LearningProgram(facts).row(.headset)?.action, .review)
        }
        withEnglish {
            XCTAssertEqual(LearningProgram(paused.with {
                $0.chapters[.headset].pausedStep = SetupTour.Step.headsetDebugging.rawValue
            }).row(.headset)?.statusText, "Step 5 of 7")
        }
    }

    // MARK: - First launch, launch options

    func testFirstLaunchIsDoneByTheQuickPathOrAStreamedSession() {
        XCTAssertFalse(LearningFixture.withGame.isDone(.firstLaunch))
        XCTAssertTrue(LearningFixture.withGame.with { $0.progress.quickPathCompleted = true }
            .isDone(.firstLaunch))
        XCTAssertTrue(LearningFixture.withGame.with {
            $0.sessionHistory = [LearningFixture.session(streamed: true)]
        }.isDone(.firstLaunch))
        XCTAssertFalse(LearningFixture.withGame.with {
            $0.sessionHistory = [LearningFixture.session(streamed: false)]
        }.isDone(.firstLaunch))
    }

    func testLaunchOptionsGoByTheirRecordAndNeedAGame() {
        var facts = LearningFixture.returning
        XCTAssertFalse(facts.isDone(.launchOptions))
        facts.chapters[.launchOptions].completedAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(facts.isDone(.launchOptions))
        // Without a game the chapter is blocked until it is done once.
        XCTAssertEqual(LearningProgram(LearningFixture.newcomer).row(.launchOptions)?.status,
                       .blocked(by: .game))
    }

    // MARK: - Paused chapters

    func testAPausedChapterShowsItsStepAndOffersContinue() {
        var facts = LearningFixture.returning
        facts.chapters[.launchOptions].pausedStep = SetupTour.Step.optionsConnection.rawValue
        let row = LearningProgram(facts).row(.launchOptions)
        XCTAssertEqual(row?.status, .paused(step: 3, of: 6))
        XCTAssertEqual(row?.action, .resume)
        withEnglish {
            XCTAssertEqual(row?.statusText, "Step 3 of 6")
            XCTAssertEqual(row?.action?.title, "Continue")
        }

        var game = LearningFixture.newcomer
        game.chapters[.game].pausedStep = SetupTour.Step.gameWait.rawValue
        XCTAssertEqual(LearningProgram(game).row(.game)?.status, .paused(step: 3, of: 5))
        var mac = LearningFixture.unbuiltMac
        mac.chapters[.mac].pausedStep = SetupTour.Step.macWhoBuilds.rawValue
        XCTAssertEqual(LearningProgram(mac).row(.mac)?.status, .paused(step: 2, of: 2))
        // A card outside the count reads as the first step.
        var stop = LearningFixture.returning
        stop.chapters[.launchOptions].pausedStep = SetupTour.Step.optionsStop.rawValue
        XCTAssertEqual(LearningProgram(stop).row(.launchOptions)?.status, .paused(step: 1, of: 6))
    }

    /// "First launch" has no numbered steps: closed on its one card, it is
    /// simply not started, never "step 1 of 0".
    func testFirstLaunchIsNeverShownAsPaused() {
        XCTAssertEqual(SetupTour.stepCount(of: .firstLaunch), 0)
        var facts = LearningFixture.withGame
        facts.chapters[.firstLaunch].pausedStep = SetupTour.Step.launchMicrophone.rawValue
        XCTAssertEqual(LearningProgram(facts).row(.firstLaunch)?.status, .notStarted)
        XCTAssertEqual(LearningProgram(facts).row(.firstLaunch)?.action, .start)
    }

    func testAnUnknownOrForeignStepNameStartsTheChapterOver() {
        var facts = LearningFixture.returning
        facts.chapters[.launchOptions].pausedStep = "a step from another version"
        XCTAssertEqual(LearningProgram(facts).row(.launchOptions)?.status, .notStarted)
        XCTAssertEqual(LearningProgram(facts).row(.launchOptions)?.action, .start)
        // Another chapter's step.
        facts.chapters[.launchOptions].pausedStep = SetupTour.Step.gameWait.rawValue
        XCTAssertEqual(LearningProgram(facts).row(.launchOptions)?.status, .notStarted)
    }

    func testDoneAndBlockedWinOverAPause() {
        var facts = LearningFixture.withGame
        facts.chapters[.game].pausedStep = SetupTour.Step.gameStopSteam.rawValue
        XCTAssertEqual(LearningProgram(facts).row(.game)?.status, .done)
        XCTAssertEqual(LearningProgram(facts).row(.game)?.action, .review)
        var blocked = LearningFixture.unbuiltMac
        blocked.chapters[.game].pausedStep = SetupTour.Step.gameWait.rawValue
        XCTAssertEqual(LearningProgram(blocked).row(.game)?.status, .blocked(by: .mac))
    }

    // MARK: - The page

    func testANewPersonGetsTheChapterListAndAReturningOneTheCard() {
        XCTAssertEqual(LearningPage(LearningFacts()).layout, .newcomer)
        XCTAssertEqual(LearningPage(LearningFixture.newcomer).layout, .newcomer)
        XCTAssertEqual(LearningPage(LearningFixture.withGame).layout, .newcomer)
        XCTAssertEqual(LearningPage(LearningFixture.returning).layout, .returning)
        // Either fact alone is enough.
        XCTAssertEqual(LearningPage(LearningFixture.withGame.with {
            $0.progress.quickPathCompleted = true
        }).layout, .returning)
        XCTAssertEqual(LearningPage(LearningFixture.withGame.with {
            $0.sessionHistory = [LearningFixture.session(streamed: true)]
        }).layout, .returning)
    }

    func testThePageHasExactlyOnePrimaryButton() {
        var answered = LearningFixture.newcomer
        answered.firstRunAnswered = true
        var done = LearningFixture.returning
        done.chapters[.launchOptions].completedAt = Date(timeIntervalSince1970: 1)
        let cases: [(LearningFacts, LearningPage.PrimaryButton?)] = [
            // Nothing is known yet: no invitation, the Mac is next.
            (LearningFacts(), .chapter(.mac)),
            (LearningFixture.unbuiltMac, .invitation),
            (LearningFixture.newcomer, .invitation),
            (LearningFixture.unbuiltMac.with { $0.firstRunAnswered = true }, .chapter(.mac)),
            (answered, .chapter(.headset)),
            (answered.with(LearningFixture.headsetReady), .chapter(.game)),
            (answered.with { $0.headsetConnection = .unauthorized }, .chapter(.headset)),
            (LearningFixture.withGame, .chapter(.headset)),
            (LearningFixture.withGame.with(LearningFixture.headsetReady), .chapter(.firstLaunch)),
            (LearningFixture.returning, .readyCard),
            (done, .readyCard),
        ]
        for (facts, expected) in cases {
            let page = LearningPage(facts)
            XCTAssertEqual(page.primaryButton, expected)
            let primaryRows = page.rows.filter(\.isPrimary).map(\.chapter)
            if case .chapter(let chapter)? = expected {
                XCTAssertEqual(primaryRows, [chapter])
            } else {
                XCTAssertEqual(primaryRows, [])
            }
            // The invitation and the card belong to different layouts.
            XCTAssertEqual(page.invitation != nil, expected == .invitation)
            XCTAssertEqual(page.layout == .returning, expected == .readyCard)
            XCTAssertNotNil(page.primaryButton)
        }
    }

    func testRowButtons() {
        let page = LearningPage(LearningFixture.withGame.with { $0.firstRunAnswered = true })
        XCTAssertEqual(page.rows.map(\.action), [.review, .start, .review, .start, .start])
        withEnglish {
            XCTAssertEqual(page.rows.compactMap(\.action).map(\.title),
                           ["Review", "Start", "Review", "Start", "Start"])
            // A section without a chapter of its own would be opened so.
            XCTAssertEqual(LearningProgramRow.Action.open(.headset).title, "Open “Headset”")
        }
    }

    func testEnglishTexts() {
        withEnglish {
            let page = LearningPage(LearningFixture.returning)
            XCTAssertEqual(page.rows.map(\.title),
                           ["Mac", "Headset", "Game", "First Launch", "Launch Options"])
            XCTAssertEqual(page.rows.map(\.purpose), [
                "Check that this Mac has everything for VR.",
                "Put the ALVR app on the headset. Once, over the cable.",
                "Add a game: from Steam or from a folder.",
                "Start the game and see it in the headset.",
                "Where else “Play” is, cable or Wi-Fi, quality.",
            ])
            XCTAssertEqual(page.rows.map(\.statusText),
                           ["Done", "Done", "Done", "Done", "Not started"])
            XCTAssertEqual(page.summary, "4 of 5 done")
            XCTAssertEqual(LearningPage.showTitle, "Show")
            XCTAssertEqual(LearningPage.hideTitle, "Hide")
            XCTAssertEqual(LearningPage.intro, [
                "TrailBridge runs Windows VR games on this Mac and shows them in a Quest 3.",
                "The ALVR app goes on the headset: it receives the picture.",
                "Games tested in the headset are marked in the list when you add a Steam game. Others may not work.",
            ])
            XCTAssertEqual(LearningPage.scheme, ["Mac", "cable or Wi-Fi", "Quest 3"])
            XCTAssertEqual(LearningPage.needsTitle, "You Will Need")
            XCTAssertEqual(LearningPage.needs, [
                "A USB-C cable that carries data",
                "A phone with the Meta Horizon app",
                "An adult with a Meta account",
                "Your Steam sign-in, and the phone for Steam Guard",
                "Disk space: on this Mac, an external disk or network storage, as you choose in Settings",
                "Time for the game to download",
            ])
        }
    }

    func testEveryLanguageFillsThePage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        var paused = LearningFixture.returning
        paused.chapters[.launchOptions].pausedStep = SetupTour.Step.optionsHistory.rawValue
        for language in AppLanguage.allCases {
            L10n.language = language
            for facts in [LearningFacts(), LearningFixture.unbuiltMac, LearningFixture.newcomer,
                          LearningFixture.withGame, LearningFixture.returning, paused] {
                let page = LearningPage(facts)
                let texts = page.rows.flatMap { [$0.title, $0.purpose, $0.statusText, $0.action?.title ?? "-"] }
                    + [page.summary, LearningPage.showTitle, LearningPage.hideTitle, LearningPage.needsTitle]
                    + LearningPage.intro + LearningPage.scheme + LearningPage.needs
                    + [page.invitation?.text ?? "-", page.invitation?.note ?? "-",
                       page.invitation?.startTitle ?? "-", page.invitation?.laterTitle ?? "-"]
                for text in texts {
                    XCTAssertFalse(text.isEmpty, "\(language)")
                    XCTAssertFalse(text.contains("%"), "\(language): \(text)")
                }
            }
            // The purpose of the last chapter names Play as Play names itself.
            XCTAssertTrue(LearningChapter.launchOptions.purpose.contains(L10n.string(.libraryPlay)),
                          "\(language)")
        }
    }
}
