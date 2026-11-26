import XCTest
import BasaltCore
@testable import BasaltManagerKit

final class QuickPathTourTests: XCTestCase {
    private typealias Step = QuickPathTour.Step

    private let onStream = QuickPathEnvironment(onStreamSection: true, pageSheetOpen: false)
    private let environments = [
        QuickPathEnvironment(onStreamSection: true, pageSheetOpen: false),
        QuickPathEnvironment(onStreamSection: false, pageSheetOpen: false),
        QuickPathEnvironment(onStreamSection: false, pageSheetOpen: true),
        QuickPathEnvironment(section: .headset, pageSheetOpen: false, gameWithOwnSettings: "Game"),
    ]

    /// Every state the tour can get into, from any session state, by any
    /// order of session changes and button presses.
    private func reachableStates() -> [QuickPathTour] {
        let sessions: [LearningSessionPhase] = [
            .idle, .starting, .live, .windowsApp,
            .failed("boom"), .failed(AlvrWiredFailure.adbMissing),
        ]
        let events = sessions.map(QuickPathTour.Event.session)
            + [.firstFrame, .done, .back, .skip, .checkAgain, .retry, .close]
        var states = [QuickPathTour]()
        var queue = [StreamConnectionMode.wifi, .wired].flatMap { connection in
            sessions.map { QuickPathTour(connection: connection, session: $0) }
        }
        while let state = queue.popLast() {
            guard !states.contains(state) else { continue }
            states.append(state)
            for event in events {
                var next = state
                next.handle(event)
                queue.append(next)
            }
        }
        return states
    }

    private func tour(
        connection: StreamConnectionMode = .wifi, session: LearningSessionPhase = .idle,
        _ events: QuickPathTour.Event...
    ) -> QuickPathTour {
        var tour = QuickPathTour(connection: connection, session: session)
        events.forEach { tour.handle($0) }
        return tour
    }

    // MARK: - The straight path

    func testStartsOnTheOrderCardAndWalksToCompletion() {
        var tour = tour()
        XCTAssertEqual(tour.phase, .step(.order))
        tour.handle(.done)
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.live))
        XCTAssertEqual(tour.phase, .step(.picture))
        XCTAssertTrue(tour.awaitsFirstFrame)
        tour.handle(.firstFrame)
        XCTAssertEqual(tour.phase, .completed)
        XCTAssertTrue(tour.isFinished)
        XCTAssertFalse(tour.awaitsFirstFrame)
        XCTAssertNil(tour.presentation(in: onStream))
    }

    func testStepNumbersCountOnlyTheThreeSteps() {
        XCTAssertEqual(Step.allCases.map(\.number), [nil, 1, 2, 3])
        XCTAssertEqual(Step.numberedCount, 3)
    }

    // MARK: - The order card

    /// The card itself says "Play": a launch started straight from it counts
    /// as it does on step 1.
    func testALaunchFromTheOrderCardMovesOnAsOnStep1() {
        let starting = tour(.session(.starting))
        XCTAssertEqual(starting.phase, .step(.waitForLive))
        XCTAssertFalse(starting.isRevisit)

        XCTAssertEqual(tour(.session(.failed("boom"))).phase, .failed(message: "boom"))

        // From there the steps count themselves, to the end.
        var whole = starting
        whole.handle(.session(.live))
        XCTAssertEqual(whole.phase, .step(.picture))
        whole.handle(.firstFrame)
        XCTAssertEqual(whole.phase, .completed)
    }

    /// Going live is not the user's act: the launch was already under way.
    /// The card waits for "Done", which lands on the first step still to do.
    func testTheOrderCardStaysWhenALaunchUnderWayGoesLive() {
        // The user came back to the card with "Back" while the game started.
        var back = tour(.done, .session(.starting), .back, .back, .session(.live))
        XCTAssertEqual(back.phase, .step(.order))
        XCTAssertFalse(back.isRevisit)
        XCTAssertTrue(back.awaitsFirstFrame)
        back.handle(.done)
        XCTAssertEqual(back.phase, .step(.picture))
        XCTAssertFalse(back.isRevisit)

        // The tour began while the game was starting.
        var begun = tour(session: .starting, .session(.live))
        XCTAssertEqual(begun.phase, .step(.order))
        begun.handle(.done)
        XCTAssertEqual(begun.phase, .step(.picture))

        // No "starting" in between.
        XCTAssertEqual(tour(.session(.live)).phase, .step(.order))
        XCTAssertEqual(tour(.session(.live), .done).phase, .step(.picture))
    }

    func testTheOrderCardStaysThroughEverythingThatIsNotALaunch() {
        let stays: [QuickPathTour.Event] = [
            .session(.idle), .session(.windowsApp), .checkAgain, .back,
        ]
        for session: LearningSessionPhase in [.idle, .windowsApp, .starting, .live, .failed("old")] {
            var tour = tour(session: session)
            for event in stays {
                tour.handle(event)
                XCTAssertEqual(tour.phase, .step(.order), "\(session): \(event)")
                XCTAssertFalse(tour.isRevisit, "\(session): \(event)")
            }
        }
        // The headset's first frame is noted and the card stays.
        let framed = tour(session: .live, .firstFrame)
        XCTAssertEqual(framed.phase, .step(.order))
        XCTAssertTrue(framed.hasFrame)
        XCTAssertFalse(framed.isRevisit)

        // Only changes count: the launch and the failure that were there
        // when the tour began are not reported again.
        XCTAssertEqual(tour(session: .starting, .session(.starting)).phase, .step(.order))
        XCTAssertEqual(tour(session: .live, .session(.live)).phase, .step(.order))
        XCTAssertEqual(tour(session: .failed("old"), .session(.failed("old"))).phase, .step(.order))
    }

    func testTheOrderCardCountsALaunchAfterTryAgainAndAfterBack() {
        var retried = tour(.done, .session(.starting), .session(.failed("boom")), .retry)
        XCTAssertEqual(retried.phase, .step(.order))
        // The failure that led here is not shown a second time by itself.
        retried.handle(.session(.failed("boom")))
        XCTAssertEqual(retried.phase, .step(.order))
        retried.handle(.session(.starting))
        XCTAssertEqual(retried.phase, .step(.waitForLive))

        var back = tour(.done, .back)
        XCTAssertEqual(back.phase, .step(.order))
        back.handle(.session(.starting))
        XCTAssertEqual(back.phase, .step(.waitForLive))
        XCTAssertFalse(back.isRevisit)
    }

    /// After "Try again" Play is pressed straight from the order card, and
    /// the launch fails the same way.
    func testPlayFromTheOrderCardAfterTryAgainShowsTheNextFailureAndThenCompletes() throws {
        var tour = tour(.done, .session(.starting), .session(.failed("A")))
        XCTAssertEqual(tour.phase, .failed(message: "A"))
        tour.handle(.retry)
        XCTAssertEqual(tour.phase, .step(.order))

        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.failed("A")))
        XCTAssertEqual(tour.phase, .failed(message: "A"))
        let failure = try XCTUnwrap(tour.presentation(in: onStream))
        XCTAssertEqual(failure.buttons, [.retry])
        XCTAssertEqual(failure.primaryButton, .retry)
        XCTAssertEqual(failure.label, L10n.string(.sessionFailed))

        tour.handle(.retry)
        XCTAssertEqual(tour.phase, .step(.order))
        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.live))
        XCTAssertEqual(tour.phase, .step(.picture))
        tour.handle(.firstFrame)
        XCTAssertEqual(tour.phase, .completed)
    }

    /// A failed launch passes through "stopped" on its way to "failed".
    func testAFailedLaunchFromTheOrderCardIsShownThroughTheStoppedState() {
        var tour = tour(.done, .session(.starting), .session(.idle), .session(.failed("A")), .retry)
        XCTAssertEqual(tour.phase, .step(.order))
        for phase: LearningSessionPhase in [.starting, .idle, .failed("A")] {
            tour.handle(.session(phase))
        }
        XCTAssertEqual(tour.phase, .failed(message: "A"))
    }

    func testDoneOnTheOrderCardLandsOnTheFirstStepStillToDo() {
        XCTAssertEqual(tour(session: .idle, .done).phase, .step(.pressPlay))
        XCTAssertEqual(tour(session: .failed("old"), .done).phase, .step(.pressPlay))
        XCTAssertEqual(tour(session: .windowsApp, .done).phase, .step(.pressPlay))
        XCTAssertEqual(tour(session: .starting, .done).phase, .step(.waitForLive))
        XCTAssertEqual(tour(session: .live, .done).phase, .step(.picture))
        XCTAssertEqual(tour(session: .live, .firstFrame, .done).phase, .completed)
    }

    func testDoneDoesNothingOnAnAutomaticStep() {
        for events: [QuickPathTour.Event] in [
            [.done], [.done, .session(.starting)], [.done, .session(.starting), .session(.live)],
        ] {
            var tour = QuickPathTour(connection: .wifi, session: .idle)
            events.forEach { tour.handle($0) }
            let before = tour
            tour.handle(.done)
            XCTAssertEqual(tour, before)
        }
    }

    // MARK: - Automatic steps

    func testPressPlayCountsOnlyWhenALaunchStarts() {
        var tour = tour(session: .idle, .done)
        for phase: LearningSessionPhase in [.windowsApp, .idle] {
            tour.handle(.session(phase))
            XCTAssertEqual(tour.phase, .step(.pressPlay), "\(phase)")
        }
        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
    }

    func testPressPlayGoesStraightToThePictureWhenStartingWasMissed() {
        XCTAssertEqual(tour(session: .idle, .done, .session(.live)).phase, .step(.picture))
    }

    func testAStaleFailureBeforeTheTourIsNotReportedAgain() {
        var tour = tour(session: .failed("old"), .done)
        tour.handle(.session(.failed("old")))
        XCTAssertEqual(tour.phase, .step(.pressPlay))
    }

    func testWaitingReturnsToPlayWhenTheLaunchIsStopped() {
        XCTAssertEqual(tour(.done, .session(.starting), .session(.idle)).phase, .step(.pressPlay))
        XCTAssertEqual(tour(.done, .session(.starting), .session(.windowsApp)).phase, .step(.pressPlay))
    }

    func testPictureFollowsTheSessionBackwards() {
        let atPicture = tour(.done, .session(.starting), .session(.live))
        var stopped = atPicture
        stopped.handle(.session(.idle))
        XCTAssertEqual(stopped.phase, .step(.pressPlay))
        var restarted = atPicture
        restarted.handle(.session(.starting))
        XCTAssertEqual(restarted.phase, .step(.waitForLive))
        var utility = atPicture
        utility.handle(.session(.windowsApp))
        XCTAssertEqual(utility.phase, .step(.pressPlay))
    }

    func testFirstFrameCountsOnlyInTheLiveSession() {
        var tour = tour(.done, .session(.starting))
        tour.handle(.firstFrame)
        XCTAssertFalse(tour.hasFrame)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.live))
        XCTAssertEqual(tour.phase, .step(.picture))
        tour.handle(.firstFrame)
        XCTAssertEqual(tour.phase, .completed)
    }

    func testAFrameOfAnEndedSessionIsForgotten() {
        var tour = tour(.done, .session(.starting), .session(.live), .back, .firstFrame)
        XCTAssertTrue(tour.hasFrame)
        tour.handle(.session(.idle))
        XCTAssertFalse(tour.hasFrame)
        tour.handle(.session(.starting))
        tour.handle(.session(.live))
        XCTAssertFalse(tour.hasFrame)
        XCTAssertTrue(tour.awaitsFirstFrame)
    }

    // MARK: - Failure

    func testFailureOnEveryStepShowsTheFailure() {
        let cases: [(QuickPathTour, Step)] = [
            (tour(.done), .pressPlay),
            (tour(.done, .session(.starting)), .waitForLive),
            (tour(.done, .session(.starting), .session(.live)), .picture),
        ]
        for (start, step) in cases {
            var tour = start
            XCTAssertEqual(tour.phase, .step(step))
            tour.handle(.session(.failed("boom")))
            XCTAssertEqual(tour.phase, .failed(message: "boom"), "\(step)")
        }
    }

    func testFailureIsShownOnARevisitedStepToo() {
        var tour = tour(.done, .session(.starting), .back)
        tour.handle(.session(.failed("boom")))
        XCTAssertEqual(tour.phase, .failed(message: "boom"))
        XCTAssertFalse(tour.isRevisit)
    }

    func testAfterAFailureRetryReturnsToTheOrderCardAndCloseEnds() {
        let failed = tour(.done, .session(.starting), .session(.failed("boom")))
        var retried = failed
        retried.handle(.retry)
        XCTAssertEqual(retried.phase, .step(.order))
        var closed = failed
        closed.handle(.close)
        XCTAssertEqual(closed.phase, .closed)
        // The other buttons belong to steps.
        for event: QuickPathTour.Event in [.done, .back, .skip, .checkAgain, .firstFrame] {
            var same = failed
            same.handle(event)
            XCTAssertEqual(same.phase, failed.phase, "\(event)")
        }
    }

    func testPlayPressedStraightFromTheFailureResumesTheSteps() {
        let failed = tour(.done, .session(.starting), .session(.failed("boom")))
        var starting = failed
        starting.handle(.session(.starting))
        XCTAssertEqual(starting.phase, .step(.waitForLive))
        var live = failed
        live.handle(.session(.live))
        XCTAssertEqual(live.phase, .step(.picture))
        var idle = failed
        idle.handle(.session(.idle))
        XCTAssertEqual(idle.phase, failed.phase)
    }

    // MARK: - Back

    func testBackShowsThePreviousStep() {
        var tour = tour(.done, .session(.starting), .session(.live))
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        XCTAssertTrue(tour.isRevisit)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        XCTAssertTrue(tour.isRevisit)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.order))
        XCTAssertFalse(tour.isRevisit)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.order))
    }

    func testBackDoesNotSkipForwardByItself() {
        // The step is already done by the facts, and stays shown.
        var tour = tour(.done, .session(.starting), .session(.live), .back)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        // Further session changes and the first frame do not move it either.
        tour.handle(.firstFrame)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.idle))
        tour.handle(.session(.starting))
        tour.handle(.session(.live))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        XCTAssertTrue(tour.isRevisit)
    }

    func testDoneOnARevisitedStepMovesOnByTheFacts() {
        // Live, no frame yet: on to the picture step, which then counts itself.
        var tour = tour(.done, .session(.starting), .session(.live), .back, .back)
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        tour.handle(.done)
        XCTAssertEqual(tour.phase, .step(.picture))
        XCTAssertFalse(tour.isRevisit)
        tour.handle(.firstFrame)
        XCTAssertEqual(tour.phase, .completed)
    }

    func testDoneOnARevisitedStepCompletesWhenTheFrameAlreadyCame() {
        var tour = tour(.done, .session(.starting), .session(.live), .back, .firstFrame)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.done)
        XCTAssertEqual(tour.phase, .completed)
    }

    func testDoneOnARevisitedStepThatIsNoLongerDoneKeepsItAndLetsItCountAgain() {
        var tour = tour(.done, .session(.starting), .back, .session(.idle))
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        XCTAssertTrue(tour.isRevisit)
        tour.handle(.done)
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        XCTAssertFalse(tour.isRevisit)
        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
    }

    func testDoneOnARevisitedStep2AfterStopShowsPressPlay() {
        // Step 2 seen again after "Stop" would point at a launch that no
        // longer runs: "Done" shows the step still to do, which is Play.
        var stopped = tour(.done, .session(.starting), .session(.live), .back, .session(.idle))
        XCTAssertEqual(stopped.phase, .step(.waitForLive))
        XCTAssertTrue(stopped.isRevisit)
        stopped.handle(.done)
        XCTAssertEqual(stopped.phase, .step(.pressPlay))
        XCTAssertFalse(stopped.isRevisit)
        stopped.handle(.session(.starting))
        XCTAssertEqual(stopped.phase, .step(.waitForLive))

        // Played again meanwhile: the revisited step 2 is the step to do.
        var starting = tour(.done, .session(.starting), .session(.live), .back,
                            .session(.idle), .session(.starting))
        XCTAssertEqual(starting.phase, .step(.waitForLive))
        XCTAssertTrue(starting.isRevisit)
        starting.handle(.done)
        XCTAssertEqual(starting.phase, .step(.waitForLive))
        XCTAssertFalse(starting.isRevisit)
        starting.handle(.session(.live))
        XCTAssertEqual(starting.phase, .step(.picture))
    }

    // MARK: - Not working?

    func testCheckAgainKeepsAStepThatCountsItself() {
        // A step that was not revisited has already counted what there is.
        var tour = tour(.done)
        tour.handle(.checkAgain)
        XCTAssertEqual(tour.phase, .step(.pressPlay))
        tour.handle(.session(.starting))
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.checkAgain)
        XCTAssertEqual(tour.phase, .step(.waitForLive))
        tour.handle(.session(.live))
        XCTAssertEqual(tour.phase, .step(.picture))
        tour.handle(.checkAgain)
        XCTAssertEqual(tour.phase, .step(.picture))
    }

    func testCheckAgainOnARevisitedStepActsLikeDone() {
        var tour = tour(.done, .session(.starting), .session(.live), .back)
        tour.handle(.checkAgain)
        XCTAssertEqual(tour.phase, .step(.picture))
    }

    func testOnlyTheLastStepCanBeSkippedAndItEndsWithoutCompleting() {
        // The app sees the launch and the live state itself: the order card
        // and steps 1 and 2 have nothing to skip, revisited or not.
        for start in [
            tour(), tour(session: .live), tour(.done), tour(.done, .session(.starting)),
            tour(.done, .session(.starting), .back),
            tour(.done, .session(.starting), .session(.live), .back),
        ] {
            var tour = start
            tour.handle(.skip)
            XCTAssertEqual(tour, start, "\(start.phase)")
        }
        var last = tour(.done, .session(.starting), .session(.live))
        XCTAssertEqual(last.phase, .step(.picture))
        last.handle(.skip)
        XCTAssertEqual(last.phase, .closed)
    }

    func testTheLastStepIsShownOnlyInALiveSession() {
        let states = reachableStates()
        XCTAssertTrue(states.contains { $0.phase == .step(.picture) })
        for state in states where state.phase == .step(.picture) {
            XCTAssertEqual(state.session, .live)
            XCTAssertFalse(state.isRevisit)
        }
    }

    /// Whatever "Not working?" offers does something. So do the strip's own
    /// buttons, except "Check again" under an open sheet, which only makes
    /// the app look at its window again.
    func testNoOptionOfAnyStepIsANoOp() {
        var optionsSeen = 0
        for state in reachableStates() {
            for environment in environments {
                guard let shown = state.presentation(in: environment) else {
                    XCTAssertTrue(state.isFinished)
                    continue
                }
                for option in shown.help?.options ?? [] {
                    optionsSeen += 1
                    let event = option.event
                    XCTAssertNotNil(event, "\(state.phase): \(option)")
                    var next = state
                    event.map { next.handle($0) }
                    XCTAssertNotEqual(next, state, "\(state.phase): \(option)")
                }
                for button in shown.buttons where button != .checkAgain {
                    guard let event = button.event else { continue }
                    var next = state
                    next.handle(event)
                    XCTAssertNotEqual(next, state, "\(state.phase): \(button)")
                }
            }
        }
        XCTAssertGreaterThan(optionsSeen, 0)
    }

    func testHelpOfSteps1And2IsTipsOnlyAndStep3KeepsSkip() throws {
        for connection: StreamConnectionMode in [.wifi, .wired] {
            for early in [tour(connection: connection, .done),
                          tour(connection: connection, .done, .session(.starting))] {
                let help = try XCTUnwrap(early.presentation(in: onStream)?.help)
                XCTAssertEqual(help.options, [])
                XCTAssertTrue((1...3).contains(help.tips.count), "\(early.phase)")
                XCTAssertEqual(help.title, L10n.string(.learningStuck))
            }
            let last = tour(connection: connection, .done, .session(.starting), .session(.live))
            let help = try XCTUnwrap(last.presentation(in: onStream)?.help)
            XCTAssertEqual(help.options, [.skip])
            XCTAssertEqual(help, QuickPathHelp.cantSeeGame(options: [.skip]))
        }
        // Step 2's tips are the connection's own.
        let wifi = try XCTUnwrap(tour(connection: .wifi, .done, .session(.starting))
            .presentation(in: onStream)?.help)
        let usb = try XCTUnwrap(tour(connection: .wired, .done, .session(.starting))
            .presentation(in: onStream)?.help)
        XCTAssertEqual(wifi.tips.count, 3)
        XCTAssertEqual(usb.tips.count, 2)
        XCTAssertEqual(wifi.tips.last, usb.tips.last)
    }

    func testRetryStartsOverFromAnyStep() {
        var tour = tour(.done, .session(.starting), .session(.live), .back)
        tour.handle(.retry)
        XCTAssertEqual(tour.phase, .step(.order))
        XCTAssertFalse(tour.isRevisit)
    }

    // MARK: - Close and the end states

    func testCloseEndsFromEveryStep() {
        for start in [tour(), tour(.done), tour(.done, .session(.starting)),
                      tour(.done, .session(.starting), .session(.live))] {
            var tour = start
            tour.handle(.close)
            XCTAssertEqual(tour.phase, .closed)
        }
    }

    func testAFinishedTourIgnoresEverything() {
        let events: [QuickPathTour.Event] = [
            .session(.idle), .session(.starting), .session(.live), .session(.failed("x")),
            .firstFrame, .done, .back, .skip, .checkAgain, .retry, .close,
        ]
        for finished in [tour(.close), tour(.done, .session(.starting), .session(.live), .firstFrame)] {
            XCTAssertTrue(finished.isFinished)
            for event in events {
                var tour = finished
                tour.handle(event)
                XCTAssertEqual(tour, finished, "\(event)")
            }
        }
    }

    // MARK: - What the strip shows

    func testEveryStateOffersAtMostTwoButtonsAndNoIdleNext() {
        let states = [
            tour(), tour(.done), tour(.done, .session(.starting)),
            tour(.done, .session(.starting), .session(.live)),
            tour(.done, .session(.starting), .back),
            tour(.done, .session(.starting), .session(.failed("boom"))),
            tour(.done, .session(.starting), .session(.failed(AlvrWiredFailure.adbMissing))),
        ]
        for state in states {
            for environment in environments {
                guard let shown = state.presentation(in: environment) else {
                    XCTFail("nothing shown for \(state.phase)")
                    continue
                }
                XCTAssertLessThanOrEqual(shown.buttons.count, 2)
                XCTAssertFalse(shown.buttons.isEmpty)
                XCTAssertEqual(shown.help != nil, shown.buttons.contains(.help))
                for button in shown.buttons {
                    switch button {
                    case .help, .open: XCTAssertNil(button.event)
                    default: XCTAssertNotNil(button.event)
                    }
                    XCTAssertFalse(shown.title(of: button).isEmpty)
                }
                // At most one button is primary, and it is one of those shown.
                if let primary = shown.primaryButton {
                    XCTAssertTrue(shown.buttons.contains(primary))
                }
                XCTAssertFalse(shown.text.isEmpty)
                XCTAssertFalse(shown.label.isEmpty)
            }
        }
    }

    func testButtonsOfManualAutomaticAndRevisitedSteps() throws {
        XCTAssertEqual(try XCTUnwrap(tour().presentation(in: onStream)).buttons, [.done])
        XCTAssertEqual(try XCTUnwrap(tour().presentation(in: onStream)).primaryButton, .done)
        for automatic in [tour(.done), tour(.done, .session(.starting)),
                          tour(.done, .session(.starting), .session(.live))] {
            let shown = try XCTUnwrap(automatic.presentation(in: onStream))
            XCTAssertEqual(shown.buttons, [.back, .help])
            XCTAssertNil(shown.primaryButton)
        }
        let revisited = try XCTUnwrap(tour(.done, .session(.starting), .back).presentation(in: onStream))
        XCTAssertEqual(revisited.buttons, [.back, .done])
        XCTAssertEqual(revisited.primaryButton, .done)
        XCTAssertNil(revisited.help)
        XCTAssertNotEqual(revisited.id, try XCTUnwrap(tour(.done).presentation(in: onStream)).id)
    }

    func testTargetsAndTheStreamSection() throws {
        let away = QuickPathEnvironment(onStreamSection: false, pageSheetOpen: false)
        let order = try XCTUnwrap(tour().presentation(in: away))
        XCTAssertNil(order.target)
        XCTAssertFalse(order.opensStream)

        let play = try XCTUnwrap(tour(.done).presentation(in: away))
        XCTAssertEqual(play.target, .playButton)
        XCTAssertTrue(play.opensStream)
        XCTAssertFalse(try XCTUnwrap(tour(.done).presentation(in: onStream)).opensStream)

        let wait = try XCTUnwrap(tour(.done, .session(.starting)).presentation(in: away))
        XCTAssertEqual(wait.target, .statusLabel)
        XCTAssertTrue(wait.opensStream)

        let picture = try XCTUnwrap(
            tour(.done, .session(.starting), .session(.live)).presentation(in: away))
        XCTAssertNil(picture.target)
        XCTAssertFalse(picture.opensStream)
    }

    /// The app opens the Stream section when a step is first shown, and
    /// leaves the section alone when the same step is only drawn again.
    func testTheStreamSectionOpensOnlyForANewlyShownStep() throws {
        let away = QuickPathEnvironment(onStreamSection: false, pageSheetOpen: false)
        let play = try XCTUnwrap(tour(.done).presentation(in: away))
        XCTAssertTrue(play.opensStream(afterShowing: nil))
        XCTAssertTrue(play.opensStream(afterShowing: try XCTUnwrap(tour().presentation(in: away)).id))
        // Drawn again, for example in another language: the id is the same.
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        let russian = try XCTUnwrap(tour(.done).presentation(in: away))
        L10n.language = .en
        let english = try XCTUnwrap(tour(.done).presentation(in: away))
        XCTAssertNotEqual(russian.text, english.text)
        XCTAssertEqual(russian.id, english.id)
        XCTAssertFalse(english.opensStream(afterShowing: russian.id))

        // The next step is a new one, and so is a step shown after its
        // "close the open window" form.
        let wait = try XCTUnwrap(tour(.done, .session(.starting)).presentation(in: away))
        XCTAssertTrue(wait.opensStream(afterShowing: play.id))
        let blocked = try XCTUnwrap(tour(.done).presentation(
            in: QuickPathEnvironment(onStreamSection: false, pageSheetOpen: true)))
        XCTAssertFalse(blocked.opensStream(afterShowing: nil))
        XCTAssertTrue(play.opensStream(afterShowing: blocked.id))

        // A step that needs no section never opens one.
        XCTAssertFalse(try XCTUnwrap(tour().presentation(in: away)).opensStream(afterShowing: nil))
        XCTAssertFalse(try XCTUnwrap(tour(.done).presentation(in: onStream)).opensStream(afterShowing: nil))
    }

    func testAnOpenPageSheetKeepsTheSectionAndAsksToCloseIt() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        let sheet = QuickPathEnvironment(onStreamSection: false, pageSheetOpen: true)
        for state in [tour(.done), tour(.done, .session(.starting))] {
            let shown = try XCTUnwrap(state.presentation(in: sheet))
            XCTAssertFalse(shown.opensStream)
            XCTAssertNil(shown.target)
            XCTAssertEqual(shown.buttons, [.back, .checkAgain])
            XCTAssertEqual(shown.text, "Close the open window, then click “Check Again”.")
            XCTAssertEqual(shown.title(of: .checkAgain), "Check Again")
        }
        // A sheet on the Stream page itself needs no section change.
        let onStreamWithSheet = QuickPathEnvironment(onStreamSection: true, pageSheetOpen: true)
        XCTAssertEqual(try XCTUnwrap(tour(.done).presentation(in: onStreamWithSheet)).target, .playButton)
        // The order card and the last step live on no page.
        XCTAssertEqual(try XCTUnwrap(tour().presentation(in: sheet)).buttons, [.done])
    }

    func testEnglishTexts() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en

        let wifi = try XCTUnwrap(tour(connection: .wifi).presentation(in: onStream))
        XCTAssertEqual(wifi.label, "Launch order · \(L10n.string(.connectionWiFi))")
        XCTAssertEqual(wifi.text, "Open ALVR in the headset → take the headset off → “Play” → "
            + "the first time, “Allow” → put the headset on.")
        XCTAssertEqual(wifi.title(of: .done), "Done")
        let usb = try XCTUnwrap(tour(connection: .wired).presentation(in: onStream))
        XCTAssertEqual(usb.label, "Launch order · USB Cable")
        XCTAssertEqual(usb.text, "Connect the cable. ALVR opens by itself after “Play”. "
            + "The headset must be unlocked.")

        let play = try XCTUnwrap(tour(.done).presentation(in: onStream))
        XCTAssertEqual(play.label, "Step 1 of 3")
        XCTAssertEqual(play.text, "Click “Play”.")
        XCTAssertEqual(play.buttons.map(play.title(of:)), ["Back", "Not working?"])
        XCTAssertEqual(play.help?.tips, [
            "“Play” is not available while a Windows app (Steam or an installer) is open "
                + "or a game is being added. Click “Stop”, or wait until it finishes.",
        ])
        XCTAssertEqual(play.help?.options, [])

        let wait = try XCTUnwrap(tour(.done, .session(.starting)).presentation(in: onStream))
        XCTAssertEqual(wait.label, "Step 2 of 3")
        XCTAssertEqual(wait.text, "Wait for “LIVE”. If your Mac asks “Allow … to connect?”, "
            + "click “Allow”. If a Steam window opens, sign in.")
        XCTAssertEqual(wait.help?.tips, [
            "Check that ALVR is open in the headset.",
            "If your Mac asks “Allow … to connect?”, click “Allow”.",
            "If a Steam window opened, sign in.",
        ])
        let usbWait = try XCTUnwrap(
            tour(connection: .wired, .done, .session(.starting)).presentation(in: onStream))
        XCTAssertEqual(usbWait.label, "Step 2 of 3")
        XCTAssertEqual(usbWait.text, "Wait for “LIVE”. If a Steam window opens, sign in.")
        XCTAssertEqual(usbWait.help?.tips, [
            "Put on the headset and unlock it.",
            "If a Steam window opened, sign in.",
        ])

        let picture = try XCTUnwrap(
            tour(.done, .session(.starting), .session(.live)).presentation(in: onStream))
        XCTAssertEqual(picture.label, "Step 3 of 3")
        XCTAssertEqual(picture.text, "The picture is going to the headset. Put the headset on. "
            + "To finish, click “Stop”.")
        XCTAssertEqual(picture.buttons.map(picture.title(of:)), ["Back", "Can't see the game?"])
        XCTAssertEqual(picture.help?.tips, [
            "If the game in “Library” has the “SET UP OPENVR” label: click “Stop”, "
                + "then that label, turn on “OpenVR support”, and click “Play” again.",
            "Check that ALVR is open in the headset.",
            "The headset must be awake and unlocked.",
        ])
        XCTAssertEqual(picture.help?.options.map(picture.title(of:)), ["Skip This Step"])
        // The link the Stream page keeps after the quick path: the same tips.
        let link = QuickPathHelp.cantSeeGame()
        XCTAssertEqual(link.title, "Can't see the game?")
        XCTAssertEqual(link.tips, picture.help?.tips)
        XCTAssertEqual(link.options, [])
        XCTAssertEqual(QuickPathPresentation.closeTitle, "Close the Hints")

        // The same steps in another language: every text is translated, none stays English.
        func everyText() throws -> [String] {
            let steps: [QuickPathPresentation] = [
                try XCTUnwrap(tour(connection: .wifi).presentation(in: onStream)),
                try XCTUnwrap(tour(connection: .wired).presentation(in: onStream)),
                try XCTUnwrap(tour(.done).presentation(in: onStream)),
                try XCTUnwrap(tour(.done, .session(.starting)).presentation(in: onStream)),
                try XCTUnwrap(tour(connection: .wired, .done, .session(.starting)).presentation(in: onStream)),
                try XCTUnwrap(tour(.done, .session(.starting), .session(.live)).presentation(in: onStream)),
            ]
            var texts: [String] = []
            for step in steps {
                texts += [step.label, step.text]
                texts += step.buttons.map(step.title(of:))
                texts += step.help?.tips ?? []
                texts += step.help?.options.map(step.title(of:)) ?? []
            }
            texts += [QuickPathHelp.cantSeeGame().title, QuickPathPresentation.closeTitle]
            return texts
        }
        let english = try everyText()
        L10n.language = .ru
        let translated = try everyText()
        XCTAssertEqual(translated.count, english.count)
        for (text, original) in zip(translated, english) {
            XCTAssertNotEqual(text, original)
        }
    }

    /// The connection can be changed while the tour is open, for example
    /// between two launches.
    func testTextsFollowTheConnectionPlayLaunchesWithNow() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        func shown(_ tour: QuickPathTour, now connection: StreamConnectionMode?) throws -> QuickPathPresentation {
            try XCTUnwrap(tour.presentation(in: QuickPathEnvironment(
                section: .stream, pageSheetOpen: false, connection: connection)))
        }

        // Started over Wi-Fi, Play launches over USB now.
        let usbOrder = try shown(tour(connection: .wifi), now: .wired)
        XCTAssertEqual(usbOrder.label, "Launch order · USB Cable")
        XCTAssertEqual(usbOrder.text, "Connect the cable. ALVR opens by itself after “Play”. "
            + "The headset must be unlocked.")
        let usbWait = try shown(tour(connection: .wifi, .done, .session(.starting)), now: .wired)
        XCTAssertEqual(usbWait.text, "Wait for “LIVE”. If a Steam window opens, sign in.")
        XCTAssertEqual(usbWait.help?.tips, [
            "Put on the headset and unlock it.",
            "If a Steam window opened, sign in.",
        ])

        // The reverse.
        let wifiOrder = try shown(tour(connection: .wired), now: .wifi)
        XCTAssertEqual(wifiOrder.label, "Launch order · \(L10n.string(.connectionWiFi))")
        XCTAssertEqual(wifiOrder.text, "Open ALVR in the headset → take the headset off → “Play” → "
            + "the first time, “Allow” → put the headset on.")
        let wifiWait = try shown(tour(connection: .wired, .done, .session(.starting)), now: .wifi)
        XCTAssertEqual(wifiWait.text, "Wait for “LIVE”. If your Mac asks “Allow … to connect?”, "
            + "click “Allow”. If a Steam window opens, sign in.")
        XCTAssertEqual(wifiWait.help?.tips, [
            "Check that ALVR is open in the headset.",
            "If your Mac asks “Allow … to connect?”, click “Allow”.",
            "If a Steam window opened, sign in.",
        ])

        for (started, now): (StreamConnectionMode, StreamConnectionMode) in [(.wifi, .wired), (.wired, .wifi)] {
            for events: [QuickPathTour.Event] in [
                [], [.done], [.done, .session(.starting)], [.done, .session(.starting), .back],
                [.done, .session(.starting), .session(.live)],
            ] {
                var changed = QuickPathTour(connection: started, session: .idle)
                var fresh = QuickPathTour(connection: now, session: .idle)
                for event in events {
                    changed.handle(event)
                    fresh.handle(event)
                }
                // Exactly what a tour started over that connection shows.
                XCTAssertEqual(try shown(changed, now: now), try shown(fresh, now: nil), "\(changed.phase)")
                // The app does not name the connection: the one the tour began with.
                let own = try shown(changed, now: nil)
                XCTAssertEqual(own, try shown(changed, now: started), "\(changed.phase)")
                // The same step drawn again: its id stays, so no section is opened for it.
                XCTAssertEqual(try shown(changed, now: now).id, own.id, "\(changed.phase)")
            }
        }
        let away = QuickPathEnvironment(section: nil, pageSheetOpen: false, connection: .wifi)
        var awayOverUSB = away
        awayOverUSB.connection = .wired
        let waiting = tour(connection: .wifi, .done, .session(.starting))
        let before = try XCTUnwrap(waiting.presentation(in: away))
        let after = try XCTUnwrap(waiting.presentation(in: awayOverUSB))
        XCTAssertNotEqual(after.text, before.text)
        XCTAssertTrue(after.opensStream)
        XCTAssertFalse(after.opensStream(afterShowing: before.id))
    }

    func testFailureShowsTheMatchingAdviceOrAGenericLine() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en

        let known = try XCTUnwrap(tour(
            .done, .session(.starting), .session(.failed(L10n.string(.modelWaitingHeadset)))
        ).presentation(in: onStream))
        XCTAssertEqual(known.advice?.cause, .waitingForHeadset)
        XCTAssertEqual(known.label, "The headset did not connect")
        XCTAssertEqual(known.text, "Open ALVR in the headset, then click “Play”.")
        // This advice's own action would start the quick path over, which
        // "Try again" does already. The strip's cross closes.
        XCTAssertEqual(known.buttons, [.retry])
        XCTAssertEqual(known.primaryButton, .retry)
        XCTAssertEqual(known.buttons.map(known.title(of:)), ["Try Again"])
        XCTAssertNil(known.target)

        // The advice follows the connection the tour was started with.
        let usb = try XCTUnwrap(tour(
            connection: .wired,
            .done, .session(.starting), .session(.failed(L10n.string(.modelWaitingHeadset)))
        ).presentation(in: onStream))
        XCTAssertEqual(usb.text, "Put on the headset and check that it is unlocked. Then click “Play”.")
        XCTAssertEqual(usb.buttons, [.retry])
        // When the app knows the connection Play launched with, the advice
        // follows that one, whichever the tour was started with.
        let launchedOverUSB = try XCTUnwrap(tour(
            .done, .session(.starting), .session(.failed(L10n.string(.modelWaitingHeadset)))
        ).presentation(in: QuickPathEnvironment(section: .stream, pageSheetOpen: false, connection: .wired)))
        XCTAssertEqual(launchedOverUSB.text, usb.text)
        XCTAssertEqual(launchedOverUSB.advice?.context, LaunchFailureContext(connection: .wired))
        let launchedOverWiFi = try XCTUnwrap(tour(
            connection: .wired,
            .done, .session(.starting), .session(.failed(L10n.string(.modelWaitingHeadset)))
        ).presentation(in: QuickPathEnvironment(section: .stream, pageSheetOpen: false, connection: .wifi)))
        XCTAssertEqual(launchedOverWiFi.text, known.text)

        let unknown = try XCTUnwrap(tour(
            .done, .session(.starting), .session(.failed("The streamer exited with code 9"))
        ).presentation(in: onStream))
        XCTAssertNil(unknown.advice)
        XCTAssertEqual(unknown.label, "Session failed")
        XCTAssertEqual(unknown.text, "The launch failed. The reason is shown in “Stream”.")
        XCTAssertEqual(unknown.buttons, [.retry])
        XCTAssertEqual(unknown.primaryButton, .retry)
        XCTAssertNotEqual(unknown.id, known.id)
    }

    func testFailureOffersTheAdvicesSectionFirstThenTryAgain() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        let failed = tour(connection: .wired, .done, .session(.starting),
                          .session(.failed("Could not start wired ALVR session: \(AlvrWiredFailure.adbMissing)")))

        let shown = try XCTUnwrap(failed.presentation(in: onStream))
        XCTAssertEqual(shown.advice?.cause, .adbMissing)
        XCTAssertEqual(shown.buttons, [.open(.headset), .retry])
        XCTAssertEqual(shown.primaryButton, .open(.headset))
        XCTAssertEqual(shown.buttons.map(shown.title(of:)), ["Open “Headset”", "Try Again"])
        XCTAssertNil(shown.help)
        XCTAssertEqual(shown.text, LaunchFailureAdvice(
            cause: .adbMissing, context: LaunchFailureContext(connection: .wired)).text)

        // Leaving the section would close an open sheet: no section button.
        let underSheet = try XCTUnwrap(failed.presentation(
            in: QuickPathEnvironment(onStreamSection: true, pageSheetOpen: true)))
        XCTAssertEqual(underSheet.buttons, [.retry])
        XCTAssertEqual(underSheet.primaryButton, .retry)
        XCTAssertEqual(underSheet.text, shown.text)
        // The section is open already: the button would do nothing.
        let there = try XCTUnwrap(failed.presentation(
            in: QuickPathEnvironment(section: .headset, pageSheetOpen: false)))
        XCTAssertEqual(there.buttons, [.retry])
        // The strip is drawn again when its buttons change.
        XCTAssertNotEqual(shown.id, there.id)
        XCTAssertEqual(there.id, underSheet.id)

        // The game's own stream settings change the way to Wi-Fi.
        let own = try XCTUnwrap(failed.presentation(in: QuickPathEnvironment(
            section: .stream, pageSheetOpen: false, gameWithOwnSettings: "Blood Trail")))
        XCTAssertEqual(own.advice?.context,
                       LaunchFailureContext(connection: .wired, gameWithOwnSettings: "Blood Trail"))
        XCTAssertTrue(own.text.contains("“Stream Settings for Blood Trail…”"))
        XCTAssertNotEqual(own.text, shown.text)

        // Steam: its own section.
        let steam = try XCTUnwrap(tour(
            .done, .session(.starting), .session(.failed(L10n.string(.modelSteamNotSignedIn)))
        ).presentation(in: onStream))
        XCTAssertEqual(steam.buttons, [.open(.steam), .retry])
        XCTAssertEqual(steam.title(of: .open(.steam)), "Open “Steam”")
    }

    /// A hint names a control by the control's own text, in every language.
    func testHintsNameControlsWithTheControlsOwnTextInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            let play = L10n.string(.libraryPlay)
            let allow = L10n.string(.headsetAllow)

            let wifi = try XCTUnwrap(tour(connection: .wifi).presentation(in: onStream))
            XCTAssertTrue(wifi.text.contains(play), "\(language)")
            XCTAssertTrue(wifi.text.contains(allow), "\(language)")
            XCTAssertTrue(wifi.label.contains(L10n.string(.connectionWiFi)), "\(language)")
            let usb = try XCTUnwrap(tour(connection: .wired).presentation(in: onStream))
            XCTAssertTrue(usb.text.contains(play), "\(language)")
            XCTAssertTrue(usb.label.contains(L10n.string(.connectionUSB)), "\(language)")

            let first = try XCTUnwrap(tour(.done).presentation(in: onStream))
            XCTAssertTrue(first.text.contains(play), "\(language)")
            let second = try XCTUnwrap(tour(.done, .session(.starting)).presentation(in: onStream))
            XCTAssertTrue(second.text.contains(L10n.string(.sessionLiveState)), "\(language)")
            XCTAssertTrue(second.text.contains(L10n.string(.headsetRequestTitle, "…")), "\(language)")
            XCTAssertTrue(second.text.contains(allow), "\(language)")
            let secondUSB = try XCTUnwrap(
                tour(connection: .wired, .done, .session(.starting)).presentation(in: onStream))
            XCTAssertTrue(secondUSB.text.contains(L10n.string(.sessionLiveState)), "\(language)")
            XCTAssertFalse(secondUSB.text.contains(L10n.string(.headsetRequestTitle, "…")), "\(language)")

            let playTip = try XCTUnwrap(first.help?.tips.first)
            XCTAssertTrue(playTip.contains(play), "\(language)")
            XCTAssertTrue(playTip.contains(L10n.string(.commonStop)), "\(language)")
            let allowTip = try XCTUnwrap(second.help?.tips.dropFirst().first)
            XCTAssertTrue(allowTip.contains(L10n.string(.headsetRequestTitle, "…")), "\(language)")
            XCTAssertTrue(allowTip.contains(allow), "\(language)")
            let third = try XCTUnwrap(
                tour(.done, .session(.starting), .session(.live)).presentation(in: onStream))
            XCTAssertTrue(third.text.contains(L10n.string(.commonStop)), "\(language)")
            let tip = try XCTUnwrap(third.help?.tips.first)
            for name in [L10n.string(.commonStop), L10n.string(.sidebarLibrary),
                         L10n.string(.libraryOpenVRSetup), L10n.string(.openVRTitle), play] {
                XCTAssertTrue(tip.contains(name), "\(language): \(name)")
            }
            XCTAssertEqual(third.help?.tips.count, 3)

            XCTAssertEqual(first.title(of: .back), L10n.string(.commonBack))
            XCTAssertEqual(wifi.title(of: .done), L10n.string(.sheetDone))
            for step in [first, second, secondUSB, third] {
                XCTAssertFalse(step.text.contains("%"), "\(language)")
                for tip in step.help?.tips ?? [] {
                    XCTAssertFalse(tip.isEmpty, "\(language)")
                    XCTAssertFalse(tip.contains("%"), "\(language): \(tip)")
                }
            }
        }
    }

    // MARK: - The first frame of this session

    func testHeadsetFrameCountsOnlyFromThisSessionsStreamingStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let before = StreamMetricSample(date: start.addingTimeInterval(-1), fps: 72)
        let noFPS = StreamMetricSample(date: start.addingTimeInterval(1), megabits: 30, sentFPS: 72)
        let zero = StreamMetricSample(date: start.addingTimeInterval(2), fps: 0)
        let atStart = StreamMetricSample(date: start, fps: 71.5)
        let after = StreamMetricSample(date: start.addingTimeInterval(3), fps: 72)

        XCTAssertFalse(QuickPathFrames.hasHeadsetFrame(in: [], since: start))
        XCTAssertFalse(QuickPathFrames.hasHeadsetFrame(in: [before, noFPS, zero], since: start))
        XCTAssertTrue(QuickPathFrames.hasHeadsetFrame(in: [before, atStart], since: start))
        XCTAssertTrue(QuickPathFrames.hasHeadsetFrame(in: [before, noFPS, after], since: start))
        // Startup has not reached streaming yet: older samples prove nothing.
        XCTAssertFalse(QuickPathFrames.hasHeadsetFrame(in: [before, after], since: nil))
    }

    func testTheFrameWatchLooksOnlyAtSamplesAddedSinceItsLastLook() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ offset: TimeInterval, fps: Double?) -> StreamMetricSample {
            StreamMetricSample(date: start.addingTimeInterval(offset), fps: fps)
        }
        var watch = QuickPathFrameWatch()
        XCTAssertEqual(watch.seenCount, 0)

        // The first look takes in whatever the list already holds.
        var samples = [sample(1, fps: nil), sample(2, fps: 0)]
        XCTAssertFalse(watch.hasHeadsetFrame(in: samples, since: start))
        XCTAssertEqual(watch.seenCount, 2)

        // A sample that was looked at is not looked at again, whatever it holds.
        samples[0] = sample(1, fps: 72)
        XCTAssertFalse(watch.hasHeadsetFrame(in: samples, since: start))
        samples.append(sample(3, fps: nil))
        XCTAssertFalse(watch.hasHeadsetFrame(in: samples, since: start))
        XCTAssertEqual(watch.seenCount, 3)

        // The new sample is.
        samples.append(sample(4, fps: 72))
        XCTAssertTrue(watch.hasHeadsetFrame(in: samples, since: start))
        XCTAssertEqual(watch.seenCount, 4)
        // Asked again with nothing new, there is nothing to find.
        XCTAssertFalse(watch.hasHeadsetFrame(in: samples, since: start))
    }

    func testTheFrameWatchStartsOverWhenTheListGetsShorter() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let quiet = (0..<5).map { StreamMetricSample(date: start.addingTimeInterval(Double($0)), megabits: 30) }
        var watch = QuickPathFrameWatch()
        XCTAssertFalse(watch.hasHeadsetFrame(in: quiet, since: start))
        XCTAssertEqual(watch.seenCount, 5)

        // Cleared for a new session, then its first report.
        XCTAssertFalse(watch.hasHeadsetFrame(in: [], since: start))
        XCTAssertEqual(watch.seenCount, 0)
        let frame = StreamMetricSample(date: start.addingTimeInterval(9), fps: 72)
        XCTAssertTrue(watch.hasHeadsetFrame(in: [frame], since: start))

        // Trimmed at the front while the frame was among the kept samples.
        var trimmed = QuickPathFrameWatch()
        XCTAssertFalse(trimmed.hasHeadsetFrame(in: quiet, since: start))
        XCTAssertTrue(trimmed.hasHeadsetFrame(in: [quiet[3], quiet[4], frame], since: start))
        XCTAssertEqual(trimmed.seenCount, 3)

        // A report from before this session's streaming start never counts.
        var early = QuickPathFrameWatch()
        XCTAssertFalse(early.hasHeadsetFrame(in: [frame], since: start.addingTimeInterval(10)))
        XCTAssertFalse(early.hasHeadsetFrame(in: [frame], since: nil))
    }

    // MARK: - After the quick path

    func testCantSeeGameStaysOnlyForTheSessionTheQuickPathCompletedIn() {
        let completed = Date(timeIntervalSince1970: 1_800_000_000)
        func shows(_ completedIn: Date?, _ live: Date?) -> Bool {
            QuickPathFollowUp.showsCantSeeGame(completedSessionStart: completedIn, liveSessionStart: live)
        }
        // The same session is still live.
        XCTAssertTrue(shows(completed, completed))
        // It ended: nothing is live.
        XCTAssertFalse(shows(completed, nil))
        // A later session is another one.
        XCTAssertFalse(shows(completed, completed.addingTimeInterval(600)))
        // The quick path was never completed.
        XCTAssertFalse(shows(nil, completed))
        XCTAssertFalse(shows(nil, nil))
    }
}
