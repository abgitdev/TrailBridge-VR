import AppKit
import Combine
import BasaltManagerKit

/// Keeps one chapter in step with the app while it holds the hint strip. It
/// feeds the chapter the facts whenever something a step reads has changed,
/// and tells the Learning controller that the chapter moved. The controller
/// draws; nothing here touches the strip or the model.
///
/// It listens only while a step is shown, and only to what that chapter
/// reads. Once the chapter is over it holds nothing.
@MainActor
final class SetupTourRunner {
    private(set) var tour: SetupTour
    /// The controller has written the chapter's completion.
    var completionRecorded = false

    private let model: BasaltAppModel
    private let window: () -> NSWindow?
    private let facts: () -> LearningFacts
    private let changed: () -> Void

    private var observation: AnyCancellable?
    /// What `observation` listens to: the chapter's publishers, or only the
    /// session while the end-of-chapter line is shown.
    private var observesStep: Bool?
    private var sheetObservers = [NSObjectProtocol]()
    /// The main window is about to show a sheet that it does not hold yet.
    private var sheetIsOpening = false
    private var feedScheduled = false

    init(tour: SetupTour, model: BasaltAppModel, window: @escaping () -> NSWindow?,
         facts: @escaping () -> LearningFacts, changed: @escaping () -> Void) {
        self.tour = tour
        self.model = model
        self.window = window
        self.facts = facts
        self.changed = changed
    }

    func send(_ event: SetupTour.Event) {
        tour.handle(event)
        changed()
    }

    /// Reads the facts and hands them to the chapter when they differ from
    /// the ones it has.
    func feedFacts() {
        feedScheduled = false
        guard !tour.isOver else { return }
        var facts = facts()
        if !sheetObservers.isEmpty {
            // While the window itself is asked, its answer is the one that
            // counts: a sheet's own "I am open" mark is cleared a moment
            // after the sheet has gone, with nothing to say when.
            facts.pageSheetOpen = sheetIsOpening || window()?.attachedSheet != nil
        }
        guard facts != tour.facts else { return }
        send(.facts(facts))
    }

    /// `@Published` sends before the value changes, so the facts are read
    /// one turn later; several changes in one turn are read once.
    private func scheduleFeed() {
        guard !feedScheduled else { return }
        feedScheduled = true
        Task { @MainActor [weak self] in self?.feedFacts() }
    }

    // MARK: - What a step listens to

    /// Call after every move of the chapter.
    func syncObservations() {
        guard !tour.isOver else {
            stop()
            return
        }
        let onStep = tour.step != nil
        if observesStep != onStep {
            observesStep = onStep
            observation = Publishers.MergeMany(onStep ? stepSignals : [signal(model.$sessionState)])
                .sink { [weak self] in self?.scheduleFeed() }
        }
        syncSheetObservers(onStep && watchesSheets)
    }

    func stop() {
        observation = nil
        observesStep = nil
        syncSheetObservers(false)
    }

    /// The session (a VR launch stops the chapter) and the section (a step
    /// asks for its page) concern every chapter; the rest is what the
    /// chapter's own steps read.
    private var stepSignals: [AnyPublisher<Void, Never>] {
        let common = [signal(model.$sessionState), signal(model.$selection)]
        switch tour.chapter {
        case .mac:
            return common + [signal(model.$setupChecks)]
        case .game:
            // The badges are assigned again when a Library sheet closes, even
            // unchanged: no duplicate filter here, or that signal is lost.
            return common + [
                signal(model.$profiles), signal(model.$bottles), signal(model.$openVRBadges),
                signal(model.$steamGames), signal(model.$games), signal(model.$folderImport),
            ]
        case .launchOptions:
            return common + [
                signal(model.$settings), signal(model.$profileSettings),
                signal(model.$preferredProfileName), signal(model.$profiles), signal(model.$bottles),
            ]
        case .headset:
            // What the Headset page's polling sees. It assigns the same
            // status every few seconds, so only a change is a signal. The
            // progress ends with the poll that shows what was installed.
            return common + [
                signal(model.$headsetStatus.removeDuplicates()),
                signal(model.$headsetScanError.removeDuplicates()),
                signal(model.$headsetCheckedRoot.removeDuplicates()),
                signal(model.$headsetProgress.removeDuplicates()),
            ]
        case .firstLaunch:
            return common
        }
    }

    private func signal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    // MARK: - Sheets

    /// The chapters whose steps open a sheet: the Steam wizard, the folder
    /// import, OpenVR support, a game's stream settings, the Headset page's
    /// downloads and its "replace the old client" question.
    private var watchesSheets: Bool {
        tour.chapter == .game || tour.chapter == .launchOptions || tour.chapter == .headset
    }

    /// The model does not say when a page's sheet closes, so the main window
    /// is asked, and only while a step needs to know.
    private func syncSheetObservers(_ wanted: Bool) {
        guard wanted != !sheetObservers.isEmpty else { return }
        let center = NotificationCenter.default
        guard wanted, let window = window() else {
            sheetObservers.forEach(center.removeObserver)
            sheetObservers = []
            sheetIsOpening = false
            return
        }
        sheetObservers = [
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    // Hide the hint at once: the sheet is about to cover it.
                    self?.sheetIsOpening = true
                    self?.feedFacts()
                }
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sheetIsOpening = false
                    // The page settles its own state as the sheet goes.
                    self?.scheduleFeed()
                }
            },
        ]
    }
}
