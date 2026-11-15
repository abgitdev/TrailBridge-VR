import Foundation

extension LearningFacts {
    /// Whether a chapter is done, from facts where there are facts. "Launch
    /// options" has nothing to look at, so it goes by its record. "Headset"
    /// goes by its record as well: once the cable is out, nothing on the Mac
    /// shows that the headset was set up.
    public func isDone(_ chapter: LearningChapter) -> Bool {
        switch chapter {
        case .mac:
            return macReady
        case .headset:
            // A headset that streamed once is set up. So is one whose
            // chapter was walked to its end, and one the Mac talks to over
            // USB that has the tested ALVR on it. Another ALVR version
            // still has to be replaced, and a headset that still asks to
            // allow debugging is not there yet.
            return hasStreamedSession || chapters[.headset].completedAt != nil
                || (headsetConnection == .connected && headsetHasTestedClient)
        case .game:
            return hasLaunchableGame
        case .firstLaunch:
            return hasStreamedSession
        case .launchOptions:
            return chapters[.launchOptions].completedAt != nil
        }
    }

    /// The chapter that has to be done first; nil when nothing stands in
    /// the way. "Headset" needs nothing, so it can be prepared while the
    /// Mac is not ready, and "Game" does not wait for "Headset": a Steam
    /// download takes hours and needs no headset.
    public func blocker(of chapter: LearningChapter) -> LearningChapter? {
        let needed: [LearningChapter]
        switch chapter {
        case .mac, .headset: needed = []
        case .game: needed = [.mac]
        case .firstLaunch: needed = [.mac, .game]
        case .launchOptions: needed = [.game]
        }
        return needed.first { !isDone($0) }
    }
}

/// One line of the Learning program.
public struct LearningProgramRow: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case done
        case notStarted
        /// Stopped at a step; "Continue" returns to it.
        case paused(step: Int, of: Int)
        /// Another chapter has to be done first.
        case blocked(by: LearningChapter)
    }

    public enum Action: Equatable, Sendable {
        case start
        case resume
        /// Walk a chapter that is done again, as a review.
        case review
        /// The chapter has no steps of its own yet: open its section.
        case open(LearningDestination)

        public var title: String {
            switch self {
            case .start: return L10n.string(.learningChapterStart)
            case .resume: return L10n.string(.learningChapterContinue)
            case .review: return L10n.string(.learningChapterReview)
            case .open(let section): return L10n.string(.learningOpenSection, section.title)
            }
        }
    }

    public let chapter: LearningChapter
    public let status: Status
    /// The row's button; nil while the chapter is blocked.
    public let action: Action?
    /// The page's one primary button is this row's.
    public let isPrimary: Bool

    public var id: LearningChapter { chapter }
    public var title: String { chapter.title }
    public var purpose: String { chapter.purpose }

    public var statusText: String {
        switch status {
        case .done: return L10n.string(.learningStatusDone)
        case .notStarted: return L10n.string(.learningStatusNotStarted)
        case .paused(let step, let count):
            return L10n.string(.learningStepLabel, Int64(step), Int64(count))
        case .blocked(let chapter): return L10n.string(.learningStatusFirst, chapter.title)
        }
    }
}

/// The chapters with their real states, from one set of facts.
public struct LearningProgram: Equatable, Sendable {
    /// Every chapter, in order. No row is primary here: the page decides
    /// where its one primary button goes.
    public let rows: [LearningProgramRow]
    /// The first chapter still to do that nothing blocks; nil when all are
    /// done.
    public let nextChapter: LearningChapter?

    public var doneCount: Int { rows.filter { $0.status == .done }.count }

    public init(_ facts: LearningFacts) {
        rows = LearningChapter.allCases.map { Self.row($0, facts, isPrimary: false) }
        nextChapter = Self.nextChapter(in: facts, after: nil)
    }

    public func row(_ chapter: LearningChapter) -> LearningProgramRow? {
        rows.first { $0.chapter == chapter }
    }

    /// The chapter to offer next. `completed` is the chapter that has just
    /// been walked to its end: it counts as done even before its record or
    /// the facts say so.
    public static func nextChapter(
        in facts: LearningFacts, after completed: LearningChapter?
    ) -> LearningChapter? {
        LearningChapter.allCases.first {
            $0 != completed && !facts.isDone($0) && facts.blocker(of: $0) == nil
        }
    }

    static func row(
        _ chapter: LearningChapter, _ facts: LearningFacts, isPrimary: Bool
    ) -> LearningProgramRow {
        let status = status(of: chapter, facts)
        let action: LearningProgramRow.Action?
        if !SetupTour.hasSteps(chapter) {
            action = .open(SetupTour.section(of: chapter))
        } else {
            switch status {
            case .done: action = .review
            case .notStarted: action = .start
            case .paused: action = .resume
            case .blocked: action = nil
            }
        }
        return LearningProgramRow(chapter: chapter, status: status, action: action,
                                  isPrimary: isPrimary && action != nil)
    }

    private static func status(
        of chapter: LearningChapter, _ facts: LearningFacts
    ) -> LearningProgramRow.Status {
        if facts.isDone(chapter) { return .done }
        if let blocker = facts.blocker(of: chapter) { return .blocked(by: blocker) }
        // A step name this version does not know starts the chapter over.
        // So does a chapter without numbered steps: "First launch" has one
        // card of its own and then goes on as the quick path.
        let count = SetupTour.stepCount(of: chapter)
        if count > 0, let name = facts.chapters[chapter].pausedStep,
           let step = SetupTour.Step(rawValue: name), step.chapter == chapter {
            return .paused(step: step.number ?? 1, of: count)
        }
        return .notStarted
    }
}

/// The first-launch invitation: offered to a new person, until answered.
public struct LearningInvitation: Equatable, Sendable {
    /// False when parts of the app are still to be built on this Mac: the
    /// invitation then says so instead of promising a game.
    public let macReady: Bool
    /// What the Mac still lacks is all supplied on the Setup page itself:
    /// nothing has to be built, and nobody else has to be asked.
    public let macFixedOnSetupPage: Bool
    /// The chapter "Start" opens: the first one still to do.
    public let chapter: LearningChapter

    public var text: String {
        L10n.string(macReady ? .learningInviteText
                    : macFixedOnSetupPage ? .learningInviteMacSetup : .learningInviteMacNotReady)
    }

    /// "Learning is always in the sidebar."
    public var note: String { L10n.string(.learningInviteNote) }
    public var startTitle: String { L10n.string(.learningChapterStart) }
    public var laterTitle: String { L10n.string(.learningInviteLater) }
}

/// Who gets the invitation, and with it the Learning section as the app's
/// first page.
public enum LearningFirstRun {
    /// A new person: no game ready to launch and no session that ever
    /// streamed. Never before the Mac's checks have arrived: without them
    /// the app does not know yet whom it is talking to. Never when
    /// `learning.json` is damaged: the answer could not be remembered, so
    /// the invitation would come back at every launch.
    public static func shouldOffer(_ facts: LearningFacts) -> Bool {
        !facts.progressDamaged && !facts.firstRunAnswered && !facts.setupChecks.isEmpty
            && !facts.hasLaunchableGame && !facts.hasStreamedSession
    }

    public static func invitation(_ facts: LearningFacts) -> LearningInvitation? {
        guard shouldOffer(facts),
              let chapter = LearningProgram.nextChapter(in: facts, after: nil) else { return nil }
        return LearningInvitation(macReady: facts.macReady,
                                  macFixedOnSetupPage: facts.macFixedOnSetupPage, chapter: chapter)
    }
}

/// What the Learning page shows, and where its one primary button is.
public struct LearningPage: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// The intro, "You will need" and the chapter list.
        case newcomer
        /// The "Ready for VR" card on top, the program folded into one line.
        case returning
    }

    /// Where the page's one primary button is.
    public enum PrimaryButton: Equatable, Sendable {
        /// "Start" in the invitation.
        case invitation
        /// The next chapter's button in its row.
        case chapter(LearningChapter)
        /// The "Ready for VR" card's main button.
        case readyCard
    }

    public let layout: Layout
    public let invitation: LearningInvitation?
    public let rows: [LearningProgramRow]
    public let primaryButton: PrimaryButton?
    private let doneCount: Int

    public init(_ facts: LearningFacts) {
        let program = LearningProgram(facts)
        doneCount = program.doneCount
        // Someone whose game has once reached the headset comes back to
        // start VR, not to be taught: the card goes first.
        layout = facts.hasStreamedSession ? .returning : .newcomer
        invitation = layout == .newcomer ? LearningFirstRun.invitation(facts) : nil
        let primary: PrimaryButton?
        if layout == .returning {
            primary = .readyCard
        } else if invitation != nil {
            primary = .invitation
        } else {
            primary = program.nextChapter.map(PrimaryButton.chapter)
        }
        primaryButton = primary
        rows = LearningChapter.allCases.map {
            LearningProgram.row($0, facts, isPrimary: primary == .chapter($0))
        }
    }

    /// "3 of 5 done", the folded program's line.
    public var summary: String {
        L10n.string(.learningProgramSummary, Int64(doneCount), Int64(rows.count))
    }

    public static var showTitle: String { L10n.string(.learningProgramShow) }
    public static var hideTitle: String { L10n.string(.learningProgramHide) }

    /// The intro's three lines.
    public static var intro: [String] {
        [L10n.string(.learningIntroWhat), L10n.string(.learningIntroALVR),
         L10n.string(.learningIntroGames)]
    }

    /// The scheme under the intro: Mac, the link, the headset.
    public static var scheme: [String] {
        [L10n.string(.learningRowMac), L10n.string(.learningSchemeLink),
         L10n.string(.learningSchemeHeadset)]
    }

    public static var needsTitle: String { L10n.string(.learningNeedsTitle) }

    /// "You will need", one line each.
    public static var needs: [String] {
        [L10n.string(.learningNeedCable), L10n.string(.learningNeedPhone),
         L10n.string(.learningNeedAdult), L10n.string(.learningNeedSteam),
         L10n.string(.learningNeedDisk), L10n.string(.learningNeedTime)]
    }
}
