import Foundation

/// The control a quick path step outlines.
public enum QuickPathTarget: Equatable, Sendable {
    /// "Play" in the Stream page's hero.
    case playButton
    /// The state label in the Stream page's hero.
    case statusLabel
}

/// A button of the hint strip. The strip never shows more than two.
public enum QuickPathButton: Equatable, Sendable {
    case back
    /// "Done": the user says the step is done.
    case done
    /// Opens `QuickPathPresentation.help` ("Not working?" or "Can't see the
    /// game?"); it changes nothing in the tour by itself.
    case help
    case checkAgain
    case skip
    case retry
    /// After a failure: opens the section where the advice is carried out.
    /// The app opens it; the tour stays on the failure.
    case open(LearningDestination)

    /// The event to feed back into the tour; nil for `help` and `open`.
    public var event: QuickPathTour.Event? {
        switch self {
        case .back: return .back
        case .done: return .done
        case .help, .open: return nil
        case .checkAgain: return .checkAgain
        case .skip: return .skip
        case .retry: return .retry
        }
    }

    /// Whether the button may be the strip's one primary button.
    var canBePrimary: Bool {
        switch self {
        case .done, .retry, .checkAgain, .open: return true
        case .back, .help, .skip: return false
        }
    }
}

/// What "Not working?" opens: a few real tips, and on the last step a way on.
public struct QuickPathHelp: Equatable, Sendable {
    /// The title of the button that opens it.
    public let title: String
    public let tips: [String]
    /// Every option changes the tour: none is offered where it would do nothing.
    public let options: [QuickPathButton]

    /// "Can't see the game?": on the last step, and in the Stream page's hero
    /// for the rest of the session the quick path completed in.
    public static func cantSeeGame(options: [QuickPathButton] = []) -> QuickPathHelp {
        QuickPathHelp(
            title: L10n.string(.learningCantSeeGame),
            tips: [
                L10n.string(.learningTipOpenVR,
                            L10n.string(.sidebarLibrary), L10n.string(.libraryOpenVRSetup),
                            L10n.string(.commonStop), L10n.string(.openVRTitle),
                            L10n.string(.libraryPlay)),
                L10n.string(.learningTipALVR),
                L10n.string(.learningTipAwake),
            ],
            options: options)
    }
}

/// What the app knows about its window when it asks what to show.
public struct QuickPathEnvironment: Equatable, Sendable {
    /// The selected section, when it is one Learning can open; nil otherwise.
    public var section: LearningDestination?
    /// A page's sheet is open (Steam wizard, folder import, OpenVR support,
    /// game settings). Changing the section would close it mid-work.
    public var pageSheetOpen: Bool
    /// The game Play launches, when it has its own stream settings: advice
    /// about the connection then points at those.
    public var gameWithOwnSettings: String?
    /// The connection Play launches with now: the game's own stream settings,
    /// else the shared ones. Everything the strip says about the connection
    /// follows it: the order card, step 2 and its tips, and the advice after
    /// a failure. Nil keeps the connection the tour started with.
    public var connection: StreamConnectionMode?

    public init(section: LearningDestination?, pageSheetOpen: Bool,
                gameWithOwnSettings: String? = nil, connection: StreamConnectionMode? = nil) {
        self.section = section
        self.pageSheetOpen = pageSheetOpen
        self.gameWithOwnSettings = gameWithOwnSettings
        self.connection = connection
    }

    public init(onStreamSection: Bool, pageSheetOpen: Bool) {
        self.init(section: onStreamSection ? .stream : nil, pageSheetOpen: pageSheetOpen)
    }

    /// The Stream section is selected.
    public var onStreamSection: Bool { section == .stream }
}

/// Everything the hint strip shows for the tour's current state, in the
/// interface language at the time it was asked for.
public struct QuickPathPresentation: Equatable, Sendable {
    /// Changes whenever what is shown changes, so VoiceOver hears it once.
    public let id: String
    /// "Step 2 of 3", the order card's heading, or the failure's cause.
    public let label: String
    public let text: String
    public let target: QuickPathTarget?
    /// The step lives on the Stream page and the app may switch to it now.
    public let opensStream: Bool
    public let buttons: [QuickPathButton]
    /// Present exactly when `buttons` contains `.help`.
    public let help: QuickPathHelp?
    /// The matching advice when the session failed with a known cause.
    public let advice: LaunchFailureAdvice?

    /// The one button drawn as primary: the first that may be. After a
    /// failure that is the advice's own action, when there is one.
    public var primaryButton: QuickPathButton? { buttons.first(where: \.canBePrimary) }

    /// Whether the app should switch to the Stream section for this. Only a
    /// newly shown step does: drawing the same step again, as a language
    /// change does, must not pull the user back from another section.
    public func opensStream(afterShowing previousID: String?) -> Bool {
        opensStream && id != previousID
    }

    public func title(of button: QuickPathButton) -> String {
        switch button {
        case .back: return L10n.string(.commonBack)
        case .done: return L10n.string(.sheetDone)
        case .help: return help?.title ?? L10n.string(.learningStuck)
        case .checkAgain: return L10n.string(.learningRecheck)
        case .skip: return L10n.string(.learningSkipStep)
        case .retry: return L10n.string(.learningRetry)
        case .open(let destination): return LaunchFailureAction.open(destination).title
        }
    }

    /// The name of the strip's own close control, shown in every state.
    public static var closeTitle: String { L10n.string(.learningCloseTour) }
}

extension QuickPathTour {
    /// What to show now; nil once the tour is completed or closed.
    public func presentation(in environment: QuickPathEnvironment) -> QuickPathPresentation? {
        switch phase {
        case .completed, .closed:
            return nil
        case .failed(let message):
            let advice = LaunchFailureAdvisor.advice(
                for: message,
                context: LaunchFailureContext(connection: shownConnection(in: environment),
                                              gameWithOwnSettings: environment.gameWithOwnSettings))
            // The advice's own action comes first, then "Try again". Only a
            // section to open is offered: "Try again" already starts the
            // quick path over. Not the section that is open, and never under
            // an open sheet, so the button always does something.
            var buttons = [QuickPathButton.retry]
            if case .open(let destination)? = advice?.availableAction(pageSheetOpen: environment.pageSheetOpen),
               destination != environment.section {
                buttons.insert(.open(destination), at: 0)
            }
            return QuickPathPresentation(
                id: "quick-failed-\(advice?.cause.rawValue ?? "unknown")\(buttons.count > 1 ? "-open" : "")",
                label: advice?.title ?? L10n.string(.sessionFailed),
                text: advice?.text
                    ?? L10n.string(.learningFailureGeneric, LearningDestination.stream.title),
                target: nil, opensStream: false,
                buttons: buttons, help: nil, advice: advice)
        case .step(let step):
            return presentation(of: step, in: environment)
        }
    }

    /// The connection the texts are written for. A change of it alone never
    /// changes a presentation's id: the same step is only drawn again, and
    /// the app does not switch sections for that.
    private func shownConnection(in environment: QuickPathEnvironment) -> StreamConnectionMode {
        environment.connection ?? connection
    }

    private func presentation(
        of step: Step, in environment: QuickPathEnvironment
    ) -> QuickPathPresentation {
        let connection = shownConnection(in: environment)
        let label = label(of: step, connection: connection)
        let livesOnStream = step == .pressPlay || step == .waitForLive
        if livesOnStream, !environment.onStreamSection, environment.pageSheetOpen {
            // Never leave a section under an open sheet.
            return QuickPathPresentation(
                id: "quick-\(step)-sheet", label: label,
                text: L10n.string(.learningSheetBlocked, L10n.string(.learningRecheck)),
                target: nil, opensStream: false,
                buttons: [.back, .checkAgain], help: nil, advice: nil)
        }

        let buttons: [QuickPathButton]
        var help: QuickPathHelp?
        if step == .order {
            buttons = [.done]
        } else if isRevisit {
            buttons = [.back, .done]
        } else {
            buttons = [.back, .help]
            help = self.help(for: step, connection: connection)
        }
        return QuickPathPresentation(
            id: "quick-\(step)\(isRevisit ? "-again" : "")", label: label,
            text: text(of: step, connection: connection),
            target: target(of: step),
            opensStream: livesOnStream && !environment.onStreamSection,
            buttons: buttons, help: help, advice: nil)
    }

    private func label(of step: Step, connection: StreamConnectionMode) -> String {
        guard let number = step.number else {
            return L10n.string(.learningOrderLabel,
                               L10n.string(connection == .wired ? .connectionUSB : .connectionWiFi))
        }
        return L10n.string(.learningStepLabel, Int64(number), Int64(Step.numberedCount))
    }

    /// Control names come from the controls' own keys, so a hint always
    /// names the button as the button names itself.
    private func text(of step: Step, connection: StreamConnectionMode) -> String {
        let play = L10n.string(.libraryPlay)
        switch step {
        case .order:
            return connection == .wired
                ? L10n.string(.learningOrderUSB, play)
                : L10n.string(.learningOrderWiFi, play, L10n.string(.headsetAllow))
        case .pressPlay:
            return L10n.string(.learningStepPlay, play)
        case .waitForLive:
            let live = L10n.string(.sessionLiveState)
            // Only a Wi-Fi headset makes the Mac ask before it connects.
            return connection == .wired
                ? L10n.string(.learningStepWaitUSB, live)
                : L10n.string(.learningStepWait, live,
                              L10n.string(.headsetRequestTitle, "…"), L10n.string(.headsetAllow))
        case .picture:
            return L10n.string(.learningStepPicture, L10n.string(.commonStop))
        }
    }

    private func target(of step: Step) -> QuickPathTarget? {
        switch step {
        case .pressPlay: return .playButton
        case .waitForLive: return .statusLabel
        case .order, .picture: return nil
        }
    }

    /// Steps 1 and 2 count themselves when the app sees the launch and the
    /// live state, so their help is tips only: there is nothing to skip or
    /// to check again. Only the last step can be skipped.
    private func help(for step: Step, connection: StreamConnectionMode) -> QuickPathHelp {
        let tips: [String]
        switch step {
        case .picture:
            return .cantSeeGame(options: [.skip])
        case .order, .pressPlay:
            tips = [L10n.string(.learningTipPlayBusy,
                                L10n.string(.libraryPlay), L10n.string(.commonStop))]
        case .waitForLive:
            let steam = L10n.string(.learningTipSteamSignIn)
            tips = connection == .wired
                ? [L10n.string(.learningTipPutOnUnlock), steam]
                : [L10n.string(.learningTipALVR),
                   L10n.string(.learningTipAllow,
                               L10n.string(.headsetRequestTitle, "…"), L10n.string(.headsetAllow)),
                   steam]
        }
        return QuickPathHelp(title: L10n.string(.learningStuck), tips: tips, options: [])
    }
}
