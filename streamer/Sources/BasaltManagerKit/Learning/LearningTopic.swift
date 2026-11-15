import Foundation

/// A short topic of the Learning page, outside the program's chapters: one
/// to three hints on the app's real controls. Nothing about a topic is
/// remembered: closed, it starts from its first hint the next time.
public enum LearningTopic: String, CaseIterable, Sendable {
    // "If something does not work"
    case launchFailed, noSound, report
    // "More"
    case interface, graphics, connection

    /// Where the Learning page lists the topic.
    public enum Group: CaseIterable, Sendable {
        /// "If something does not work": always on the page.
        case trouble
        /// "More": folded until asked for.
        case more

        public var title: String {
            switch self {
            case .trouble: return L10n.string(.learningTroubleTitle)
            case .more: return L10n.string(.learningMoreTitle)
            }
        }

        public var topics: [LearningTopic] {
            LearningTopic.allCases.filter { $0.group == self }
        }
    }

    public var group: Group {
        switch self {
        case .launchFailed, .noSound, .report: return .trouble
        case .interface, .graphics, .connection: return .more
        }
    }

    public var title: String {
        switch self {
        case .launchFailed: return L10n.string(.learningTopicLaunchFailed)
        case .noSound: return L10n.string(.learningTopicNoSound)
        case .report: return L10n.string(.learningTopicReport)
        case .interface: return L10n.string(.learningTopicInterface)
        case .graphics: return L10n.string(.learningTopicGraphics)
        // The switch's own name.
        case .connection: return L10n.string(.streamConnection)
        }
    }

    /// One phrase: what the topic shows.
    public var purpose: String {
        switch self {
        case .launchFailed: return L10n.string(.learningWhyLaunchFailed, L10n.string(.learningHowToFix))
        case .noSound: return L10n.string(.learningWhyNoSound)
        case .report: return L10n.string(.learningWhyReport)
        case .interface: return L10n.string(.learningWhyInterface)
        case .graphics: return L10n.string(.learningWhyGraphics)
        case .connection: return L10n.string(.learningWhyConnection)
        }
    }

    /// The title of a topic's button on the Learning page.
    public static var showTitle: String { L10n.string(.learningProgramShow) }
}

/// The control a topic's hint outlines. The app maps it to its own marker.
public enum LearningTopicTarget: Hashable, CaseIterable, Sendable {
    /// The state label in the Stream page's hero.
    case streamStatus
    /// "How to fix" under a failure in the Stream page's hero.
    case streamHowToFix
    /// The "Stream" row of the sidebar.
    case sidebarStream
    /// The session card at the bottom of the sidebar.
    case sidebarSession
    /// The "Connection" switch on the Settings page.
    case settingsConnection
    /// "Use recommended" on the Settings page.
    case settingsUseRecommended
    /// The "Game audio" list on the Settings page.
    case settingsGameAudio
    /// "Create Report…" on the Settings page.
    case settingsCreateReport

    /// The page the control is on; nil for the sidebar, which is on every
    /// page. A page scrolls only to the targets of its own.
    public var section: LearningDestination? {
        switch self {
        case .streamStatus, .streamHowToFix: return .stream
        case .sidebarStream, .sidebarSession: return nil
        case .settingsConnection, .settingsUseRecommended, .settingsGameAudio,
             .settingsCreateReport: return .settings
        }
    }
}

/// What a topic reads. The app fills it from its model; nothing here asks
/// the system.
public struct LearningTopicFacts: Equatable, Sendable {
    /// The selected section, when it is one Learning knows; nil otherwise.
    public var section: LearningDestination?
    public var session = LearningSessionPhase.idle
    /// The Stream page shows a launch failure with a "How to fix" button:
    /// one of the causes Learning knows.
    public var knownFailure: LaunchFailureCause?
    /// The game Play launches, when it has its own stream settings: the
    /// Settings page then changes nothing for it.
    public var gameWithOwnSettings: String?
    /// The shared stream settings use the preset recommended for this Mac.
    public var recommendedPresetSelected = false
    /// A BlackHole device is installed, so the "Game audio" list offers it.
    public var blackHoleInstalled = false

    public init() {}
}

/// A button of the hint strip. A topic never shows more than two.
public enum LearningTopicButton: Equatable, Sendable {
    case back
    case next
    /// On the last hint. The app then opens the Learning section.
    case done

    public var event: LearningTopicTour.Event {
        switch self {
        case .back: return .back
        case .next, .done: return .next
        }
    }

    var canBePrimary: Bool { self != .back }
}

/// Everything the hint strip shows for a topic's current hint, in the
/// interface language at the time it was asked for.
public struct LearningTopicPresentation: Equatable, Sendable {
    /// A short list behind the quiet link under the text.
    public struct List: Equatable, Sendable {
        public let title: String
        public let items: [String]
    }

    /// Changes whenever a new hint is shown, so VoiceOver hears it once.
    public let id: String
    /// The topic's name, with "step 2 of 3" when it has more than one hint.
    public let label: String
    public let text: String
    /// Nil when the hint's control is not on screen now.
    public let target: LearningTopicTarget?
    /// The section the hint lives in, when another one is selected.
    public let section: LearningDestination?
    public let buttons: [LearningTopicButton]
    public let list: List?

    /// The one button drawn as primary: the first that may be.
    public var primaryButton: LearningTopicButton? { buttons.first(where: \.canBePrimary) }

    /// The section the app should switch to for this. Only a newly shown
    /// hint opens one: drawing the same hint again, as a language change
    /// does, must not pull the user back from another section.
    public func opensSection(afterShowing previousID: String?) -> LearningDestination? {
        id != previousID ? section : nil
    }

    public func title(of button: LearningTopicButton) -> String {
        switch button {
        case .back: return L10n.string(.commonBack)
        case .next: return L10n.string(.commonNext)
        case .done: return L10n.string(.sheetDone)
        }
    }

    /// The name of the strip's own close control.
    public static var closeTitle: String { L10n.string(.learningCloseTour) }
}

/// One topic, walked hint by hint. A value with no clock, timers or I/O:
/// the app feeds it facts and button presses, and shows what `presentation`
/// describes. A topic waits for nothing: "Back" and "Next" only, as a
/// chapter's review. One hint counts itself as well: "Press Stream" moves
/// on when the Stream section opens.
public struct LearningTopicTour: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        // The launch failed
        /// Where the cause is written.
        case failedCause
        /// The "How to fix" button under it.
        case failedFix

        // No sound in the headset
        case soundChoice
        /// The game has its own stream settings: the list just shown does
        /// not apply to it.
        case soundOwn
        /// The game's window has to stay in front on the Mac.
        case soundFront
        case soundBlackHole

        // Getting help
        case report

        // The interface
        case interfaceStream
        case interfaceCard

        // Graphics
        case graphicsRecommended
        case graphicsOwn

        // Connection: when to choose Wi-Fi or USB
        case connectionWiFi
        case connectionUSB
        case connectionOwn

        public var topic: LearningTopic {
            switch self {
            case .failedCause, .failedFix: return .launchFailed
            case .soundChoice, .soundOwn, .soundFront, .soundBlackHole: return .noSound
            case .report: return .report
            case .interfaceStream, .interfaceCard: return .interface
            case .graphicsRecommended, .graphicsOwn: return .graphics
            case .connectionWiFi, .connectionUSB, .connectionOwn: return .connection
            }
        }

        /// The section the hint's control is in; nil when the control is in
        /// the sidebar, so the hint is read on whatever page is open.
        var section: LearningDestination? {
            switch self {
            case .failedCause, .failedFix: return .stream
            case .soundChoice, .soundOwn, .soundFront, .soundBlackHole, .report,
                 .graphicsRecommended, .graphicsOwn,
                 .connectionWiFi, .connectionUSB, .connectionOwn: return .settings
            case .interfaceStream, .interfaceCard: return nil
            }
        }
    }

    public enum Event: Equatable, Sendable {
        /// The facts as they are now. Feed every change while a hint is shown.
        case facts(LearningTopicFacts)
        case next
        case back
        /// The strip's close button; also sent when anything else takes the
        /// strip.
        case close
    }

    public let topic: LearningTopic
    /// The hint shown now; nil once the topic is over.
    public private(set) var step: Step?
    public private(set) var facts: LearningTopicFacts
    /// "Done" ended the topic, not the close button.
    public private(set) var isCompleted = false
    /// The shown hint was reached with "Back". It then waits for "Next"
    /// instead of counting itself, so "Back" never jumps forward again.
    public private(set) var isRevisit = false
    /// "Press Stream" was shown while another section was open: opening
    /// Stream now counts.
    private var isArmed = false

    public init(topic: LearningTopic, facts: LearningTopicFacts) {
        self.topic = topic
        self.facts = facts
        show(steps.first)
    }

    /// Nothing more is shown.
    public var isOver: Bool { step == nil }

    /// The hints the topic has now, in order. A hint about a game's own
    /// settings is there only for such a game.
    public var steps: [Step] {
        Step.allCases.filter { $0.topic == topic && applies($0) }
    }

    private func applies(_ step: Step) -> Bool {
        switch step {
        case .soundOwn, .graphicsOwn, .connectionOwn: return facts.gameWithOwnSettings != nil
        default: return true
        }
    }

    public mutating func handle(_ event: Event) {
        guard let step else { return }
        switch event {
        case .close:
            self.step = nil
        case .next:
            guard let next = neighbour(of: step, by: 1) else {
                isCompleted = true
                self.step = nil
                return
            }
            show(next)
        case .back:
            guard let previous = neighbour(of: step, by: -1) else { return }
            show(previous, revisit: true)
        case .facts(let new):
            let old = facts
            facts = new
            // A VR launch has begun: the game takes it from here.
            if new.session == .starting, old.session != .starting {
                self.step = nil
                return
            }
            // The game lost its own settings while their hint was shown.
            guard applies(step) else {
                show(neighbour(of: step, by: 1) ?? neighbour(of: step, by: -1))
                return
            }
            guard step == .interfaceStream, !isRevisit else { return }
            if new.section != .stream {
                isArmed = true
            } else if isArmed {
                show(neighbour(of: step, by: 1))
            }
        }
    }

    /// The hint before or after, among the ones the topic has now. The
    /// shown hint is found by the topic's whole order, so it has
    /// neighbours even when it no longer applies itself.
    private func neighbour(of step: Step, by offset: Int) -> Step? {
        let all = Step.allCases.filter { $0.topic == topic }
        guard let index = all.firstIndex(of: step) else { return nil }
        return offset > 0
            ? all[(index + 1)...].first(where: applies)
            : all[..<index].last(where: applies)
    }

    private mutating func show(_ step: Step?, revisit: Bool = false) {
        self.step = step
        isRevisit = revisit
        isArmed = step == .interfaceStream && facts.section != .stream
    }

    // MARK: - What is shown

    /// What to show now; nil once the topic is over.
    public var presentation: LearningTopicPresentation? {
        guard let step else { return nil }
        let steps = steps
        let index = steps.firstIndex(of: step) ?? 0
        let isLast = index == steps.count - 1
        return LearningTopicPresentation(
            id: "topic-\(step.rawValue)\(isRevisit ? "-again" : "")",
            label: steps.count > 1
                ? L10n.string(.learningChapterStepLabel, topic.title, Int64(index + 1), Int64(steps.count))
                : topic.title,
            text: text(of: step),
            target: target(of: step),
            section: step.section.flatMap { $0 == facts.section ? nil : $0 },
            buttons: (index > 0 ? [.back] : []) + [isLast ? .done : .next],
            list: list(of: step))
    }

    /// Only what is on screen now is outlined.
    private func target(of step: Step) -> LearningTopicTarget? {
        switch step {
        case .failedCause: return .streamStatus
        // The button is in the hero only under a failure Learning knows.
        case .failedFix: return facts.knownFailure != nil ? .streamHowToFix : nil
        case .soundChoice, .soundBlackHole: return .settingsGameAudio
        case .report: return .settingsCreateReport
        case .interfaceStream: return .sidebarStream
        case .interfaceCard: return .sidebarSession
        case .graphicsRecommended: return .settingsUseRecommended
        case .connectionWiFi, .connectionUSB: return .settingsConnection
        case .soundOwn, .soundFront, .graphicsOwn, .connectionOwn: return nil
        }
    }

    /// Control names come from the controls' own keys, so a hint always
    /// names a button as the button names itself.
    private func text(of step: Step) -> String {
        let fix = L10n.string(.learningHowToFix)
        switch step {
        case .failedCause:
            return L10n.string(.learningFailedCause, LearningDestination.stream.title)
        case .failedFix:
            guard let cause = facts.knownFailure else { return L10n.string(.learningFailedFix, fix) }
            return L10n.string(.learningFailedFixNow, Self.title(of: cause), fix)

        case .soundChoice:
            return L10n.string(.learningSoundChoice,
                               L10n.string(.settingsGameAudio), L10n.string(.settingsMacAudio))
        case .soundOwn:
            return ownSettingText(L10n.string(.settingsGameAudio))
        case .soundFront:
            return L10n.string(.learningSoundFront)
        case .soundBlackHole:
            // "Get BlackHole…" is on the page only while it is not installed.
            return facts.blackHoleInstalled
                ? L10n.string(.learningSoundBlackHole, L10n.string(.settingsMacAudio))
                : L10n.string(.learningSoundBlackHoleGet, L10n.string(.settingsGetBlackHole))

        case .report:
            return L10n.string(.learningReportStep, L10n.string(.settingsCreateReport))

        case .interfaceStream:
            return L10n.string(.learningInterfaceStream, LearningDestination.stream.title)
        case .interfaceCard:
            return L10n.string(.learningInterfaceCard, L10n.string(.commonStop))

        case .graphicsRecommended:
            // The "Launch options" chapter's own words for the same button.
            return L10n.string(facts.recommendedPresetSelected
                               ? .learningOptionsRecommendedSet : .learningOptionsRecommended,
                               L10n.string(.settingsUseRecommended))
        case .graphicsOwn:
            return ownSettingText(L10n.string(.streamQuality))

        case .connectionWiFi:
            return L10n.string(.learningConnectionWiFi, L10n.string(.connectionWiFi))
        case .connectionUSB:
            return L10n.string(.learningConnectionUSB, L10n.string(.connectionUSB))
        case .connectionOwn:
            return ownSettingText(L10n.string(.streamConnection))
        }
    }

    /// "The game has its own settings: … is changed for it in …".
    private func ownSettingText(_ setting: String) -> String {
        L10n.string(.learningTopicOwnSetting,
                    SetupTour.shortName(facts.gameWithOwnSettings ?? ""), setting,
                    L10n.string(.streamAdjust), SetupTour.ownSettingsItem)
    }

    /// The failures "How to fix" knows, by the names their advice has.
    private func list(of step: Step) -> LearningTopicPresentation.List? {
        guard step == .failedFix, facts.knownFailure == nil else { return nil }
        return LearningTopicPresentation.List(
            title: L10n.string(.learningFailedKnownCauses),
            items: LaunchFailureCause.allCases.map(Self.title(of:)))
    }

    /// A cause's name is the same whatever the launch was like.
    private static func title(of cause: LaunchFailureCause) -> String {
        LaunchFailureAdvice(cause: cause, context: LaunchFailureContext(connection: .wired)).title
    }
}

/// A "?" badge beside a control: a few short sentences on what the control
/// is for. There are exactly four.
public enum LearningHelpBadge: String, CaseIterable, Sendable {
    case connection, quality, gameAudio, openVR

    /// The name of the control the badge stands beside, from the control's
    /// own key.
    public var controlTitle: String {
        switch self {
        case .connection: return L10n.string(.streamConnection)
        case .quality: return L10n.string(.streamQuality)
        case .gameAudio: return L10n.string(.settingsGameAudio)
        case .openVR: return L10n.string(.openVRTitle)
        }
    }

    /// What VoiceOver calls the badge.
    public var label: String { L10n.string(.learningBadgeLabel, controlTitle) }

    public var text: String {
        switch self {
        case .connection:
            // The "Connection" topic's two hints, one for each choice.
            return L10n.string(
                .learningTwoSentences,
                L10n.string(.learningConnectionWiFi, L10n.string(.connectionWiFi)),
                L10n.string(.learningConnectionUSB, L10n.string(.connectionUSB)))
        case .quality:
            return L10n.string(.learningBadgeQuality, L10n.string(.settingsUseRecommended))
        case .gameAudio:
            return L10n.string(.learningBadgeGameAudio, L10n.string(.settingsMacAudio))
        case .openVR:
            return L10n.string(.learningBadgeOpenVR, L10n.string(.libraryOpenVRSetup))
        }
    }
}
