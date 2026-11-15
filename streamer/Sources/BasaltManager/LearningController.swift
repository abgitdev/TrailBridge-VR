import Combine
import SwiftUI
import BasaltManagerKit

/// Runs the Learning section on top of the app model. It gathers the facts
/// for the Learning page, walks the chapters and the quick path, and shows
/// launch advice. The decisions are the pure types in
/// BasaltManagerKit/Learning; this class feeds them snapshots and events and
/// shows what they describe. It only watches the model: the launch and the
/// session are never changed here.
@MainActor
final class LearningController: ObservableObject {
    /// The Learning page's own question to adb about the USB headset.
    enum HeadsetPoll: Equatable {
        /// Not asked yet.
        case pending
        /// Left out: a session runs, or the Headset page is installing.
        case skipped
        case failed
        case answered(HeadsetStatus)
    }

    private struct ShownAdvice {
        let advice: LaunchFailureAdvice
        /// Its button was pressed; the text stays, the button goes.
        var actionUsed = false
    }

    /// What holds the hint strip. Only one thing does at a time: starting
    /// another lets the one before go, and a chapter let go is paused with
    /// its step recorded. `render` draws whichever is here.
    private enum Scenario {
        case quickPath(QuickPathTour)
        case chapter(SetupTourRunner)
        case advice(ShownAdvice)
        /// A topic of "If something does not work" or "More".
        case topic(LearningTopicTour)
    }

    @Published private(set) var headsetPoll = HeadsetPoll.pending
    /// "Check again" is at work.
    @Published private(set) var isRechecking = false
    /// The quick path's strip shows a launch failure with its advice. The
    /// "How to fix" buttons elsewhere hide meanwhile: they would do nothing.
    @Published private(set) var tourShowsFailure = false
    /// The streaming start of the session the quick path completed in. While
    /// that session is live, the Stream page keeps "Can't see the game?".
    @Published private(set) var completedSessionStart: Date?
    /// Something holds the hint strip: the reminder after a break waits.
    @Published private(set) var stripTaken = false

    private let model: BasaltAppModel
    private let highlight: TourHighlight
    /// The main window, for its sheets.
    private let window: () -> NSWindow?
    /// The one store of Learning progress, for every write, on the main
    /// thread. A second store on the same file would bring back what this
    /// one has since changed.
    private let store: LearningProgressStore

    private var scenario: Scenario? {
        didSet {
            var failed = false
            if case .quickPath(let tour)? = scenario, case .failed = tour.phase { failed = true }
            if tourShowsFailure != failed { tourShowsFailure = failed }
            let taken = scenario != nil
            if stripTaken != taken { stripTaken = taken }
        }
    }

    /// The quick path, while it holds the strip.
    private var tour: QuickPathTour? {
        get {
            if case .quickPath(let tour)? = scenario { return tour }
            return nil
        }
        set {
            if let newValue {
                scenario = .quickPath(newValue)
            } else if case .quickPath? = scenario {
                scenario = nil
            }
        }
    }

    /// Launch advice, while it holds the strip.
    private var advice: ShownAdvice? {
        get {
            if case .advice(let advice)? = scenario { return advice }
            return nil
        }
        set {
            if let newValue {
                scenario = .advice(newValue)
            } else if case .advice? = scenario {
                scenario = nil
            }
        }
    }

    /// The quick path runs as the "First launch" chapter.
    private var quickPathIsChapter = false
    /// A chapter waits for the one full refresh before its first step.
    private var isPreparingChapter = false
    /// The step the strip showed last; nil while nothing holds the strip.
    private var shownStepID: String?
    /// Held only while the strip shows a quick path step or advice.
    private var sessionObservation: AnyCancellable?
    /// Held only until the headset's first frame of the live session.
    private var frameObservation: AnyCancellable?
    /// Which of the console's samples the wait for that frame has looked at.
    private var frameWatch = QuickPathFrameWatch()
    /// Held only while the strip may offer to open a section: after a
    /// failure, or with advice. Opened from the sidebar, the button must go.
    private var selectionObservation: AnyCancellable?
    /// Held only while the order card is shown: it names the connection of
    /// the next launch, which the user can still change.
    private var connectionObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    /// Held only while a topic holds the strip.
    private var topicObservation: [AnyCancellable] = []
    /// The connection of the launch under way, as it began. The strip speaks
    /// of that one until the launch ends, whatever the settings say by then.
    private var launchConnection: StreamConnectionMode?
    private var renderScheduled = false
    private var isPollingHeadset = false

    init(model: BasaltAppModel, highlight: TourHighlight, window: @escaping () -> NSWindow?) {
        self.model = model
        self.highlight = highlight
        self.window = window
        store = LearningProgressStore(
            configDirectory: model.workspace.configFolder)
        // A new person lands on the Learning page with its invitation.
        model.initialSection = { [weak self] in
            guard let self, LearningFirstRun.shouldOffer(self.facts) else { return nil }
            return .learning
        }
        // The strip's text was built in the old language. @Published emits
        // before L10n changes, so read the new language one turn later.
        languageObservation = model.$language.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
    }

    // MARK: - Ready for VR

    /// The card's rows and the main button, from the model as it is now.
    var readiness: LearningReadiness { LearningReadiness(snapshot) }

    private var snapshot: LearningReadinessSnapshot {
        var snapshot = LearningReadinessSnapshot()
        snapshot.setupChecks = model.setupChecks
        // `refresh()` fills the checks or, when it fails, leaves them empty.
        // Empty while it runs is "checking"; empty after it is a failure.
        snapshot.setupCheckFailed = model.setupChecks.isEmpty && !model.isBusy && !isRechecking

        let settings = model.displayedStreamSettings
        snapshot.connection = settings.connection
        switch headsetPoll {
        case .pending: break
        case .skipped: snapshot.headsetPollSkipped = true
        case .failed:
            snapshot.headsetPolled = true
            snapshot.headsetPollFailed = true
        case .answered(let status):
            snapshot.headsetPolled = true
            snapshot.headsetStatus = status
        }
        snapshot.sessionHistory = model.sessionHistory

        // The Stream page's rule for the game Play launches.
        // Shown by the name the Library gives it, never the profile's own key.
        let profile = model.selectedLaunchProfileName
        snapshot.gameName = profile.map(model.gameTitle(forProfile:))
        snapshot.openVRBadge = profile.flatMap { model.openVRBadges[$0] }

        switch settings.gameAudioChoice {
        case .mac:
            snapshot.macAudio = true
            snapshot.macAudioSupported = GameAudioSource.macAudioSupported
        case .device(let name) where !name.isEmpty:
            snapshot.audioDeviceName = name
            snapshot.audioDeviceAvailable = model.audioDevices.contains { $0.name == name }
        case .device, .off:
            break
        }

        snapshot.session = Self.phase(model.sessionState)
        snapshot.importRunning = model.isImportingGameFolder
        snapshot.gameDownloading = gameDownloading
        return snapshot
    }

    /// The "Game" chapter waits for Steam to finish a download, shown or
    /// paused: the card must not offer to stop Steam.
    private var gameDownloading: Bool {
        guard case .utility = model.sessionState else { return false }
        if case .chapter(let runner)? = scenario, runner.tour.waitsForGame { return true }
        return SetupTour.waitsForGame(in: facts)
    }

    /// "Check again" reads files and asks adb, so it waits for a quiet moment.
    var canRecheck: Bool {
        !isRechecking && !model.isBusy && !model.sessionState.isActive && !model.isImportingGameFolder
    }

    /// The Learning page appeared: ask adb about the USB headset, once.
    func pageOpened() async {
        await pollHeadset()
    }

    /// Reads the Mac's setup checks and the USB headset again. The shared
    /// `refresh()` is not used: it raises `isBusy` for the whole window.
    func recheck() {
        guard canRecheck else { return }
        isRechecking = true
        Task {
            await model.recheckSetup()
            await pollHeadset()
            isRechecking = false
        }
    }

    /// One read-only question to adb. Never asked for Wi-Fi, where it says
    /// nothing; never while a session runs or the Headset page installs.
    private func pollHeadset() async {
        guard model.displayedStreamSettings.connection == .wired, !isPollingHeadset else { return }
        guard !model.sessionState.isActive, model.headsetProgress == nil else {
            // An earlier answer may be stale by now, so it is not shown either.
            setHeadsetPoll(.skipped)
            return
        }
        isPollingHeadset = true
        defer { isPollingHeadset = false }
        let root = model.dataRoot
        let result = await Task.detached {
            Result { try HeadsetSetup(dataRoot: root).inspect() }
        }.value
        guard root == model.dataRoot else { return }
        switch result {
        case .success(let status): setHeadsetPoll(.answered(status))
        case .failure: setHeadsetPoll(.failed)
        }
    }

    private func setHeadsetPoll(_ value: HeadsetPoll) {
        if headsetPoll != value { headsetPoll = value }
    }

    func perform(_ action: LearningPrimaryAction) {
        switch action {
        case .startQuickPath: startQuickPath()
        case .open(let destination): open(Self.section(destination))
        case .stopWindowsApp:
            if case .utility = model.sessionState { model.stop() }
        case .recheck: recheck()
        case .wait: break
        }
    }

    // MARK: - Sections and sheets

    /// A page's sheet (Steam wizard, folder import, OpenVR support, game
    /// settings) belongs to its page: leaving the section closes it mid-work.
    private var pageSheetOpen: Bool { knownSheetOpen || window()?.attachedSheet != nil }

    /// Only the sheets the model knows. Advice after a failure is drawn while
    /// the error alert, a sheet of the window itself, is still up or closing,
    /// so that one must not count; the advice's button checks every sheet
    /// again when it is pressed.
    private var knownSheetOpen: Bool {
        model.steamWizardPresented || model.folderImportSheetPresented
    }

    /// Opens a section, unless that would close a page's open sheet.
    @discardableResult
    private func open(_ section: ManagerSection) -> Bool {
        guard model.selection != section else { return true }
        guard !pageSheetOpen else { return false }
        model.selection = section
        return true
    }

    /// For the Help menu.
    var canOpenLearning: Bool { model.selection == .learning || !pageSheetOpen }
    func openLearning() { open(.learning) }

    /// For the Help menu: either the quick path can start, or the Learning
    /// page can open to say what is missing.
    var canOfferQuickPath: Bool { !pageSheetOpen || readiness.canStartQuickPath }

    // MARK: - Quick path

    /// Starts "How to start VR again". When something stands in the way, it
    /// opens the Learning page instead: the card there names it and its
    /// button is the next real action.
    func startQuickPath() {
        guard readiness.canStartQuickPath else {
            openLearning()
            return
        }
        beginQuickPath(asChapter: false)
    }

    private func beginQuickPath(asChapter: Bool) {
        endScenario()
        quickPathIsChapter = asChapter
        shownStepID = nil
        tour = QuickPathTour(connection: model.displayedStreamSettings.connection,
                             session: Self.phase(model.sessionState))
        // A launch may already be under way; nil when none is.
        launchConnection = model.sessionState.profileName.map { model.streamSettings(for: $0).connection }
        observeSession()
        render()
    }

    /// Every change of the session state, in order and as it is assigned. A
    /// view redraw would miss a "starting" that lasts less than a frame.
    private func observeSession() {
        guard sessionObservation == nil else { return }
        let subscription = model.$sessionState.sink { [weak self] state in
            self?.sessionChanged(to: state)
        }
        // The first value arrives during `sink` and may already end the need.
        if tour != nil || advice != nil { sessionObservation = subscription }
    }

    private func sessionChanged(to state: SessionState) {
        if tour != nil {
            noteLaunchConnection(in: state)
            send(.session(Self.phase(state)))
        } else if advice != nil, state.profileName != nil {
            // A VR launch has begun, so the advice has done its work.
            dismissAdvice()
        }
    }

    /// Remembers the connection a launch begins with and forgets it when the
    /// launch ends. `launch()` works its settings out from the same values
    /// in the same turn, just before it sets "starting".
    private func noteLaunchConnection(in state: SessionState) {
        switch state {
        case .starting(let profile):
            launchConnection = model.streamSettings(for: profile).connection
        case .streaming:
            break
        case .stopped, .failed, .utility:
            launchConnection = nil
        }
    }

    private func send(_ event: QuickPathTour.Event) {
        guard var tour else { return }
        tour.handle(event)
        if tour.isFinished {
            finishQuickPath(completed: tour.phase == .completed)
            return
        }
        self.tour = tour
        syncFrameObservation()
        // A failed launch passes through "stopped" on its way to "failed" in
        // one turn; show only where it ends up.
        scheduleRender()
    }

    /// After this nothing of the quick path runs or draws: the game plays.
    private func finishQuickPath(completed: Bool) {
        tour = nil
        shownStepID = nil
        sessionObservation = nil
        frameObservation = nil
        selectionObservation = nil
        connectionObservation = nil
        launchConnection = nil
        highlight.clear()
        defer { quickPathIsChapter = false }
        guard completed else { return }
        // The quick path completes only in a live session. Remembering which
        // one is all the Stream page needs to keep "Can't see the game?"
        // until that session ends; nothing watches for the end.
        completedSessionStart = model.streamingStartedAt
        let asChapter = quickPathIsChapter
        write {
            try store.recordQuickPathCompleted()
            if asChapter { try store.recordChapterCompleted(.firstLaunch) }
        }
    }

    /// One write through the one store. A damaged or unwritable file loses
    /// nothing but this note: the store keeps it in memory until the app
    /// quits. The Learning page reads the store, so it is drawn again.
    private func write(_ body: () throws -> Void) {
        try? body()
        objectWillChange.send()
    }

    /// Listens to the session console only while the quick path waits for the
    /// headset's first frame, and lets go at that frame.
    private func syncFrameObservation() {
        guard tour?.awaitsFirstFrame == true else {
            frameObservation = nil
            return
        }
        guard frameObservation == nil else { return }
        frameWatch = QuickPathFrameWatch()
        let subscription = model.console.$samples.sink { [weak self] samples in
            self?.samplesChanged(to: samples)
        }
        // The first value arrives during `sink` and may already be the frame.
        if tour?.awaitsFirstFrame == true { frameObservation = subscription }
    }

    /// Looks only at the samples added since the last call.
    private func samplesChanged(to samples: [StreamMetricSample]) {
        guard tour?.awaitsFirstFrame == true,
              frameWatch.hasHeadsetFrame(in: samples, since: model.streamingStartedAt) else { return }
        // `send` drops the subscription: the tour no longer awaits a frame.
        send(.firstFrame)
    }

    // MARK: - The Learning page and its chapters

    /// The chapters, the invitation and where the one primary button is,
    /// from the model as it is now.
    var page: LearningPage { LearningPage(facts) }

    /// The facts the program and the chapters are built from.
    var facts: LearningFacts {
        var facts = LearningFacts()
        facts.setupChecks = model.setupChecks
        facts.pinnedEngineListed = model.engines.contains { $0.kind == .pinned && $0.supportsBasaltDXMT }
        facts.appBusy = model.isBusy
        // What the Headset page last saw; this never asks the headset itself.
        facts.headsetConnection = model.headsetStatus.connection
        facts.headsetClientInstalled = model.headsetStatus.clientInstalled
        facts.headsetClientVersion = model.headsetStatus.clientVersion
        facts.headsetChecked = model.headsetChecked
        facts.headsetScanError = model.headsetScanError
        facts.sessionHistory = model.sessionHistory
        facts.session = Self.phase(model.sessionState)
        facts.importRunning = model.isImportingGameFolder

        facts.launchableGames = model.launchableProfiles.map(\.name)
        facts.selectedGame = model.selectedLaunchProfileName
        facts.openVRBadges = model.openVRBadges
        facts.libraryShowsAddButtons = model.libraryShowsAddButtons
        let cards = model.steamGamesByLibraryFilters
        facts.steamGameWithoutProfile = cards
            .first { $0.bottleOrigin == .managed && model.profile(for: $0) == nil }
            .map { LearningLibraryGame(id: $0.id, name: $0.name) }
        facts.externalGame = cards.first { $0.bottleOrigin != .managed }
            .map { LearningLibraryGame(id: $0.id, name: $0.name, place: $0.bottleOrigin.label) }

        facts.connection = model.settings.connection
        facts.gameWithOwnSettings = gameWithOwnSettings
        facts.recommendedPresetSelected = model.settings.qualityPreset == model.qualityRecommendation.preset
        switch model.displayedStreamSettings.gameAudioChoice {
        case .mac:
            facts.gameAudioOn = GameAudioSource.macAudioSupported
            facts.gameAudioMac = facts.gameAudioOn
        case .device(let name):
            facts.gameAudioOn = !name.isEmpty && model.audioDevices.contains { $0.name == name }
            facts.gameAudioMac = false
        case .off:
            facts.gameAudioOn = false
            facts.gameAudioMac = false
        }

        facts.section = Self.destination(model.selection)
        facts.pageSheetOpen = pageSheetOpen

        facts.progress = store.progress
        facts.chapters = store.chapters
        facts.firstRunAnswered = store.firstRun != nil
        facts.progressDamaged = store.isDamaged
        return facts
    }

    /// A row's button on the Learning page.
    func perform(_ row: LearningProgramRow) {
        startChapter(row.chapter)
    }

    /// "Start" or "Not now" in the invitation. Either answer is the last time
    /// it is shown.
    func answerInvitation(_ answer: LearningFirstRunRecord.Answer) {
        let chapter = page.invitation?.chapter
        write { try store.recordFirstRunAnswer(answer) }
        switch answer {
        case .start:
            if let chapter { startChapter(chapter) }
        case .later:
            // Where the app opens without the invitation.
            open(model.missingRequiredSetupCount > 0 ? .setup : .library)
        }
    }

    /// Starts a chapter the way its row says: a first pass, "Continue" from
    /// the recorded step, or a review of a chapter that is done.
    func startChapter(_ chapter: LearningChapter) {
        guard !isPreparingChapter,
              let action = LearningProgram(facts).row(chapter)?.action else { return }
        switch action {
        case .open(let destination):
            // The chapter has no steps of its own yet.
            open(Self.section(destination))
        case .start, .resume, .review:
            let mode: SetupTour.Mode = action == .review ? .review : .firstPass
            if chapter == .firstLaunch {
                startFirstLaunch(mode)
            } else {
                begin(chapter, mode)
            }
        }
    }

    /// "First launch" ends in the quick path. What the quick path cannot
    /// begin with is opened instead, as on the "Ready for VR" card. An open
    /// Steam or a running import does not stand in the way here: the quick
    /// path's first step says what to do about them.
    private func startFirstLaunch(_ mode: SetupTour.Mode) {
        switch readiness.primaryAction {
        case .open(let destination):
            open(Self.section(destination))
        case .recheck, .wait(.checking):
            break
        case .startQuickPath, .stopWindowsApp, .wait(.importRunning), .wait(.gameDownload):
            begin(.firstLaunch, mode)
        }
    }

    private func begin(_ chapter: LearningChapter, _ mode: SetupTour.Mode) {
        endScenario()
        // Parts built while the app was open are in the Setup checks but not
        // in the engine list the Steam wizard and the folder import read.
        // One full refresh fills it, and only here.
        guard chapter == .game, facts.needsEngineRefresh else {
            show(chapter, mode)
            return
        }
        isPreparingChapter = true
        Task {
            await model.refresh()
            isPreparingChapter = false
            // Something else may have taken the strip meanwhile.
            if scenario == nil { show(chapter, mode) }
        }
    }

    private func show(_ chapter: LearningChapter, _ mode: SetupTour.Mode) {
        let paused = mode == .firstPass ? store.chapters[chapter].pausedStep : nil
        guard let tour = SetupTour(chapter: chapter, mode: mode, facts: facts, resumeAt: paused) else { return }
        shownStepID = nil
        scenario = .chapter(SetupTourRunner(
            tour: tour, model: model, window: window,
            facts: { [unowned self] in self.facts },
            changed: { [weak self] in self?.chapterChanged() }))
        chapterChanged()
    }

    /// The chapter moved: record what is to be remembered, let go of it when
    /// it is over, and draw.
    private func chapterChanged() {
        guard case .chapter(let runner)? = scenario else { return }
        let tour = runner.tour
        if tour.isCompleted, tour.mode == .firstPass, !runner.completionRecorded {
            runner.completionRecorded = true
            write { try store.recordChapterCompleted(tour.chapter) }
        }
        guard tour.isOver else {
            runner.syncObservations()
            scheduleRender()
            return
        }
        // Closed, or a VR session began: "Continue" returns to this step.
        if let step = tour.pausedStep, !tour.isCompleted {
            write { try store.recordChapterPaused(tour.chapter, atStep: step.rawValue) }
        }
        runner.stop()
        scenario = nil
        shownStepID = nil
        if tour.phase == .handOff {
            beginQuickPath(asChapter: true)
        } else {
            render()
        }
    }

    /// Whatever holds the strip lets go of it. A chapter is paused, and its
    /// step is recorded.
    private func endScenario() {
        switch scenario {
        case .quickPath:
            send(.close)
        case .chapter(let runner):
            runner.send(.close)
        case .advice:
            dismissAdvice()
        case .topic:
            sendTopic(.close)
        case nil:
            break
        }
    }

    /// The app is quitting: a chapter under way is recorded now, while the
    /// write can still finish.
    func willTerminate() {
        endScenario()
    }

    private func press(_ button: SetupButton) {
        guard case .chapter(let runner)? = scenario else { return }
        // What the app does by itself; the chapter stays as it is.
        switch button {
        case .link(let link):
            NSWorkspace.shared.open(link.url)
            return
        case .open(let destination):
            // The runner sees the section change and the step is drawn again.
            open(Self.section(destination))
            return
        default:
            break
        }
        guard let event = button.event else { return }
        switch button {
        case .checkAgain:
            // The checks are read again first; the chapter then sees them.
            // Only files are read, so an open Steam does not stand in the way.
            guard !isRechecking, !model.isBusy else { return }
            isRechecking = true
            Task {
                await model.recheckSetup()
                isRechecking = false
                guard case .chapter(let current)? = scenario, current === runner else { return }
                runner.feedFacts()
                runner.send(event)
            }
        case .continueTo(let chapter):
            runner.send(event)
            startChapter(chapter)
        case .later, .done:
            runner.send(event)
            open(.learning)
        default:
            runner.send(event)
        }
    }

    private func hint(for shown: SetupPresentation) -> TourHint {
        var hint = TourHint(id: shown.id, stepLabel: shown.label, text: shown.text)
        hint.actions = shown.buttons.map { action(for: $0, in: shown) }
        // Help that is not one of the two buttons is the quiet link.
        if !shown.buttons.contains(.help), let help = shown.help {
            hint.link = TourHint.Action(title: help.title, help: list(help, in: shown))
        }
        hint.close = TourHint.Action(title: SetupPresentation.closeTitle) { [weak self] in
            self?.endScenario()
        }
        return hint
    }

    private func action(for button: SetupButton, in shown: SetupPresentation) -> TourHint.Action {
        var action = TourHint.Action(title: shown.title(of: button),
                                     isPrimary: shown.primaryButton == button)
        if button == .help, let help = shown.help {
            action.help = list(help, in: shown)
        } else {
            action.perform = { [weak self] in self?.press(button) }
        }
        return action
    }

    private func list(_ help: SetupHelp, in shown: SetupPresentation) -> TourHint.Help {
        TourHint.Help(tips: help.tips, actions: help.options.map { action(for: $0, in: shown) })
    }

    // MARK: - How to fix

    /// The game Play launches, when it has its own stream settings, by the
    /// name the Library gives it: the hints print it.
    private var gameWithOwnSettings: String? {
        model.selectedLaunchProfileName.flatMap {
            model.profileSettings[$0] != nil ? model.gameTitle(forProfile: $0) : nil
        }
    }

    /// The advice for a failure message, for the launch the Stream page
    /// shows: its game's own stream settings, else the shared ones.
    func advice(for message: String) -> LaunchFailureAdvice? {
        LaunchFailureAdvisor.advice(for: message, context: LaunchFailureContext(
            connection: model.displayedStreamSettings.connection,
            gameWithOwnSettings: gameWithOwnSettings))
    }

    /// Shows the advice in the hint strip, above whatever page is open.
    func showAdvice(_ advice: LaunchFailureAdvice) {
        if let tour {
            // The quick path's own strip already explains this failure.
            if case .failed = tour.phase { return }
        }
        endScenario()
        self.advice = ShownAdvice(advice: advice)
        observeSession()
        render()
    }

    private func dismissAdvice() {
        advice = nil
        if tour == nil { sessionObservation = nil }
        render()
    }

    private func perform(_ action: LaunchFailureAction) {
        switch action {
        case .open(let destination):
            guard open(Self.section(destination)) else { return }
            advice?.actionUsed = true
            render()
        case .restartQuickPath:
            dismissAdvice()
            startQuickPath()
        }
    }

    // MARK: - The hint strip

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in self?.render() }
    }

    /// Draws the strip again when the user changes the section, while the
    /// strip may offer to open one. `@Published` sends before the value
    /// changes, so the drawing waits one turn.
    private func syncSelectionObservation() {
        guard tourShowsFailure || (tour == nil && advice != nil) else {
            selectionObservation = nil
            return
        }
        guard selectionObservation == nil else { return }
        selectionObservation = model.$selection.dropFirst()
            .sink { [weak self] _ in self?.scheduleRender() }
    }

    /// Draws the order card again when the connection of the next launch
    /// changes: the shared stream settings, a game's own, or the game Play
    /// launches (the preferred game, or the first one ready when it is not:
    /// the games and environments decide that). Only the order card: a step,
    /// the failure or advice drawn again could meet a closing sheet.
    /// `@Published` sends before the value changes, so the drawing waits one
    /// turn; a refresh that changes several of these draws once.
    private func syncConnectionObservation() {
        guard tour?.step == .order else {
            connectionObservation = nil
            return
        }
        guard connectionObservation == nil else { return }
        connectionObservation = Publishers.Merge5(
            model.$settings.dropFirst().map { _ in () },
            model.$profileSettings.dropFirst().map { _ in () },
            model.$preferredProfileName.dropFirst().map { _ in () },
            model.$profiles.dropFirst().map { _ in () },
            model.$bottles.dropFirst().map { _ in () })
            .sink { [weak self] in self?.scheduleRender() }
    }

    /// The one place that draws the strip, for whichever scenario holds it.
    private func render() {
        renderScheduled = false
        syncSelectionObservation()
        syncConnectionObservation()
        switch scenario {
        case .quickPath(let tour):
            let environment = QuickPathEnvironment(
                section: Self.destination(model.selection),
                pageSheetOpen: tourShowsFailure ? knownSheetOpen : pageSheetOpen,
                gameWithOwnSettings: gameWithOwnSettings,
                connection: launchConnection ?? model.displayedStreamSettings.connection)
            guard let shown = tour.presentation(in: environment) else { return }
            // Only a newly shown step opens the Stream page. Drawing the same
            // step again, as a language change does, leaves the section alone.
            if shown.opensStream(afterShowing: shownStepID) { model.selection = .stream }
            shownStepID = shown.id
            highlight.show(target: shown.target.map(Self.targetID), hint: hint(for: shown))
        case .chapter(let runner):
            // Under a sheet a chapter draws nothing: the sheet has its own steps.
            guard let shown = runner.tour.presentation else {
                highlight.clear()
                return
            }
            // Only a newly shown step opens its section, as in the quick path.
            if let destination = shown.opensSection(afterShowing: shownStepID) {
                open(Self.section(destination))
            }
            shownStepID = shown.id
            highlight.show(target: shown.target.map(TourTargetID.chapter), hint: hint(for: shown))
        case .advice(let advice):
            highlight.show(target: nil, hint: hint(for: advice))
        case .topic(let tour):
            guard let shown = tour.presentation else {
                highlight.clear()
                return
            }
            // Only a newly shown hint opens its section, as in a chapter.
            if let destination = shown.opensSection(afterShowing: shownStepID) {
                open(Self.section(destination))
            }
            shownStepID = shown.id
            highlight.show(target: shown.target.map(Self.targetID), hint: hint(for: shown))
        case nil:
            highlight.clear()
        }
    }

    private func hint(for shown: QuickPathPresentation) -> TourHint {
        var hint = TourHint(id: shown.id, stepLabel: shown.label, text: shown.text)
        hint.actions = shown.buttons.map { action(for: $0, in: shown) }
        hint.close = TourHint.Action(title: QuickPathPresentation.closeTitle) { [weak self] in
            self?.send(.close)
        }
        return hint
    }

    private func action(for button: QuickPathButton, in shown: QuickPathPresentation) -> TourHint.Action {
        var action = TourHint.Action(title: shown.title(of: button),
                                     isPrimary: shown.primaryButton == button)
        if let event = button.event {
            action.perform = { [weak self] in self?.send(event) }
        } else if case .open(let destination) = button {
            action.perform = { [weak self] in self?.openFromFailure(destination) }
        } else if let help = shown.help {
            action.help = TourHint.Help(
                tips: help.tips, actions: help.options.map { self.action(for: $0, in: shown) })
        }
        return action
    }

    /// The failure strip's "Open Headset". The failure and "Try again" stay;
    /// the button goes, because the section is open now.
    private func openFromFailure(_ destination: LearningDestination) {
        guard open(Self.section(destination)) else { return }
        render()
    }

    private func hint(for shown: ShownAdvice) -> TourHint {
        let advice = shown.advice
        var hint = TourHint(
            id: "advice-\(advice.cause.rawValue)\(shown.actionUsed ? "-used" : "")",
            stepLabel: advice.title, text: advice.text, isTourStep: false)
        hint.close = TourHint.Action(title: L(.commonClose)) { [weak self] in self?.dismissAdvice() }
        if !shown.actionUsed, let action = advice.availableAction(pageSheetOpen: knownSheetOpen),
           !isAlreadyDone(action) {
            hint.actions = [TourHint.Action(title: action.title, isPrimary: true) { [weak self] in
                self?.perform(action)
            }]
        }
        return hint
    }

    /// "Open Headset" has nothing to do on the Headset page.
    private func isAlreadyDone(_ action: LaunchFailureAction) -> Bool {
        if case .open(let destination) = action { return model.selection == Self.section(destination) }
        return false
    }

    // MARK: - Topics

    /// What a topic reads, from the model as it is now.
    private var topicFacts: LearningTopicFacts {
        var facts = LearningTopicFacts()
        facts.section = Self.destination(model.selection)
        facts.session = Self.phase(model.sessionState)
        if case .failed(let message) = model.sessionState {
            facts.knownFailure = advice(for: message)?.cause
        }
        facts.gameWithOwnSettings = gameWithOwnSettings
        facts.recommendedPresetSelected = model.settings.qualityPreset == model.qualityRecommendation.preset
        facts.blackHoleInstalled = model.audioDevices.contains {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
        }
        return facts
    }

    /// Starts a topic of "If something does not work" or "More". It shows
    /// where things are and presses nothing.
    func startTopic(_ topic: LearningTopic) {
        endScenario()
        shownStepID = nil
        scenario = .topic(LearningTopicTour(topic: topic, facts: topicFacts))
        observeTopicFacts()
        render()
    }

    /// Feeds the topic what it reads while it holds the strip. The session
    /// is read from each state as it is assigned, so a launch that begins
    /// ends the topic even when "starting" lasts less than a frame; the rest
    /// is read one turn later, since `@Published` sends before the change.
    private func observeTopicFacts() {
        let session = model.$sessionState.dropFirst().sink { [weak self] state in
            guard let self else { return }
            var facts = self.topicFacts
            facts.session = Self.phase(state)
            if case .failed(let message) = state {
                facts.knownFailure = self.advice(for: message)?.cause
            } else {
                facts.knownFailure = nil
            }
            self.sendTopic(.facts(facts))
        }
        let others = Publishers.Merge6(
            model.$selection.dropFirst().map { _ in () },
            model.$settings.dropFirst().map { _ in () },
            model.$profileSettings.dropFirst().map { _ in () },
            model.$preferredProfileName.dropFirst().map { _ in () },
            model.$profiles.dropFirst().map { _ in () },
            model.$audioDevices.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.sendTopic(.facts(self.topicFacts))
            }
        topicObservation = [session, others]
    }

    private func sendTopic(_ event: LearningTopicTour.Event) {
        guard case .topic(var tour)? = scenario else { return }
        tour.handle(event)
        guard !tour.isOver else {
            scenario = nil
            topicObservation = []
            shownStepID = nil
            // "Done" returns to the Learning page; the close button stays put.
            if tour.isCompleted { open(.learning) }
            render()
            return
        }
        scenario = .topic(tour)
        scheduleRender()
    }

    private func hint(for shown: LearningTopicPresentation) -> TourHint {
        var hint = TourHint(id: shown.id, stepLabel: shown.label, text: shown.text)
        hint.actions = shown.buttons.map { button in
            TourHint.Action(title: shown.title(of: button),
                            isPrimary: shown.primaryButton == button) { [weak self] in
                self?.sendTopic(button.event)
            }
        }
        if let list = shown.list {
            hint.link = TourHint.Action(title: list.title, help: TourHint.Help(tips: list.items))
        }
        hint.close = TourHint.Action(title: LearningTopicPresentation.closeTitle) { [weak self] in
            self?.sendTopic(.close)
        }
        return hint
    }

    // MARK: - After a long break

    /// The Stream page's line for someone who has not played for a while.
    /// `playOffered`: Play is on the page now.
    func returnReminderDue(playOffered: Bool, now: Date = Date()) -> Bool {
        var reminder = LearningReturnReminder()
        reminder.sessionHistory = model.sessionHistory
        reminder.answeredAt = store.returnReminder?.answeredAt
        reminder.progressDamaged = store.isDamaged
        reminder.playOffered = playOffered
        reminder.stripTaken = stripTaken
        return reminder.isDue(now: now)
    }

    /// The line's button: the quick path, and the line goes for this break.
    func useReturnReminder() {
        write { try store.recordReturnReminderAnswered() }
        startQuickPath()
    }

    /// The line's close button.
    func dismissReturnReminder() {
        write { try store.recordReturnReminderAnswered() }
    }

    // MARK: - The app's types and Learning's

    private static func phase(_ state: SessionState) -> LearningSessionPhase {
        switch state {
        case .stopped: return .idle
        case .starting: return .starting
        case .streaming: return .live
        case .utility: return .windowsApp
        case .failed(let message): return .failed(message)
        }
    }

    private static func section(_ destination: LearningDestination) -> ManagerSection {
        switch destination {
        case .setup: return .setup
        case .library: return .library
        case .stream: return .stream
        case .steam: return .steam
        case .headset: return .headset
        case .settings: return .settings
        case .learning: return .learning
        }
    }

    private static func destination(_ section: ManagerSection) -> LearningDestination? {
        LearningDestination.allCases.first { Self.section($0) == section }
    }

    private static func targetID(_ target: QuickPathTarget) -> TourTargetID {
        switch target {
        case .playButton: return .streamPlay
        case .statusLabel: return .streamStatus
        }
    }

    /// A control a chapter or the quick path marks already keeps its id.
    private static func targetID(_ target: LearningTopicTarget) -> TourTargetID {
        switch target {
        case .streamStatus: return .streamStatus
        case .settingsConnection: return .chapter(.settingsConnection)
        case .settingsUseRecommended: return .chapter(.settingsUseRecommended)
        case .streamHowToFix, .sidebarStream, .sidebarSession, .settingsGameAudio,
             .settingsCreateReport: return .topic(target)
        }
    }
}

private struct LearningControllerKey: EnvironmentKey {
    static let defaultValue: LearningController? = nil
}

extension EnvironmentValues {
    /// Optional for the same reason as `tourHighlight`: a window without it
    /// simply offers no learning.
    var learning: LearningController? {
        get { self[LearningControllerKey.self] }
        set { self[LearningControllerKey.self] = newValue }
    }
}
