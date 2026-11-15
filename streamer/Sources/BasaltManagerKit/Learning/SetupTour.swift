import Foundation

/// One chapter of the Learning program, walked step by step on the app's
/// real controls. A value with no clock, timers or I/O: the app feeds it
/// facts and button presses, and shows what `presentation` describes.
///
/// A first pass waits on a step until the app sees its result, and skips
/// what is already done. A review of a chapter that is done waits for
/// nothing: "Back" and "Next" only.
public struct SetupTour: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case firstPass, review }

    /// How a game is added, chosen on the first step of "Game".
    public enum Branch: String, Equatable, Sendable { case steam, folder }

    /// How the opening sentence of "Headset" gets said in a first pass.
    enum HeadsetIntro: Equatable, Sendable {
        /// Not at all: the pass was resumed.
        case none
        /// Still to be said.
        case pending
        /// As the first words of the tools step, which had something to do.
        case withTools
        /// On a card of its own, which was answered.
        case said
    }

    public enum Step: String, CaseIterable, Sendable {
        // Mac
        /// The Setup page's summary: what is missing, in plain words. In a
        /// review of a ready Mac it only says so.
        case macSummary
        /// Who builds the missing parts; "Check again".
        case macWhoBuilds

        // Headset
        /// The chapter's opening sentence on a card of its own, when the
        /// first step is not the USB tools: only that step has room for it.
        case headsetIntro
        /// "Get Android Platform Tools…".
        case headsetTools
        /// A Meta developer account, made on Meta's site.
        case headsetAccount
        /// Developer Mode, switched on in the phone.
        case headsetDeveloperMode
        case headsetCable
        /// The USB debugging request in the headset.
        case headsetDebugging
        /// "Install on Headset…".
        case headsetInstall
        /// ALVR is opened in the headset once.
        case headsetOpenALVR

        // Game
        /// A Steam game is already in a TrailBridge environment: its card
        /// offers "Create Profile".
        case gameCreateProfile
        /// A game sits in Whisky or CrossOver: its card offers "Copy…".
        case gameCopy
        /// Steam or a folder: answered with the strip's own two buttons.
        case gameChoose
        /// What to do in the Steam wizard, said before it opens.
        case gameSteam
        /// What to do in the folder import, said before it opens.
        case gameFolder
        /// The window was closed and the game is still on its way.
        case gameWait
        /// Steam stayed open, so Play is greyed out.
        case gameStopSteam
        /// The game's label asks for the OpenVR plug-in.
        case gameOpenVR

        // First launch
        /// The one thing to say before the quick path takes over.
        case launchMicrophone

        // Launch options
        /// Steam is open, so "Change…" is greyed out.
        case optionsStop
        case optionsLibrary
        case optionsStream
        case optionsConnection
        /// The game has its own stream settings: the switch just shown does
        /// not apply to it.
        case optionsOwnConnection
        case optionsRecommended
        case optionsOwnSettings
        case optionsHistory

        public var chapter: LearningChapter {
            switch self {
            case .macSummary, .macWhoBuilds: return .mac
            case .headsetIntro, .headsetTools, .headsetAccount, .headsetDeveloperMode, .headsetCable,
                 .headsetDebugging, .headsetInstall, .headsetOpenALVR: return .headset
            case .gameChoose, .gameCreateProfile, .gameCopy, .gameSteam, .gameFolder,
                 .gameWait, .gameStopSteam, .gameOpenVR: return .game
            case .launchMicrophone: return .firstLaunch
            case .optionsStop, .optionsLibrary, .optionsStream, .optionsConnection,
                 .optionsOwnConnection, .optionsRecommended, .optionsOwnSettings,
                 .optionsHistory: return .launchOptions
            }
        }

        /// "Step N of M" in a first pass. Steps that stand for the same
        /// place on the way share a number; nil for a card outside the count.
        public var number: Int? {
            switch self {
            case .macSummary: return 1
            case .macWhoBuilds: return 2
            case .headsetIntro: return nil
            case .headsetTools: return 1
            case .headsetAccount: return 2
            case .headsetDeveloperMode: return 3
            case .headsetCable: return 4
            case .headsetDebugging: return 5
            case .headsetInstall: return 6
            case .headsetOpenALVR: return 7
            case .gameChoose, .gameCreateProfile, .gameCopy: return 1
            case .gameSteam, .gameFolder: return 2
            case .gameWait: return 3
            case .gameStopSteam: return 4
            case .gameOpenVR: return 5
            case .launchMicrophone, .optionsStop: return nil
            case .optionsLibrary: return 1
            case .optionsStream: return 2
            case .optionsConnection, .optionsOwnConnection: return 3
            case .optionsRecommended: return 4
            case .optionsOwnSettings: return 5
            case .optionsHistory: return 6
            }
        }

        /// The section the step's control is in; nil when it lives on no page.
        var section: LearningDestination? {
            switch self {
            case .macSummary, .macWhoBuilds: return .setup
            // The steps done in the phone or the headset live here too:
            // only the open Headset page asks the headset.
            case .headsetIntro, .headsetTools, .headsetAccount, .headsetDeveloperMode, .headsetCable,
                 .headsetDebugging, .headsetInstall, .headsetOpenALVR: return .headset
            case .gameChoose, .gameCreateProfile, .gameCopy, .gameSteam, .gameFolder,
                 .gameOpenVR, .optionsLibrary: return .library
            case .gameWait, .gameStopSteam, .launchMicrophone, .optionsStop: return nil
            case .optionsStream, .optionsOwnSettings, .optionsHistory: return .stream
            case .optionsConnection, .optionsOwnConnection, .optionsRecommended: return .settings
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        case step(Step)
        /// The end-of-chapter line is shown: the chapter is completed.
        case finished
        /// The chapter's own cards are over and the quick path takes it
        /// from here ("First launch").
        case handOff
        /// Stopped before the end: closed, or a VR session began. A first
        /// pass remembers `pausedStep`.
        case stopped
        /// The end-of-chapter line was answered or closed.
        case closed
    }

    public enum Event: Equatable, Sendable {
        /// The facts as they are now. Feed every change while a step is shown.
        case facts(LearningFacts)
        /// "Next".
        case next
        case back
        /// "Check again". The app reads the Mac's checks again and feeds
        /// the new facts before it sends this.
        case checkAgain
        /// "Skip this step", inside "Not working?".
        case skip
        /// The first step of "Game" was answered.
        case choose(Branch)
        /// "Add another game": not the way the facts suggested.
        case otherWay
        /// The strip's close button; also sent when the quick path or
        /// launch advice takes the strip.
        case close
    }

    public let chapter: LearningChapter
    public let mode: Mode
    public private(set) var phase = Phase.stopped
    public private(set) var facts: LearningFacts
    /// The shown step was reached with "Back". It then waits for "Next"
    /// instead of counting itself, so "Back" never jumps forward again.
    public private(set) var isRevisit = false
    /// The chapter was walked to its end. The app records that for a
    /// first pass; a review of a chapter that is done changes no record.
    public private(set) var isCompleted = false
    /// The step a first pass stopped at, for the chapter's record.
    public private(set) var pausedStep: Step?
    public private(set) var branch: Branch?

    /// A sheet was opened and closed on the way: the user has acted, so a
    /// game may be on its way.
    private var hasActed = false
    private var choseOtherWay = false
    private var skippedOpenVR = false
    private(set) var headsetIntro = HeadsetIntro.none
    /// "Headset": the steps done outside the app that are behind. Answered
    /// with "Done", or shown to be done by the headset on the cable.
    private var confirmed = Set<Step>()
    /// "Headset": the tested ALVR was seen on the headset, or the step was
    /// skipped. The last step then stays, cable or no cable.
    private var installBehind = false
    /// The user left the page of a step that waits on it.
    private(set) var isAway = false
    /// For a step that counts a change (the Settings section opens, the
    /// recommended preset gets selected): the state before the change was
    /// seen while the step was shown.
    private var isArmed = false

    /// The longest hint the strip is given, in characters.
    public static let hintLimit = 160

    // MARK: - Chapters

    static func steps(of chapter: LearningChapter) -> [Step] {
        Step.allCases.filter { $0.chapter == chapter }
    }

    /// False for a chapter that has no steps of its own: its row opens its
    /// section instead. Every chapter has steps now.
    public static func hasSteps(_ chapter: LearningChapter) -> Bool {
        !steps(of: chapter).isEmpty
    }

    /// The section a chapter without steps opens.
    static func section(of chapter: LearningChapter) -> LearningDestination {
        switch chapter {
        case .mac: return .setup
        case .headset: return .headset
        case .game: return .library
        case .firstLaunch, .launchOptions: return .stream
        }
    }

    /// The M of "Step N of M" in a first pass.
    public static func stepCount(of chapter: LearningChapter) -> Int {
        steps(of: chapter).compactMap(\.number).max() ?? 0
    }

    /// The steps a review walks, in order.
    private static func reviewSteps(of chapter: LearningChapter) -> [Step] {
        switch chapter {
        case .mac: return [.macSummary]
        case .headset:
            return [.headsetIntro, .headsetTools, .headsetAccount, .headsetDeveloperMode,
                    .headsetCable, .headsetDebugging, .headsetInstall, .headsetOpenALVR]
        case .firstLaunch: return []
        case .game:
            return [.gameChoose, .gameSteam, .gameFolder, .gameWait, .gameStopSteam, .gameOpenVR]
        case .launchOptions:
            return [.optionsLibrary, .optionsStream, .optionsConnection, .optionsOwnConnection,
                    .optionsRecommended, .optionsOwnSettings, .optionsHistory]
        }
    }

    // MARK: - Start

    /// Nil for a chapter without steps of its own. `pausedStep` is the name
    /// the chapter's record holds; an unknown one starts the chapter over.
    public init?(chapter: LearningChapter, mode: Mode, facts: LearningFacts,
                 resumeAt pausedStep: String? = nil) {
        guard Self.hasSteps(chapter) else { return nil }
        self.chapter = chapter
        self.mode = mode
        self.facts = facts
        // Learning does nothing while a game runs.
        guard !facts.session.isVRSession else { return }

        let paused = pausedStep.flatMap(Step.init(rawValue:)).flatMap { $0.chapter == chapter ? $0 : nil }
        switch mode {
        case .review:
            move(to: Self.reviewSteps(of: chapter).first(where: applies))
        case .firstPass where chapter == .game:
            switch paused {
            case .gameSteam: branch = .steam
            case .gameFolder: branch = .folder
            case .gameWait: hasActed = true
            default: break
            }
            move(to: gameRoute())
        case .firstPass where chapter == .headset:
            switch paused {
            // From the start, with the opening sentence.
            case nil, .headsetIntro: headsetIntro = .pending
            case .headsetDeveloperMode: confirmed = [.headsetAccount]
            case .headsetCable, .headsetDebugging, .headsetInstall:
                confirmed = [.headsetAccount, .headsetDeveloperMode]
            case .headsetOpenALVR:
                confirmed = [.headsetAccount, .headsetDeveloperMode]
                installBehind = true
            default: break
            }
            noteHeadset()
            move(to: headsetRoute())
        case .firstPass:
            let steps = Self.steps(of: chapter)
            let start = paused.flatMap(steps.firstIndex(of:)) ?? 0
            move(to: steps[start...].first(where: applies))
        }
    }

    public var step: Step? {
        if case .step(let step) = phase { return step }
        return nil
    }

    /// Nothing more is shown.
    public var isOver: Bool { phase == .handOff || phase == .stopped || phase == .closed }

    /// "Game" is waiting for a download or a copy to finish. The "Ready for
    /// VR" card must not offer to stop Steam meanwhile.
    public var waitsForGame: Bool { step == .gameWait && !facts.hasLaunchableGame }

    /// The same for a chapter that is not shown now, from its record.
    public static func waitsForGame(in facts: LearningFacts) -> Bool {
        facts.chapters[.game].pausedStep == Step.gameWait.rawValue && !facts.hasLaunchableGame
            && (facts.session == .windowsApp || facts.importRunning)
    }

    // MARK: - Events

    public mutating func handle(_ event: Event) {
        guard !isOver else { return }
        switch event {
        case .facts(let new):
            factsChanged(to: new)
        case .close:
            stop()
        case .next:
            guard let step else {
                phase = .closed
                return
            }
            next(after: step)
        case .back:
            guard let step, let previous = previousStep(before: step) else { return }
            // Back at the question: it is asked again.
            if previous == .gameChoose { branch = nil }
            // Back at a step answered with "Done": it is asked again, and
            // so are the ones after it.
            confirmed.subtract(Self.steps(of: chapter).drop { $0 != previous })
            show(previous, revisit: true)
        case .checkAgain:
            guard step != nil, mode == .firstPass else { return }
            isRevisit = false
            reroute()
        case .skip:
            guard step == .gameOpenVR || step == .headsetInstall, mode == .firstPass else { return }
            if step == .headsetInstall { installBehind = true } else { skippedOpenVR = true }
            isRevisit = false
            reroute()
        case .choose(let chosen):
            guard step == .gameChoose, mode == .firstPass else { return }
            branch = chosen
            move(to: gameRoute())
        case .otherWay:
            guard step == .gameCreateProfile || step == .gameCopy, mode == .firstPass else { return }
            choseOtherWay = true
            move(to: gameRoute())
        }
    }

    private mutating func factsChanged(to new: LearningFacts) {
        let sheetClosed = facts.pageSheetOpen && !new.pageSheetOpen
        if chapter == .headset, mode == .firstPass, let page = step?.section {
            // Back on the step's page, or gone from it while it was shown.
            if new.section == page { isAway = false } else if facts.section == page { isAway = true }
        }
        facts = new
        if new.session.isVRSession {
            stop()
            return
        }
        if sheetClosed { hasActed = true }
        guard let step, mode == .firstPass else { return }
        noteHeadset()
        if !condition(of: step) { isArmed = true }
        // While a sheet is open nothing moves: it has its own steps.
        guard !new.pageSheetOpen, !isRevisit else { return }
        if chapter == .game || chapter == .headset {
            // These two go by the facts alone. In "Game" the question
            // stays until it is answered or a game is there.
            reroute()
        } else if !applies(step) || (isArmed && condition(of: step)) {
            reroute()
        }
    }

    /// Shows the step the facts ask for now.
    private mutating func reroute() {
        guard let step else { return }
        if chapter == .game {
            move(to: gameRoute())
        } else if chapter == .headset {
            move(to: headsetRoute())
        } else if applies(step), !(isArmed && condition(of: step)) {
            show(step)
        } else {
            move(to: stepAfter(step))
        }
    }

    private mutating func next(after step: Step) {
        switch mode {
        case .review:
            move(to: stepAfter(step))
        case .firstPass:
            if waitsByItself(step) {
                // Reached with "Back", it counts itself again from here.
                guard isRevisit else { return }
                isRevisit = false
                reroute()
            } else if chapter == .headset {
                // "Next" on the opening card, or "Done" on a step that is
                // done outside the app.
                if step == .headsetIntro { headsetIntro = .said } else { confirmed.insert(step) }
                move(to: headsetRoute())
            } else if step != .gameChoose {
                move(to: stepAfter(step))
            }
        }
    }

    /// The next step of the chapter that has something to say.
    private func stepAfter(_ step: Step) -> Step? {
        let steps = mode == .review ? Self.reviewSteps(of: chapter) : Self.steps(of: chapter)
        guard let index = steps.firstIndex(of: step) else { return nil }
        return steps[(index + 1)...].first(where: applies)
    }

    /// The nearest earlier step of the chapter that still has something to
    /// say. It goes by the chapter's order and the facts, not by what was
    /// shown, so "Back" works right after "Continue" too.
    private func previousStep(before step: Step) -> Step? {
        // The question's two answers take both button places.
        if mode == .firstPass, step == .gameChoose { return nil }
        let steps = mode == .review ? Self.reviewSteps(of: chapter) : Self.steps(of: chapter)
        guard let index = steps.firstIndex(of: step) else { return nil }
        return steps[..<index].last(where: canReturn(to:))
    }

    /// A step, or the chapter's end when there is none left.
    private mutating func move(to step: Step?) {
        if let step {
            show(step)
        } else {
            end()
        }
    }

    private mutating func show(_ step: Step, revisit: Bool = false) {
        // A new step asks for its page again.
        if self.step != step { isAway = false }
        phase = .step(step)
        isRevisit = revisit
        isArmed = !condition(of: step)
    }

    /// No step is left. "First launch" goes on as the quick path. Any other
    /// chapter is completed when its facts say so; a first pass that ran
    /// out of steps before that stays where it is. "Headset" ends on the
    /// user's word, as "Launch options" does: its last step is done in the
    /// headset, and an ALVR installed another way is not seen from here.
    private mutating func end() {
        if chapter == .firstLaunch {
            phase = .handOff
        } else if mode == .review || chapter == .launchOptions || chapter == .headset
                    || facts.isDone(chapter) {
            isCompleted = true
            phase = .finished
        }
    }

    private mutating func stop() {
        if case .finished = phase {
            phase = .closed
            return
        }
        if mode == .firstPass { pausedStep = step }
        phase = .stopped
    }

    // MARK: - What the facts say

    /// Whether the step has something to say now.
    private func applies(_ step: Step) -> Bool {
        if mode == .review {
            switch step {
            case .optionsOwnConnection: return facts.gameWithOwnSettings != nil
            case .gameOpenVR, .optionsLibrary: return facts.selectedGame != nil
            default: return true
            }
        }
        switch step {
        case .macSummary: return !facts.macReady
        // An unsupported Mac has nothing anyone could build, and without
        // the checks nobody knows what is missing.
        case .macWhoBuilds: return !facts.macReady && !macUnsupported && !facts.setupChecks.isEmpty
        case .launchMicrophone: return facts.gameAudioOn
        case .optionsStop: return facts.session == .windowsApp
        case .optionsOwnConnection: return facts.gameWithOwnSettings != nil
        default: return true
        }
    }

    /// Whether "Back" may show the step again. The steps of "Game" are
    /// shown by facts and answers, so each one says when it belongs to the
    /// way that was taken.
    private func canReturn(to step: Step) -> Bool {
        guard mode == .firstPass, step.chapter == .game || step.chapter == .headset else {
            return applies(step)
        }
        let suggested = facts.steamGameWithoutProfile != nil || facts.externalGame != nil
        switch step {
        case .gameCreateProfile:
            return !facts.hasLaunchableGame && !choseOtherWay && facts.steamGameWithoutProfile != nil
        case .gameCopy:
            return !facts.hasLaunchableGame && !choseOtherWay && facts.steamGameWithoutProfile == nil
                && facts.externalGame != nil
        case .gameChoose:
            return !facts.hasLaunchableGame && (choseOtherWay || !suggested)
        case .gameSteam: return branch == .steam
        case .gameFolder: return branch == .folder
        case .gameWait: return gameRoute() == .gameWait
        case .gameStopSteam: return gameRoute() == .gameStopSteam
        // "Headset": only what is still to do can be read again. Once the
        // Mac sees the headset, the account and Developer Mode are behind.
        case .headsetAccount, .headsetDeveloperMode:
            return facts.headsetTools == .ready && !facts.headsetSeen && !installBehind
        // The step was skipped, and its button is still on the page.
        case .headsetInstall: return facts.headsetTools == .ready && facts.headsetShowsInstall
        case .headsetIntro, .headsetTools, .headsetCable, .headsetDebugging: return false
        default: return true
        }
    }

    /// The change a step waits for, when it counts a change rather than a
    /// state: a step shown while the state already holds says so and waits
    /// for "Next".
    private func condition(of step: Step) -> Bool {
        switch step {
        case .optionsStream: return facts.section == .settings
        case .optionsRecommended: return facts.recommendedPresetSelected
        default: return false
        }
    }

    /// A step a first pass leaves by itself, when the app sees its result.
    /// It has no "Next" unless it was reached with "Back".
    func waitsByItself(_ step: Step) -> Bool {
        switch step {
        case .macWhoBuilds, .optionsStop, .optionsStream: return true
        // Nothing to read on: the checks did not arrive, or the Mac itself
        // is not supported.
        case .macSummary: return macUnsupported || facts.setupChecks.isEmpty
        case .headsetTools, .headsetCable, .headsetDebugging, .headsetInstall: return true
        // The card to read, and what is done on a site, in the phone and
        // in the headset: the app cannot see it, the user says "Done".
        case .headsetIntro, .headsetAccount, .headsetDeveloperMode, .headsetOpenALVR: return false
        case .gameChoose: return false
        default: return step.chapter == .game
        }
    }

    var macUnsupported: Bool {
        facts.setupChecks.contains { $0.id == "mac" && $0.status != .ready }
    }

    /// What the headset on the cable has shown so far in a first pass of
    /// "Headset". It is kept: a cable taken out later undoes none of it.
    private mutating func noteHeadset() {
        guard chapter == .headset, mode == .firstPass else { return }
        // The tools step is shown with something to do, and the opening
        // sentence with it.
        if headsetIntro == .pending, facts.headsetTools == .missing || facts.headsetTools == .failed {
            headsetIntro = .withTools
        }
        // A status under a failed question may be an old one.
        guard facts.headsetTools == .ready else { return }
        if facts.headsetSeen { confirmed.formUnion([.headsetAccount, .headsetDeveloperMode]) }
        if facts.headsetConnection == .connected, facts.headsetHasTestedClient { installBehind = true }
    }

    /// The step of "Headset" the facts ask for; nil when the last one was
    /// answered.
    private func headsetRoute() -> Step? {
        if installBehind {
            return confirmed.contains(.headsetOpenALVR) ? nil : .headsetOpenALVR
        }
        // Without the tools nothing below can be seen.
        guard facts.headsetTools == .ready else { return .headsetTools }
        if headsetIntro == .pending { return .headsetIntro }
        switch facts.headsetConnection {
        case .noTools, .none:
            if !confirmed.contains(.headsetAccount) { return .headsetAccount }
            if !confirmed.contains(.headsetDeveloperMode) { return .headsetDeveloperMode }
            return .headsetCable
        case .unauthorized:
            return .headsetDebugging
        case .connected:
            // With the tested ALVR on it, `installBehind` is already set.
            return .headsetInstall
        }
    }

    /// The step of "Game" the facts ask for; nil when the chapter is done.
    private func gameRoute() -> Step? {
        if facts.hasLaunchableGame {
            // Play is greyed out while Steam is open, and so is the OpenVR
            // switch: Steam goes first.
            if facts.session == .windowsApp { return .gameStopSteam }
            if facts.gameNeedingOpenVR != nil, !skippedOpenVR { return .gameOpenVR }
            return nil
        }
        if hasActed, facts.session == .windowsApp || facts.importRunning { return .gameWait }
        if !choseOtherWay {
            if facts.steamGameWithoutProfile != nil { return .gameCreateProfile }
            if facts.externalGame != nil { return .gameCopy }
        }
        switch branch {
        case .steam: return .gameSteam
        case .folder: return .gameFolder
        case nil: return .gameChoose
        }
    }

    /// Whether the shown step has a step to go back to.
    var hasPrevious: Bool { step.flatMap(previousStep(before:)) != nil }

    /// The step's place among the steps a review walks, from 1.
    func reviewNumber(of step: Step) -> (number: Int, count: Int) {
        let steps = Self.reviewSteps(of: chapter).filter(applies)
        return ((steps.firstIndex(of: step) ?? 0) + 1, steps.count)
    }
}
