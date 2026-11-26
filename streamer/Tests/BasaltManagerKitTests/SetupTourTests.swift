import XCTest
@testable import BasaltManagerKit

final class SetupTourTests: XCTestCase {
    private typealias Step = SetupTour.Step

    private let game = "BRUTALISTICK VR"

    private func tour(
        _ chapter: LearningChapter, _ mode: SetupTour.Mode,
        _ facts: LearningFacts, resumeAt: String? = nil
    ) throws -> SetupTour {
        try XCTUnwrap(SetupTour(chapter: chapter, mode: mode, facts: facts, resumeAt: resumeAt))
    }

    /// A first pass.
    private func tour(
        _ chapter: LearningChapter, _ facts: LearningFacts, resumeAt: String? = nil
    ) throws -> SetupTour {
        try tour(chapter, .firstPass, facts, resumeAt: resumeAt)
    }

    private func shown(_ tour: SetupTour) throws -> SetupPresentation {
        try XCTUnwrap(tour.presentation)
    }

    private func english(_ body: () throws -> Void) rethrows {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        try body()
    }

    /// Feeds facts changed in one place.
    private func feed(_ tour: inout SetupTour, _ change: (inout LearningFacts) -> Void) {
        tour.handle(.facts(tour.facts.with(change)))
    }

    // MARK: - Chapters and steps

    func testEveryStepBelongsToOneChapter() {
        XCTAssertEqual(Set(Step.allCases.map(\.chapter)), Set(LearningChapter.allCases))
        XCTAssertEqual(Set(Step.allCases.map(\.rawValue)).count, Step.allCases.count)
        XCTAssertEqual(LearningChapter.allCases.map(SetupTour.stepCount(of:)), [2, 7, 5, 0, 6])
        XCTAssertEqual(LearningChapter.allCases.map(SetupTour.hasSteps), [true, true, true, true, true])
        for step in Step.allCases {
            if let number = step.number {
                XCTAssertTrue((1...SetupTour.stepCount(of: step.chapter)).contains(number), "\(step)")
            }
        }
    }

    // MARK: - Chapter 1: Mac

    func testMacNamesTheMissingPartsThenWhoBuildsThem() throws {
        try english {
            var facts = LearningFixture.unbuiltMac
            facts.setupChecks = LearningFixture.checks(missing: ["wine", "runtime"])
            var tour = try tour(.mac, facts)
            XCTAssertEqual(tour.phase, .step(.macSummary))
            var hint = try shown(tour)
            XCTAssertEqual(hint.label, "Mac · step 1 of 2")
            XCTAssertEqual(hint.text, "Parts of the app are missing: “Runs Windows games on your Mac”, "
                + "“Connects the game's VR output to the headset”.")
            XCTAssertEqual(hint.target, .setupSummary)
            XCTAssertEqual(hint.section, .setup)
            XCTAssertEqual(hint.buttons, [.next])
            XCTAssertNil(hint.help)

            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.macWhoBuilds))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Mac · step 2 of 2")
            XCTAssertEqual(hint.text, "The person who installed TrailBridge builds them. "
                + "If that was not you, ask them. Then click “Check Again”.")
            XCTAssertEqual(hint.target, .setupSummary)
            XCTAssertEqual(hint.buttons, [.back, .checkAgain])
            XCTAssertEqual(hint.primaryButton, .checkAgain)
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["Back", "Check Again"])
        }
    }

    /// A packaged app: the only missing parts are the ones the Setup page
    /// supplies itself, so nobody is sent to the person who builds.
    func testMacPointsToTheRowsButtonsWhenTheSetupPageSuppliesTheParts() throws {
        func facts(_ missing: [SetupCheck]) -> LearningFacts {
            var facts = LearningFixture.unbuiltMac
            let ids = Set(missing.map(\.id))
            facts.setupChecks = LearningFixture.checks().filter { !ids.contains($0.id) } + missing
            return facts
        }
        let wine = SetupCheck(id: "wine", title: "wine", detail: "", status: .actionNeeded,
                              required: true, action: SetupInspector.downloadWineAction)
        let rosetta = SetupCheck(id: "rosetta", title: "rosetta", detail: "", status: .actionNeeded,
                                 required: true, action: SetupInspector.copyRosettaCommandAction)
        let runtime = SetupCheck(id: "runtime", title: "runtime", detail: "", status: .actionNeeded,
                                 required: true, action: "Open Build Instructions")
        try english {
            for missing in [[wine], [rosetta], [wine, rosetta]] {
                let tour = try tour(.mac, facts(missing), resumeAt: Step.macWhoBuilds.rawValue)
                let hint = try shown(tour)
                XCTAssertEqual(hint.text, "Each has its own button in the list below. "
                    + "Click it and follow what its row says. "
                    + "When that is done, click “Check Again”.")
                XCTAssertEqual(hint.buttons, [.back, .checkAgain])
            }
            // One part that has to be built: the old words.
            let built = try tour(.mac, facts([wine, runtime]), resumeAt: Step.macWhoBuilds.rawValue)
            XCTAssertEqual(try shown(built).text, "The person who installed TrailBridge builds them. "
                + "If that was not you, ask them. Then click “Check Again”.")
            // Rosetta is named in the summary in its row's words.
            XCTAssertEqual(try shown(try tour(.mac, facts([rosetta]))).text,
                           "Parts of the app are missing: “Runs code made for Intel processors on the Mac”.")
        }
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            for missing in [[wine], [rosetta], [wine, rosetta]] {
                for step in [Step.macSummary, .macWhoBuilds] {
                    let text = try shown(try tour(.mac, facts(missing), resumeAt: step.rawValue)).text
                    XCTAssertLessThanOrEqual(text.count, SetupTour.hintLimit, "\(language): \(text)")
                    XCTAssertFalse(text.contains("%"), "\(language): \(text)")
                }
            }
            let text = try shown(try tour(.mac, facts([wine]), resumeAt: Step.macWhoBuilds.rawValue)).text
            XCTAssertTrue(text.contains(L10n.string(.learningRecheck)), "\(language): \(text)")
        }
    }

    func testMacCountsItselfWhenTheChecksTurnReady() throws {
        for start in [Step.macSummary, .macWhoBuilds] {
            var tour = try tour(.mac, LearningFixture.unbuiltMac)
            if start == .macWhoBuilds { tour.handle(.next) }
            XCTAssertEqual(tour.step, start)
            // Still missing: "Check again" changes nothing.
            tour.handle(.checkAgain)
            XCTAssertEqual(tour.step, start)
            XCTAssertFalse(tour.isCompleted)
            // One part built, two to go.
            feed(&tour) { $0.setupChecks = LearningFixture.checks(missing: ["dxmt"]) }
            XCTAssertEqual(tour.step, start)
            feed(&tour) { $0.setupChecks = LearningFixture.checks() }
            XCTAssertEqual(tour.phase, .finished, "\(start)")
            XCTAssertTrue(tour.isCompleted)
        }
    }

    func testAReadyMacCompletesAFirstPassAtOnce() throws {
        let tour = try tour(.mac, LearningFixture.newcomer)
        XCTAssertEqual(tour.phase, .finished)
        XCTAssertTrue(tour.isCompleted)
        XCTAssertNil(tour.pausedStep)
    }

    /// With no checks nobody knows what is missing, and with an unsupported
    /// Mac nobody could build it: one card, "Check again", never "done".
    func testMacWithoutChecksOrUnsupportedOffersOnlyCheckAgain() throws {
        try english {
            var unknown = try tour(.mac, LearningFacts())
            var hint = try shown(unknown)
            XCTAssertEqual(hint.text, "The Mac could not be checked. Click “Check Again”.")
            XCTAssertEqual(hint.buttons, [.checkAgain])
            unknown.handle(.next)
            unknown.handle(.checkAgain)
            XCTAssertEqual(unknown.phase, .step(.macSummary))
            XCTAssertFalse(unknown.isCompleted)

            var facts = LearningFixture.unbuiltMac
            facts.setupChecks = LearningFixture.checks(unsupportedMac: true)
            var unsupported = try tour(.mac, facts)
            hint = try shown(unsupported)
            XCTAssertEqual(hint.text, "TrailBridge requires Apple Silicon and macOS 14 or later.")
            XCTAssertEqual(hint.buttons, [.checkAgain])
            unsupported.handle(.next)
            XCTAssertEqual(unsupported.phase, .step(.macSummary))

            // The checks arrive: the missing parts are named.
            feed(&unknown) { $0.setupChecks = LearningFixture.checks(missing: ["wine"]) }
            XCTAssertEqual(unknown.phase, .step(.macSummary))
            XCTAssertEqual(try shown(unknown).buttons, [.next])
            XCTAssertEqual(try shown(unknown).text,
                           "Parts of the app are missing: “Runs Windows games on your Mac”.")
        }
    }

    func testMacBackNeverJumpsForward() throws {
        var tour = try tour(.mac, LearningFixture.unbuiltMac)
        tour.handle(.next)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.macSummary))
        XCTAssertTrue(tour.isRevisit)
        XCTAssertFalse(tour.hasPrevious)
        // The Mac turns ready while the revisited step is shown: it stays.
        feed(&tour) { $0.setupChecks = LearningFixture.checks() }
        XCTAssertEqual(tour.phase, .step(.macSummary))
        XCTAssertEqual(try shown(tour).buttons, [.next])
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .finished)
    }

    func testTheMissingPartsListStaysWithinTheStripInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            for missing in [["wine"], ["wine", "runtime"], ["wine", "runtime", "dxmt"], ["dxmt"]] {
                var facts = LearningFixture.unbuiltMac
                facts.setupChecks = LearningFixture.checks(missing: Set(missing))
                let text = try shown(try tour(.mac, facts)).text
                XCTAssertLessThanOrEqual(text.count, SetupTour.hintLimit, "\(language): \(text)")
                // The first missing part is always named, in its row's words.
                let first = L10n.string(missing[0] == "wine" ? .setupEngineHelp : .setupGraphicsHelp)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))
                XCTAssertTrue(text.contains(first), "\(language): \(text)")
            }
        }
        // English is the long one: three parts do not fit, and it says so.
        L10n.language = .en
        let all = try shown(try tour(.mac, LearningFixture.unbuiltMac)).text
        XCTAssertEqual(all, "Parts of the app are missing: “Runs Windows games on your Mac”, "
            + "“Connects the game's VR output to the headset” and others. They are marked below.")
    }

    // MARK: - Chapter 3: Game

    func testGameStartsWithTheQuestionAndItsTwoAnswers() throws {
        try english {
            var tour = try tour(.game, LearningFixture.newcomer)
            XCTAssertEqual(tour.phase, .step(.gameChoose))
            let hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game · step 1 of 5")
            XCTAssertEqual(hint.text, "Where is your game: bought on Steam, or in a folder on a disk? "
                + "Click “From Steam” or “From a Folder”.")
            XCTAssertEqual(hint.target, .libraryAddButtons)
            XCTAssertEqual(hint.section, .library)
            XCTAssertEqual(hint.buttons, [.choose(.steam), .choose(.folder)])
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["From Steam", "From a Folder"])
            XCTAssertNil(hint.primaryButton)
            // The other ways are a quiet link, named and not walked.
            XCTAssertEqual(hint.help?.title, "Other Ways")
            XCTAssertEqual(hint.help?.tips, [
                "An installer from GOG or itch.io: “+”, then “Add Game…”.",
                "Beat Saber through BSManager: “+”, then “Install BSManager…”.",
                "A game installed in Whisky or CrossOver: its card shows in “Library”. "
                    + "Click “Copy into Basalt…” on it.",
                "These ways have no step-by-step hints yet.",
            ])
            XCTAssertEqual(hint.help?.options, [])
            // The question has no "Next": only an answer moves on.
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.gameChoose))
        }
    }

    func testEachAnswerSaysWhatToDoInItsWindowBeforeTheWindowOpens() throws {
        try english {
            var steam = try tour(.game, LearningFixture.newcomer)
            steam.handle(.choose(.steam))
            XCTAssertEqual(steam.phase, .step(.gameSteam))
            XCTAssertEqual(steam.branch, .steam)
            var hint = try shown(steam)
            XCTAssertEqual(hint.label, "Game · step 2 of 5")
            XCTAssertEqual(hint.text, "Click “Add Steam Game…”. In the window, pick your game; "
                + "if it is not listed, pick “Another game”. Then click “Next”.")
            XCTAssertEqual(hint.target, .libraryAddSteam)
            XCTAssertEqual(hint.buttons, [.back, .help])
            XCTAssertEqual(hint.help?.title, "Not working?")
            XCTAssertEqual(hint.help?.options, [])

            var folder = try tour(.game, LearningFixture.newcomer)
            folder.handle(.choose(.folder))
            XCTAssertEqual(folder.phase, .step(.gameFolder))
            hint = try shown(folder)
            XCTAssertEqual(hint.text, "Click “Add Game from Folder…”. In the window, click “Choose Folder…”, "
                + "check the chosen .exe, then click “Add Game”.")
            XCTAssertEqual(hint.target, .libraryAddFolder)
            XCTAssertEqual(hint.help?.tips, ["“Add Game” stays grey until the game's .exe file is chosen."])

            // "Back" returns to the question, and the other answer can be given.
            steam.handle(.back)
            XCTAssertEqual(steam.phase, .step(.gameChoose))
            XCTAssertNil(steam.branch)
            XCTAssertEqual(try shown(steam).buttons, [.choose(.steam), .choose(.folder)])
            steam.handle(.choose(.folder))
            XCTAssertEqual(steam.phase, .step(.gameFolder))
        }
    }

    /// One of the two real buttons can be pressed straight from the
    /// question. Its window opens at once, so the hint of that way is never
    /// shown, and the facts decide what comes after the window.
    func testARealButtonPressedOnTheQuestionWorksWithoutAnAnswer() throws {
        // The Steam wizard, closed while Steam downloads: the wait.
        var steam = try tour(.game, LearningFixture.newcomer)
        feed(&steam) { $0.pageSheetOpen = true }
        XCTAssertNil(steam.presentation)
        XCTAssertEqual(steam.phase, .step(.gameChoose))
        feed(&steam) {
            $0.session = .windowsApp
            $0.libraryShowsAddButtons = false
        }
        feed(&steam) { $0.pageSheetOpen = false }
        XCTAssertEqual(steam.phase, .step(.gameWait))
        XCTAssertNil(steam.branch)
        // No hint of a way was shown: "Back" returns to the question.
        XCTAssertEqual(try shown(steam).buttons, [.back, .help])
        // The wizard is opened again and finishes the game.
        feed(&steam) { $0.pageSheetOpen = true }
        feed(&steam) {
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
        }
        feed(&steam) { $0.pageSheetOpen = false }
        XCTAssertEqual(steam.phase, .step(.gameStopSteam))
        feed(&steam) { $0.session = .idle }
        XCTAssertEqual(steam.phase, .finished)

        // The folder import, start to end inside its window: the chapter ends.
        var folder = try tour(.game, LearningFixture.newcomer)
        feed(&folder) { $0.pageSheetOpen = true }
        feed(&folder) { $0.importRunning = true }
        feed(&folder) {
            $0.importRunning = false
            $0.libraryShowsAddButtons = false
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
        }
        feed(&folder) { $0.pageSheetOpen = false }
        XCTAssertEqual(folder.phase, .finished)
        XCTAssertTrue(folder.isCompleted)

        // A window closed with nothing done: the question again.
        var cancelled = try tour(.game, LearningFixture.newcomer)
        feed(&cancelled) { $0.pageSheetOpen = true }
        feed(&cancelled) { $0.pageSheetOpen = false }
        XCTAssertEqual(cancelled.phase, .step(.gameChoose))
        XCTAssertEqual(try shown(cancelled).buttons, [.choose(.steam), .choose(.folder)])
    }

    /// In a Library that already has cards the two buttons are in the "+"
    /// menu, which cannot be outlined: the hint says where it is.
    func testWithoutTheLargeButtonsTheHintPointsAtThePlusMenu() throws {
        try english {
            let facts = LearningFixture.newcomer.with { $0.libraryShowsAddButtons = false }
            var tour = try tour(.game, facts)
            XCTAssertNil(try shown(tour).target)
            tour.handle(.choose(.steam))
            XCTAssertNil(try shown(tour).target)
            XCTAssertEqual(try shown(tour).text, "Click “+” at the top right, then “Add Steam Game…”. "
                + "In the window, pick your game; if it is not listed, pick “Another game”. Then click “Next”.")
            tour.handle(.back)
            tour.handle(.choose(.folder))
            XCTAssertEqual(try shown(tour).text, "Click “+” at the top right, then “Add Game from Folder…”. "
                + "In the window, click “Choose Folder…”, check the chosen .exe, then click “Add Game”.")
        }
    }

    func testNothingIsDrawnOrMovedWhileASheetIsOpen() throws {
        var tour = try tour(.game, LearningFixture.newcomer)
        tour.handle(.choose(.steam))
        feed(&tour) { $0.pageSheetOpen = true }
        XCTAssertNil(tour.presentation)
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        // Whatever happens under the sheet, the step stays.
        feed(&tour) { $0.session = .windowsApp }
        feed(&tour) {
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
        }
        XCTAssertNil(tour.presentation)
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        XCTAssertFalse(tour.isOver)
        // The sheet closes: now the facts decide.
        feed(&tour) { $0.pageSheetOpen = false }
        XCTAssertEqual(tour.phase, .step(.gameStopSteam))
    }

    func testTheSteamWayToTheEnd() throws {
        try english {
            var tour = try tour(.game, LearningFixture.newcomer)
            tour.handle(.choose(.steam))
            // The wizard opens, Steam starts, the wizard is closed mid-download.
            feed(&tour) { $0.pageSheetOpen = true }
            feed(&tour) {
                $0.session = .windowsApp
                $0.libraryShowsAddButtons = false
            }
            feed(&tour) { $0.pageSheetOpen = false }
            XCTAssertEqual(tour.phase, .step(.gameWait))
            XCTAssertTrue(tour.waitsForGame)
            var hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game · step 3 of 5")
            XCTAssertEqual(hint.text, "Do not stop Steam or quit TrailBridge: the download would break off. "
                + "The chapter goes on when the game gets “Play”; you can open the wizard again.")
            XCTAssertNil(hint.target)
            XCTAssertNil(hint.section)
            XCTAssertEqual(hint.buttons, [.back, .help])

            // The wizard is opened again and adds the game; Steam stays open.
            feed(&tour) { $0.pageSheetOpen = true }
            feed(&tour) {
                $0.launchableGames = [self.game]
                $0.selectedGame = self.game
                $0.openVRBadges = [self.game: .needsSetup]
            }
            feed(&tour) { $0.pageSheetOpen = false }
            XCTAssertEqual(tour.phase, .step(.gameStopSteam))
            XCTAssertFalse(tour.waitsForGame)
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game · step 4 of 5")
            XCTAssertEqual(hint.text, "The game is added. Steam is still open, so “Play” is not available. "
                + "If the game has finished downloading, click “Stop” in the sidebar.")
            XCTAssertEqual(hint.target, .sidebarStop)

            // Steam is stopped: the OpenVR label is next.
            feed(&tour) { $0.session = .idle }
            XCTAssertEqual(tour.phase, .step(.gameOpenVR))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game · step 5 of 5")
            XCTAssertEqual(hint.text, "The game is marked “SET UP OPENVR”. Click that label and turn on "
                + "“OpenVR support”; if asked, click “Download and turn on”. Then click “Done”.")
            XCTAssertEqual(hint.target, .libraryStatusChip(self.game))
            XCTAssertEqual(hint.section, .library)
            XCTAssertEqual(hint.buttons, [.back, .help])
            XCTAssertEqual(hint.help?.options, [.skip])

            // The OpenVR sheet does its work; the label turns to "ready".
            feed(&tour) { $0.pageSheetOpen = true }
            feed(&tour) { $0.openVRBadges = [self.game: .installed] }
            XCTAssertEqual(tour.phase, .step(.gameOpenVR))
            feed(&tour) { $0.pageSheetOpen = false }
            XCTAssertEqual(tour.phase, .finished)
            XCTAssertTrue(tour.isCompleted)
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game")
            XCTAssertEqual(hint.text, "The “Game” chapter is done. Next: “Headset”.")
            XCTAssertEqual(hint.buttons, [.continueTo(.headset), .later])
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["Go On", "Later"])
            XCTAssertEqual(hint.primaryButton, .continueTo(.headset))
        }
    }

    func testStepsThatAreAlreadyDoneAreSkipped() throws {
        // No OpenVR label and Steam closed: the game alone ends the chapter.
        var plain = try tour(.game, LearningFixture.newcomer)
        plain.handle(.choose(.folder))
        feed(&plain) { $0.pageSheetOpen = true }
        feed(&plain) {
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
            $0.openVRBadges = [self.game: .none]
        }
        feed(&plain) { $0.pageSheetOpen = false }
        XCTAssertEqual(plain.phase, .finished)

        // Steam closed, the label asks: straight to the label.
        var label = try tour(.game, LearningFixture.newcomer)
        label.handle(.choose(.steam))
        feed(&label) {
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
            $0.openVRBadges = [self.game: .needsSetup]
        }
        XCTAssertEqual(label.phase, .step(.gameOpenVR))

        // Steam open, no label: only "Stop", then the end.
        var steam = try tour(.game, LearningFixture.newcomer)
        steam.handle(.choose(.steam))
        feed(&steam) {
            $0.session = .windowsApp
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
        }
        XCTAssertEqual(steam.phase, .step(.gameStopSteam))
        feed(&steam) { $0.session = .idle }
        XCTAssertEqual(steam.phase, .finished)
    }

    func testTheLabelIsAGuessAndCanBeSkipped() throws {
        var tour = try tour(.game, LearningFixture.withGame.with {
            $0.openVRBadges = [self.game: .needsSetup]
        })
        XCTAssertEqual(tour.phase, .step(.gameOpenVR))
        tour.handle(.skip)
        XCTAssertEqual(tour.phase, .finished)
        XCTAssertTrue(tour.isCompleted)
        // Only that step can be skipped.
        var choose = try self.tour(.game, LearningFixture.newcomer)
        choose.handle(.skip)
        XCTAssertEqual(choose.phase, .step(.gameChoose))
        choose.handle(.choose(.steam))
        choose.handle(.skip)
        XCTAssertEqual(choose.phase, .step(.gameSteam))
    }

    /// The game that Play launches is asked about first; another launchable
    /// game with the label is found too.
    func testTheLabelOfAnyLaunchableGameCounts() throws {
        var facts = LearningFixture.withGame
        facts.launchableGames = ["Blood Trail", game]
        facts.selectedGame = "Blood Trail"
        facts.openVRBadges = ["Blood Trail": .installed, game: .needsSetup]
        XCTAssertEqual(try shown(try tour(.game, facts)).target, .libraryStatusChip(game))
        facts.openVRBadges["Blood Trail"] = .needsSetup
        XCTAssertEqual(try shown(try tour(.game, facts)).target, .libraryStatusChip("Blood Trail"))
    }

    /// A wizard closed without Steam running leaves nothing on its way: the
    /// same hint is shown again.
    func testAWindowClosedWithNothingRunningShowsTheSameStepAgain() throws {
        var tour = try tour(.game, LearningFixture.newcomer)
        tour.handle(.choose(.steam))
        feed(&tour) { $0.pageSheetOpen = true }
        feed(&tour) { $0.pageSheetOpen = false }
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        XCTAssertFalse(tour.waitsForGame)
        // Waiting ends without a game when Steam is closed: back to the hint.
        feed(&tour) { $0.pageSheetOpen = true }
        feed(&tour) { $0.session = .windowsApp }
        feed(&tour) { $0.pageSheetOpen = false }
        XCTAssertEqual(tour.phase, .step(.gameWait))
        feed(&tour) { $0.session = .idle }
        XCTAssertEqual(tour.phase, .step(.gameSteam))
    }

    /// Steam that was open before anything was pressed is not a download.
    func testSteamOpenBeforeAnyActionIsNotWaiting() throws {
        var tour = try tour(.game, LearningFixture.newcomer.with { $0.session = .windowsApp })
        XCTAssertEqual(tour.phase, .step(.gameChoose))
        tour.handle(.choose(.steam))
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        feed(&tour) { $0.importRunning = true }
        XCTAssertEqual(tour.phase, .step(.gameSteam))
    }

    func testTheFolderWayWaitsForTheCopy() throws {
        try english {
            var tour = try tour(.game, LearningFixture.newcomer)
            tour.handle(.choose(.folder))
            feed(&tour) { $0.pageSheetOpen = true }
            feed(&tour) { $0.importRunning = true }
            // The import outlives its sheet when the section changes.
            feed(&tour) { $0.pageSheetOpen = false }
            XCTAssertEqual(tour.phase, .step(.gameWait))
            XCTAssertEqual(try shown(tour).text,
                           "The game is being copied. The chapter goes on when the game gets “Play”.")
            feed(&tour) {
                $0.importRunning = false
                $0.launchableGames = [self.game]
                $0.selectedGame = self.game
            }
            XCTAssertEqual(tour.phase, .finished)
        }
    }

    func testTheFactsSuggestTheWayFirst() throws {
        try english {
            let card = LearningLibraryGame(id: "steam-1", name: "Blood Trail")
            var tour = try tour(.game, LearningFixture.newcomer.with {
                $0.libraryShowsAddButtons = false
                $0.steamGameWithoutProfile = card
            })
            XCTAssertEqual(tour.phase, .step(.gameCreateProfile))
            var hint = try shown(tour)
            XCTAssertEqual(hint.label, "Game · step 1 of 5")
            XCTAssertEqual(hint.text, "“Blood Trail” is already here. Click “Create Profile” "
                + "on its card: “Play” will appear.")
            XCTAssertEqual(hint.target, .libraryGameAction("steam-1"))
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertEqual(hint.help?.options, [.otherWay])
            XCTAssertEqual(hint.help.map { hint.title(of: $0.options[0]) }, "Add Another Game")
            // The profile appears: the chapter ends.
            feed(&tour) {
                $0.steamGameWithoutProfile = nil
                $0.launchableGames = ["Blood Trail"]
                $0.selectedGame = "Blood Trail"
            }
            XCTAssertEqual(tour.phase, .finished)

            // A game in Whisky: "Copy" first, then its profile.
            let external = LearningLibraryGame(id: "whisky-7", name: "Beat Saber", place: "Whisky")
            var copy = try self.tour(.game, LearningFixture.newcomer.with {
                $0.libraryShowsAddButtons = false
                $0.externalGame = external
            })
            XCTAssertEqual(copy.phase, .step(.gameCopy))
            hint = try shown(copy)
            XCTAssertEqual(hint.text, "“Beat Saber” is installed in Whisky. "
                + "Click “Copy into Basalt…” on its card.")
            XCTAssertEqual(hint.target, .libraryGameAction("whisky-7"))
            feed(&copy) { $0.pageSheetOpen = true }
            feed(&copy) {
                $0.externalGame = nil
                $0.steamGameWithoutProfile = LearningLibraryGame(id: "steam-9", name: "Beat Saber")
            }
            feed(&copy) { $0.pageSheetOpen = false }
            XCTAssertEqual(copy.phase, .step(.gameCreateProfile))
            XCTAssertEqual(try shown(copy).target, .libraryGameAction("steam-9"))
            // A profile in an environment before the copy wins over the copy.
            XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer.with {
                $0.externalGame = external
                $0.steamGameWithoutProfile = card
            }).phase, .step(.gameCreateProfile))
        }
    }

    func testAnotherGameCanBeAddedInsteadOfTheSuggestedOne() throws {
        let card = LearningLibraryGame(id: "steam-1", name: "Blood Trail")
        var tour = try tour(.game, LearningFixture.newcomer.with {
            $0.libraryShowsAddButtons = false
            $0.steamGameWithoutProfile = card
        })
        tour.handle(.otherWay)
        XCTAssertEqual(tour.phase, .step(.gameChoose))
        // The suggestion does not come back by itself.
        feed(&tour) { $0.appBusy = true }
        XCTAssertEqual(tour.phase, .step(.gameChoose))
        tour.handle(.choose(.steam))
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        // "Other way" is offered only where a way was suggested.
        tour.handle(.otherWay)
        XCTAssertEqual(tour.phase, .step(.gameSteam))
    }

    /// A Steam card without a profile has no Play: the step does not count.
    func testASteamCardWithoutAProfileDoesNotEndTheChapter() throws {
        var tour = try tour(.game, LearningFixture.newcomer)
        tour.handle(.choose(.steam))
        feed(&tour) { $0.pageSheetOpen = true }
        feed(&tour) {
            $0.session = .windowsApp
            $0.libraryShowsAddButtons = false
            $0.steamGameWithoutProfile = LearningLibraryGame(id: "steam-1", name: "Blood Trail")
        }
        feed(&tour) { $0.pageSheetOpen = false }
        // While Steam runs the game may still be downloading: wait.
        XCTAssertEqual(tour.phase, .step(.gameWait))
        XCTAssertFalse(tour.isCompleted)
        feed(&tour) { $0.session = .idle }
        XCTAssertEqual(tour.phase, .step(.gameCreateProfile))
        XCTAssertFalse(tour.isCompleted)
    }

    func testGameBackNeverJumpsForward() throws {
        var tour = try tour(.game, LearningFixture.newcomer)
        tour.handle(.choose(.steam))
        feed(&tour) { $0.pageSheetOpen = true }
        feed(&tour) { $0.session = .windowsApp }
        feed(&tour) { $0.pageSheetOpen = false }
        XCTAssertEqual(tour.phase, .step(.gameWait))
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        XCTAssertTrue(tour.isRevisit)
        XCTAssertEqual(try shown(tour).buttons, [.back, .next])
        XCTAssertNil(try shown(tour).help)
        // Facts keep coming; the revisited step stays.
        feed(&tour) { $0.appBusy = true }
        feed(&tour) {
            $0.launchableGames = [self.game]
            $0.selectedGame = self.game
        }
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        // "Next" lands on the first step still to do.
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.gameStopSteam))
        XCTAssertFalse(tour.isRevisit)
        // With the game there, the wait and the question are behind for
        // good: "Back" shows only the hint of the way that was taken.
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.gameSteam))
        XCTAssertFalse(tour.hasPrevious)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.gameSteam))

        // Before the game is there: the wait, the hint, the question, and
        // never past it.
        var waiting = try self.tour(.game, LearningFixture.newcomer)
        waiting.handle(.choose(.folder))
        feed(&waiting) { $0.pageSheetOpen = true }
        feed(&waiting) { $0.importRunning = true }
        feed(&waiting) { $0.pageSheetOpen = false }
        XCTAssertEqual(waiting.phase, .step(.gameWait))
        waiting.handle(.back)
        XCTAssertEqual(waiting.phase, .step(.gameFolder))
        waiting.handle(.back)
        XCTAssertEqual(waiting.phase, .step(.gameChoose))
        XCTAssertNil(waiting.branch)
        XCTAssertFalse(waiting.hasPrevious)
        waiting.handle(.back)
        XCTAssertEqual(waiting.phase, .step(.gameChoose))
        // The copy still runs, but the revisited question waits for its answer.
        feed(&waiting) { $0.appBusy = true }
        XCTAssertEqual(waiting.phase, .step(.gameChoose))
        waiting.handle(.choose(.folder))
        XCTAssertEqual(waiting.phase, .step(.gameWait))
    }

    func testGamePausesAndResumes() throws {
        var tour = try tour(.game, LearningFixture.newcomer)
        tour.handle(.choose(.steam))
        feed(&tour) { $0.pageSheetOpen = true }
        feed(&tour) { $0.session = .windowsApp }
        feed(&tour) { $0.pageSheetOpen = false }
        tour.handle(.close)
        XCTAssertEqual(tour.phase, .stopped)
        XCTAssertTrue(tour.isOver)
        XCTAssertEqual(tour.pausedStep, .gameWait)
        XCTAssertFalse(tour.isCompleted)
        XCTAssertNil(tour.presentation)
        // Nothing moves a tour that is over.
        tour.handle(.next)
        feed(&tour) { $0.session = .idle }
        XCTAssertEqual(tour.phase, .stopped)

        // "Continue" while Steam still downloads: the wait again.
        let waiting = LearningFixture.newcomer.with { $0.session = .windowsApp }
        XCTAssertEqual(try self.tour(.game, waiting, resumeAt: "gameWait").phase, .step(.gameWait))
        // Steam was closed meanwhile: the question again.
        XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer, resumeAt: "gameWait").phase,
                       .step(.gameChoose))
        // The game arrived meanwhile: what is left of the chapter.
        XCTAssertEqual(try self.tour(.game, LearningFixture.withGame.with {
            $0.openVRBadges = [self.game: .needsSetup]
        }, resumeAt: "gameWait").phase, .step(.gameOpenVR))
        // An answer already given is remembered with its step.
        XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer, resumeAt: "gameSteam").phase,
                       .step(.gameSteam))
        XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer, resumeAt: "gameFolder").phase,
                       .step(.gameFolder))
        // A name of another version or another chapter starts over.
        XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer, resumeAt: "gameDownload").phase,
                       .step(.gameChoose))
        XCTAssertEqual(try self.tour(.game, LearningFixture.newcomer, resumeAt: "optionsStream").phase,
                       .step(.gameChoose))
    }

    func testTheCardKnowsWhenGameWaitsForADownload() {
        var facts = LearningFixture.newcomer
        XCTAssertFalse(SetupTour.waitsForGame(in: facts))
        facts.chapters[.game].pausedStep = Step.gameWait.rawValue
        XCTAssertFalse(SetupTour.waitsForGame(in: facts))
        facts.session = .windowsApp
        XCTAssertTrue(SetupTour.waitsForGame(in: facts))
        facts.session = .idle
        facts.importRunning = true
        XCTAssertTrue(SetupTour.waitsForGame(in: facts))
        facts.launchableGames = [game]
        XCTAssertFalse(SetupTour.waitsForGame(in: facts))
        // Paused elsewhere in the chapter: Steam is just open.
        var other = LearningFixture.newcomer.with { $0.session = .windowsApp }
        other.chapters[.game].pausedStep = Step.gameSteam.rawValue
        XCTAssertFalse(SetupTour.waitsForGame(in: other))
    }

    /// Parts built while the app was open: the Setup check sees the engine,
    /// the app's engine list does not, and the Steam wizard reads the list.
    func testOneFullRefreshIsAskedForOnEnteringGame() {
        var facts = LearningFixture.newcomer
        XCTAssertFalse(facts.needsEngineRefresh)
        facts.pinnedEngineListed = false
        XCTAssertTrue(facts.needsEngineRefresh)
        // Only when nothing else is going on.
        XCTAssertFalse(facts.with { $0.appBusy = true }.needsEngineRefresh)
        XCTAssertFalse(facts.with { $0.session = .windowsApp }.needsEngineRefresh)
        XCTAssertFalse(facts.with { $0.session = .live }.needsEngineRefresh)
        XCTAssertFalse(facts.with { $0.importRunning = true }.needsEngineRefresh)
        XCTAssertFalse(facts.with { $0.pageSheetOpen = true }.needsEngineRefresh)
        // Not while the engine itself is still missing, or nothing is known.
        XCTAssertFalse(LearningFixture.unbuiltMac.needsEngineRefresh)
        XCTAssertFalse(LearningFacts().needsEngineRefresh)
    }

    // MARK: - Chapter 4: First launch

    func testFirstLaunchWithTheMacsOwnAudioAsksForSystemAudio() throws {
        try english {
            let tour = try tour(.firstLaunch, LearningFixture.withGame.with {
                $0.gameAudioOn = true
                $0.gameAudioMac = true
            })
            XCTAssertEqual(tour.phase, .step(.launchMicrophone))
            XCTAssertEqual(try shown(tour).text,
                "If macOS asks to record system audio, click “Allow”: that is how the game's sound "
                + "gets to the headset. If the game asks for the microphone, you can allow it too.")
        }
    }

    func testFirstLaunchSaysTheMicrophoneSentenceThenHandsOver() throws {
        try english {
            var tour = try tour(.firstLaunch, LearningFixture.withGame.with { $0.gameAudioOn = true })
            XCTAssertEqual(tour.phase, .step(.launchMicrophone))
            let hint = try shown(tour)
            XCTAssertEqual(hint.label, "First Launch")
            XCTAssertEqual(hint.text, "If macOS asks for access to the microphone, click “Allow”: "
                + "that is how the game's sound gets to the headset.")
            XCTAssertNil(hint.target)
            XCTAssertNil(hint.section)
            XCTAssertEqual(hint.buttons, [.next])
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .handOff)
            XCTAssertTrue(tour.isOver)
            // The quick path completes the chapter, not these cards.
            XCTAssertFalse(tour.isCompleted)
            XCTAssertNil(tour.pausedStep)
            XCTAssertNil(tour.presentation)
        }
    }

    func testFirstLaunchWithoutGameSoundOrAsAReviewHandsOverAtOnce() throws {
        XCTAssertEqual(try tour(.firstLaunch, LearningFixture.withGame).phase, .handOff)
        // macOS asks once, at the first launch: a review does not repeat it.
        XCTAssertEqual(try tour(.firstLaunch, .review, LearningFixture.returning).phase, .handOff)
    }

    // MARK: - Chapter 5: Launch options

    private var optionsFacts: LearningFacts {
        LearningFixture.returning.with { $0.recommendedPresetSelected = false }
    }

    func testLaunchOptionsWalkTheSixSteps() throws {
        try english {
            var tour = try tour(.launchOptions, optionsFacts)
            XCTAssertEqual(tour.phase, .step(.optionsLibrary))
            var hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 1 of 6")
            XCTAssertEqual(hint.text, "You can play from here too: every game has its own card "
                + "with a “Play” button.")
            // The whole card, not its Play button: nothing is to be pressed.
            XCTAssertEqual(hint.target, .libraryGameTile(self.game))
            XCTAssertEqual(hint.section, .library)
            XCTAssertEqual(hint.buttons, [.next])

            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsStream))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 2 of 6")
            XCTAssertEqual(hint.text, "The second place to start is here: the “Game” list and “Play”. "
                + "Now click “Change…”, then “Global Stream Settings…”.")
            XCTAssertEqual(hint.target, .streamAdjust)
            XCTAssertEqual(hint.section, .stream)
            XCTAssertEqual(hint.buttons, [.back, .help])
            XCTAssertEqual(hint.help?.tips, [
                "“Change…” is not available while a session runs or Steam is open. Click “Stop”.",
            ])
            // No "Next" here: the step counts itself.
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsStream))
            feed(&tour) { $0.section = .stream }
            XCTAssertNil(try shown(tour).section)
            feed(&tour) { $0.section = .settings }

            XCTAssertEqual(tour.phase, .step(.optionsConnection))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 3 of 6")
            XCTAssertEqual(hint.text, "This is “Connection”: choose yours. Now it is “USB Cable”: "
                + "the headset is on the cable, and ALVR opens by itself after “Play”.")
            XCTAssertEqual(hint.target, .settingsConnection)
            XCTAssertNil(hint.section)
            XCTAssertEqual(hint.buttons, [.back, .next])
            // The text follows the switch; the step stays.
            feed(&tour) { $0.connection = .wifi }
            XCTAssertEqual(tour.phase, .step(.optionsConnection))
            XCTAssertEqual(try shown(tour).text, "This is “Connection”: choose yours. Now it is “Wi-Fi”: "
                + "the Mac and the headset are on one network; open ALVR in the headset first, then click “Play”.")
            XCTAssertEqual(try shown(tour).id, hint.id)

            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsRecommended))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 4 of 6")
            XCTAssertEqual(hint.text, "Not sure which quality to choose? Click “Use recommended”. "
                + "You can also keep your own values.")
            XCTAssertEqual(hint.target, .settingsUseRecommended)
            XCTAssertEqual(hint.buttons, [.back, .next])
            // Pressed: the step counts itself.
            feed(&tour) { $0.recommendedPresetSelected = true }

            XCTAssertEqual(tour.phase, .step(.optionsOwnSettings))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 5 of 6")
            XCTAssertEqual(hint.text, "A game can have its own settings: “Change…”, then "
                + "“Stream Settings for …”.")
            XCTAssertEqual(hint.target, .streamAdjust)
            XCTAssertEqual(hint.section, .stream)
            XCTAssertEqual(hint.buttons, [.back, .next])
            // The details are a quiet link, not a third button.
            XCTAssertEqual(hint.help?.title, "Not working?")
            XCTAssertEqual(hint.help?.tips, [
                "In that window, “Save” gives the game its own copy: the shared settings, "
                    + "“Connection” included, no longer apply to it.",
                "“Use global” in the same window brings the shared settings back.",
            ])

            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsHistory))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 6 of 6")
            XCTAssertEqual(hint.text, "Your past sessions are here; ▶ in a row starts the same game again.")
            XCTAssertEqual(hint.target, .streamRecentSessions)
            XCTAssertEqual(hint.buttons, [.back, .next])
            XCTAssertFalse(tour.isCompleted)

            tour.handle(.next)
            XCTAssertEqual(tour.phase, .finished)
            XCTAssertTrue(tour.isCompleted)
            hint = try shown(tour)
            // Every other chapter is done: nothing is next.
            XCTAssertEqual(hint.text, "The “Launch Options” chapter is done.")
            XCTAssertEqual(hint.buttons, [.done])
            XCTAssertEqual(hint.title(of: .done), "Done")
            XCTAssertEqual(hint.primaryButton, .done)
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .closed)
            XCTAssertTrue(tour.isOver)
            XCTAssertTrue(tour.isCompleted)
            XCTAssertNil(tour.presentation)
        }
    }

    /// The Settings section must open while the step is shown: being there
    /// already, as after "Continue", does not count.
    func testOpeningSettingsCountsOnlyAsAChange() throws {
        var tour = try tour(.launchOptions, optionsFacts.with { $0.section = .settings },
                            resumeAt: "optionsStream")
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        XCTAssertEqual(try shown(tour).section, .stream)
        feed(&tour) { $0.appBusy = true }
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        // The app opens the Stream section for the step; then the menu is used.
        feed(&tour) { $0.section = .stream }
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        feed(&tour) { $0.section = .settings }
        XCTAssertEqual(tour.phase, .step(.optionsConnection))
    }

    func testARecommendedPresetAlreadySelectedIsSaidAndNotSkipped() throws {
        try english {
            var tour = try tour(.launchOptions, LearningFixture.returning, resumeAt: "optionsRecommended")
            XCTAssertEqual(tour.phase, .step(.optionsRecommended))
            XCTAssertEqual(try shown(tour).text, "Quality: the one recommended for this Mac is already selected. "
                + "“Use recommended” always brings it back.")
            XCTAssertEqual(try shown(tour).buttons, [.back, .next])
            // Nothing to wait for: facts do not move it.
            feed(&tour) { $0.appBusy = true }
            XCTAssertEqual(tour.phase, .step(.optionsRecommended))
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsOwnSettings))

            // Another preset is chosen and the recommended one again: that
            // is the press the step waits for.
            var changed = try self.tour(.launchOptions, LearningFixture.returning,
                                        resumeAt: "optionsRecommended")
            feed(&changed) { $0.recommendedPresetSelected = false }
            XCTAssertEqual(changed.phase, .step(.optionsRecommended))
            feed(&changed) { $0.recommendedPresetSelected = true }
            XCTAssertEqual(changed.phase, .step(.optionsOwnSettings))
        }
    }

    /// A game with its own stream settings: the switch just shown does not
    /// apply to it, and the next card says where its switch is.
    func testAGameWithItsOwnSettingsGetsItsOwnCard() throws {
        try english {
            let facts = optionsFacts.with { $0.gameWithOwnSettings = self.game }
            var tour = try tour(.launchOptions, facts, resumeAt: "optionsConnection")
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsOwnConnection))
            let hint = try shown(tour)
            XCTAssertEqual(hint.label, "Launch Options · step 3 of 6")
            XCTAssertEqual(hint.text, "“BRUTALISTICK VR” has its own settings: its connection is changed "
                + "in “Change…”, then “Stream Settings for …”.")
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.buttons, [.back, .next])
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsRecommended))
            // Without own settings the card is not there.
            var plain = try self.tour(.launchOptions, optionsFacts, resumeAt: "optionsConnection")
            plain.handle(.next)
            XCTAssertEqual(plain.phase, .step(.optionsRecommended))
        }
    }

    func testALongGameNameIsCutInAHint() throws {
        let long = "The Elder Scrolls V: Skyrim VR Special Anniversary Edition"
        XCTAssertEqual(SetupTour.shortName(long), "The Elder Scrolls V: Sk…")
        XCTAssertEqual(SetupTour.shortName(game), game)
        XCTAssertEqual(SetupTour.shortName(String(repeating: "x", count: 24)).count, 24)
        XCTAssertEqual(SetupTour.shortName(String(repeating: "x", count: 25)).count, 24)
    }

    func testSteamOpenComesFirstInLaunchOptions() throws {
        try english {
            var tour = try tour(.launchOptions, optionsFacts.with { $0.session = .windowsApp })
            XCTAssertEqual(tour.phase, .step(.optionsStop))
            let hint = try shown(tour)
            // A card outside the count.
            XCTAssertEqual(hint.label, "Launch Options")
            XCTAssertEqual(hint.text, "Steam is open, so “Change…” is not available. "
                + "If Steam is not downloading anything, click “Stop” in the sidebar.")
            XCTAssertEqual(hint.target, .sidebarStop)
            XCTAssertNil(hint.section)
            XCTAssertEqual(hint.buttons, [.help])
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.optionsStop))
            feed(&tour) { $0.session = .idle }
            XCTAssertEqual(tour.phase, .step(.optionsLibrary))
            // "Stop" is gone with Steam: nothing to go back to.
            XCTAssertFalse(tour.hasPrevious)
            XCTAssertEqual(try shown(tour).buttons, [.next])
        }
    }

    func testLaunchOptionsBackNeverJumpsForward() throws {
        var tour = try tour(.launchOptions, optionsFacts)
        tour.handle(.next)
        feed(&tour) { $0.section = .stream }
        feed(&tour) { $0.section = .settings }
        XCTAssertEqual(tour.phase, .step(.optionsConnection))
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        XCTAssertTrue(tour.isRevisit)
        XCTAssertEqual(try shown(tour).buttons, [.back, .next])
        // The section changes while the revisited step is shown: it stays.
        feed(&tour) { $0.section = .stream }
        feed(&tour) { $0.section = .settings }
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        XCTAssertTrue(tour.isRevisit)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.optionsLibrary))
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.optionsLibrary))
        // Forward again: the first step is information, the second counts
        // itself again from now on.
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.optionsStream))
        XCTAssertFalse(tour.isRevisit)
        XCTAssertEqual(try shown(tour).buttons, [.back, .help])
    }

    func testLaunchOptionsPauseAndResume() throws {
        var tour = try tour(.launchOptions, optionsFacts)
        tour.handle(.next)
        feed(&tour) { $0.section = .stream }
        feed(&tour) { $0.section = .settings }
        tour.handle(.close)
        XCTAssertEqual(tour.phase, .stopped)
        XCTAssertEqual(tour.pausedStep, .optionsConnection)
        XCTAssertFalse(tour.isCompleted)

        let resumed = try self.tour(.launchOptions, optionsFacts, resumeAt: "optionsConnection")
        XCTAssertEqual(resumed.phase, .step(.optionsConnection))
        // The chapter is a line: "Back" works right after "Continue".
        XCTAssertTrue(resumed.hasPrevious)
        XCTAssertEqual(try shown(resumed).buttons, [.back, .next])
        XCTAssertEqual(try self.tour(.launchOptions, optionsFacts, resumeAt: "no such step").phase,
                       .step(.optionsLibrary))
        XCTAssertEqual(try self.tour(.launchOptions, optionsFacts, resumeAt: "gameWait").phase,
                       .step(.optionsLibrary))
    }

    func testTheHistoryStepSpeaksOfWhatIsThere() throws {
        try english {
            let empty = optionsFacts.with {
                $0.sessionHistory = []
            }
            XCTAssertEqual(try shown(try tour(.launchOptions, empty, resumeAt: "optionsHistory")).text,
                           "Your sessions will show here after the first one; ▶ in a row starts the same game again.")
        }
    }

    // MARK: - A VR session, close, and the end line

    func testAVRSessionStopsEveryChapterAndRemembersTheStep() throws {
        for session in [LearningSessionPhase.starting, .live] {
            var mac = try tour(.mac, LearningFixture.unbuiltMac)
            feed(&mac) { $0.session = session }
            XCTAssertEqual(mac.phase, .stopped)
            XCTAssertEqual(mac.pausedStep, .macSummary)
            XCTAssertNil(mac.presentation)

            var game = try tour(.game, LearningFixture.newcomer)
            game.handle(.choose(.folder))
            // Even under an open sheet.
            feed(&game) { $0.pageSheetOpen = true }
            feed(&game) { $0.session = session }
            XCTAssertEqual(game.phase, .stopped)
            XCTAssertEqual(game.pausedStep, .gameFolder)

            var options = try tour(.launchOptions, optionsFacts)
            feed(&options) { $0.session = session }
            XCTAssertEqual(options.phase, .stopped)
            XCTAssertEqual(options.pausedStep, .optionsLibrary)

            // A tour is never begun during a session.
            let late = try tour(.game, LearningFixture.newcomer.with { $0.session = session })
            XCTAssertEqual(late.phase, .stopped)
            XCTAssertNil(late.pausedStep)
            XCTAssertNil(late.presentation)
        }
        // A Windows program or a failed launch is not a VR session.
        for session in [LearningSessionPhase.windowsApp, .failed("boom"), .idle] {
            var mac = try tour(.mac, LearningFixture.unbuiltMac)
            feed(&mac) { $0.session = session }
            XCTAssertEqual(mac.phase, .step(.macSummary), "\(session)")
        }
    }

    func testClosingAReviewRemembersNothing() throws {
        var review = try tour(.launchOptions, .review, LearningFixture.returning)
        review.handle(.next)
        review.handle(.close)
        XCTAssertEqual(review.phase, .stopped)
        XCTAssertNil(review.pausedStep)
        XCTAssertFalse(review.isCompleted)
        var session = try tour(.game, .review, LearningFixture.returning)
        feed(&session) { $0.session = .starting }
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(session.pausedStep)
    }

    func testTheEndLineNamesTheNextChapterAndClosesOnAnyAnswer() throws {
        try english {
            // Mac just turned ready for a new person: the headset is next.
            var mac = try tour(.mac, LearningFixture.unbuiltMac)
            feed(&mac) { $0.setupChecks = LearningFixture.checks() }
            var hint = try shown(mac)
            XCTAssertEqual(hint.id, "setup-mac-end")
            XCTAssertEqual(hint.text, "The “Mac” chapter is done. Next: “Headset”.")
            XCTAssertEqual(hint.buttons, [.continueTo(.headset), .later])
            XCTAssertNil(hint.target)
            XCTAssertNil(hint.section)
            // With ALVR on the headset the Mac sees over USB, the game is next.
            feed(&mac, LearningFixture.headsetReady)
            hint = try shown(mac)
            XCTAssertEqual(hint.text, "The “Mac” chapter is done. Next: “Game”.")
            XCTAssertEqual(hint.buttons, [.continueTo(.game), .later])

            for button in hint.buttons {
                var answered = mac
                answered.handle(try XCTUnwrap(button.event))
                XCTAssertEqual(answered.phase, .closed)
                XCTAssertTrue(answered.isCompleted)
            }
            var closed = mac
            closed.handle(.close)
            XCTAssertEqual(closed.phase, .closed)
            XCTAssertTrue(closed.isCompleted)
            XCTAssertNil(closed.pausedStep)
            var session = mac
            feed(&session) { $0.session = .starting }
            XCTAssertEqual(session.phase, .closed)

            // The chapter just walked is never its own "next", even before
            // its record is written.
            var options = try self.tour(.launchOptions, self.optionsFacts, resumeAt: "optionsHistory")
            options.handle(.next)
            XCTAssertEqual(try shown(options).buttons, [.done])
            XCTAssertEqual(LearningProgram.nextChapter(in: self.optionsFacts, after: nil), .launchOptions)
            XCTAssertNil(LearningProgram.nextChapter(in: self.optionsFacts, after: .launchOptions))
        }
    }

    // MARK: - Review

    /// A review waits for nothing: "Back" and "Next" on every step.
    func testAReviewWalksEveryStepWithBackAndNext() throws {
        let cases: [(LearningChapter, [Step])] = [
            (.mac, [.macSummary]),
            (.headset, [.headsetIntro, .headsetTools, .headsetAccount, .headsetDeveloperMode,
                        .headsetCable, .headsetDebugging, .headsetInstall, .headsetOpenALVR]),
            (.game, [.gameChoose, .gameSteam, .gameFolder, .gameWait, .gameStopSteam, .gameOpenVR]),
            (.launchOptions, [.optionsLibrary, .optionsStream, .optionsConnection, .optionsRecommended,
                              .optionsOwnSettings, .optionsHistory]),
        ]
        for (chapter, steps) in cases {
            var tour = try tour(chapter, .review, LearningFixture.returning)
            for (index, step) in steps.enumerated() {
                XCTAssertEqual(tour.phase, .step(step), "\(chapter)")
                let hint = try shown(tour)
                XCTAssertEqual(hint.buttons, index == 0 ? [.next] : [.back, .next], "\(step)")
                XCTAssertEqual(hint.primaryButton, .next)
                XCTAssertTrue(hint.id.hasSuffix("-review"), hint.id)
                // No fact moves a review.
                feed(&tour) {
                    $0.section = .settings
                    $0.recommendedPresetSelected.toggle()
                    $0.session = .windowsApp
                    $0.setupChecks = LearningFixture.checks(missing: ["wine"])
                    $0.launchableGames = []
                    $0.openVRBadges = [:]
                    LearningFixture.headset(.connected)(&$0)
                }
                XCTAssertEqual(tour.phase, .step(step), "\(step)")
                tour.handle(.facts(LearningFixture.returning))
                // Events of a first pass do nothing here.
                tour.handle(.checkAgain)
                tour.handle(.skip)
                tour.handle(.choose(.steam))
                tour.handle(.otherWay)
                XCTAssertEqual(tour.phase, .step(step), "\(step)")
                tour.handle(.next)
            }
            XCTAssertEqual(tour.phase, .finished, "\(chapter)")
            XCTAssertTrue(tour.isCompleted)
            XCTAssertNil(tour.pausedStep)
        }
    }

    func testAReviewGoesBackStepByStep() throws {
        var tour = try tour(.launchOptions, .review, LearningFixture.returning.with {
            $0.gameWithOwnSettings = self.game
        })
        let steps: [Step] = [.optionsLibrary, .optionsStream, .optionsConnection, .optionsOwnConnection,
                             .optionsRecommended, .optionsOwnSettings, .optionsHistory]
        for _ in steps.dropLast() { tour.handle(.next) }
        XCTAssertEqual(tour.phase, .step(.optionsHistory))
        for step in steps.dropLast().reversed() {
            tour.handle(.back)
            XCTAssertEqual(tour.phase, .step(step))
        }
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.optionsLibrary))
    }

    /// A review outlines only what is on screen now. Where a control exists
    /// only in another state there is no outline, and the text says where
    /// the control appears.
    func testAReviewNeverOutlinesAControlThatIsNotThere() throws {
        try english {
            var mac = try tour(.mac, .review, LearningFixture.returning)
            var hint = try shown(mac)
            XCTAssertEqual(hint.label, "Mac · review, step 1 of 1")
            XCTAssertEqual(hint.text, "This shows whether the Mac is ready. Everything is in place now, "
                + "so there is no “Build instructions” button.")
            XCTAssertEqual(hint.target, .setupSummary)
            mac.handle(.next)
            XCTAssertEqual(try shown(mac).text, "The “Mac” chapter is done. Next: “Launch Options”.")

            var game = try self.tour(.game, .review, LearningFixture.returning)
            hint = try shown(game)
            XCTAssertEqual(hint.label, "Game · review, step 1 of 6")
            XCTAssertEqual(hint.text, "“+” at the top right adds a game: “Add Steam Game…” or "
                + "“Add Game from Folder…”. The two large buttons show here only while there are no games.")
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.help?.title, "Other Ways")
            game.handle(.next)
            hint = try shown(game)
            XCTAssertEqual(hint.text, "In “Add Steam Game”, pick your game; "
                + "if it is not listed, pick “Another game”. Then click “Next”.")
            XCTAssertNil(hint.target)
            XCTAssertNil(hint.help)
            game.handle(.next)
            hint = try shown(game)
            XCTAssertEqual(hint.text, "In “Add Game from Folder”, click “Choose Folder…”, "
                + "check the chosen .exe, then click “Add Game”.")
            XCTAssertNil(hint.target)
            game.handle(.next)
            hint = try shown(game)
            XCTAssertEqual(hint.text, "While Steam downloads a game, do not stop Steam "
                + "or quit TrailBridge: the download would break off.")
            XCTAssertNil(hint.target)
            game.handle(.next)
            hint = try shown(game)
            XCTAssertEqual(hint.label, "Game · review, step 5 of 6")
            XCTAssertEqual(hint.text, "While Steam is open, “Play” is not available. “Stop” "
                + "shows in the sidebar only while it is open.")
            // "Stop" is in the sidebar only while Steam is open.
            XCTAssertNil(hint.target)
            feed(&game) { $0.session = .windowsApp }
            XCTAssertEqual(try shown(game).target, .sidebarStop)
            feed(&game) { $0.session = .idle }
            game.handle(.next)
            hint = try shown(game)
            // The label is on the card in every state; the text follows it.
            XCTAssertEqual(hint.target, .libraryStatusChip(self.game))
            XCTAssertEqual(hint.text, "The “READY · OPENVR” label: the OpenVR plug-in is on. "
                + "Click the label to turn it off.")
            feed(&game) { $0.openVRBadges = [self.game: .none] }
            XCTAssertEqual(try shown(game).text, "This game is marked “READY”: it needs no OpenVR plug-in. "
                + "Other games may show “SET UP OPENVR” here.")
            feed(&game) { $0.openVRBadges = [self.game: .needsSetup] }
            XCTAssertEqual(try shown(game).text, "The game is marked “SET UP OPENVR”. Click that label and turn on "
                + "“OpenVR support”; if asked, click “Download and turn on”. Then click “Done”.")
            // Still a review: the label turning ready moves nothing.
            feed(&game) { $0.openVRBadges = [self.game: .installed] }
            XCTAssertEqual(game.phase, .step(.gameOpenVR))

            var options = try self.tour(.launchOptions, .review, LearningFixture.returning)
            options.handle(.next)
            hint = try shown(options)
            XCTAssertEqual(hint.label, "Launch Options · review, step 2 of 6")
            XCTAssertEqual(hint.text, "The second place to start is here: the “Game” list and “Play”. "
                + "“Change…”, then “Global Stream Settings…” opens the settings.")
            XCTAssertEqual(hint.target, .streamAdjust)
        }
    }

    // MARK: - Every state

    /// Facts a chapter can meet. Each chapter gets the ones it reads.
    private func factVariants(for chapter: LearningChapter) -> [LearningFacts] {
        let card = LearningLibraryGame(id: "steam-1", name: "Half-Life: Alyx")
        let external = LearningLibraryGame(id: "whisky-7", name: "Beat Saber", place: "CrossOver")
        let long = "The Elder Scrolls V: Skyrim VR Special Anniversary Edition"
        let live = LearningFixture.returning.with { $0.session = .live }
        switch chapter {
        case .headset:
            let onPage = LearningFixture.newcomer.with { $0.section = .headset }
            return [
                // Not asked yet; no adb at all; the wrapper with nothing
                // behind it; adb there and the question failed.
                LearningFixture.newcomer,
                onPage,
                onPage.with { $0.headsetChecked = true },
                onPage.with(LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB)),
                onPage.with(LearningFixture.headsetScanFailed("Headset command failed: protocol fault")),
                // The cable is out, here and seen from another section.
                onPage.with(LearningFixture.headset(.none)),
                onPage.with(LearningFixture.headset(.none)).with { $0.section = .library },
                onPage.with(LearningFixture.headset(.none)).with { $0.pageSheetOpen = true },
                onPage.with(LearningFixture.headset(.unauthorized)),
                // No ALVR, another ALVR, the tested one.
                onPage.with(LearningFixture.headset(.connected)),
                onPage.with(LearningFixture.headset(.connected, client: "20.11.0")),
                onPage.with(LearningFixture.headsetReady),
                // A question failed after the headset was seen.
                onPage.with(LearningFixture.headset(.connected))
                    .with(LearningFixture.headsetScanFailed("Headset command failed: device offline")),
                LearningFixture.returning.with(LearningFixture.headset(.none)).with { $0.connection = .wifi },
                live,
            ]
        case .mac:
            return [
                LearningFacts(),
                LearningFixture.unbuiltMac,
                LearningFixture.unbuiltMac.with { $0.setupChecks = LearningFixture.checks(missing: ["dxmt"]) },
                LearningFixture.unbuiltMac.with { $0.setupChecks = LearningFixture.checks(unsupportedMac: true) },
                LearningFixture.newcomer,
                LearningFixture.returning,
                live,
            ]
        case .game:
            return [
                LearningFixture.newcomer,
                LearningFixture.newcomer.with { $0.pageSheetOpen = true },
                LearningFixture.newcomer.with { $0.session = .windowsApp },
                LearningFixture.newcomer.with { $0.importRunning = true },
                LearningFixture.newcomer.with {
                    $0.libraryShowsAddButtons = false
                    $0.steamGameWithoutProfile = card
                },
                LearningFixture.newcomer.with {
                    $0.libraryShowsAddButtons = false
                    $0.externalGame = external
                },
                LearningFixture.withGame,
                LearningFixture.withGame.with { $0.session = .windowsApp },
                LearningFixture.withGame.with { $0.openVRBadges = [self.game: .needsSetup] },
                LearningFixture.withGame.with { $0.openVRBadges = [self.game: .none] },
                LearningFixture.returning,
                live,
            ]
        case .firstLaunch:
            return [LearningFixture.withGame, LearningFixture.withGame.with { $0.gameAudioOn = true },
                    LearningFixture.returning, live]
        case .launchOptions:
            return [
                LearningFixture.returning,
                LearningFixture.returning.with { $0.pageSheetOpen = true },
                LearningFixture.returning.with { $0.session = .windowsApp },
                LearningFixture.returning.with { $0.section = .stream },
                LearningFixture.returning.with {
                    $0.section = .settings
                    $0.connection = .wifi
                    $0.recommendedPresetSelected = false
                },
                LearningFixture.returning.with {
                    $0.launchableGames = [long]
                    $0.selectedGame = long
                    $0.gameWithOwnSettings = long
                    $0.openVRBadges = [long: .none]
                    $0.sessionHistory = []
                    $0.progress.quickPathCompleted = false
                    LearningFixture.headsetReady(&$0)
                },
                live,
            ]
        }
    }

    /// The states found once, for every test that walks them.
    private static var states: (all: [SetupTour], shown: [SetupTour])?

    /// Every state a chapter can get into, by any order of facts and
    /// presses. `shown` holds one state for each thing the strip can show:
    /// the same step, mode and facts reached another way reads the same.
    private func reachableStates() -> (all: [SetupTour], shown: [SetupTour]) {
        if let states = Self.states { return states }
        var all = [SetupTour]()
        var shown = [SetupTour]()
        for chapter in LearningChapter.allCases {
            let variants = factVariants(for: chapter)
            let events = variants.map(SetupTour.Event.facts)
                + [.next, .back, .checkAgain, .skip, .choose(.steam), .choose(.folder), .otherWay, .close]
            var queue = [SetupTour.Mode.firstPass, .review].flatMap { mode in
                variants.compactMap { SetupTour(chapter: chapter, mode: mode, facts: $0) }
            }
            // Looked up by what the strip shows; the few states that differ
            // only in how they were reached are compared one by one.
            var seen = [String: [SetupTour]]()
            while let state = queue.popLast() {
                let facts = variants.firstIndex(of: state.facts) ?? -1
                let key = "\(state.mode) \(state.phase) \(state.isRevisit) \(facts)"
                if seen[key]?.contains(state) == true { continue }
                if seen[key] == nil { shown.append(state) }
                seen[key, default: []].append(state)
                all.append(state)
                for event in events {
                    var next = state
                    next.handle(event)
                    if next != state { queue.append(next) }
                }
            }
        }
        Self.states = (all, shown)
        return (all, shown)
    }

    func testEveryStateKeepsTheStripsRules() throws {
        let states = reachableStates().all
        // Every step is reached, in a first pass or a review.
        XCTAssertEqual(Set(states.compactMap(\.step)), Set(Step.allCases))
        XCTAssertTrue(states.contains { $0.phase == .finished })
        XCTAssertTrue(states.contains { $0.phase == .handOff })
        for state in states {
            guard let hint = state.presentation else {
                // Nothing is drawn under a sheet or once the tour is over.
                XCTAssertTrue(state.isOver || state.facts.pageSheetOpen)
                continue
            }
            XCTAssertFalse(state.isOver)
            XCTAssertFalse(state.facts.session.isVRSession)
            XCTAssertFalse(state.facts.pageSheetOpen)
            // Never more than two buttons, never none, at most one primary.
            XCTAssertTrue((1...2).contains(hint.buttons.count), hint.id)
            XCTAssertEqual(Set(hint.buttons.map(hint.title(of:))).count, hint.buttons.count, hint.id)
            XCTAssertLessThanOrEqual(hint.buttons.filter(\.canBePrimary).count, 1, hint.id)
            // A help button always has something to open, and every button
            // but "help" changes the tour.
            if hint.buttons.contains(.help) { XCTAssertNotNil(hint.help, hint.id) }
            XCTAssertFalse(hint.help?.tips.isEmpty ?? false, hint.id)
            // "Check again" may find nothing new: the app reads the checks
            // first, and the same facts leave the step as it is.
            for button in hint.buttons + (hint.help?.options ?? [])
            where button != .help && button != .checkAgain {
                // A page in the browser and a section are the app's own
                // doing: the tour stays as it is.
                if case .link = button { XCTAssertNil(button.event, hint.id); continue }
                if case .open = button { XCTAssertNil(button.event, hint.id); continue }
                var next = state
                next.handle(try XCTUnwrap(button.event, hint.id))
                XCTAssertNotEqual(next, state, "\(hint.id): \(button)")
            }
            if hint.buttons == [.open(.headset)] {
                // The user left the page of a step that waits on it. The
                // strip offers that page; it does not pull the user back.
                let step = try XCTUnwrap(state.step, hint.id)
                XCTAssertEqual(step.chapter, .headset, hint.id)
                XCTAssertNotEqual(state.facts.section, .headset, hint.id)
                XCTAssertTrue(state.waitsByItself(step), hint.id)
                XCTAssertNil(hint.section, hint.id)
                XCTAssertNil(hint.target, hint.id)
                XCTAssertTrue(hint.id.hasSuffix("-away"), hint.id)
                continue
            }
            XCTAssertFalse(hint.id.hasSuffix("-away"), hint.id)
            // "Back" is offered exactly when there is a step to go back to.
            XCTAssertEqual(hint.buttons.contains(.back), state.hasPrevious, hint.id)
            // A step that lives on a page asks for that page, and only then.
            if let step = state.step {
                XCTAssertEqual(hint.section, step.section == state.facts.section ? nil : step.section, hint.id)
            } else {
                XCTAssertNil(hint.section)
                XCTAssertNil(hint.target)
            }
            // A review never waits: no step of it is without "Next".
            if state.mode == .review, state.step != nil {
                XCTAssertEqual(hint.buttons.last, .next, hint.id)
                XCTAssertFalse(hint.buttons.contains(.help), hint.id)
            }
        }
    }

    /// Outlines point only at what the facts say is on screen.
    func testTargetsFollowTheFacts() {
        for state in reachableStates().all {
            guard let target = state.presentation?.target else { continue }
            let facts = state.facts
            switch target {
            case .libraryAddButtons, .libraryAddSteam, .libraryAddFolder:
                XCTAssertTrue(facts.libraryShowsAddButtons)
            case .libraryGameAction(let id):
                XCTAssertTrue([facts.steamGameWithoutProfile?.id, facts.externalGame?.id].contains(id))
            case .libraryStatusChip(let name), .libraryGameTile(let name):
                XCTAssertTrue(facts.launchableGames.contains(name))
            case .sidebarStop:
                XCTAssertEqual(facts.session, .windowsApp)
            case .headsetGetTools:
                // By the Headset page's own rule for showing the button.
                XCTAssertEqual(facts.headsetTools, .missing)
            case .headsetInstall:
                XCTAssertEqual(facts.headsetConnection, .connected)
                XCTAssertNotEqual(facts.headsetClientVersion, PinnedHeadsetDownload.testedALVR.version)
            case .headsetStatus:
                // The card is on the page in every state. A review points
                // at it only for what it says now.
                if state.mode == .review, state.step == .headsetDebugging {
                    XCTAssertEqual(facts.headsetConnection, .unauthorized)
                }
            case .setupSummary, .streamAdjust, .streamRecentSessions, .settingsConnection,
                 .settingsUseRecommended:
                break
            }
        }
    }

    /// The strip holds 160 characters. Every hint of every chapter keeps to
    /// that in all ten tables, with real names put in.
    func testNoHintIsLongerThanTheStripHoldsInAnyLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        XCTAssertEqual(SetupTour.hintLimit, 160)
        let states = reachableStates().shown
        XCTAssertGreaterThan(states.count, 300)
        for language in AppLanguage.allCases {
            L10n.language = language
            var longest = ""
            for state in states {
                guard let hint = state.presentation else { continue }
                XCTAssertLessThanOrEqual(hint.text.count, SetupTour.hintLimit,
                                         "\(language) \(hint.id): \(hint.text)")
                XCTAssertFalse(hint.text.isEmpty, "\(language) \(hint.id)")
                XCTAssertFalse(hint.text.contains("%"), "\(language) \(hint.id): \(hint.text)")
                XCTAssertFalse(hint.label.isEmpty, "\(language) \(hint.id)")
                XCTAssertFalse(hint.label.contains("%"), "\(language) \(hint.id): \(hint.label)")
                for title in hint.buttons.map(hint.title(of:)) + [hint.help?.title ?? "-"] {
                    XCTAssertFalse(title.isEmpty, "\(language) \(hint.id)")
                }
                for tip in hint.help?.tips ?? [] {
                    XCTAssertFalse(tip.isEmpty, "\(language) \(hint.id)")
                    XCTAssertFalse(tip.contains("%"), "\(language) \(hint.id): \(tip)")
                }
                if hint.text.count > longest.count { longest = hint.text }
            }
            XCTAssertGreaterThan(longest.count, 60, "\(language)")
        }
    }

    /// The same for "Headset", over every state and not one per step: its
    /// tools step reads differently with the opening sentence in front, and
    /// a waiting step differently once the user has left the page.
    func testNoHeadsetHintIsLongerThanTheStripHoldsInAnyLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let states = reachableStates().all.filter { $0.chapter == .headset }
        XCTAssertTrue(states.contains { $0.headsetIntro == .withTools })
        XCTAssertTrue(states.contains { $0.isAway && $0.presentation?.buttons == [.open(.headset)] })
        for language in AppLanguage.allCases {
            L10n.language = language
            var texts = Set<String>()
            for state in states {
                guard let hint = state.presentation else { continue }
                texts.insert(hint.text)
                for tip in hint.help?.tips ?? [] {
                    XCTAssertFalse(tip.isEmpty, "\(language) \(hint.id)")
                    XCTAssertFalse(tip.contains("%"), "\(language) \(hint.id): \(tip)")
                }
            }
            // Every text of the chapter: 7 steps, their states, the review.
            XCTAssertGreaterThanOrEqual(texts.count, 20, "\(language)")
            for text in texts {
                XCTAssertLessThanOrEqual(text.count, SetupTour.hintLimit, "\(language): \(text)")
                XCTAssertFalse(text.contains("%"), "\(language): \(text)")
            }
        }
    }

    /// A hint names a control by the control's own text, in every language.
    func testHintsNameControlsWithTheControlsOwnTextInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            func text(_ chapter: LearningChapter, _ facts: LearningFacts, at step: Step) throws -> String {
                let tour = try tour(chapter, facts, resumeAt: step.rawValue)
                XCTAssertEqual(tour.step, step, "\(language)")
                return try shown(tour).text
            }
            func expect(_ text: String, names keys: L10nKey...) {
                for key in keys {
                    XCTAssertTrue(text.contains(L10n.string(key)), "\(language): \(key) in \(text)")
                }
            }
            let unbuilt = LearningFixture.unbuiltMac
            expect(try text(.mac, unbuilt, at: .macWhoBuilds), names: .learningRecheck)
            expect(try shown(try tour(.mac, .review, LearningFixture.returning)).text, names: .setupBuildHelp)

            let newcomer = LearningFixture.newcomer
            expect(try text(.game, newcomer, at: .gameChoose),
                   names: .learningGameFromSteam, .learningGameFromFolder)
            for facts in [newcomer, newcomer.with { $0.libraryShowsAddButtons = false }] {
                expect(try text(.game, facts, at: .gameSteam),
                       names: .libraryAddSteam, .wizardOtherGame, .commonNext)
                expect(try text(.game, facts, at: .gameFolder),
                       names: .libraryAddGameFolder, .folderImportChooseFolder, .folderImportAdd)
            }
            let profile = newcomer.with {
                $0.steamGameWithoutProfile = LearningLibraryGame(id: "1", name: "Blood Trail")
            }
            expect(try text(.game, profile, at: .gameCreateProfile), names: .libraryCreateProfile, .libraryPlay)
            let copy = newcomer.with {
                $0.externalGame = LearningLibraryGame(id: "2", name: "Blood Trail", place: "Whisky")
            }
            expect(try text(.game, copy, at: .gameCopy), names: .libraryCopy)
            XCTAssertTrue(try text(.game, copy, at: .gameCopy).contains("Whisky"), "\(language)")
            let waiting = newcomer.with { $0.session = .windowsApp }
            expect(try text(.game, waiting, at: .gameWait), names: .libraryPlay)
            let stop = LearningFixture.withGame.with { $0.session = .windowsApp }
            expect(try text(.game, stop, at: .gameStopSteam), names: .libraryPlay, .commonStop)
            let label = LearningFixture.withGame.with { $0.openVRBadges = [self.game: .needsSetup] }
            expect(try text(.game, label, at: .gameOpenVR),
                   names: .libraryOpenVRSetup, .openVRTitle, .openVRDownloadEnable, .sheetDone)

            let options = optionsFacts
            expect(try text(.launchOptions, options.with { $0.session = .windowsApp }, at: .optionsStop),
                   names: .streamAdjust, .commonStop)
            expect(try text(.launchOptions, options, at: .optionsLibrary), names: .libraryPlay)
            expect(try text(.launchOptions, options, at: .optionsStream),
                   names: .streamGame, .libraryPlay, .streamAdjust, .streamGlobalSettings)
            expect(try text(.launchOptions, options, at: .optionsConnection),
                   names: .streamConnection, .connectionUSB, .libraryPlay)
            expect(try text(.launchOptions, options.with { $0.connection = .wifi }, at: .optionsConnection),
                   names: .streamConnection, .connectionWiFi, .libraryPlay)
            expect(try text(.launchOptions, options, at: .optionsRecommended), names: .settingsUseRecommended)
            expect(try text(.launchOptions, LearningFixture.returning, at: .optionsRecommended),
                   names: .settingsUseRecommended)
            expect(try text(.launchOptions, options, at: .optionsOwnSettings), names: .streamAdjust)
            var ownTour = try tour(.launchOptions, options.with { $0.gameWithOwnSettings = self.game },
                                   resumeAt: Step.optionsOwnConnection.rawValue)
            XCTAssertEqual(ownTour.step, .optionsOwnConnection)
            let own = try shown(ownTour).text
            ownTour.handle(.next)
            XCTAssertTrue(own.contains(game), "\(language)")
            // The menu item's own text, with "…" where the game's name goes.
            let item = L10n.string(.streamProfileSettings, "…").replacingOccurrences(of: "……", with: "…")
            XCTAssertTrue(own.contains(item), "\(language): \(own)")
            XCTAssertFalse(own.contains("……"), "\(language)")

            // Button titles.
            let end = try shown(try tour(.mac, LearningFixture.newcomer))
            XCTAssertEqual(end.buttons.map(end.title(of:)),
                           [L10n.string(.learningChapterGoOn), L10n.string(.learningChapterLater)])
            XCTAssertTrue(end.text.contains(LearningChapter.mac.title), "\(language)")
            XCTAssertTrue(end.text.contains(LearningChapter.headset.title), "\(language)")
            XCTAssertEqual(end.title(of: .back), L10n.string(.commonBack))
            XCTAssertEqual(end.title(of: .next), L10n.string(.commonNext))
            XCTAssertEqual(end.title(of: .checkAgain), L10n.string(.learningRecheck))
            XCTAssertEqual(end.title(of: .skip), L10n.string(.learningSkipStep))
            XCTAssertEqual(end.title(of: .help), L10n.string(.learningStuck))
            XCTAssertEqual(SetupPresentation.closeTitle, L10n.string(.learningCloseTour))
        }
    }

    // MARK: - Marks in the Library

    /// A Steam game with a profile is on the page twice. Only one of its
    /// cards is marked, so a step outlines one control and scrolls to it.
    func testEachProfileIsMarkedOnExactlyOneCard() {
        typealias Card = LearningLibraryMarks.Card
        // The page's order: Steam cards, BSManager versions, launch profiles.
        let cards = [
            Card(id: "steam:1", profile: "BRUTALISTICK VR"),
            Card(id: "steam:2", profile: nil),
            Card(id: "steam:3", profile: "Blood Trail"),
            Card(id: "bs:1", profile: "Beat Saber 1.40"),
            Card(id: "bs:2", profile: nil),
            Card(id: "direct:1", profile: "BRUTALISTICK VR"),
            Card(id: "direct:2", profile: "Blood Trail"),
            Card(id: "direct:3", profile: "Folder Game"),
            Card(id: "direct:4", profile: nil),
            Card(id: "direct:5", profile: "Folder Game"),
        ]
        let marked = LearningLibraryMarks.markedCards(cards)
        XCTAssertEqual(marked, ["steam:1", "steam:3", "bs:1", "direct:3"])
        // Every profile is marked once, on the first card that shows it.
        for profile in Set(cards.compactMap(\.profile)) {
            let own = cards.filter { $0.profile == profile }
            XCTAssertEqual(own.filter { marked.contains($0.id) }.map(\.id), [own[0].id], profile)
        }
        // A card without a profile has nothing to mark.
        XCTAssertTrue(cards.filter { $0.profile == nil }.allSatisfy { !marked.contains($0.id) })
        // Without its Steam card (hidden by a filter) the profile's own card is marked.
        XCTAssertEqual(LearningLibraryMarks.markedCards(Array(cards.dropFirst(3))),
                       ["bs:1", "direct:1", "direct:2", "direct:3"])
        XCTAssertEqual(LearningLibraryMarks.markedCards([]), [])
    }

    /// Every target a step can ask for is its own value, on one page.
    func testTargetsAreDistinctAndEachBelongsToOnePage() {
        var targets = Set<SetupTarget>()
        for state in reachableStates().all {
            if let target = state.presentation?.target { targets.insert(target) }
        }
        let fixed: [SetupTarget] = [
            .headsetStatus, .headsetGetTools, .headsetInstall,
            .setupSummary, .libraryAddButtons, .libraryAddSteam, .libraryAddFolder, .sidebarStop,
            .streamAdjust, .streamRecentSessions, .settingsConnection, .settingsUseRecommended,
        ]
        XCTAssertEqual(Set(fixed).count, fixed.count)
        XCTAssertTrue(Set(fixed).isSubset(of: targets))
        // The marks on a card differ by kind even for one game.
        XCTAssertEqual(Set<SetupTarget>([.libraryGameAction("a"), .libraryStatusChip("a"),
                                         .libraryGameTile("a"), .libraryGameTile("b")]).count, 4)
        for state in reachableStates().all {
            guard let hint = state.presentation, let target = hint.target, let step = state.step else { continue }
            // A target is on the page its step lives on, or in the sidebar.
            if let page = target.section {
                XCTAssertEqual(page, step.section, hint.id)
            } else {
                XCTAssertEqual(target, .sidebarStop, hint.id)
            }
        }
    }

    /// The app opens a step's section when the step is first shown, and
    /// leaves the section alone when the same step is only drawn again.
    func testASectionOpensOnlyForANewlyShownStep() throws {
        var tour = try tour(.launchOptions, optionsFacts)
        let library = try shown(tour)
        XCTAssertEqual(library.opensSection(afterShowing: nil), .library)
        XCTAssertNil(library.opensSection(afterShowing: library.id))
        // Drawn again in another language: the same id.
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        let russian = try shown(tour)
        L10n.language = .en
        let english = try shown(tour)
        XCTAssertNotEqual(russian.text, english.text)
        XCTAssertEqual(russian.id, english.id)

        tour.handle(.next)
        let stream = try shown(tour)
        XCTAssertNotEqual(stream.id, library.id)
        XCTAssertEqual(stream.opensSection(afterShowing: library.id), .stream)
        // On its own page a step asks for nothing.
        feed(&tour) { $0.section = .stream }
        XCTAssertNil(try shown(tour).opensSection(afterShowing: library.id))
        // A step reached with "Back" is a new showing; a review has its own ids.
        feed(&tour) { $0.section = .settings }
        tour.handle(.back)
        XCTAssertNotEqual(try shown(tour).id, stream.id)
        XCTAssertEqual(try shown(tour).opensSection(afterShowing: stream.id), .stream)
        let review = try shown(try self.tour(.launchOptions, .review, LearningFixture.returning))
        XCTAssertNotEqual(review.id, library.id)
        // Every step and both modes have ids of their own.
        var ids = Set<String>()
        for state in reachableStates().shown {
            guard let hint = state.presentation, let step = state.step else { continue }
            ids.insert(hint.id)
            XCTAssertTrue(hint.id.contains(step.rawValue), hint.id)
        }
        XCTAssertGreaterThanOrEqual(ids.count, Step.allCases.count)
    }
}
