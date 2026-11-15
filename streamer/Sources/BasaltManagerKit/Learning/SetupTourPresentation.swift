import Foundation

/// The control a chapter step outlines. The app maps it to its own marker.
public enum SetupTarget: Hashable, Sendable {
    /// The Setup page's summary card.
    case setupSummary
    /// The Headset page's status card.
    case headsetStatus
    /// "Get Android Platform Tools…" on the Headset page.
    case headsetGetTools
    /// "Install on Headset…" on the Headset page.
    case headsetInstall
    /// Both "Add…" buttons of the empty Library.
    case libraryAddButtons
    case libraryAddSteam
    case libraryAddFolder
    /// "Create Profile" or "Copy…" on a game's card, by the card's id.
    case libraryGameAction(String)
    /// The status label on a game's card, by the profile's name.
    case libraryStatusChip(String)
    /// A game's whole card, by the profile's name.
    case libraryGameTile(String)
    /// "Stop" under the session state in the sidebar.
    case sidebarStop
    /// "Change…" on the Stream page.
    case streamAdjust
    case streamRecentSessions
    /// The "Connection" switch on the Settings page.
    case settingsConnection
    /// "Use recommended" on the Settings page.
    case settingsUseRecommended

    /// The page the control is on; nil for the sidebar, which is on every
    /// page. A page scrolls only to the targets of its own.
    public var section: LearningDestination? {
        switch self {
        case .setupSummary: return .setup
        case .headsetStatus, .headsetGetTools, .headsetInstall: return .headset
        case .libraryAddButtons, .libraryAddSteam, .libraryAddFolder, .libraryGameAction,
             .libraryStatusChip, .libraryGameTile: return .library
        case .sidebarStop: return nil
        case .streamAdjust, .streamRecentSessions: return .stream
        case .settingsConnection, .settingsUseRecommended: return .settings
        }
    }
}

/// Which cards of the Library carry a game's marks. A Steam game with a
/// profile is listed twice, as a Steam card and as a launch profile; two
/// marks with one id would outline both and scroll to either.
public enum LearningLibraryMarks {
    /// One card as the Library lists it: its own id, and the profile behind
    /// it when it has one.
    public struct Card: Equatable, Sendable {
        public let id: String
        public let profile: String?

        public init(id: String, profile: String?) {
            self.id = id
            self.profile = profile
        }
    }

    /// The ids of the cards that are marked: for every profile the first
    /// card that shows it, in the page's order. The Library lists Steam
    /// cards first, so a Steam game is marked on its Steam card.
    public static func markedCards(_ cards: [Card]) -> Set<String> {
        var profiles = Set<String>()
        var marked = Set<String>()
        for card in cards {
            guard let profile = card.profile, profiles.insert(profile).inserted else { continue }
            marked.insert(card.id)
        }
        return marked
    }
}

/// A page outside the app that a step sends the user to.
public enum SetupLink: Equatable, Sendable {
    /// Where a Meta developer account is made.
    case metaDeveloperSignUp

    public var url: URL {
        switch self {
        case .metaDeveloperSignUp: return URL(string: "https://developers.meta.com/horizon/sign-up/")!
        }
    }
}

/// A button of the hint strip. The strip never shows more than two.
public enum SetupButton: Equatable, Sendable {
    case back
    case next
    /// "Done" on a step that is done outside the app: on a site, in the
    /// phone, in the headset.
    case confirm
    /// The app opens the page in the browser. The tour stays as it is.
    case link(SetupLink)
    /// "Open "Headset"": the step waits on a page that is not open now. The
    /// app opens that section. The tour stays as it is.
    case open(LearningDestination)
    /// "Done" on the end-of-chapter line when no chapter is next. The app
    /// then opens the Learning section.
    case done
    case checkAgain
    /// Opens `SetupPresentation.help`; it changes nothing by itself.
    case help
    case skip
    case choose(SetupTour.Branch)
    /// "Add another game".
    case otherWay
    /// "Go on" on the end-of-chapter line: the app starts that chapter.
    case continueTo(LearningChapter)
    /// "Later" on the end-of-chapter line: the app opens the Learning
    /// section, where the next chapter waits.
    case later

    /// The event to feed back into the tour; nil for `help` and for what
    /// the app does by itself: `link` and `open`.
    public var event: SetupTour.Event? {
        switch self {
        case .back: return .back
        case .next, .confirm, .done, .continueTo, .later: return .next
        case .checkAgain: return .checkAgain
        case .help, .link, .open: return nil
        case .skip: return .skip
        case .choose(let branch): return .choose(branch)
        case .otherWay: return .otherWay
        }
    }

    /// Whether the button may be the strip's one primary button.
    var canBePrimary: Bool {
        switch self {
        case .next, .confirm, .open, .done, .checkAgain, .continueTo: return true
        case .back, .link, .help, .skip, .choose, .otherWay, .later: return false
        }
    }
}

/// A short list behind a button or a quiet link: tips, and ways on.
public struct SetupHelp: Equatable, Sendable {
    /// The title of the control that opens it.
    public let title: String
    public let tips: [String]
    /// Every option changes the tour.
    public let options: [SetupButton]
}

/// Everything the hint strip shows for a chapter's current state, in the
/// interface language at the time it was asked for.
public struct SetupPresentation: Equatable, Sendable {
    /// Changes whenever a new step is shown, so VoiceOver hears it once.
    public let id: String
    /// "Game · step 2 of 5", or the chapter's name.
    public let label: String
    public let text: String
    /// Nil when the step's control is not on screen now: the text then says
    /// where it appears.
    public let target: SetupTarget?
    /// The section the step lives in, when another one is selected.
    public let section: LearningDestination?
    public let buttons: [SetupButton]
    /// Drawn as a button when `buttons` holds `.help`; otherwise as a quiet
    /// link under the text, so the strip keeps to two buttons.
    public let help: SetupHelp?

    /// The one button drawn as primary: the first that may be.
    public var primaryButton: SetupButton? { buttons.first(where: \.canBePrimary) }

    /// The section the app should switch to for this. Only a newly shown
    /// step opens one: drawing the same step again, as a language change
    /// does, must not pull the user back from another section.
    public func opensSection(afterShowing previousID: String?) -> LearningDestination? {
        id != previousID ? section : nil
    }

    public func title(of button: SetupButton) -> String {
        switch button {
        case .back: return L10n.string(.commonBack)
        case .next: return L10n.string(.commonNext)
        case .confirm, .done: return L10n.string(.sheetDone)
        case .link(.metaDeveloperSignUp): return L10n.string(.learningHeadsetOpenMeta)
        case .open(let section): return L10n.string(.learningOpenSection, section.title)
        case .checkAgain: return L10n.string(.learningRecheck)
        case .help: return help?.title ?? L10n.string(.learningStuck)
        case .skip: return L10n.string(.learningSkipStep)
        case .choose(.steam): return L10n.string(.learningGameFromSteam)
        case .choose(.folder): return L10n.string(.learningGameFromFolder)
        case .otherWay: return L10n.string(.learningGameOtherWay)
        case .continueTo: return L10n.string(.learningChapterGoOn)
        case .later: return L10n.string(.learningChapterLater)
        }
    }

    /// The name of the strip's own close control, shown in every state.
    public static var closeTitle: String { L10n.string(.learningCloseTour) }
}

extension SetupTour {
    /// What to show now. Nil while a sheet is open over the page: it has
    /// its own steps, and everything it needs was said before it opened.
    /// Nil as well once the tour is over.
    public var presentation: SetupPresentation? {
        guard !facts.pageSheetOpen else { return nil }
        switch phase {
        case .handOff, .stopped, .closed:
            return nil
        case .finished:
            return endLine
        case .step(let step):
            if waitsAway(step) { return awayLine(of: step) }
            let (buttons, help) = controls(of: step)
            let suffix = mode == .review ? "-review" : isRevisit ? "-again" : ""
            return SetupPresentation(
                id: "setup-\(step.rawValue)\(suffix)", label: label(of: step),
                text: text(of: step), target: target(of: step),
                section: step.section.flatMap { $0 == facts.section ? nil : $0 },
                buttons: buttons, help: help)
        }
    }

    /// "The "Mac" chapter is done. Next: "Headset"."
    private var endLine: SetupPresentation {
        let next = LearningProgram.nextChapter(in: facts, after: chapter)
        return SetupPresentation(
            id: "setup-\(chapter.rawValue)-end", label: chapter.title,
            text: next.map { L10n.string(.learningChapterEndNext, chapter.title, $0.title) }
                ?? L10n.string(.learningChapterEnd, chapter.title),
            target: nil, section: nil,
            buttons: next.map { [.continueTo($0), .later] } ?? [.done], help: nil)
    }

    /// A step of "Headset" waits, and the user has left the Headset page.
    /// Only that page asks the headset while it is open, so the wait would
    /// never end.
    private func waitsAway(_ step: Step) -> Bool {
        mode == .firstPass && step.chapter == .headset && isAway && !isRevisit && waitsByItself(step)
    }

    /// It says where the step is and offers to open that page. The section
    /// is not asked for: the user left it on purpose.
    private func awayLine(of step: Step) -> SetupPresentation {
        SetupPresentation(
            id: "setup-\(step.rawValue)-away", label: label(of: step),
            text: L10n.string(.learningHeadsetAway, LearningDestination.headset.title),
            target: nil, section: nil, buttons: [.open(.headset)], help: nil)
    }

    private func label(of step: Step) -> String {
        if mode == .review {
            let place = reviewNumber(of: step)
            return L10n.string(.learningChapterReviewLabel, chapter.title,
                               Int64(place.number), Int64(place.count))
        }
        guard let number = step.number else { return chapter.title }
        return L10n.string(.learningChapterStepLabel, chapter.title,
                           Int64(number), Int64(Self.stepCount(of: chapter)))
    }

    // MARK: - Buttons

    private func controls(of step: Step) -> ([SetupButton], SetupHelp?) {
        let back: [SetupButton] = hasPrevious ? [.back] : []
        if mode == .review { return (back + [.next], link(of: step)) }
        // The question's two answers take both places.
        if step == .gameChoose { return ([.choose(.steam), .choose(.folder)], link(of: step)) }
        guard waitsByItself(step) else {
            switch step {
            // No step before it can be read again, so both places are free.
            case .headsetAccount: return ([.link(.metaDeveloperSignUp), .confirm], link(of: step))
            case .headsetDeveloperMode, .headsetOpenALVR: return (back + [.confirm], link(of: step))
            default: return (back + [.next], link(of: step))
            }
        }
        if isRevisit { return (back + [.next], nil) }
        if step.chapter == .mac { return (back + [.checkAgain], nil) }
        let help = self.help(of: step)
        return (back + [.help], help)
    }

    /// "Not working?" on a step that waits by itself.
    private func help(of step: Step) -> SetupHelp {
        let play = L10n.string(.libraryPlay)
        let stop = L10n.string(.commonStop)
        var options = [SetupButton]()
        let tips: [String]
        switch step {
        case .gameCreateProfile:
            tips = [L10n.string(.learningTipProfileWizard, play, L10n.string(.libraryAddSteam))]
            options = [.otherWay]
        case .gameCopy:
            tips = [L10n.string(.learningTipCopyThenProfile, L10n.string(.libraryCreateProfile))]
            options = [.otherWay]
        case .gameSteam:
            tips = [L10n.string(.learningTipWizardReopen), L10n.string(.learningTipSteamSignIn)]
        case .gameFolder:
            tips = [L10n.string(.learningTipFolderExe, L10n.string(.folderImportAdd))]
        case .gameWait:
            tips = [L10n.string(.learningTipWizardReopen),
                    L10n.string(.learningTipResumeLater,
                                L10n.string(.learningChapterContinue), L10n.string(.learningTitle))]
        case .gameOpenVR:
            tips = [L10n.string(.learningTipOpenVRGuess)]
            options = [.skip]
        case .headsetTools:
            let recheck = L10n.string(.learningTipHeadsetRecheck, LearningDestination.headset.title)
            switch facts.headsetTools {
            case .checking: tips = [recheck]
            case .failed: tips = [L10n.string(.headsetErrorGuidance), recheck]
            case .missing, .ready:
                tips = [L10n.string(.learningTipHeadsetRetry,
                                    L10n.string(.headsetGetTools), L10n.string(.commonDetails))]
            }
        case .headsetCable:
            tips = [L10n.string(.learningTipHeadsetDataCable), L10n.string(.learningTipHeadsetDevModeOn),
                    L10n.string(.learningTipHeadsetRecheck, LearningDestination.headset.title)]
        case .headsetDebugging:
            tips = [L10n.string(.learningTipHeadsetReplug), L10n.string(.learningTipHeadsetDontShowAgain),
                    L10n.string(.learningTipAwake)]
        case .headsetInstall:
            // An ALVR installed another way has another package name, and
            // the Headset page cannot see it.
            tips = [L10n.string(.learningTipHeadsetRetry,
                                L10n.string(.headsetInstall), L10n.string(.commonDetails)),
                    L10n.string(.learningTipHeadsetOtherALVR, L10n.string(.headsetClientMissing))]
            options = [.skip]
        case .optionsStream:
            tips = [L10n.string(.learningTipAdjustBusy, L10n.string(.streamAdjust), stop)]
        default:
            tips = [L10n.string(.learningTipPlayBusy, play, stop)]
        }
        return SetupHelp(title: L10n.string(.learningStuck), tips: tips, options: options)
    }

    /// The quiet link under a step that already has its two buttons.
    private func link(of step: Step) -> SetupHelp? {
        switch step {
        case .gameChoose:
            // Honest: these ways are named, not walked.
            return SetupHelp(
                title: L10n.string(.learningOtherWays),
                tips: [
                    L10n.string(.learningOtherWayInstaller, L10n.string(.libraryAddGame)),
                    L10n.string(.learningOtherWayBSManager, L10n.string(.libraryInstallBSManager)),
                    L10n.string(.learningOtherWayCopy,
                                L10n.string(.sidebarLibrary), L10n.string(.libraryCopy)),
                    L10n.string(.learningOtherWaysNote),
                ],
                options: [])
        case .headsetAccount:
            // A review has "Back" and "Next" in both places: the site's
            // button goes into the list.
            return SetupHelp(
                title: L10n.string(.learningStuck),
                tips: [L10n.string(.learningTipHeadsetOrganization),
                       L10n.string(.learningTipHeadsetVerification)],
                options: mode == .review ? [.link(.metaDeveloperSignUp)] : [])
        case .headsetDeveloperMode:
            return SetupHelp(
                title: L10n.string(.learningStuck),
                tips: [L10n.string(.learningTipHeadsetNoToggle)], options: [])
        case .optionsOwnSettings:
            return SetupHelp(
                title: L10n.string(.learningStuck),
                tips: [
                    L10n.string(.learningTipOwnSave,
                                L10n.string(.sheetSave), L10n.string(.streamConnection)),
                    L10n.string(.learningTipOwnReset, L10n.string(.sheetUseGlobal)),
                ],
                options: [])
        default:
            return nil
        }
    }

    // MARK: - Targets

    /// Only what is on screen now is outlined; a review never points at a
    /// control that exists only in another state.
    private func target(of step: Step) -> SetupTarget? {
        switch step {
        case .macSummary, .macWhoBuilds:
            return .setupSummary
        case .headsetTools:
            // The button is on the page only while the tools are missing.
            // A first pass that is checking, or could not check, points at
            // the card that says so.
            if facts.headsetTools == .missing { return .headsetGetTools }
            return mode == .review ? nil : .headsetStatus
        case .headsetCable:
            return .headsetStatus
        case .headsetDebugging:
            // The card speaks of the request only while it is unanswered.
            return mode == .review && facts.headsetConnection != .unauthorized ? nil : .headsetStatus
        case .headsetInstall:
            return facts.headsetShowsInstall ? .headsetInstall : nil
        case .headsetIntro, .headsetAccount, .headsetDeveloperMode, .headsetOpenALVR:
            return nil
        case .gameChoose:
            return facts.libraryShowsAddButtons ? .libraryAddButtons : nil
        case .gameSteam:
            return facts.libraryShowsAddButtons ? .libraryAddSteam : nil
        case .gameFolder:
            return facts.libraryShowsAddButtons ? .libraryAddFolder : nil
        case .gameCreateProfile:
            return facts.steamGameWithoutProfile.map { .libraryGameAction($0.id) }
        case .gameCopy:
            return facts.externalGame.map { .libraryGameAction($0.id) }
        case .gameStopSteam, .optionsStop:
            return facts.session == .windowsApp ? .sidebarStop : nil
        case .gameOpenVR:
            let game = mode == .review ? facts.selectedGame : facts.gameNeedingOpenVR
            return game.map(SetupTarget.libraryStatusChip)
        case .optionsLibrary:
            return facts.selectedGame.map(SetupTarget.libraryGameTile)
        case .optionsStream, .optionsOwnSettings:
            return .streamAdjust
        case .optionsConnection:
            return .settingsConnection
        case .optionsRecommended:
            return .settingsUseRecommended
        case .optionsHistory:
            return .streamRecentSessions
        case .gameWait, .launchMicrophone, .optionsOwnConnection:
            return nil
        }
    }

    // MARK: - Texts

    /// Control names come from the controls' own keys, so a hint always
    /// names a button as the button names itself.
    private func text(of step: Step) -> String {
        let play = L10n.string(.libraryPlay)
        let stop = L10n.string(.commonStop)
        let adjust = L10n.string(.streamAdjust)
        let review = mode == .review
        switch step {
        case .macSummary:
            return macSummaryText
        case .macWhoBuilds:
            // Parts the Setup page itself supplies need no one who builds.
            return L10n.string(facts.macFixedOnSetupPage ? .learningMacFixHere : .learningMacWhoBuilds,
                               L10n.string(.learningRecheck))

        case .headsetIntro:
            return L10n.string(.learningHeadsetIntro)
        case .headsetTools:
            return headsetToolsText
        case .headsetAccount:
            return L10n.string(.learningHeadsetAccount)
        case .headsetDeveloperMode:
            return L10n.string(.learningHeadsetDeveloperMode)
        case .headsetCable:
            return L10n.string(review ? .learningHeadsetReviewCable : .learningHeadsetCable)
        case .headsetDebugging:
            return L10n.string(.learningHeadsetDebugging)
        case .headsetInstall:
            let install = L10n.string(.headsetInstall)
            let download = L10n.string(.headsetDownloadInstall)
            if review, !facts.headsetShowsInstall {
                return L10n.string(.learningHeadsetReviewInstall, install)
            }
            // The app asks to replace the client only when another ALVR is
            // on the headset.
            return facts.headsetClientInstalled
                ? L10n.string(.learningHeadsetInstallReplace, install, download,
                              L10n.string(.headsetReplaceTitle), L10n.string(.headsetReplaceAction))
                : L10n.string(.learningHeadsetInstall, install, download)
        case .headsetOpenALVR:
            // The Headset page's own sentence, word for word.
            let path = L10n.string(.headsetOpenClient)
            return review ? path : L10n.string(.learningHeadsetOpenALVR, path, L10n.string(.sheetDone))

        case .gameChoose:
            return review
                ? L10n.string(.learningGameReviewAdd,
                              L10n.string(.libraryAddSteam), L10n.string(.libraryAddGameFolder))
                : L10n.string(.learningGameChoose,
                              L10n.string(.learningGameFromSteam), L10n.string(.learningGameFromFolder))
        case .gameCreateProfile:
            return L10n.string(.learningGameCreateProfile,
                               Self.shortName(facts.steamGameWithoutProfile?.name ?? ""),
                               L10n.string(.libraryCreateProfile), play)
        case .gameCopy:
            return L10n.string(.learningGameCopy,
                               Self.shortName(facts.externalGame?.name ?? ""),
                               facts.externalGame?.place ?? "", L10n.string(.libraryCopy))
        case .gameSteam:
            let other = L10n.string(.wizardOtherGame)
            let next = L10n.string(.commonNext)
            if review { return L10n.string(.learningGameReviewSteam, L10n.string(.wizardTitle), other, next) }
            return L10n.string(facts.libraryShowsAddButtons ? .learningGameSteam : .learningGameSteamPlus,
                               L10n.string(.libraryAddSteam), other, next)
        case .gameFolder:
            let choose = L10n.string(.folderImportChooseFolder)
            let add = L10n.string(.folderImportAdd)
            if review {
                return L10n.string(.learningGameReviewFolder, L10n.string(.folderImportTitle), choose, add)
            }
            return L10n.string(facts.libraryShowsAddButtons ? .learningGameFolder : .learningGameFolderPlus,
                               L10n.string(.libraryAddGameFolder), choose, add)
        case .gameWait:
            if review { return L10n.string(.learningGameReviewWait) }
            return facts.importRunning
                ? L10n.string(.learningGameWaitImport, play)
                : L10n.string(.learningGameWaitSteam, play)
        case .gameStopSteam:
            return L10n.string(review ? .learningGameReviewStop : .learningGameStopSteam, play, stop)
        case .gameOpenVR:
            if review, let game = facts.selectedGame, facts.openVRBadges[game] != .needsSetup {
                return facts.openVRBadges[game] == .installed
                    ? L10n.string(.learningGameReviewOpenVROn, L10n.string(.libraryOpenVRReady))
                    : L10n.string(.learningGameReviewOpenVRNone,
                                  L10n.string(.libraryReady), L10n.string(.libraryOpenVRSetup))
            }
            return L10n.string(.learningGameOpenVR,
                               L10n.string(.libraryOpenVRSetup), L10n.string(.openVRTitle),
                               L10n.string(.openVRDownloadEnable), L10n.string(.sheetDone))

        case .launchMicrophone:
            return L10n.string(facts.gameAudioMac ? .learningMacAudioPermission : .learningMicrophone)

        case .optionsStop:
            return L10n.string(.learningOptionsStop, adjust, stop)
        case .optionsLibrary:
            return L10n.string(.learningOptionsLibrary, play)
        case .optionsStream:
            return L10n.string(review ? .learningOptionsStreamReview : .learningOptionsStream,
                               L10n.string(.streamGame), play, adjust,
                               L10n.string(.streamGlobalSettings))
        case .optionsConnection:
            let connection = L10n.string(.streamConnection)
            return facts.connection == .wired
                ? L10n.string(.learningOptionsUSB, connection, L10n.string(.connectionUSB), play)
                : L10n.string(.learningOptionsWiFi, connection, L10n.string(.connectionWiFi), play)
        case .optionsOwnConnection:
            return L10n.string(.learningOptionsOwnConnection,
                               Self.shortName(facts.gameWithOwnSettings ?? ""),
                               adjust, Self.ownSettingsItem)
        case .optionsRecommended:
            return L10n.string(facts.recommendedPresetSelected
                               ? .learningOptionsRecommendedSet : .learningOptionsRecommended,
                               L10n.string(.settingsUseRecommended))
        case .optionsOwnSettings:
            return L10n.string(.learningOptionsOwnSettings, adjust, Self.ownSettingsItem)
        case .optionsHistory:
            return L10n.string(facts.sessionHistory.isEmpty
                               ? .learningOptionsHistoryEmpty : .learningOptionsHistory)
        }
    }

    /// The tools step: what the Headset page's last look found. A first
    /// pass from the start opens it with the chapter's first sentence.
    private var headsetToolsText: String {
        let button = L10n.string(.headsetGetTools)
        let download = L10n.string(.learningHeadsetTools, button, L10n.string(.headsetAgreeDownload))
        if mode == .review {
            return facts.headsetTools == .missing
                ? download : L10n.string(.learningHeadsetReviewTools, button)
        }
        let text: String
        switch facts.headsetTools {
        case .checking: text = L10n.string(.learningHeadsetToolsChecking)
        // The Headset page's error: its label, and the reason under "Details".
        case .failed:
            text = L10n.string(.learningHeadsetToolsFailed,
                               L10n.string(.commonError), L10n.string(.commonDetails))
        case .missing, .ready: text = download
        }
        guard headsetIntro == .pending || headsetIntro == .withTools else { return text }
        return L10n.string(.learningTwoSentences, L10n.string(.learningHeadsetIntro), text)
    }

    /// The Setup summary: ready, not checked, an unsupported Mac, or the
    /// missing parts named as their own rows name them.
    private var macSummaryText: String {
        if facts.macReady {
            return L10n.string(.learningMacReady, L10n.string(.setupBuildHelp))
        }
        if facts.setupChecks.isEmpty {
            return L10n.string(.learningMacNotChecked, L10n.string(.learningRecheck))
        }
        if macUnsupported { return L10n.string(.setupMacUnsupported) }
        let missing = facts.missingRequiredChecks
        let names = missing.compactMap(Self.plainName(of:)).map { L10n.string(.learningQuoted, $0) }
        // A part this version has no words for: the summary's own count.
        guard !names.isEmpty else { return L10n.plural(.setupStepsLeft, missing.count) }
        // As many as the strip holds; the rest are marked on the page.
        for count in stride(from: names.count, through: 2, by: -1) {
            let list = names.prefix(count).joined(separator: L10n.string(.learningListSeparator))
            let text = L10n.string(count == names.count ? .learningMacMissing : .learningMacMissingMore, list)
            if text.count <= Self.hintLimit { return text }
        }
        return L10n.string(names.count > 1 ? .learningMacMissingMore : .learningMacMissing, names[0])
    }

    /// What a part does, in the words of its row on the Setup page, without
    /// the full stop.
    private static func plainName(of check: SetupCheck) -> String? {
        let key: L10nKey
        switch check.id {
        case "wine": key = .setupEngineHelp
        case "rosetta": key = .setupRosettaHelp
        case "runtime": key = .setupRuntimeHelp
        case "dxmt": key = .setupGraphicsHelp
        default: return nil
        }
        return L10n.string(key).trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))
    }

    /// "Stream Settings for …", the menu item under "Change…".
    static var ownSettingsItem: String {
        L10n.string(.streamProfileSettings, "…").replacingOccurrences(of: "……", with: "…")
    }

    /// A game's name, cut so that a long one cannot push a hint past the
    /// strip.
    static func shortName(_ name: String) -> String {
        name.count > 24 ? name.prefix(23).trimmingCharacters(in: .whitespaces) + "…" : name
    }
}
