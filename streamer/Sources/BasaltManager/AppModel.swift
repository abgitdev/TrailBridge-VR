import Foundation
import AppKit
import CoreGraphics
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

/// Sidebar order; also the keyboard shortcut order in the View menu.
enum ManagerSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case steam = "Steam"
    case stream = "Stream"
    case bottles = "Bottles"
    case headset = "Headset"
    case setup = "Setup"
    case settings = "Settings"
    case diagnostics = "Diagnostics"
    /// The sidebar's first row. Kept last here, so the other sections keep
    /// their View menu shortcuts.
    case learning = "Learning"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .library: return "gamecontroller"
        case .steam: return "person.crop.circle.badge.checkmark"
        case .stream: return "dot.radiowaves.left.and.right"
        case .bottles: return "shippingbox"
        case .headset: return "visionpro"
        case .setup: return "checklist"
        case .settings: return "gearshape"
        case .diagnostics: return "waveform.path.ecg"
        case .learning: return "book"
        }
    }
}

/// A recording's frame summary once its CSV has been read.
enum RecordingSummaryState: Equatable {
    case ready(FrameTraceSummary)
    /// The CSV holds no frames to summarize.
    case empty
}

/// The Wine download of the Setup page.
enum WineInstallState: Equatable {
    case idle
    case downloading(received: Int64, total: Int64?)
    case verifying
    case unpacking
    /// Why it failed, in the app's language.
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .downloading, .verifying, .unpacking: return true
        case .idle, .failed: return false
        }
    }
}

enum SessionState: Equatable {
    case stopped
    case starting(profile: String)
    case streaming(profile: String)
    case utility(String)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return L10n.string(.modelNotRunning)
        case .starting: return L10n.string(.sessionConnecting)
        case .streaming(let profile): return L10n.string(.modelStreaming, profile)
        case .utility(let name): return name
        case .failed(let message): return message
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .streaming, .utility: return true
        case .stopped, .failed: return false
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

    /// The game profile of a starting or streaming session.
    var profileName: String? {
        switch self {
        case .starting(let profile), .streaming(let profile): return profile
        case .stopped, .utility, .failed: return nil
        }
    }
}

/// Whether the data folder can be used. Until it is ready nothing reads,
/// creates or writes anything in it.
enum DataFolderState: Equatable {
    case checking
    case ready
    case problem(DataFolderProblem)
}

/// The settings file is there and cannot be read. Until it is set aside no
/// data folder is opened (which one was chosen is in that file) and no
/// setting is saved.
struct SettingsFileProblem: Equatable {
    let file: URL
    /// The system's own words, for "Details".
    let detail: String
}

@MainActor
final class BasaltAppModel: ObservableObject {
    @Published var selection = ManagerSection.library
    /// Updated before publishing the checks from the same scan.
    private(set) var setupGStreamerVersion: String?
    @Published private(set) var setupChecks = [SetupCheck]()
    @Published private(set) var bottles = [ManagedBottle]()
    @Published private(set) var profiles = [LaunchProfile]()
    /// Environments and game profiles whose file cannot be read: shown with
    /// a note and a way to remove them, and their names stay taken.
    @Published private(set) var damagedBottles = [DamagedItem]()
    @Published private(set) var damagedProfiles = [DamagedItem]()
    @Published private(set) var openVRBadges = [String: OpenVRBadgeState]()
    let qualityRecommendation: StreamQualityRecommendation
    @Published private(set) var games = [DetectedGame]()
    @Published private(set) var discoveredBottles = [DiscoveredBottle]()
    @Published private(set) var steamGames = [SteamGame]()
    @Published private(set) var bsManagerInstances = [BSManagerInstance]()
    @Published private(set) var bsManagerInstallations = [BSManagerInstallation]()
    @Published private(set) var engines = [BottleEngine]()
    @Published private(set) var audioDevices = [GameAudioDevice]()
    @Published private(set) var sessionState = SessionState.stopped
    /// The log and metric samples, observed separately from this model.
    let console = SessionConsole()
    @Published var settings: StreamLaunchSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var profileSettings = [String: StreamLaunchSettings]()
    /// Diagnostic recording choices by profile name; a game without an entry records nothing.
    @Published private(set) var recordingSettings = [String: DiagnosticRecordingSettings]()
    /// Recorded sessions in the data root's Diagnostics folder, newest first.
    @Published private(set) var recordings = [DiagnosticRecording]()
    /// What limited each recording that has a frame CSV; absent while it is being read.
    @Published private(set) var recordingSummaries = [String: RecordingSummaryState]()
    /// The recording the running session is writing; never summarized or deleted.
    @Published private(set) var activeRecordingID: String?
    @Published private(set) var dataRoot: URL
    /// `.checking` and `.problem` only for a folder that was chosen or set
    /// explicitly; the default folder is created as before.
    @Published private(set) var dataFolderState = DataFolderState.ready
    /// Set while the settings file cannot be read; the window then shows
    /// only that, with the ways out.
    @Published private(set) var settingsFileProblem: SettingsFileProblem?
    /// The data folder's disk, for Settings; nil until it has been read.
    @Published private(set) var dataFolderVolume: DataFolderVolume?
    /// The first refresh of the current data folder has finished. Until then
    /// the lists are empty, or still the previous folder's, so the Library
    /// shows that it is loading instead of "No games yet".
    @Published private(set) var libraryLoaded = false
    /// Shows the question asked before the data goes to network storage.
    @Published var askingAboutNetworkDataFolder = false
    /// The checked folder that question is about.
    private var networkDataFolder: DataFolderVerdict?
    /// The latest look at the data folder; an older one that answers late is dropped.
    private var dataFolderCheckID = UUID()
    @Published private(set) var bsManagerLocation: URL?
    /// The profile the Stream page offers to play; follows the last launch.
    @Published var preferredProfileName: String? {
        didSet {
            savePreference(preferredProfileName, forKey: Self.preferredProfileKey)
        }
    }
    @Published var isBusy = false
    /// The Wine download the Setup page offers, while it runs or has failed.
    @Published private(set) var wineInstall = WineInstallState.idle
    /// The sheet that says what the download is before it starts.
    @Published var showingWineDownload = false
    /// The Rosetta command is on the clipboard.
    @Published private(set) var rosettaCommandCopied = false
    private var wineInstallTask: Task<Void, Never>?
    @Published var alertMessage: String?
    /// Finished VR sessions, newest first, persisted in the data root.
    @Published private(set) var sessionHistory = [SessionRecord]()
    /// Presents the diagnostic report sheet from Settings or the Help menu.
    @Published var showingDiagnostics = false
    @Published var headsetStatus = HeadsetStatus(connection: .noTools)
    @Published var headsetError: String?
    @Published var headsetProgress: String?
    @Published var headsetConfirmation: HeadsetConfirmation?
    @Published var trustedHeadsets = [String]()
    /// The list of trusted headsets is there and cannot be read; the
    /// Headset page offers to reset it.
    @Published var trustedHeadsetsUnreadable = false
    @Published var headsetRequests = [HeadsetRequest]()
    @Published var headsetRequest: HeadsetRequest?
    @Published var headsetScanError: String?
    /// The data folder in which the Headset page's polling last had an
    /// answer, good or bad; nil before the first one. Until then
    /// `headsetStatus` is a placeholder nobody has read.
    @Published var headsetCheckedRoot: URL?
    @Published var headsetReplacementReason = L10n.string(.modelClientSignature)
    var headsetInstallSerial: String?
    @Published var steamUpdateMessage: String?
    @Published var startDespiteSteamUpdate = false
    @Published var steamWizardChoiceID: String? {
        didSet { saveSteamWizardPreference(steamWizardChoiceID, forKey: "steamWizard.game") }
    }
    @Published var steamWizardCustomName = "steam-games" {
        didSet { saveSteamWizardPreference(steamWizardCustomName, forKey: "steamWizard.environment") }
    }
    @Published var steamWizardOtherAppID: String? {
        didSet { saveSteamWizardPreference(steamWizardOtherAppID, forKey: "steamWizard.otherAppID") }
    }
    @Published var steamWizardDisk: SteamWizardDiskState?
    @Published var steamWizardError: String?
    @Published var steamWizardChecking = false
    @Published var steamWizardWorking = false
    var steamWizardPresented = false
    @Published private(set) var steamSetupActivities = [String: SteamSetupActivity]()
    @Published private(set) var steamBootstrapReady = [String: Bool]()
    @Published private(set) var steamConnectionStates = [String: SteamConnectionState]()
    /// What went wrong with Steam in an environment, shown next to
    /// "Restart Steam" and "Close Steam".
    @Published private(set) var steamTroubles = [String: SteamTrouble]()
    /// Environments with Wine processes that no session of this app owns.
    @Published private(set) var steamLeftovers = Set<String>()
    @Published private(set) var steamRestarting = Set<String>()
    @Published private(set) var steamClosing = Set<String>()
    private var steamDownloadStalls = [String: SteamDownloadStall]()
    private var steamReadiness = [String: SteamBootstrapReadiness]()
    private var utilitySessionID: UUID?
    private var steamSetupBottleID: String?
    private var steamInstallerHasExited = false
    /// Set while a plain Steam start waits out its grace period.
    private var pendingPlainSteamStart: UUID?
    private var steamSetupWatch: Task<Void, Never>?
    private var steamConnectionWatch: Task<Void, Never>?
    private var steamConnectionObservation: (bottle: DiscoveredBottle, offset: Int, sessionID: UUID)?
    private var steamRequestProcesses = [UUID: Process]()
    private var wineShutdownFailed = false
    private var wineShutdownError: String?
    /// Add Game from Folder while it runs, and how it ended until its sheet
    /// has shown that. Kept here rather than in the sheet: changing the
    /// language rebuilds the whole window, and `refresh()` resets `isBusy`.
    @Published private(set) var folderImport: GameFolderImport?
    /// The Add Game from Folder sheet is on screen and shows the outcome.
    var folderImportSheetPresented = false
    private var folderImportCancellation: GameFolderImportCancellation?

    var missingRequiredSetupCount: Int {
        setupChecks.filter { $0.required && $0.status != .ready }.count
    }

    let repoRoot: URL
    /// Where the app may write: beside a checkout, or in the support
    /// folder when its own files are inside the app bundle.
    let workspace: AppWorkspace
    private let preferences: WorkspacePreferences
    @Published var language: AppLanguage {
        didSet {
            L10n.language = language
            savePreference(language.rawValue, forKey: "app.language")
        }
    }
    @Published var appearance: AppAppearance {
        didSet { savePreference(appearance.rawValue, forKey: "app.appearance") }
    }
    @Published var libraryVROnly = false {
        didSet { savePreference(libraryVROnly, forKey: "library.vrOnly") }
    }
    @Published var libraryShowTools = false {
        didSet { savePreference(libraryShowTools, forKey: "library.showTools") }
    }
    private(set) var manager: BottleManager

    private var streamerProcess: Process?
    private var gameProcess: Process?
    private let gameFocusKeeper = GameFocusKeeper()
    private var steamProcess: Process?
    private var controlFile: URL?
    private var activeWineCommand: BottleLaunchCommand?
    /// Identifies the in-flight `launch`. `stop()` clears it, so a launch that
    /// is still awaiting cleanup, Steam, or the streamer abandons quietly
    /// instead of starting more processes or reporting a spurious failure.
    private var activeLaunchID: UUID?
    /// The prefix shutdown `stop()` runs off the main actor, with the commands
    /// and streamers it is shutting down. `launch` waits for it before touching
    /// the bottle, and quitting repeats it synchronously so it is issued before exit.
    private var wineShutdown: (
        task: Task<Void, Never>, commands: [BottleLaunchCommand], streamers: [Process])? {
        didSet { if wineStopping != (wineShutdown != nil) { wineStopping = wineShutdown != nil } }
    }
    /// Wine is being stopped: nothing new may start in the meantime, so the
    /// buttons that would start something wait (`launchUtility` refuses it).
    @Published private(set) var wineStopping = false
    /// The note in the data folder about the session this app is running,
    /// for the next start in case this one never gets to stop it.
    private var sessionMarker: (store: SessionMarkerStore, marker: SessionMarker)?
    /// The look, once per data folder, for a session an earlier app instance
    /// left running there, and the cleanup after it.
    private var leftoverCleanup: (root: URL, task: Task<Void, Never>)?
    /// The session `launch` started; `finishSession` records it to history.
    private var openSession: (record: SessionRecord, dataRoot: URL)?
    /// The game of the running session, whose own log a diagnostic report
    /// reads anew; nil once the session has stopped.
    private var runningGame: GameLogRun?
    /// The latest capture queued, even if it finishes while a report is reading.
    private var latestGameLogCaptureID: UUID?
    /// Kept until the excerpt and its history entry have been saved. At
    /// quit, only captures the background shutdown has yet to claim are read here.
    private var pendingGameLogs = [UUID: (run: GameLogRun, claimed: Bool)]() {
        didSet {
            let pending = !pendingGameLogs.isEmpty
            if gameLogCapturePending != pending { gameLogCapturePending = pending }
        }
    }
    @Published private(set) var gameLogCapturePending = false
    var hasClaimedGameLogCapture: Bool { pendingGameLogs.values.contains(where: \.claimed) }
    /// The session whose output the log shows. A game log read after
    /// another launch or a utility has taken the log over is not named there.
    private var loggedSessionID: UUID?
    /// Each session's output and game log, read for known errors until its
    /// hints are given (`finishKnownErrors`).
    private var knownErrors = KnownErrorScanner()
    /// The session whose processes are being started: their output is read
    /// for its hints, also once it has stopped. From launch to `stop()`.
    private var scannedSessionID: UUID?
    /// When the current session started streaming; nil before that.
    var streamingStartedAt: Date? { openSession?.record.streamingStartedAt }
    private var hasChosenInitialSection = false
    /// Learning's say in the section the app opens on; nil leaves the choice as it is.
    var initialSection: (() -> ManagerSection?)?
    private static let streamSettingsKey = "BasaltVR.streamSettings.v1"
    private static let preferredProfileKey = "BasaltVR.preferredProfile"
    private static let profileSettingsKey = "BasaltVR.profileSettings.v1"
    private static let recordingSettingsKey = "BasaltVR.diagnosticRecording.v1"
    private let recordingSummaryCache = FrameTraceSummaryCache()
    private var recordingsRefreshID = UUID()
    private static let dataRootKey = "BasaltVR.dataRoot"
    private static let bsManagerLocationKey = "BasaltVR.bsManagerLocation"

    init() {
        let recommendation = StreamQualityRecommendation.currentMac()
        qualityRecommendation = recommendation
        var startupError: String?
        let discovered: URL
        do {
            discovered = try RepositoryLocator.find()
        } catch {
            let packagedSupport = Bundle.main.resourceURL?
                .appendingPathComponent("BasaltVR", isDirectory: true)
            let candidates = [
                packagedSupport,
                Bundle.main.executableURL,
            ].compactMap { $0 }
            if let bundled = candidates.lazy.compactMap({
                try? RepositoryLocator.find(startingAt: $0)
            }).first {
                discovered = bundled
            } else {
                discovered = URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true)
                startupError = error.localizedDescription
            }
        }
        repoRoot = discovered
        let workspace = AppWorkspace(repoRoot: discovered)
        self.workspace = workspace
        let defaults = WorkspacePreferences(fileURL: workspace.configFolder.appendingPathComponent(
            "manager-preferences.json"))
        preferences = defaults
        let preferredLanguages = Locale.preferredLanguages.filter { identifier in
            AppLanguage.available.contains {
                $0.rawValue == Locale(identifier: identifier).language.languageCode?.identifier
            }
        }
        language = defaults.string(forKey: "app.language").flatMap(AppLanguage.init(rawValue:))
            .flatMap { AppLanguage.available.contains($0) ? $0 : nil }
            ?? AppLanguage.preferred(from: preferredLanguages)
        appearance = defaults.string(forKey: "app.appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        steamWizardChoiceID = defaults.string(forKey: "steamWizard.game")
        steamWizardCustomName = defaults.string(forKey: "steamWizard.environment") ?? "steam-games"
        steamWizardOtherAppID = defaults.string(forKey: "steamWizard.otherAppID")
        // A file that cannot be read, or one whose data folder entry cannot:
        // either way the chosen folder is unknown, and the default one must
        // not quietly take its place.
        var settingsProblem: SettingsFileProblem?
        if let error = defaults.loadError {
            settingsProblem = SettingsFileProblem(
                file: defaults.fileURL,
                detail: (error as? WorkspacePreferences.Unreadable)?.reason ?? error.localizedDescription)
        } else if defaults.isUnreadable(String.self, forKey: Self.dataRootKey) {
            settingsProblem = SettingsFileProblem(file: defaults.fileURL, detail: Self.dataRootKey)
        }
        libraryVROnly = defaults.value(forKey: "library.vrOnly") ?? false
        libraryShowTools = defaults.value(forKey: "library.showTools") ?? false
        if let data = defaults.data(forKey: Self.streamSettingsKey),
           let decoded = try? JSONDecoder().decode(StreamLaunchSettings.self, from: data) {
            settings = decoded
        } else {
            settings = recommendation.settings
        }
        if let data = defaults.data(forKey: Self.profileSettingsKey),
           let decoded = try? JSONDecoder().decode(
            [String: StreamLaunchSettings].self, from: data) {
            profileSettings = decoded
        }
        if let data = defaults.data(forKey: Self.recordingSettingsKey),
           let decoded = try? JSONDecoder().decode(
            [String: DiagnosticRecordingSettings].self, from: data) {
            recordingSettings = decoded.filter { $0.value.isEnabled }
        }
        let start = DataFolderStart.choose(
            environment: ProcessInfo.processInfo.environment["BASALT_DATA_DIR"],
            saved: defaults.string(forKey: Self.dataRootKey), workspace: workspace)
        // The default folder is beside the app's own files and is looked at
        // here; any other is resolved once it has answered (`checkDataFolder`).
        let selectedRoot = settingsProblem == nil && start.source == .standard
            ? DataFolderStart.resolved(start.folder) : start.folder
        dataRoot = selectedRoot
        bsManagerLocation = defaults.string(forKey: Self.bsManagerLocationKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        preferredProfileName = defaults.string(forKey: Self.preferredProfileKey)
        manager = BottleManager(root: selectedRoot, repoRoot: discovered,
                                createsDataFolder: start.source == .standard)
        alertMessage = startupError
        L10n.language = language
        settingsFileProblem = settingsProblem
        if settingsProblem != nil {
            // No folder is opened and nothing is created until the person
            // has dealt with the file.
            dataFolderState = .checking
        } else {
            openDataFolder(start)
        }
        // A session that ended abnormally can leave its link file or a Wine
        // command's output behind; a running session's file is younger.
        Task.detached(priority: .utility) {
            let cutoff = Date(timeIntervalSinceNow: -86_400)
            for url in AppFootprint.temporaryFiles(
                in: FileManager.default.temporaryDirectory, olderThan: cutoff) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Starts with the folder `dataRoot` and `manager` were set to.
    private func openDataFolder(_ start: DataFolderStart) {
        if let problem = DataFolderCheck.pathProblem(dataRoot) {
            dataFolderState = .problem(problem)
        } else if start.source == .standard {
            dataFolderState = .ready
            sessionHistory = SessionHistoryStore(dataRoot: dataRoot).load()
            Task { await refresh() }
        } else {
            // A chosen folder may be on a disk that is away or a share that
            // does not answer: look at it off the main thread, touch nothing.
            dataFolderState = .checking
            Task { await checkDataFolder() }
        }
    }

    /// Moves the settings file that cannot be read out of the way, under a
    /// name that says so, and starts as with no settings: the default data
    /// folder, or the one `BASALT_DATA_DIR` names. Settings save again.
    func setSettingsFileAside() {
        guard settingsFileProblem != nil else { return }
        do {
            let moved = try preferences.setAside()
            settingsFileProblem = nil
            let start = DataFolderStart.choose(
                environment: ProcessInfo.processInfo.environment["BASALT_DATA_DIR"],
                saved: nil, workspace: workspace)
            dataRoot = start.source == .standard ? DataFolderStart.resolved(start.folder) : start.folder
            manager = BottleManager(root: dataRoot, repoRoot: repoRoot,
                                    createsDataFolder: start.source == .standard)
            alertMessage = L10n.string(.settingsFileSetAsideDone, moved.lastPathComponent)
            openDataFolder(start)
        } catch {
            alertMessage = L10n.string(.settingsFileSetAsideFailed, error.localizedDescription)
        }
    }

    /// Looks at the data folder without creating anything. When it is there,
    /// the app loads from it as at any start; when it is not, the folder
    /// stays chosen and the window says why.
    func checkDataFolder() async {
        guard settingsFileProblem == nil else { return }
        let root = dataRoot
        let id = UUID()
        dataFolderCheckID = id
        dataFolderState = .checking
        let (result, resolved) = await Task.detached {
            (DataFolderCheck().checkExisting(root), DataFolderStart.resolved(root))
        }.value
        guard dataFolderCheckID == id else { return }
        switch result {
        case .success(let volume):
            let history = await Task.detached { SessionHistoryStore(dataRoot: resolved).load() }.value
            guard dataFolderCheckID == id else { return }
            // From here on the folder is used by its resolved path, so that
            // a symbolic link on the way to it never makes two paths of one
            // place. A new manager: it remembers the disk the folder is on
            // now, and never creates the folder itself.
            if resolved.path != dataRoot.path { dataRoot = resolved }
            manager = BottleManager(root: resolved, repoRoot: repoRoot, createsDataFolder: false)
            dataFolderVolume = volume
            sessionHistory = history
            dataFolderState = .ready
            await refresh()
        case .failure(let problem):
            dataFolderVolume = nil
            dataFolderState = .problem(problem)
        }
    }

    /// After something failed: looks whether the data folder is still
    /// there, on the disk it was opened on. When it is not, the window
    /// shows the missing-folder page and this answers true, so the caller
    /// says that the disk is not connected instead of repeating what the
    /// system said about the file it could not write.
    func dataFolderHasGone() async -> Bool {
        guard dataFolderState == .ready else { return false }
        let root = dataRoot
        let opened = manager.openedDataFolder
        let result = await Task.detached {
            DataFolderCheck().checkExisting(root, opened: opened)
        }.value
        guard root == dataRoot, dataFolderState == .ready, result == .failure(.missing) else {
            return false
        }
        dataFolderVolume = nil
        dataFolderState = .problem(.missing)
        return true
    }

    /// Shows why something failed, or, when the reason is that the data
    /// folder's disk has left, that.
    func present(_ error: any Error) {
        let message = error.localizedDescription
        Task {
            alertMessage = await dataFolderHasGone()
                ? L10n.string(.dataFolderDiskNotConnected) : message
        }
    }

    /// The kind of disk and its free space for Settings, read off the main thread.
    func refreshDataFolderVolume() async {
        guard dataFolderState == .ready else { return }
        let root = dataRoot
        let result = await Task.detached { DataFolderCheck().checkExisting(root) }.value
        guard root == dataRoot, dataFolderState == .ready else { return }
        dataFolderVolume = try? result.get()
    }

    func refresh() async {
        // `prepare()` creates folders: never in place of a missing disk.
        guard dataFolderState == .ready else { return }
        // Before the library can start anything in an environment.
        await cleanUpLeftoverSession()
        isBusy = true
        let manager = manager
        let repoRoot = repoRoot
        typealias RefreshResult = Result<(
            [ManagedBottle], [LaunchProfile], [DetectedGame],
            [BottleEngine], String?, [SetupCheck], [GameAudioDevice],
            [DiscoveredBottle], [SteamGame], [BSManagerInstance],
            [BSManagerInstallation], [DamagedItem], [DamagedItem]
        ), Error>
        let bsManagerLocation = bsManagerLocation
        let result: RefreshResult = await Task.detached {
            do {
                try manager.prepare()
                let bottles = try manager.listBottles()
                let profiles = try manager.listProfiles()
                let damagedBottles = try manager.listDamagedBottles()
                let damagedProfiles = try manager.listDamagedProfiles()
                let games = GameDetector().detect(bottles: bottles, profiles: profiles)
                let (checks, gStreamerVersion) = SetupInspector(
                    repoRoot: repoRoot, manager: manager).inspectWithGStreamerVersion()
                let audio = (try? GameAudioDeviceDiscovery.inputDevices()) ?? []
                let discovered = ExternalBottleDiscovery().discover(managed: bottles)
                let steam = SteamLibraryDiscovery().discover(in: discovered)
                let bsManager = BSManagerDiscovery().discover(
                    additionalLocations: bsManagerLocation.map { [$0] } ?? [],
                    bottles: bottles)
                let bsManagerApps = BSManagerInstallationDiscovery().discover(
                    in: bottles)
                return RefreshResult.success(
                    (bottles, profiles, games, manager.engines(), gStreamerVersion, checks, audio,
                     discovered, steam, bsManager, bsManagerApps,
                     damagedBottles, damagedProfiles))
            } catch {
                return RefreshResult.failure(error)
            }
        }.value
        switch result {
        case .success(let values):
            (bottles, profiles, games, engines, setupGStreamerVersion, setupChecks, audioDevices,
             discoveredBottles, steamGames, bsManagerInstances,
             bsManagerInstallations, damagedBottles, damagedProfiles) = values
            print("BasaltVR library: \(discoveredBottles.count) bottle(s), "
                  + "\(steamGames.filter { !$0.isTool }.count) Steam game(s), "
                  + "\(bsManagerInstances.count) BSManager instance(s), "
                  + "\(bsManagerInstallations.count) BSManager app(s), "
                  + "\(profiles.count) launch profile(s)")
            var updatedSettings = settings
            updatedSettings.applyAudioDefault(devices: audioDevices)
            if updatedSettings != settings { settings = updatedSettings }
            // Open on the library once the Mac is ready; first-run users
            // land on the checks they still need to finish.
            if !hasChosenInitialSection {
                hasChosenInitialSection = true
                if selection == .library, let section = initialSection?() {
                    selection = section
                } else if selection == .library, missingRequiredSetupCount > 0 {
                    selection = .setup
                }
            }
        case .failure(let error):
            // The disk with the data folder left: the window says so on
            // its own page, and nothing was created where the disk was.
            if error is DataFolderUnavailable {
                dataFolderVolume = nil
                dataFolderState = .problem(.missing)
            } else if await !dataFolderHasGone() {
                alertMessage = error.localizedDescription
            }
        }
        if !libraryLoaded { libraryLoaded = true }
        await refreshOpenVRBadges()
        isBusy = false
    }

    /// Reads the Setup checks again and nothing else, for "Check again" on
    /// the Learning page. Unlike `refresh()` it leaves `isBusy` and every
    /// other list alone, so no button elsewhere changes state.
    func recheckSetup() async {
        guard dataFolderState == .ready else { return }
        let manager = manager
        let repoRoot = repoRoot
        let root = dataRoot
        let (checks, gStreamerVersion) = await Task.detached {
            SetupInspector(repoRoot: repoRoot, manager: manager).inspectWithGStreamerVersion()
        }.value
        // A data folder changed meanwhile has its own `refresh()`.
        guard root == dataRoot, checks != setupChecks else { return }
        setupGStreamerVersion = gStreamerVersion
        setupChecks = checks
    }

    /// File discovery never runs on the main actor or during card rendering.
    func refreshOpenVRBadges() async {
        let manager = manager
        let names = profiles.map(\.name)
        let badges = await Task.detached(priority: .utility) {
            // `listProfiles` gives unique names; a repeated one must still not trap.
            Dictionary(names.map { name in
                (name, (try? OpenVRBadgeState.inspect(profileName: name, manager: manager)) ?? .needsSetup)
            }, uniquingKeysWith: { first, _ in first })
        }.value
        openVRBadges = badges
    }

    @discardableResult
    func createBottle(name: String, engineID: String) async -> Bool {
        let manager = manager
        return await runBottleTask {
            _ = try manager.createBottle(name: name, engineID: engineID)
        }
    }

    func prepareBottle(_ name: String) async {
        let manager = manager
        await runBottleTask {
            _ = try manager.installDXMT(in: name)
            _ = try manager.installRuntime(in: name)
            _ = try manager.verify(name)
        }
    }

    @discardableResult
    func importBottle(_ bottle: DiscoveredBottle, as name: String) async -> Bool {
        guard !bottle.isManaged else { return false }
        guard let engine = engines.first(where: { $0.supportsBasaltDXMT }) else {
            alertMessage = wineDownloadOffered ? wineDownloadGuidance
                : L10n.string(.modelImportNeedsEngine)
            return false
        }
        let manager = manager
        return await runBottleTask {
            _ = try manager.importPrefix(
                name: name, engineID: engine.id, sourcePrefix: bottle.prefix)
        }
    }

    func createProfile(for game: DetectedGame) async {
        guard game.profileName == nil else { return }
        isBusy = true
        let existingNames = Set(profiles.map { $0.name.lowercased() })
        let base = sanitizedProfileName("\(game.title)-\(game.bottleName)")
        var name = base
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        do {
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: game.bottleName, source: game.source,
                executable: game.executable,
                workingDirectory: game.hostExecutable?.deletingLastPathComponent().path))
            await refresh()
        } catch {
            present(error)
            isBusy = false
        }
    }

    func createSteamProfile(for game: SteamGame) async {
        guard profile(for: game) == nil else { return }
        guard let bottle = discoveredBottles.first(where: {
            $0.id == game.bottleID && $0.managed != nil
        }), let managed = bottle.managed else {
            alertMessage = L10n.string(.modelCopyBeforeProfile, game.bottleOrigin.label)
            return
        }
        let name = uniqueProfileName(for: "\(game.name)-\(managed.name)")
        let prefix = URL(fileURLWithPath: managed.prefixPath, isDirectory: true)
        do {
            try manager.saveProfile(SteamInstallation.gameProfile(
                named: name, game: game, prefix: prefix))
            await refresh()
        } catch {
            present(error)
        }
    }

    func createBSManagerProfile(
        for instance: BSManagerInstance, in bottle: ManagedBottle
    ) async {
        let name = uniqueProfileName(
            for: "Beat-Saber-\(instance.name)-\(bottle.name)")
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        do {
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: bottle.name, source: .bsmanager,
                executable: BottleManager.winePath(
                    for: instance.executable, prefix: prefix),
                workingDirectory: instance.directory.path,
                environment: [
                    "SteamAppId": "620980",
                    "SteamGameId": "620980",
                    "SteamOverlayGameId": "620980",
                    // BSIPA uses winhttp.dll as its early bootstrap hook.
                    "WINEDLLOVERRIDES": "winhttp=n,b",
                ]))
            await refresh()
        } catch {
            present(error)
        }
    }

    /// A launch profile for a Windows game chosen by hand (GOG, itch.io, or
    /// any installer). Its folder becomes the profile's game folder
    /// (`gameRoot`).
    @discardableResult
    func createGameProfile(
        named title: String, executable: URL, source: LaunchSource,
        arguments: [String], in bottle: ManagedBottle
    ) async -> Bool {
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let folder = executable.deletingLastPathComponent()
        guard ManualGame.isInstalled(executable, inPrefix: prefix),
              let windowsExecutable = ManualGame.windowsPath(for: executable, prefix: prefix),
              let windowsFolder = ManualGame.windowsPath(for: folder, prefix: prefix) else {
            alertMessage = L10n.string(.modelInstallFirst, executable.lastPathComponent, bottle.name)
            return false
        }
        let name = uniqueProfileName(for: title)
        do {
            try manager.saveProfile(LaunchProfile(
                name: name, bottleName: bottle.name, source: source,
                executable: windowsExecutable,
                arguments: arguments,
                workingDirectory: folder.path,
                gameRoot: windowsFolder))
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func profile(for instance: BSManagerInstance) -> LaunchProfile? {
        profiles.first { profile in
            guard profile.source == .bsmanager,
                  let bottle = bottles.first(where: {
                      $0.name == profile.bottleName
                  }) else { return false }
            let expected = BottleManager.winePath(
                for: instance.executable,
                prefix: URL(fileURLWithPath: bottle.prefixPath, isDirectory: true))
            return profile.workingDirectory == instance.directory.path
                || profile.executable.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    func setBSManagerLocation(_ location: URL?) async {
        bsManagerLocation = location?.standardizedFileURL
        if let location = bsManagerLocation {
            savePreference(location.path, forKey: Self.bsManagerLocationKey)
        } else {
            savePreference(Optional<String>.none, forKey: Self.bsManagerLocationKey)
        }
        await refresh()
    }

    func profile(for game: SteamGame) -> LaunchProfile? {
        guard game.bottleOrigin == .managed else { return nil }
        return profiles.first {
            $0.bottleName == game.bottleName && $0.source == .steam
                && ($0.arguments.contains(game.appID)
                    || $0.environment["SteamAppId"] == game.appID
                    || $0.environment["SteamGameId"] == game.appID)
        }
    }

    func updateProfile(_ profile: LaunchProfile) async {
        do {
            try manager.saveProfile(profile)
            await refresh()
        } catch {
            present(error)
        }
    }

    func installOpenComposite(profileName: String, artifact: URL, target: URL) async {
        isBusy = true
        do {
            _ = try manager.installOpenComposite(
                profileName: profileName, artifact: artifact, targetDLL: target)
        } catch {
            present(error)
        }
        isBusy = false
    }

    func deleteBottle(_ name: String) async {
        guard !sessionState.isActive, !isBusy else { return }
        let manager = manager
        let removedProfiles = profiles.filter { $0.bottleName == name }.map(\.name)
        guard await runBottleTask({ try manager.deleteBottle(name) }) else { return }
        // A bottle recreated later gets the same profile names; it must not
        // inherit the deleted profiles' own stream settings.
        for profile in removedProfiles { profileSettings[profile] = nil }
        if !removedProfiles.isEmpty { persistProfileSettings() }
        // Nor may it start recording because a deleted game once did.
        if removedProfiles.contains(where: { recordingSettings[$0] != nil }) {
            for profile in removedProfiles { recordingSettings[profile] = nil }
            persistRecordingSettings()
        }
    }

    func deleteProfile(_ name: String) async {
        do {
            try manager.deleteProfile(name)
            profileSettings[name] = nil
            persistProfileSettings()
            if recordingSettings[name] != nil {
                recordingSettings[name] = nil
                persistRecordingSettings()
            }
            await refresh()
        } catch {
            present(error)
        }
    }

    /// Moves an environment or a game profile that cannot be read to the
    /// Trash: the environment's whole folder with the profiles of its
    /// games, or the profile's one file.
    func removeDamaged(_ item: DamagedItem) async {
        guard !sessionState.isActive, !isBusy, !isImportingGameFolder else { return }
        let manager = manager
        await runBottleTask { try manager.removeDamaged(item) }
    }

    func streamSettings(for profile: String) -> StreamLaunchSettings {
        var value = profileSettings[profile] ?? settings
        value.applyAudioDefault(devices: audioDevices)
        return value
    }

    func saveStreamSettings(_ value: StreamLaunchSettings, for profile: String) {
        profileSettings[profile] = value
        persistProfileSettings()
    }

    func resetStreamSettings(for profile: String) {
        profileSettings[profile] = nil
        persistProfileSettings()
    }

    // MARK: - Removing the app

    /// Where this app writes; `AppFootprint` lists what is there.
    private func footprintLocations(includingBasaltVRFolder: Bool = false) -> AppFootprint.Locations {
        .current(dataRoot: dataRoot,
                 preferencesFolder: workspace.configFolder,
                 supportFolder: workspace.isPackaged ? workspace.supportFolder : nil,
                 bundleIdentifier: Bundle.main.bundleIdentifier,
                 includesBasaltVRFolder: includingBasaltVRFolder)
    }

    /// What removing the app would delete, with sizes, and apart from it
    /// the BasaltVR folder in Application Support, which goes only when the
    /// person asks. Counting a large games folder takes a while, so it runs
    /// off the main thread.
    func appFootprint() async -> (items: [AppFootprint.Item],
                                  basaltVRFolder: AppFootprint.BasaltVRFolder?) {
        let locations = footprintLocations()
        return await Task.detached(priority: .userInitiated) {
            (AppFootprint.items(at: locations), AppFootprint.basaltVRFolder(at: locations))
        }.value
    }

    /// Stops Wine in every environment, deletes everything the app stored on
    /// this Mac, moves the app to the Trash and quits without saving window
    /// state, which would write its preferences again. The BasaltVR folder
    /// in Application Support, which the original BasaltVR app uses too,
    /// goes only with `includingBasaltVRFolder`. Returns why it could
    /// not finish; on success it does not return.
    func removeAppCompletely(includingBasaltVRFolder: Bool) async -> String? {
        guard !sessionState.isActive, activeLaunchID == nil, wineShutdown == nil else {
            return L(.uninstallBusy)
        }
        // A Wine download under way still writes into the data folder:
        // it ends, and removes its own files, before anything is deleted.
        if let task = wineInstallTask {
            task.cancel()
            await task.value
        }
        let manager = manager
        let locations = footprintLocations(includingBasaltVRFolder: includingBasaltVRFolder)
        await Task.detached { _ = manager.terminateAllBottleProcesses() }.value
        await stopADBServerStartedHere()
        if let id = locations.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        let failures = await Task.detached { () -> [String] in
            let first = AppFootprint.remove(AppFootprint.items(at: locations))
            // A refresh or a preference saved meanwhile may have written again.
            let second = AppFootprint.remove(AppFootprint.items(at: locations))
            AppFootprint.removeEmptyFolders(at: locations)
            // Never report success over files that are still there.
            let remaining = AppFootprint.items(at: locations).map(\.url.path)
            return (first + second).map { "\($0.0.url.path) (\($0.1))" }
                + remaining.filter { path in !(first + second).contains { $0.0.url.path == path } }
        }.value
        guard failures.isEmpty else {
            await refresh()
            return L(.uninstallFailed, failures.prefix(3).joined(separator: "; "))
        }
        if let id = locations.bundleIdentifier {
            // tccutil finds the app only while it is still on disk.
            _ = await Task.detached { AppPermissions.reset(bundleIdentifier: id) }.value
        }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            _ = try? await NSWorkspace.shared.recycle([app])
        }
        if let id = locations.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        AppFootprint.remove(AppFootprint.items(at: locations))
        AppFootprint.removeEmptyFolders(at: locations)
        exit(0)
    }

    // MARK: - Diagnostic recording

    /// The app's own choice for a game; both recordings are off without one.
    func recordingChoice(for profile: String) -> DiagnosticRecordingSettings {
        recordingSettings[profile] ?? DiagnosticRecordingSettings()
    }

    func saveRecordingChoice(_ value: DiagnosticRecordingSettings, for profile: String) {
        recordingSettings[profile] = value.isEnabled ? value : nil
        persistRecordingSettings()
    }

    /// What a launch of this game would record: the app's setting or the
    /// developer variables in its profile file.
    func effectiveRecording(for profile: LaunchProfile) -> DiagnosticRecordingSettings {
        recordingChoice(for: profile.name)
            .union(DiagnosticRecordingSettings(profileEnvironment: profile.environment))
    }

    /// The name the Library shows for a game profile: Steam's name for a
    /// Steam game, else the detected game's; the profile name when no game
    /// uses the profile.
    func gameTitle(forProfile name: String) -> String {
        steamGame(forProfileNamed: name)?.name ?? games.first { $0.profileName == name }?.title ?? name
    }

    /// Games whose next launch records something, by their Library names, for the reminders.
    var recordingProfileNames: [String] {
        profiles.filter { effectiveRecording(for: $0).isEnabled }.map { gameTitle(forProfile: $0.name) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var recordingsTotalBytes: Int64 { recordings.reduce(0) { $0 + $1.totalBytes } }

    /// Lists the recordings, then reads their frame CSVs off the main thread.
    func refreshRecordings() async {
        let refreshID = UUID()
        recordingsRefreshID = refreshID
        let store = DiagnosticRecordingStore(dataRoot: dataRoot)
        let listed = await Task.detached { store.list() }.value
        guard recordingsRefreshID == refreshID else { return }
        recordings = listed
        recordingSummaries = recordingSummaries.filter { id, _ in listed.contains { $0.id == id } }
        let cache = recordingSummaryCache
        let activeID = sessionState.isActive ? activeRecordingID : nil
        let summaries = await Task.detached(priority: .utility) {
            var result = [String: RecordingSummaryState]()
            cache.keep(only: listed.compactMap(\.frames))
            for recording in listed where recording.id != activeID {
                guard let frames = recording.frames else { continue }
                result[recording.id] = cache.summary(for: frames).map { .ready($0) } ?? .empty
            }
            return result
        }.value
        guard recordingsRefreshID == refreshID else { return }
        recordingSummaries = summaries
    }

    func isRecordingInProgress(_ recording: DiagnosticRecording) -> Bool {
        sessionState.isActive && recording.id == activeRecordingID
    }

    func deleteRecording(_ recording: DiagnosticRecording) async {
        guard !gameLogCapturePending, !isRecordingInProgress(recording) else { return }
        let store = DiagnosticRecordingStore(dataRoot: dataRoot)
        do {
            try await Task.detached { try store.delete(recording) }.value
        } catch {
            present(error)
        }
        await refreshRecordings()
    }

    /// Deletes every finished recording; a session still running keeps its files.
    func deleteAllRecordings() async {
        guard !gameLogCapturePending else { return }
        let store = DiagnosticRecordingStore(dataRoot: dataRoot)
        var keeping = Set<String>()
        if sessionState.isActive, let activeRecordingID { keeping.insert(activeRecordingID) }
        do {
            _ = try await Task.detached { try store.deleteAll(keeping: keeping) }.value
        } catch {
            present(error)
        }
        await refreshRecordings()
    }

    /// Moves the app to another data folder, on any disk. Nothing is moved
    /// or deleted: the old folder keeps its games and environments.
    func changeDataRoot(to root: URL) async {
        guard !sessionState.isActive else {
            alertMessage = L10n.string(.modelStopBeforeDataChange)
            return
        }
        // The app's own default folder is used as it is.
        let isStandard = root.standardizedFileURL.path == standardDataFolder.standardizedFileURL.path
        // The folder in use, chosen again after its disk left, is not made
        // anew where the disk was.
        let opened = manager.openedDataFolder
        let result = await Task.detached {
            DataFolderCheck().check(root, usingSubfolder: !isStandard, opened: opened)
        }.value
        switch result {
        case .failure(let problem):
            alertMessage = problem.message
        case .success(let verdict) where verdict.volume.kind == .network:
            networkDataFolder = verdict
            askingAboutNetworkDataFolder = true
        case .success(let verdict):
            await useDataFolder(verdict)
        }
    }

    /// "Continue" in the network storage question.
    func confirmNetworkDataFolder() async {
        guard let verdict = networkDataFolder else { return }
        networkDataFolder = nil
        await useDataFolder(verdict)
    }

    /// Where the data is without any choice: `<repo>/.local/data` in a
    /// checkout, `Data` in the support folder of a packaged app.
    var standardDataFolder: URL { workspace.standardDataFolder }

    func useStandardDataFolder() async {
        await changeDataRoot(to: standardDataFolder)
    }

    private func useDataFolder(_ verdict: DataFolderVerdict) async {
        guard !sessionState.isActive else {
            alertMessage = L10n.string(.modelStopBeforeDataChange)
            return
        }
        // A look at the old folder that is still waiting no longer counts.
        let id = UUID()
        dataFolderCheckID = id
        // The folder as chosen is what is remembered; the app works with
        // its resolved path, as after any start.
        let chosen = verdict.folder
        let folder = await Task.detached { DataFolderStart.resolved(chosen) }.value
        guard dataFolderCheckID == id, !sessionState.isActive else { return }
        let changed = folder.path != dataRoot.path
        // A Wine download into the old folder stops and cleans up there.
        if changed {
            cancelWineDownload()
            wineInstall = .idle
        }
        dataRoot = folder
        // The default folder is not a choice to remember: the next start
        // opens it as before.
        let isStandard = chosen.path == standardDataFolder.standardizedFileURL.path
        savePreference(isStandard ? nil : chosen.path, forKey: Self.dataRootKey)
        // The check has just found or made the folder: it is not made again.
        manager = BottleManager(root: folder, repoRoot: repoRoot, createsDataFolder: false)
        dataFolderVolume = verdict.volume
        // The folder has just passed the full check.
        dataFolderState = .ready
        sessionHistory = []
        // The lists still hold the previous folder's games until the refresh.
        libraryLoaded = false
        let history = await Task.detached { SessionHistoryStore(dataRoot: folder).load() }.value
        guard dataFolderCheckID == id else { return }
        sessionHistory = history
        let notes = [verdict.subfolderNote, changed ? L10n.string(.dataFolderOldStays) : nil]
            .compactMap { $0 }
        if !notes.isEmpty { alertMessage = notes.joined(separator: "\n\n") }
        await refresh()
    }

    func launchSteam(in bottle: DiscoveredBottle) {
        do {
            guard !sessionState.isActive, wineShutdown == nil else {
                throw BottleToolError(L10n.string(.modelWaitForSessionStop))
            }
            let offset = Self.fileSize(at: SteamInstallation.connectionLogURL(in: bottle.prefix)) ?? 0
            let command = try SteamInstallation.signInCommand(bottle: bottle, manager: manager)
            let id = try launchUtility(command, label: "Steam • \(bottle.name)", waitsForBottle: true)
            observeSteamConnection(in: bottle, after: offset, sessionID: id)
            // No setup can be running now; a stopped or cancelled one is stale.
            steamSetupActivities[bottle.id] = nil
            steamWizardError = nil
            if !steamWizardPresented { selection = .steam }
        } catch { reportSteamFailure(L10n.string(.modelSteamSignInFailure), error: error) }
    }

    func installSteam(in bottle: DiscoveredBottle) async {
        guard let managed = bottle.managed, !isBusy, !sessionState.isActive else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Created first and then compared by resolved paths; never the
            // data folder itself.
            let directory: URL
            do {
                directory = try HeadsetSetup.directory("Downloads", in: dataRoot)
            } catch let error as BottleToolError where error.message == HeadsetSetup.outsideDataFolder {
                throw BottleToolError(L10n.string(.modelDownloadFolderOutside))
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: SteamInstallation.installerURL)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", data.starts(with: [0x4d, 0x5a]) else {
                throw BottleToolError(L10n.string(.modelSteamDownloadFailure))
            }
            let installer = directory.appendingPathComponent("SteamSetup.exe")
            try data.write(to: installer, options: .atomic)
            runInstaller(installer, in: managed, label: "Steam installer", waitsForBottle: true)
        } catch { reportSteamFailure(L10n.string(.modelSteamInstallFailure), error: error) }
    }

    func runInstaller(_ installer: URL, in bottle: DiscoveredBottle) {
        guard let managed = bottle.managed else { return }
        runInstaller(installer, in: managed)
    }

    func runBSManagerInstaller(_ installer: URL, in bottle: ManagedBottle) {
        runInstaller(installer, in: bottle, label: L10n.string(.modelBSManagerInstaller))
    }

    func launchBSManager(_ installation: BSManagerInstallation) {
        guard let bottle = bottles.first(where: {
            $0.name == installation.bottleName
        }) else {
            alertMessage = L10n.string(.modelBSManagerBottleMissing)
            return
        }
        do {
            // Electron needs Wine's desktop shell activation path on macOS.
            // Launching the executable directly leaves app.whenReady() pending.
            // Keeping GPU work in the main process also avoids a transparent
            // Chromium window caused by cross-process surface compositing.
            // `/wait` keeps the launcher alive while BSManager runs: a bare
            // `start` exits at once, and the utility's exit handler then
            // stops every Wine process in the bottle, BSManager included.
            let command = try manager.applicationLaunchCommand(
                bottleName: bottle.name,
                executable: "start",
                arguments: [
                    "/wait",
                    "/unix",
                    installation.executable.path,
                    "--no-sandbox",
                    "--in-process-gpu",
                    "--disable-gpu",
                ],
                currentDirectory: installation.executable.deletingLastPathComponent())
            try launchUtility(command, label: "BSManager • \(bottle.name)")
        } catch {
            present(error)
        }
    }

    private func runInstaller(
        _ installer: URL, in bottle: ManagedBottle, label: String = L10n.string(.modelInstaller),
        waitsForBottle: Bool = false
    ) {
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        do {
            let command = try manager.applicationLaunchCommand(
                bottleName: bottle.name,
                executable: BottleManager.winePath(for: installer, prefix: prefix),
                currentDirectory: installer.deletingLastPathComponent())
            let discovered = DiscoveredBottle(name: bottle.name, origin: .managed, prefix: prefix, managed: bottle)
            // "Steam installer" is the internal marker; the session shows a translated label.
            let isSteamInstaller = label == "Steam installer"
            let title = isSteamInstaller
                ? L10n.string(.modelSteamInstallerLabel, bottle.name) : "\(label) • \(bottle.name)"
            try launchUtility(command, label: title, waitsForBottle: waitsForBottle,
                              steamInstaller: isSteamInstaller ? discovered : nil)
        } catch {
            if label == "Steam installer" { reportSteamFailure(L10n.string(.modelSteamInstallerFailure), error: error) }
            else { alertMessage = error.localizedDescription }
        }
    }

    func installDependency(for check: SetupCheck) async {
        switch check.id {
        case "screen":
            _ = CGRequestScreenCaptureAccess()
            await refresh()
        case "audio":
            NSWorkspace.shared.open(BlackHoleSetup.downloadURL)
        case "adb":
            selection = .headset
            headsetConfirmation = .platformTools
        case "wine" where check.offersWineDownload:
            guard !wineInstall.isRunning else { return }
            // A failed download is tried again at once: the person has
            // already agreed to it.
            if case .failed = wineInstall { startWineDownload() } else { showingWineDownload = true }
        case "gstreamer":
            NSWorkspace.shared.open(PinnedWine.gStreamerPackageURL)
        case "rosetta":
            NSPasteboard.general.clearContents()
            rosettaCommandCopied = NSPasteboard.general.setString(Rosetta.installCommand, forType: .string)
            // The button says "Copied" for a moment, then offers itself again.
            try? await Task.sleep(for: .seconds(2))
            rosettaCommandCopied = false
        case "wine", "runtime", "dxmt":
            NSWorkspace.shared.open(repoRoot.appendingPathComponent("docs/BOTTLES.md"))
        default:
            break
        }
    }

    // MARK: - Wine download

    /// The Setup page offers to download Wine: no pinned Wine is there.
    var wineDownloadOffered: Bool { setupChecks.contains(where: \.offersWineDownload) }

    /// The download button's own title.
    var wineDownloadTitle: String { L10n.string(.setupEngineDownload, PinnedWine.download.version) }

    /// Where to click, for the pages that need the engine.
    var wineDownloadGuidance: String {
        L10n.string(.engineDownloadGuidance, wineDownloadTitle, L10n.string(.sidebarSetup))
    }

    /// Downloads the pinned Wine into the data folder in use and unpacks
    /// it; the Setup check turns ready when it is done.
    func startWineDownload() {
        guard wineInstallTask == nil, dataFolderState == .ready else { return }
        let root = dataRoot
        wineInstall = .downloading(received: 0, total: nil)
        let report: @Sendable (WineInstaller.Stage) -> Void = { [weak self] stage in
            Task { @MainActor in self?.noteWineInstall(stage, in: root) }
        }
        wineInstallTask = Task { [weak self] in
            let result: Result<WineInstaller.Outcome, Error>
            do {
                result = .success(try await WineInstaller(dataRoot: root).install(progress: report))
            } catch {
                result = .failure(error)
            }
            await self?.finishWineInstall(result, in: root)
        }
    }

    /// Stops the download or the unpacking; what was written is removed.
    func cancelWineDownload() {
        wineInstallTask?.cancel()
    }

    /// At quit: stops the download and removes what it wrote so far.
    func abandonWineDownload() {
        guard let task = wineInstallTask else { return }
        task.cancel()
        WineInstaller(dataRoot: dataRoot).removeLeftovers()
    }

    private func noteWineInstall(_ stage: WineInstaller.Stage, in root: URL) {
        // A stage reported before the end may arrive after it.
        guard wineInstallTask != nil, root == dataRoot else { return }
        switch stage {
        case .downloading(let received, let total):
            wineInstall = .downloading(received: received, total: total)
        case .verifying: wineInstall = .verifying
        case .unpacking: wineInstall = .unpacking
        }
    }

    private func finishWineInstall(_ result: Result<WineInstaller.Outcome, Error>, in root: URL) async {
        wineInstallTask = nil
        switch result {
        case .success:
            wineInstall = .idle
            if root == dataRoot { await refresh() }
        case .failure(let error):
            // Cancelled, or the data folder was changed meanwhile: nothing to say.
            if error is CancellationError || root != dataRoot {
                wineInstall = .idle
            } else if await dataFolderHasGone() {
                // The window says that the disk left.
                wineInstall = .idle
            } else {
                wineInstall = .failed(error.localizedDescription)
            }
        }
    }

    static func logLine(for fix: GameCompatibilityFix) -> String {
        switch fix {
        case .vtolVRSeparateEyePasses: L10n.string(.modelGameFixVTOLEyes)
        }
    }

    func launch(profileName: String) async {
        guard !sessionState.isActive else { return }
        guard !isImportingGameFolder else { alertMessage = L10n.string(.folderImportPlayBlocked); return }
        let launchID = UUID()
        activeLaunchID = launchID
        // Stop can run at any await below; never resume a stopped launch.
        func ensureCurrent() throws {
            guard activeLaunchID == launchID else { throw CancellationError() }
        }
        do {
            let launchSettings = streamSettings(for: profileName)
            preferredProfileName = profileName
            sessionState = .starting(profile: profileName)
            selection = .stream
            let traceManager = manager
            let sessionRoot = dataRoot
            let recording = recordingChoice(for: profileName)
            // The app's setting or the profile's developer variables turn a
            // recording on. Too little free space withholds only the video.
            let (frameTrace, videoSkipped) = try await Task.detached {
                let environment = try traceManager.loadProfile(profileName).environment
                let plan = DiagnosticRecordingPlan(
                    settings: recording, profileEnvironment: environment,
                    freeBytes: DiagnosticsStorage.freeBytes(dataRoot: traceManager.paths.root))
                let session = try traceManager.prepareFrameTrace(
                    forProfile: profileName, tracesFrames: plan.recordsFrames,
                    recordsVideo: plan.recordsVideo, videoAllowed: !plan.videoSkippedForLowSpace)
                return (session, plan.videoSkippedForLowSpace)
            }.value
            try ensureCurrent()
            // Keep the previous transcript open until it can name its game log.
            await waitForGameLogCapture(latestGameLogCaptureID)
            try ensureCurrent()
            activeRecordingID = frameTrace.map { $0.csv.deletingPathExtension().lastPathComponent }
            console.restart(
                with: L10n.string(.modelPreparingProfile, profileName), transcriptURL: frameTrace?.transcript,
                transcriptRedactor: DiagnosticRedactor(dataFolder: dataRoot.path, appFolder: repoRoot.path))
            if videoSkipped {
                appendLog(L10n.string(
                    .modelRecordingVideoSkipped,
                    DiagnosticRecordingPlan.minimumFreeBytesForVideo >> 30))
            }
            openSession = (SessionRecord(profileName: profileName, settings: launchSettings), sessionRoot)
            loggedSessionID = openSession?.record.id
            if let id = loggedSessionID {
                knownErrors.begin(id, dataRoot: sessionRoot)
                scannedSessionID = id
            }

            if let wineShutdown {
                appendLog(L10n.string(.modelWaitingWineStop))
                await wineShutdown.task.value
                try ensureCurrent()
            }
            appendLog(L10n.string(.modelStoppingStaleWine))
            let manager = manager
            // A failure thrown after Stop is swallowed by the catch below.
            let cleanup = try await Task.detached {
                try manager.terminateBottleProcesses(forProfile: profileName)
            }.value
            try ensureCurrent()
            appendLog(cleanup.leftoverSweepSkipped
                ? L10n.string(.modelSkippedWineSweep)
                : L10n.string(.modelRemovedWineProcesses, Int64(cleanup.removedLeftoverProcesses)))
            if !cleanup.leftoverSweepSkipped {
                appendLog(L10n.string(.modelBottleClean))
            }

            // Keep the bottle-side DLL in lockstep with the streamer build.
            // A stale control-protocol version otherwise connects headlessly
            // and presents as a completely black headset view. Registering
            // (only when the bottle's registry no longer names this runtime)
            // cold-starts the just-stopped prefix, so keep it off the main actor,
            // and give stop() (also reached on failure) the prefix to shut down.
            activeWineCommand = try manager.prefixCommand(forProfile: profileName)
            // Wine runs in this environment from here on: leave a note for
            // the next start, in case this app never gets to stop it.
            beginSessionMarker(bottle: try manager.loadProfile(profileName).bottleName,
                               settings: launchSettings)
            try await Task.detached {
                let profile = try manager.loadProfile(profileName)
                try manager.syncRuntime(in: profile.bottleName)
            }.value
            try ensureCurrent()
            appendLog(L10n.string(.modelRuntimeSynchronized))

            _ = try manager.installSteamWebHelperCompatibility(
                forProfile: profileName)
            if let steamCommand = try manager.steamBootstrapCommand(
                forProfile: profileName) {
                let connectionLog = try manager.steamConnectionLogURL(
                    forProfile: profileName)
                let initialLogSize = connectionLog.flatMap(Self.fileSize(at:)) ?? 0
                let steam = Process()
                steam.executableURL = steamCommand.executable
                steam.arguments = steamCommand.arguments
                steam.currentDirectoryURL = steamCommand.currentDirectory
                var steamEnvironment = ProcessInfo.processInfo.environment
                steamCommand.environment.forEach {
                    steamEnvironment[$0.key] = $0.value
                }
                steam.environment = steamEnvironment
                attachOutput(of: steam, prefix: "steam: ")
                steam.terminationHandler = { [weak self] process in
                    Task { @MainActor in
                        guard let self, self.steamProcess === process else { return }
                        self.steamProcess = nil
                    }
                }
                try steam.run()
                steamProcess = steam
                activeWineCommand = steamCommand
                appendLog(L10n.string(.modelStartingSteamPrerequisite))
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try ensureCurrent()
                // A cold start remains attached. Only accept a Logged On line
                // written by this client; otherwise a historical line can race
                // a new updater/login startup. A warm invocation exits quickly
                // and may use the current session's latest state.
                let requiredOffset = steam.isRunning ? initialLogSize : 0
                appendLog(L10n.string(.modelWaitingSteamIPC))
                try await waitForSteam(
                    connectionLog: connectionLog,
                    after: requiredOffset,
                    launchID: launchID)
            }

            let profile = try manager.loadProfile(profileName)
            startDespiteSteamUpdate = false
            try await waitForSteamUpdate(profile: profile, launchID: launchID)
            try ensureCurrent()

            let streamer = try locateBuiltExecutable(named: "basalt-streamer")
            let control = FileManager.default.temporaryDirectory.appendingPathComponent(
                "basalt-manager-\(UUID().uuidString).control")
            let process = Process()
            process.executableURL = streamer
            process.arguments = launchSettings.arguments + ["--runtime", control.path]
            // Only a video recording adds this; a frame trace alone does not.
            if let recording = frameTrace?.recording(codecExtension: launchSettings.codec.rawValue) {
                process.arguments! += ["--record-video", recording.path]
            }
            if launchSettings.connection == .wifi {
                // Create an empty, private trust file before accepting any beacons.
                let store = headsetTrustStore
                do {
                    try store.prepare()
                    trustedHeadsets = try store.load()
                    trustedHeadsetsUnreadable = false
                } catch let error as HeadsetTrustStore.Unreadable {
                    // The file stays; the Headset page offers to reset it.
                    trustedHeadsetsUnreadable = true
                    throw BottleToolError(L10n.string(
                        .modelTrustListUnreadable, error.file.lastPathComponent))
                }
                process.arguments! += ["--trust-file", store.file.path]
            }
            var streamerEnvironment = ProcessInfo.processInfo.environment
            streamerEnvironment["BASALT_DATA_DIR"] = dataRoot.path
            process.environment = streamerEnvironment
            process.currentDirectoryURL = repoRoot
            attachOutput(of: process, prefix: "")
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self, self.streamerProcess === process else { return }
                    // While launch() is still starting up, it notices the exit
                    // itself and reports the streamer's own diagnostic.
                    guard self.activeLaunchID == nil else { return }
                    let sessionWasActive = self.sessionState.isActive
                    let failure = L10n.string(.modelStreamerExit, String(process.terminationStatus))
                    self.streamerProcess = nil
                    if sessionWasActive { self.finishSession(.failed, reason: failure) }
                    self.stop()
                    if sessionWasActive {
                        self.sessionState = .failed(failure)
                    }
                }
            }
            try process.run()
            streamerProcess = process
            noteStreamerInSessionMarker(process.processIdentifier)
            controlFile = control
            appendLog(L10n.string(.modelStartingStreamer, launchSettings.connection.label))

            var startupTicks = 0
            while !FileManager.default.fileExists(atPath: control.path), startupTicks < 300 {
                if !process.isRunning { break }
                // Give a new user time to read and approve a Wi-Fi request.
                if headsetRequest == nil { startupTicks += 1 }
                try await Task.sleep(nanoseconds: 100_000_000)
                try ensureCurrent()
            }
            // A streamer terminated by Stop is not a startup failure.
            try ensureCurrent()
            if !process.isRunning {
                // Give the readability handler one turn to append the final
                // stderr chunk emitted immediately before process exit.
                try? await Task.sleep(nanoseconds: 100_000_000)
                try ensureCurrent()
                throw BottleToolError(
                    StreamerLogFailure.message(in: console.log)
                        ?? L10n.string(.modelStreamerExitedBeforeReady, String(process.terminationStatus)))
            }
            guard FileManager.default.fileExists(atPath: control.path) else {
                // Startup only. Once the game is running, headset silence is
                // advisory health state; the streamer owns reconnection.
                throw BottleToolError(
                    L10n.string(.modelWaitingHeadset))
            }

            // Headset setup/approval may take time. Recheck Steam at the point
            // of launch, then repair any DLL it replaced during that interval.
            try await waitForSteamUpdate(profile: profile, launchID: launchID)
            try ensureCurrent()
            // Steam can restore its original DLL during an update or verification.
            if profile.gameRoot != nil {
                openVRBadges[profileName] = try await Task.detached {
                    try OpenVRBadgeState.inspect(profileName: profileName, manager: manager)
                }.value
                try ensureCurrent()
                let repaired = try await Task.detached {
                    try manager.repairOpenComposite(profileName: profileName)
                }.value
                try ensureCurrent()
                if repaired { appendLog(L10n.string(.modelOpenVRReinstalled)) }
                // A game update can also undo a per-game fix; reapply it here.
                // A fix that fails is reported, and the game still starts.
                let fixes = await Task.detached {
                    Result { try manager.applyGameCompatibilityFixes(profileName: profileName) }
                }.value
                try ensureCurrent()
                switch fixes {
                case .success(let applied):
                    for fix in applied { appendLog(Self.logLine(for: fix)) }
                case .failure(let error):
                    appendLog(L10n.string(.modelGameFixFailed, error.localizedDescription))
                }
                openVRBadges[profileName] = try await Task.detached {
                    try OpenVRBadgeState.inspect(profileName: profileName, manager: manager)
                }.value
                try ensureCurrent()
            }

            // The streamer can exit while this launch waits for Steam or
            // repairs OpenVR support. Its termination handler leaves the
            // report to launch(), so check again before starting the game.
            if !process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
                try ensureCurrent()
                throw BottleToolError(
                    StreamerLogFailure.message(in: console.log)
                        ?? L10n.string(.modelStreamerExitedBeforeReady, String(process.terminationStatus)))
            }
            let command = try manager.profileLaunchCommand(
                profileName, controlFile: control, frameTrace: frameTrace)
            if !command.droppedEnvironment.isEmpty {
                appendLog(L10n.string(
                    .modelProfileVariablesDropped, command.droppedEnvironment.joined(separator: ", ")))
            }
            if command.steamLaunch != nil, let executable = command.arguments.first {
                appendLog(L10n.string(.modelSteamDirectLaunch, executable))
            }
            let game = Process()
            game.executableURL = command.executable
            game.arguments = command.arguments
            game.currentDirectoryURL = command.currentDirectory
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "BASALT_FRAME_TRACE")
            environment.removeValue(forKey: "BASALT_RECORD_VIDEO")
            command.environment.forEach { environment[$0.key] = $0.value }
            // Opt-in: ask macOS to schedule the game as a foreground,
            // latency-critical process. The setting (global or per game) and
            // the older profile variable both enable it; the variable is
            // never passed to the game.
            let profileOptIn = environment.removeValue(forKey: "BASALT_GAME_PRIORITY") == "high"
            if launchSettings.gamePriorityHigh || profileOptIn {
                game.qualityOfService = .userInteractive
                appendLog(L10n.string(.modelGamePriority))
            }
            game.environment = environment
            attachOutput(of: game, prefix: "game: ")
            let gameStartedAt = Date()
            // Read after Wine shutdown (`stop`), and
            // for a diagnostic report while the game runs.
            let gameLog = command.gameLog.flatMap { search in
                openSession.map {
                    GameLogRun(search: search, gameStartedAt: gameStartedAt, profileName: profileName,
                               sessionID: $0.record.id, sessionStartedAt: $0.record.startedAt, recording: frameTrace,
                               dataRoot: sessionRoot)
                }
            }
            game.terminationHandler = { [weak self] game in
                Task { @MainActor in
                    guard let self, self.gameProcess === game else { return }
                    self.appendLog(L10n.string(.modelGameExited, String(game.terminationStatus)))
                    // A launcher that starts the game as another process, or
                    // a game that fails while loading, ends this soon; the
                    // session ends with it, so say what to try.
                    let seconds = Date().timeIntervalSince(gameStartedAt)
                    if seconds < 15 {
                        self.appendLog(L10n.string(
                            .modelGameExitedQuickly, String(Int(seconds.rounded())),
                            L10n.string(.libraryEditProfile)))
                    }
                    self.gameProcess = nil
                    self.finishSession(.ended)
                    self.stop()
                }
            }
            // Replaces attachOutput's /dev/null stdin: hello_xr quits at its EOF.
            try HeldOpenStandardInput.run(game)
            let gStreamer = GStreamerInstallation.detect()
            if let warning = console.gStreamerWarning(for: gStreamer) {
                appendLog(warning)
            }
            gameProcess = game
            runningGame = gameLog
            // The hints go by GStreamer as the game found it, even when it is
            // installed while the game runs.
            if let id = openSession?.record.id { knownErrors.gameStarted(in: id, gStreamer: gStreamer) }
            gameFocusKeeper.start(
                gamePID: game.processIdentifier,
                headsetConnected: { [weak self] in self?.console.headsetDisconnected == false },
                log: { [weak self] in self?.appendLog($0) })
            activeWineCommand = command
            activeLaunchID = nil
            openSession?.record.streamingStartedAt = Date()
            sessionState = .streaming(profile: profileName)
            selection = .stream
        } catch {
            // Stopped (or superseded by a newer launch): stop() already
            // released everything this launch started, and calling it again
            // here could tear down a session the user has since started.
            guard activeLaunchID == launchID else { return }
            finishSession(.failed, reason: error.localizedDescription)
            stop()
            sessionState = .failed(error.localizedDescription)
            present(error)
        }
    }

    /// Ends the session at once and shuts its prefix down in the background,
    /// since `wineserver --kill --wait` can take seconds. When the app is
    /// quitting, `waitingForWine` runs the shutdown before returning instead.
    func stop(waitingForWine: Bool = false) {
        utilitySessionID = nil
        steamSetupWatch?.cancel()
        steamSetupWatch = nil
        steamConnectionWatch?.cancel()
        steamConnectionWatch = nil
        steamConnectionObservation = nil
        steamConnectionStates = [:]
        // Both are about a Steam that runs; a failed stop is reported anew.
        steamTroubles = steamTroubles.filter { if case .stopFailed = $0.value { true } else { false } }
        steamDownloadStalls = [:]
        if let id = steamSetupBottleID {
            steamSetupActivities[id] = .stopped
        }
        steamSetupBottleID = nil
        for process in steamRequestProcesses.values where process.isRunning { process.terminate() }
        steamRequestProcesses = [:]
        activeLaunchID = nil
        steamUpdateMessage = nil
        startDespiteSteamUpdate = false
        headsetRequests = []
        headsetRequest = nil
        finishSession(.stopped)
        gameFocusKeeper.stop()
        let game = gameProcess
        let steam = steamProcess
        let streamer = streamerProcess
        let wineCommand = activeWineCommand
        let gameLog = runningGame
        if let gameLog {
            latestGameLogCaptureID = gameLog.sessionID
            pendingGameLogs[gameLog.sessionID] = (gameLog, false)
        }
        // Its processes' output still counts for its hints until they are given.
        let scannedSession = scannedSessionID
        scannedSessionID = nil
        // As the shutdown below takes its Wine down, Wine may say its server crashed.
        if let scannedSession { knownErrors.noteStop(of: scannedSession) }
        gameProcess = nil
        runningGame = nil
        steamProcess = nil
        streamerProcess = nil
        activeWineCommand = nil
        if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
        controlFile = nil
        if sessionState.isActive { sessionState = .stopped }

        if let game, game.isRunning { game.terminate() }
        if let steam, steam.isRunning { steam.terminate() }
        let manager = manager
        // The streamer outlives the Wine shutdown, as the game's runtime may
        // still be connected to it.
        if wineShutdown == nil {
            wineShutdownFailed = false
            wineShutdownError = nil
        }
        let shutDown = { (commands: [BottleLaunchCommand]) in
            Self.shutDownWine(commands, manager: manager, streamer: streamer)
        }
        if waitingForWine {
            // An earlier background shutdown may not finish before exit.
            let commands = (wineShutdown?.commands ?? []) + [wineCommand].compactMap { $0 }
            let result = shutDown(commands)
            let wineStopped = !result.failed && !wineShutdownFailed
            // Quitting waits for Wine anyway; the games' logs are read then
            // too, also one a shutdown still under way has not read yet.
            let unclaimed = pendingGameLogs.values.filter { !$0.claimed }.map(\.run)
            for run in unclaimed.sorted(by: { $0.sessionStartedAt < $1.sessionStartedAt }) {
                let saved = run.save(redactedWith: gameLogRedactor(for: run),
                                     wineMayBeRunning: result.failedPrefixes.contains(run.search.prefix.path))
                noteGameLog(run, saved: saved)
            }
            // Every session yet to give its hints gives them now, with or
            // without its game's log, before the transcript closes.
            // Lines still queued while this teardown blocks may not be read.
            knownErrors.unfinished.forEach(finishKnownErrors(of:))
            for pending in wineShutdown?.streamers ?? [] where pending.isRunning {
                pending.terminate()
            }
            // On its way out the streamer puts the Mac's audio output back
            // and removes its adb forwards: give it a moment before the app
            // is gone, but never hold the quit for long. One that is still
            // running then keeps its marker, for the next start to stop it;
            // so does Wine that could not be stopped.
            let streamers = (wineShutdown?.streamers ?? []) + [streamer].compactMap { $0 }
            let streamersGone = SessionTeardown.wait(
                upTo: 3, until: { !streamers.contains(where: \.isRunning) })
            endSessionMarker(stopped: streamersGone && wineStopped)
            console.closeTranscript()
            return
        }
        guard let wineCommand else {
            _ = shutDown([])
            if let gameLog { captureGameLog(gameLog, wineMayBeRunning: true) }
            // A launch sets its Wine command before it starts any process: no pipe to wait for.
            if let scannedSession { finishKnownErrorsAfterGameLog(of: scannedSession) }
            // An earlier shutdown still running closes it when it finishes.
            if wineShutdown == nil, !gameLogCapturePending { console.closeTranscript() }
            return
        }
        queueWineShutdown(wineCommand, streamer: streamer, gameLog: gameLog, session: scannedSession)
    }

    /// Stops Wine for `command` off the main actor, after any stop already
    /// under way, and lists it in `wineShutdown`: a launch waits for it, and
    /// a later stop runs after it. Every stop goes through here, so that a
    /// late forced sweep can never meet processes started after it. With
    /// `gameLog`, the game's log is read after the shutdown attempt; with
    /// `session`, that session's hints are given after it.
    private func queueWineShutdown(_ command: BottleLaunchCommand, streamer: Process? = nil,
                                   gameLog: GameLogRun? = nil, session: UUID? = nil) {
        if wineShutdown == nil {
            wineShutdownFailed = false
            wineShutdownError = nil
        }
        let previous = wineShutdown
        let manager = manager
        let task = Task.detached { [weak self] in
            await previous?.task.value
            let result = Self.shutDownWine([command], manager: manager, streamer: streamer)
            if let session { await self?.waitForOutputToEnd(of: session) }
            await self?.finishWineShutdown(message: result.message, failed: result.failed,
                                           stopped: result.stopped, failedPrefixes: result.failedPrefixes,
                                           gameLog: gameLog, session: session)
        }
        wineShutdown = (task, (previous?.commands ?? []) + [command],
                        (previous?.streamers ?? []) + [streamer].compactMap { $0 })
    }

    /// Bounded: a Wine that does not answer is stopped by force
    /// (`BottleManager.wineStopLimit`).
    nonisolated private static func shutDownWine(
        _ commands: [BottleLaunchCommand], manager: BottleManager, streamer: Process?
    ) -> (message: String?, failed: Bool, stopped: [String], failedPrefixes: [String]) {
        var message: String?
        var failed = false
        var stopped = [String]()
        var failedPrefixes = [String]()
        for command in commands {
            do {
                let cleanup = try manager.terminateBottleProcesses(launchedWith: command)
                message = cleanup.leftoverSweepSkipped
                    ? L10n.string(.modelSkippedWineSweep)
                    : L10n.string(.modelRemovedWineProcesses, Int64(cleanup.removedLeftoverProcesses))
                if cleanup.forcedStop { message = L10n.string(.modelWineForcedStop) + (message ?? "") }
                if let prefix = prefix(of: command) { stopped.append(prefix) }
            } catch {
                failed = true
                message = L10n.string(.modelWineCleanupFailed, error.localizedDescription)
                if let prefix = prefix(of: command) { failedPrefixes.append(prefix) }
            }
        }
        if let streamer, streamer.isRunning { streamer.terminate() }
        return (message, failed, stopped, failedPrefixes)
    }

    private func finishWineShutdown(message: String?, failed: Bool, stopped: [String], failedPrefixes: [String],
                                    gameLog: GameLogRun?, session: UUID?) {
        wineShutdownFailed = wineShutdownFailed || failed
        if failed { wineShutdownError = message }
        // What Steam's panel says about this environment's last stop.
        for bottle in discoveredBottles {
            if failedPrefixes.contains(bottle.prefix.path) {
                steamTroubles[bottle.id] = .stopFailed(message ?? L10n.string(.modelNoReason))
            } else if stopped.contains(bottle.prefix.path), case .stopFailed = steamTroubles[bottle.id] {
                steamTroubles[bottle.id] = nil
            }
        }
        if let message { appendLog(message) }
        // Shutdowns run in order, so the one finishing is the oldest listed.
        guard var pending = wineShutdown else { return }
        pending.commands.removeFirst()
        pending.streamers.removeAll { !$0.isRunning }
        wineShutdown = pending.commands.isEmpty ? nil : pending
        if let gameLog { captureGameLog(gameLog, wineMayBeRunning: failed) }
        if let session { finishKnownErrorsAfterGameLog(of: session) }
        if wineShutdown == nil, !sessionState.isActive, !gameLogCapturePending { console.closeTranscript() }
        // A launch waits for this shutdown before it writes its own marker.
        // Wine that could not be stopped keeps it, for the next start.
        if wineShutdown == nil { endSessionMarker(stopped: !wineShutdownFailed) }
    }

    // MARK: - Session marker

    /// From here on Wine may run in `bottle` for this session.
    private func beginSessionMarker(bottle: String, settings: StreamLaunchSettings) {
        guard let app = SessionMarker.ProcessIdentity.of(getpid()) else { return }
        let store = SessionMarkerStore(dataRoot: dataRoot)
        let marker = SessionMarker(
            app: app, startingIn: bottle, audio: .expected(for: settings),
            adbServerStarted: AlvrADBServerOwnership.shared.hasStarted, keeping: store.load())
        sessionMarker = (store, marker)
        // A session is not refused over its marker.
        try? store.write(marker)
    }

    private func noteStreamerInSessionMarker(_ pid: Int32) {
        guard var current = sessionMarker else { return }
        current.marker.streamer = .of(pid)
        sessionMarker = current
        try? current.store.write(current.marker)
    }

    /// The streamer has said that it started the adb server: the next
    /// start stops that server if this app never gets to.
    private func noteADBServerInSessionMarker() {
        guard var current = sessionMarker, !current.marker.adbServerStarted else { return }
        current.marker.adbServerStarted = true
        sessionMarker = current
        try? current.store.write(current.marker)
    }

    private func endSessionMarker(stopped: Bool) {
        if let current = sessionMarker { current.store.end(current.marker, stopped: stopped) }
        sessionMarker = nil
    }

    /// Once per data folder: when an app instance that is gone left a
    /// session marker there, stops what that session left running. Every
    /// `refresh()` waits for it, so nothing starts in an environment that
    /// is still being stopped; the wait is bounded (`LeftoverSession`), and
    /// what could not be stopped in time is left for the next start.
    private func cleanUpLeftoverSession() async {
        let root = dataRoot
        if leftoverCleanup?.root != root {
            let repoRoot = repoRoot
            let paths = manager.paths
            let task = Task.detached { [weak self] in
                let cleanup = LeftoverSession.cleanUp(
                    in: SessionMarkerStore(dataRoot: root),
                    stopADBServer: { HeadsetSetup(dataRoot: root).stopServerLeftByEarlierRun() },
                    bottleExists: { name in
                        guard let folder = try? paths.bottleDirectory(name) else { return false }
                        return FileManager.default.fileExists(atPath: folder.path)
                    },
                    stopWine: { name, timeout in
                        // The stop every Play runs first, for a named
                        // environment; here a wineserver that does not
                        // answer in time is given up on.
                        let manager = BottleManager(
                            root: root, repoRoot: repoRoot,
                            runner: ProcessBottleCommandRunner(timeout: timeout))
                        let bottle = try manager.loadBottle(name)
                        try manager.terminateBottleProcesses(launchedWith: BottleLaunchCommand(
                            executable: URL(fileURLWithPath: bottle.wineBinaryPath), arguments: [],
                            environment: ["WINEPREFIX": bottle.prefixPath, "WINEARCH": "win64",
                                          "WINEDEBUG": "-all"],
                            currentDirectory: nil))
                    })
                guard let cleanup else { return }
                await self?.appendLog(L10n.string(cleanup.unfinished.isEmpty
                    ? .modelLeftoverSessionCleaned : .modelLeftoverSessionNotStopped))
            }
            leftoverCleanup = (root, task)
        }
        await leftoverCleanup?.task.value
    }

    /// Stops the adb server when this app run started it; one that was
    /// already running belongs to someone else and stays.
    func stopADBServerStartedHere() async {
        let root = dataRoot
        await Task.detached { _ = HeadsetSetup(dataRoot: root).stopServerIfStartedHere() }.value
    }

    private func waitForSteamUpdate(profile: LaunchProfile, launchID: UUID) async throws {
        guard profile.source == .steam else { return }
        let manager = manager
        let bottle = try manager.loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath)
        let manifest = try await Task.detached {
            try SteamUpdateState.manifestURL(profile: profile, prefix: prefix)
        }.value
        guard activeLaunchID == launchID else { throw CancellationError() }
        guard let manifest else { return }
        defer { steamUpdateMessage = nil }
        let title = gameTitle(forProfile: profile.name)
        let contentLog = SteamInstallation.contentLogURL(in: prefix)
        let bottleName = bottle.name
        // A game update that stands still is only reported: Stop and Play
        // start Steam again (`SteamDownloadStall`).
        var stall = SteamDownloadStall()
        var stalled = false
        try await SteamUpdateWaiter.wait(read: {
            guard self.activeLaunchID == launchID else { throw CancellationError() }
            let (state, activity, logSize) = try await Task.detached {
                let state = try SteamUpdateState.parse(String(contentsOf: manifest, encoding: .utf8))
                return (state, try? manager.ioActivity(inBottle: bottleName), Self.fileSize(at: contentLog))
            }.value
            stalled = stall.observe(downloading: state.isDownloadRunning, activity: activity,
                                    contentLogSize: logSize, now: ProcessInfo.processInfo.systemUptime)
            return state
        }, startAnyway: { self.startDespiteSteamUpdate }, onWaiting: { state in
            self.steamUpdateMessage = state == nil
                ? L10n.string(.modelWaitingSteamStatus, title)
                : stalled ? L10n.string(.modelSteamGameUpdateStalled, title)
                : L10n.string(.modelSteamUpdatingGame, title)
        })
    }

    private func waitForSteam(
        connectionLog: URL?, after offset: Int, launchID: UUID
    ) async throws {
        guard let connectionLog else {
            throw BottleToolError(
                L10n.string(.modelSteamLogMissing))
        }
        for _ in 0..<240 {
            guard activeLaunchID == launchID else { throw CancellationError() }
            if let data = try? Data(contentsOf: connectionLog),
               SteamConnectionLog.state(in: data, after: offset) == .loggedOn {
                appendLog(L10n.string(.modelSteamSignedInLaunch))
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw BottleToolError(
            L10n.string(.modelSteamNotSignedIn))
    }

    nonisolated private static func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    @discardableResult
    private func runBottleTask(_ operation: @escaping @Sendable () throws -> Void) async -> Bool {
        isBusy = true
        do {
            try await Task.detached(operation: operation).value
            await refresh()
            return true
        } catch {
            present(error)
            isBusy = false
            return false
        }
    }

    private func sanitizedProfileName(_ value: String) -> String {
        ProfileNaming.slug(value)
    }

    private func uniqueProfileName(for value: String) -> String {
        // A profile that cannot be read keeps its file name taken.
        ProfileNaming.unique(value, existing: profiles.map(\.name) + damagedProfiles.map(\.name))
    }

    private func savePreference<T: Encodable>(_ value: T?, forKey key: String) {
        do { try preferences.set(value, forKey: key) }
        catch { alertMessage = L10n.string(.modelSaveSettingsFailure, error.localizedDescription) }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            savePreference(data, forKey: Self.streamSettingsKey)
        }
    }

    private func persistProfileSettings() {
        if let data = try? JSONEncoder().encode(profileSettings) {
            savePreference(data, forKey: Self.profileSettingsKey)
        }
    }

    private func persistRecordingSettings() {
        if let data = try? JSONEncoder().encode(recordingSettings) {
            savePreference(data, forKey: Self.recordingSettingsKey)
        }
    }

    private func locateBuiltExecutable(named name: String) throws -> URL {
        let build = repoRoot.appendingPathComponent("streamer/.build", isDirectory: true)
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            build.appendingPathComponent("release/\(name)"),
            build.appendingPathComponent("debug/\(name)"),
            build.appendingPathComponent("arm64-apple-macosx/release/\(name)"),
            build.appendingPathComponent("arm64-apple-macosx/debug/\(name)"),
        ].compactMap { $0 }
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) { return found }
        throw BottleToolError(
            L10n.string(.modelExecutableNotBuilt, name))
    }

    private func attachOutput(of process: Process, prefix: String) {
        // GUI utilities must not inherit BasaltVR's terminal. Foundation starts
        // child processes in their own process group, so an Electron app that
        // probes inherited stdin can otherwise be stopped by SIGTTIN when
        // BasaltVR itself was launched from a shell.
        process.standardInput = FileHandle.nullDevice

        // Keep stdout and stderr on distinct handles. Reusing one Foundation
        // Pipe for both descriptors works for simple Wine programs, but
        // Electron reconstructs process.stderr as a Node socket and sees the
        // shared descriptor as EBADF during bootstrap.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        for pipe in [outputPipe, errorPipe] {
            // One stream per pipe delivers its chunks to the main actor in
            // order; a Task per chunk could run them out of order.
            let source = ObjectIdentifier(pipe)
            console.registerOutputSource(source)
            if let session = scannedSessionID, let printer = KnownErrorScanner.Printer(rawValue: prefix) {
                knownErrors.attach(source, printer: printer, to: session)
            }
            // When the pipe got each chunk: Stop's cutoff for the hints.
            let (chunks, continuation) = AsyncStream.makeStream(
                of: (data: Data, receivedAt: ContinuousClock.Instant).self)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield((data, .now))
            }
            Task { @MainActor [weak self] in
                var lastReceived = ContinuousClock.now
                for await chunk in chunks {
                    lastReceived = chunk.receivedAt
                    self?.appendLog(String(decoding: chunk.data, as: UTF8.self),
                                    from: source, prefix: prefix, receivedAt: chunk.receivedAt)
                }
                self?.finishLog(from: source, prefix: prefix, receivedAt: lastReceived)
            }
        }
    }

    @discardableResult
    private func launchUtility(_ command: BottleLaunchCommand, label: String,
                               waitsForBottle: Bool = false,
                               steamInstaller: DiscoveredBottle? = nil) throws -> UUID {
        guard !sessionState.isActive else {
            throw BottleToolError(L10n.string(.modelStopCurrentSession))
        }
        guard wineShutdown == nil else {
            throw BottleToolError(L10n.string(.modelWineStillStopping))
        }
        guard !isImportingGameFolder else { throw BottleToolError(L10n.string(.folderImportBusy)) }
        let process = Process()
        let sessionID = UUID()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        var environment = ProcessInfo.processInfo.environment
        // Terminals inside Electron apps such as VS Code may export this so
        // their own Electron helper processes behave like Node. Forwarding it
        // through Wine makes packaged Windows Electron apps such as BSManager
        // run their main script as a plain Node process instead of creating
        // an application window.
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        command.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        attachOutput(of: process, prefix: "wine: ")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.gameProcess === process, self.utilitySessionID == sessionID else { return }
                self.appendLog(L10n.string(.modelUtilityExited, label, String(process.terminationStatus)))
                self.gameProcess = nil
                if let steamInstaller {
                    if !self.steamInstallerHasExited {
                        self.steamInstallerHasExited = true
                        self.handleSteamInstallerExit(in: steamInstaller, sessionID: sessionID)
                    }
                } else if waitsForBottle {
                    // Steam replaces its bootstrap process during updates. Own
                    // the prefix until its final client exits, not just the bootstrap.
                    do { try self.watchUtilityBottle(command, label: label) }
                    catch {
                        self.alertMessage = error.localizedDescription
                        self.stop()
                    }
                } else { self.stop() }
                await self.refresh()
            }
        }
        try process.run()
        gameProcess = process
        utilitySessionID = sessionID
        activeWineCommand = command
        sessionState = .utility(label)
        console.restart(with: L10n.string(.modelLaunchingUtility, label), clearingSamples: false)
        loggedSessionID = nil
        if !steamWizardPresented { selection = .stream }
        if let steamInstaller {
            steamSetupBottleID = steamInstaller.id
            steamInstallerHasExited = false
            steamReadiness[steamInstaller.id] = SteamBootstrapReadiness()
            steamBootstrapReady[steamInstaller.id] = false
            steamSetupActivities[steamInstaller.id] = .installer
        }
        return sessionID
    }

    private func watchUtilityBottle(_ command: BottleLaunchCommand, label: String) throws {
        let waiter = Process()
        waiter.executableURL = command.executable.deletingLastPathComponent().appendingPathComponent("wineserver")
        waiter.arguments = ["--wait"]
        waiter.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, scoped in scoped }
        attachOutput(of: waiter, prefix: "wine: ")
        waiter.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.gameProcess === process else { return }
                self.gameProcess = nil
                self.stop()
                await self.refresh()
            }
        }
        try waiter.run()
        gameProcess = waiter
    }

    func reportSteamFailure(_ lead: String, error: Error) {
        let message = SteamWizardCopy.failure(lead, detail: error.localizedDescription)
        steamWizardError = message
        alertMessage = message
    }

    private func saveSteamWizardPreference<T: Encodable>(_ value: T?, forKey key: String) {
        do { try preferences.set(value, forKey: key) }
        catch { reportSteamFailure(L10n.string(.modelSaveWizardFailure), error: error) }
    }

    @discardableResult
    func checkSteamBootstrap(in bottle: DiscoveredBottle) -> Bool {
        guard let steam = SteamInstallation.executable(in: bottle.prefix) else {
            steamBootstrapReady[bottle.id] = false
            return false
        }
        var readiness = steamReadiness[bottle.id] ?? SteamBootstrapReadiness()
        let ready = readiness.observe(steam: steam, now: ProcessInfo.processInfo.systemUptime,
                                      requireStability: steamSetupBottleID == bottle.id)
        steamReadiness[bottle.id] = readiness
        if steamBootstrapReady[bottle.id] != ready { steamBootstrapReady[bottle.id] = ready }
        return ready
    }

    private func handleSteamInstallerExit(in bottle: DiscoveredBottle, sessionID: UUID) {
        guard utilitySessionID == sessionID, steamSetupBottleID == bottle.id else { return }
        let ready = checkSteamBootstrap(in: bottle)
        let log = try? String(contentsOf: SteamInstallation.bootstrapLogURL(in: bottle.prefix), encoding: .utf8)
        switch SteamInstallerExitDecision.decide(
            steamExists: SteamInstallation.executable(in: bottle.prefix) != nil,
            bootstrapState: SteamBootstrapState.parse(log), ready: ready) {
        case .cancelled:
            stop()
            steamSetupActivities[bottle.id] = .cancelled
            return
        case .startBootstrap:
            startPlainSteamIfLogStaysSilent(in: bottle, sessionID: sessionID, logAtExit: log)
        case .waitForStability, .openSignIn: break
        }
        // The installer is gone; from here on only its Steam update is awaited.
        sessionState = .utility(L10n.string(.modelSteamUpdatingLabel, bottle.name))
        startSteamSetupWatch(in: bottle, sessionID: sessionID)
    }

    /// With "Run Steam" ticked the installer has already started a client, so a
    /// second one is started only if nothing writes to the update log. A plain
    /// launch lets both bootstrap generations finish; no helper substitution yet.
    private func startPlainSteamIfLogStaysSilent(in bottle: DiscoveredBottle, sessionID: UUID,
                                                 logAtExit: String?) {
        let pending = UUID()
        pendingPlainSteamStart = pending
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(SteamBootstrapStartDecision.grace))
            guard let self else { return }
            // A later start owns the mark by then; only this one's is cleared.
            defer { if self.pendingPlainSteamStart == pending { self.pendingPlainSteamStart = nil } }
            guard self.utilitySessionID == sessionID,
                  self.steamSetupBottleID == bottle.id else { return }
            let logNow = try? String(contentsOf: SteamInstallation.bootstrapLogURL(in: bottle.prefix), encoding: .utf8)
            guard SteamBootstrapStartDecision.shouldStartPlainSteam(logAtExit: logAtExit, logNow: logNow) else { return }
            do { try self.launchPlainSteam(in: bottle, sessionID: sessionID) }
            catch {
                self.reportSteamFailure(L10n.string(.modelSteamContinueRetryFailure), error: error)
                self.stop()
            }
        }
    }

    private func launchPlainSteam(in bottle: DiscoveredBottle, sessionID: UUID) throws {
        guard utilitySessionID == sessionID else { throw CancellationError() }
        let command = try SteamInstallation.firstRunCommand(bottle: bottle, manager: manager)
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, scoped in scoped }
        attachOutput(of: process, prefix: "steam: ")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.utilitySessionID == sessionID, self.gameProcess === process else { return }
                self.gameProcess = nil
                self.appendLog(L10n.string(.modelSteamUpdaterExited, String(process.terminationStatus)))
                // The updater replaces itself. Its exit never ends this watch.
            }
        }
        try process.run()
        gameProcess = process
        activeWineCommand = command
    }

    func continueSteamSetup(in bottle: DiscoveredBottle) {
        steamWizardError = nil
        if steamSetupBottleID == bottle.id, let id = utilitySessionID {
            guard steamInstallerHasExited else { return }
            // "Wait again": a closed or crashed client must not be waited for
            // another 15 minutes.
            if SteamSetupRetryDecision.decide(
                ownedClientRunning: gameProcess?.isRunning == true,
                ready: checkSteamBootstrap(in: bottle)) == .startPlainSteamIfLogStaysSilent {
                let log = try? String(contentsOf: SteamInstallation.bootstrapLogURL(in: bottle.prefix), encoding: .utf8)
                startPlainSteamIfLogStaysSilent(in: bottle, sessionID: id, logAtExit: log)
            }
            startSteamSetupWatch(in: bottle, sessionID: id)
            return
        }
        do {
            let command = try SteamInstallation.firstRunCommand(bottle: bottle, manager: manager)
            let id = try launchUtility(command, label: L10n.string(.modelSteamUpdatingLabel, bottle.name),
                                       steamInstaller: bottle)
            steamInstallerHasExited = true
            startSteamSetupWatch(in: bottle, sessionID: id)
        } catch { reportSteamFailure(L10n.string(.modelSteamContinueFailure), error: error) }
    }

    private func startSteamSetupWatch(in bottle: DiscoveredBottle, sessionID: UUID) {
        steamSetupWatch?.cancel()
        steamSetupActivities[bottle.id] = .updating
        steamSetupWatch = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SteamBootstrapWaiter.wait(isCurrent: {
                    self.utilitySessionID == sessionID && self.steamSetupBottleID == bottle.id
                }, readReady: { self.checkSteamBootstrap(in: bottle) },
                   clientRunning: { self.steamClientRunning(in: bottle) },
                   restartClient: { self.restartLostSteamClient(in: bottle, sessionID: sessionID) },
                   readLog: {
                       try? String(contentsOf: SteamInstallation.bootstrapLogURL(in: bottle.prefix), encoding: .utf8)
                   },
                   restartStalledClient: { self.restartStalledSteamClient(in: bottle, sessionID: sessionID) },
                   reportStuck: { stuck in
                       if stuck, self.steamTroubles[bottle.id] != .updateStuck {
                           self.steamTroubles[bottle.id] = .updateStuck
                           self.appendLog(L10n.string(.modelSteamUpdateGaveUp))
                       } else if !stuck, self.steamTroubles[bottle.id] == .updateStuck {
                           self.steamTroubles[bottle.id] = nil
                       }
                   })
                switch result {
                case .openSignIn:
                    await self.closeSteamAndOpenSignIn(in: bottle, sessionID: sessionID)
                    return
                case .timedOut:
                    self.steamSetupActivities[bottle.id] = .timedOut
                    return
                case .wait: break
                }
            } catch { /* Stop or a different session invalidated this watch. */ }
        }
    }

    /// Nil when it cannot be told, and while a plain start is still pending:
    /// until then an environment without Wine processes is expected.
    private func steamClientRunning(in bottle: DiscoveredBottle) -> Bool? {
        guard pendingPlainSteamStart == nil, let managed = bottle.managed,
              let count = try? manager.runningProcessCount(inBottle: managed.name) else { return nil }
        return count > 0
    }

    /// Steam died before its update finished (`SteamClientLoss`): nothing is
    /// on screen and nothing would change before the timeout.
    private func restartLostSteamClient(in bottle: DiscoveredBottle, sessionID: UUID) {
        appendLog(L10n.string(.modelSteamClientRestarted))
        do { try launchPlainSteam(in: bottle, sessionID: sessionID) }
        catch {
            reportSteamFailure(L10n.string(.modelSteamContinueRetryFailure), error: error)
            stop()
        }
    }

    /// Steam's update stood still while it ran (`SteamUpdateStall`): stop the
    /// environment's Wine and start Steam again, as a manual stop and retry
    /// would. Meanwhile the lost-client watch sees an empty environment as
    /// expected (`pendingPlainSteamStart`).
    private func restartStalledSteamClient(in bottle: DiscoveredBottle, sessionID: UUID) {
        appendLog(L10n.string(.modelSteamUpdateStalled))
        let pending = UUID()
        pendingPlainSteamStart = pending
        // Queued like every stop: Play and Stop wait for it.
        if let command = try? SteamInstallation.firstRunCommand(bottle: bottle, manager: manager) {
            queueWineShutdown(command)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.wineShutdown?.task.value
            defer { if self.pendingPlainSteamStart == pending { self.pendingPlainSteamStart = nil } }
            guard self.utilitySessionID == sessionID, self.steamSetupBottleID == bottle.id else { return }
            // Steam is never started over processes that outlived the stop;
            // the panel says so ("Steam did not close").
            if case .stopFailed = self.steamTroubles[bottle.id] { return }
            do { try self.launchPlainSteam(in: bottle, sessionID: sessionID) }
            catch {
                self.reportSteamFailure(L10n.string(.modelSteamContinueRetryFailure), error: error)
                self.stop()
            }
        }
    }

    // MARK: - Steam that hangs

    /// How this app runs Steam in `bottle` now, if it does.
    enum SteamRun: Equatable { case setup, window, game, closing }

    func steamRun(in bottle: DiscoveredBottle) -> SteamRun? {
        if let shutdown = wineShutdown,
           shutdown.commands.contains(where: { Self.prefix(of: $0) == bottle.prefix.path }) { return .closing }
        guard sessionState.isActive else { return nil }
        if steamSetupBottleID == bottle.id { return .setup }
        if sessionState == .utility("Steam • \(bottle.name)") { return .window }
        if let command = activeWineCommand, Self.prefix(of: command) == bottle.prefix.path { return .game }
        return nil
    }

    nonisolated private static func prefix(of command: BottleLaunchCommand) -> String? {
        command.environment["WINEPREFIX"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// The installer's own run and the hand-off to the sign-in window are
    /// not restarted; everything else Steam does here is.
    func canRestartSteam(in bottle: DiscoveredBottle) -> Bool {
        guard !steamRestarting.contains(bottle.id), !steamClosing.contains(bottle.id) else { return false }
        switch steamRun(in: bottle) {
        case .window: return true
        case .setup: return steamInstallerHasExited && steamSetupActivities[bottle.id] != .openingSignIn
        default: return false
        }
    }

    /// "Restart Steam": every Wine process of the environment ends, as with
    /// "Close Steam", and Steam starts again the way it ran: its first
    /// update, or its window. The environment keeps its files, so Steam's
    /// sign-in and games stay.
    func restartSteam(in bottle: DiscoveredBottle) async {
        guard canRestartSteam(in: bottle) else { return }
        let update = steamRun(in: bottle) == .setup
        steamRestarting.insert(bottle.id)
        defer { steamRestarting.remove(bottle.id) }
        steamTroubles[bottle.id] = nil
        stop()
        if let shutdown = wineShutdown { await shutdown.task.value }
        // Something started meanwhile is not replaced.
        guard !sessionState.isActive, wineShutdown == nil else { return }
        if wineShutdownFailed {
            steamTroubles[bottle.id] = .stopFailed(wineShutdownError ?? L10n.string(.modelNoReason))
            return
        }
        steamSetupActivities[bottle.id] = nil
        if update { continueSteamSetup(in: bottle) } else { launchSteam(in: bottle) }
        if sessionState.isActive { appendLog(L10n.string(.modelSteamManualRestart)) }
    }

    /// "Close Steam": every Wine process of the environment ends, whether
    /// this app runs Steam there or it was left behind. Both stops are
    /// bounded and end in a forced one (`BottleManager.wineStopLimit`).
    func closeSteam(in bottle: DiscoveredBottle) async {
        guard !steamClosing.contains(bottle.id), !steamRestarting.contains(bottle.id) else { return }
        steamTroubles[bottle.id] = nil
        switch steamRun(in: bottle) {
        case .setup, .window, .game: stop()
        case .closing: return
        case nil: await stopLeftoverWine(in: bottle)
        }
    }

    private func stopLeftoverWine(in bottle: DiscoveredBottle) async {
        guard let managed = bottle.managed else { return }
        let command: BottleLaunchCommand
        do { command = try manager.prefixCommand(forBottle: managed.name) }
        catch {
            steamTroubles[bottle.id] = .stopFailed(error.localizedDescription)
            return
        }
        steamClosing.insert(bottle.id)
        defer { steamClosing.remove(bottle.id) }
        // Queued like every stop: a Play pressed meanwhile waits for it.
        queueWineShutdown(command)
        await wineShutdown?.task.value
        if case .stopFailed = steamTroubles[bottle.id] { return }
        steamLeftovers.remove(bottle.id)
    }

    /// Wine left running in an environment no session of this app owns,
    /// e.g. after a stop that failed. Nothing is reported while a session
    /// runs or Wine is being stopped: Play stops what it finds itself.
    func pollSteamLeftovers(in bottles: [DiscoveredBottle]) async {
        guard !sessionState.isActive, wineShutdown == nil else {
            if !steamLeftovers.isEmpty { steamLeftovers = [] }
            return
        }
        let manager = manager
        let names = bottles.compactMap { bottle in bottle.managed.map { (bottle.id, $0.name) } }
        let counts = await Task.detached {
            names.map { ($0.0, try? manager.runningProcessCount(inBottle: $0.1)) }
        }.value
        guard !sessionState.isActive, wineShutdown == nil else { return }
        var found = steamLeftovers
        for (id, count) in counts where !steamClosing.contains(id) && !steamRestarting.contains(id) {
            if let count, count > 0 { found.insert(id) } else { found.remove(id) }
        }
        if found != steamLeftovers { steamLeftovers = found }
    }

    /// The wizard's game step: a download that stands still while the
    /// Steam window is open is reported (`SteamDownloadStall`); Steam is
    /// never restarted for it without the user.
    func observeSteamDownload(in bottle: DiscoveredBottle, download: SteamDownloadState?) async {
        let downloading = download?.isRunning == true && steamRun(in: bottle) == .window
        var activity: UInt64?
        var contentLogSize: Int?
        if downloading, let managed = bottle.managed {
            let manager = manager
            let log = SteamInstallation.contentLogURL(in: bottle.prefix)
            (activity, contentLogSize) = await Task.detached {
                (try? manager.ioActivity(inBottle: managed.name), Self.fileSize(at: log))
            }.value
        }
        var stall = steamDownloadStalls[bottle.id] ?? SteamDownloadStall()
        let stuck = stall.observe(downloading: downloading, activity: activity, contentLogSize: contentLogSize,
                                  now: ProcessInfo.processInfo.systemUptime)
        steamDownloadStalls[bottle.id] = stall
        if stuck, steamTroubles[bottle.id] == nil {
            steamTroubles[bottle.id] = .downloadStuck
        } else if !stuck, steamTroubles[bottle.id] == .downloadStuck {
            steamTroubles[bottle.id] = nil
        }
    }

    func manuallyOpenSteamSignIn(in bottle: DiscoveredBottle) async {
        guard let id = utilitySessionID, steamSetupBottleID == bottle.id else {
            steamWizardError = L10n.string(.modelSteamWaitStopped)
            return
        }
        guard steamInstallerHasExited, checkSteamBootstrap(in: bottle) else {
            steamWizardError = L10n.string(.modelSteamUpdateIncomplete)
            return
        }
        await closeSteamAndOpenSignIn(in: bottle, sessionID: id)
    }

    private func closeSteamAndOpenSignIn(in bottle: DiscoveredBottle, sessionID: UUID) async {
        guard utilitySessionID == sessionID, steamSetupBottleID == bottle.id,
              steamSetupActivities[bottle.id] != .openingSignIn else { return }
        stop()
        // Stop cancels the old watcher. A separate token protects this handoff
        // across the awaited shutdown, including a second user Stop or launch.
        let handoffID = UUID()
        utilitySessionID = handoffID
        steamSetupBottleID = bottle.id
        steamSetupActivities[bottle.id] = .openingSignIn
        let handoffLabel = L10n.string(.modelSteamOpeningLabel, bottle.name)
        sessionState = .utility(handoffLabel)
        if let shutdown = wineShutdown { await shutdown.task.value }
        guard utilitySessionID == handoffID, steamSetupBottleID == bottle.id,
              sessionState == .utility(handoffLabel) else { return }
        steamSetupBottleID = nil
        sessionState = .stopped
        if wineShutdownFailed {
            steamSetupActivities[bottle.id] = .stopped
            steamWizardError = SteamWizardCopy.failure(
                L10n.string(.modelSteamStopFailure),
                detail: wineShutdownError ?? L10n.string(.modelNoReason))
            return
        }
        steamSetupActivities[bottle.id] = nil
        steamWizardError = nil
        launchSteam(in: bottle)
    }

    private func observeSteamConnection(in bottle: DiscoveredBottle, after offset: Int, sessionID: UUID) {
        steamConnectionStates[bottle.id] = .waiting
        steamConnectionObservation = (bottle, offset, sessionID)
        steamConnectionWatch?.cancel()
        steamConnectionWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.utilitySessionID == sessionID else { return }
                self.recheckSteamConnection()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func recheckSteamConnection() {
        guard let observation = steamConnectionObservation, utilitySessionID == observation.sessionID else { return }
        let log = SteamInstallation.connectionLogURL(in: observation.bottle.prefix)
        let state = (try? Data(contentsOf: log)).map {
            SteamConnectionLog.state(in: $0, after: observation.offset)
        } ?? .waiting
        if steamConnectionStates[observation.bottle.id] != state {
            steamConnectionStates[observation.bottle.id] = state
        }
    }

    func requestSteamGameInstall(appID: String, in bottle: DiscoveredBottle) {
        do {
            guard steamConnectionObservation?.bottle.id == bottle.id,
                  steamConnectionStates[bottle.id] == .loggedOn,
                  let sessionID = utilitySessionID else {
                throw BottleToolError(L10n.string(.modelOpenSteamFirst))
            }
            let command = try SteamInstallation.installGameCommand(appID: appID, bottle: bottle, manager: manager)
            let requestID = UUID()
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.currentDirectoryURL = command.currentDirectory
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, scoped in scoped }
            attachOutput(of: process, prefix: "steam: ")
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    self.steamRequestProcesses[requestID] = nil
                    guard self.utilitySessionID == sessionID else { return }
                    self.appendLog(L10n.string(.modelSteamInstallCommandExited, String(process.terminationStatus)))
                    if process.terminationStatus != 0 {
                        // The exit code of this hand-off is not documented, so it proves nothing by itself.
                        self.steamWizardError = L10n.string(.modelSteamDownloadCommandFailed, String(process.terminationStatus))
                    }
                }
            }
            try process.run()
            steamRequestProcesses[requestID] = process
            steamWizardError = nil
        } catch { reportSteamFailure(L10n.string(.modelSteamDownloadCommandFailure), error: error) }
    }

    func clearLog() {
        guard !sessionState.isActive else { return }
        console.restart()
        loggedSessionID = nil
    }

    /// Records the open session to history. The first outcome wins: the
    /// `stop()` that follows a game exit or failure finds nothing open.
    private func finishSession(_ outcome: SessionRecord.Outcome, reason: String? = nil) {
        guard let session = openSession else { return }
        openSession = nil
        var record = session.record
        // A launch stopped before the game started is not a session.
        guard record.streamingStartedAt != nil || outcome == .failed else { return }
        record.endedAt = Date()
        record.outcome = outcome
        record.failureReason = reason
        do {
            let history = try SessionHistoryStore(dataRoot: session.dataRoot).append(record) { moved in
                self.appendLog(L10n.string(.modelHistorySetAside, moved.lastPathComponent))
            }
            if session.dataRoot == dataRoot { sessionHistory = history }
        } catch {
            // One line either way; the history file is as it was.
            let message = error.localizedDescription
            Task {
                let reason = await dataFolderHasGone()
                    ? L10n.string(.dataFolderDiskNotConnected) : message
                appendLog(L10n.string(.modelSaveHistoryFailure, reason))
            }
        }
    }

    func clearSessionHistory() {
        do {
            try SessionHistoryStore(dataRoot: dataRoot).clear()
            sessionHistory = []
        } catch {
            present(error)
        }
    }

    /// Names the game's log in the session log, as the excerpt's header
    /// names it, unless another launch or a utility has taken the log over;
    /// gives the session's hints after it; and notes the saved excerpt in
    /// the session's history record.
    private func noteGameLog(_ run: GameLogRun, saved: (excerpt: GameLogExcerpt, file: URL?)?) {
        defer {
            pendingGameLogs[run.sessionID] = nil
            if loggedSessionID == run.sessionID, wineShutdown == nil, !sessionState.isActive {
                console.closeTranscript()
            }
        }
        if loggedSessionID == run.sessionID {
            appendLog(saved?.excerpt.sources.last.map { L10n.string(.modelGameLog, $0.path) }
                ?? L10n.string(.modelGameLogNone))
        }
        knownErrors.read(gameLog: saved?.excerpt, of: run.sessionID)
        finishKnownErrors(of: run.sessionID)
        // The session was recorded when it stopped; a history that has lost
        // it since stays as it is.
        guard let file = saved?.file,
              let history = try? SessionHistoryStore(dataRoot: run.dataRoot).update(
                run.sessionID, { $0.gameLog = file.lastPathComponent }),
              history.contains(where: { $0.id == run.sessionID }), run.dataRoot == dataRoot else { return }
        sessionHistory = history
        Task { await refreshRecordings() }
    }

    /// Once a stopped session's processes are gone, the last lines of its
    /// pipes, a crashed wineserver's among them, may still be on their way
    /// to the scanner: they are read until every pipe has closed, for a
    /// moment at most, and then no more.
    private func waitForOutputToEnd(of sessionID: UUID) async {
        await SessionTeardown.wait(upTo: .seconds(2)) { !knownErrors.isReading(sessionID) }
        knownErrors.stopReading(sessionID)
    }

    /// Gives the hints of a session that has stopped once its game's log has
    /// been read: `noteGameLog` gives them then. When that takes longer than
    /// a launch waits for it, they are given without the game's log.
    private func finishKnownErrorsAfterGameLog(of sessionID: UUID) {
        guard pendingGameLogs[sessionID] != nil else { return finishKnownErrors(of: sessionID) }
        Task { [weak self] in
            await self?.waitForGameLogCapture(sessionID)
            self?.finishKnownErrors(of: sessionID)
        }
    }

    /// The hints of a session that has stopped, each once: in the session
    /// log while it still shows the session, and in its history record.
    private func finishKnownErrors(of sessionID: UUID) {
        guard let finished = knownErrors.finish(sessionID), !finished.hints.isEmpty else { return }
        let hints = finished.hints.map(\.text)
        if loggedSessionID == sessionID { hints.forEach { appendLog($0 + "\n") } }
        // As the excerpt is: a history that has lost the session stays as it is.
        guard let history = try? SessionHistoryStore(dataRoot: finished.dataRoot).update(
                sessionID, { $0.hints = hints }),
              history.contains(where: { $0.id == sessionID }), finished.dataRoot == dataRoot else { return }
        sessionHistory = history
    }

    private func captureGameLog(_ run: GameLogRun, wineMayBeRunning: Bool) {
        guard pendingGameLogs[run.sessionID]?.claimed == false else { return }
        pendingGameLogs[run.sessionID]?.claimed = true
        let redactor = gameLogRedactor(for: run)
        Task.detached { [weak self] in
            let saved = run.save(redactedWith: redactor, wineMayBeRunning: wineMayBeRunning)
            await self?.noteGameLog(run, saved: saved)
        }
    }

    nonisolated private static let gameLogCaptureWaitLimit = Duration.seconds(5)

    private func waitForGameLogCapture(_ sessionID: UUID?, upTo timeout: Duration = gameLogCaptureWaitLimit) async {
        guard let sessionID else { return }
        await SessionTeardown.wait(upTo: timeout) { pendingGameLogs[sessionID] == nil }
    }

    func waitForClaimedGameLogCaptures() async {
        await SessionTeardown.wait(upTo: .seconds(3)) { !hasClaimedGameLogCapture }
    }

    /// The session's data folder is named as such in its game's excerpt.
    private func gameLogRedactor(for run: GameLogRun) -> DiagnosticRedactor {
        DiagnosticRedactor(dataFolder: run.dataRoot.path, appFolder: repoRoot.path)
    }

    /// The excerpt of the game's own log saved with a session; nil when it is gone.
    func gameLogText(for record: SessionRecord) async -> String? {
        guard let name = record.gameLog else { return nil }
        let store = DiagnosticRecordingStore(dataRoot: dataRoot)
        return await Task.detached { store.gameLogText(named: name) }.value
    }

    /// Where that excerpt is, for Show in Finder.
    func gameLogFile(for record: SessionRecord) -> URL? {
        record.gameLog.flatMap { DiagnosticRecordingStore(dataRoot: dataRoot).gameLogFile(named: $0) }
    }

    /// A snapshot for bug reports. Callers render it through a
    /// `DiagnosticRedactor`; nothing here leaves the Mac by itself. The
    /// game's own log is read off the main thread: that of the running
    /// game, else the excerpt saved with the latest session, which a session
    /// that has just stopped is given first.
    func makeDiagnosticReport(includeLog: Bool, includeGameLog: Bool) async -> DiagnosticReport {
        let captureID = latestGameLogCaptureID
        let waitStarted = ContinuousClock.now
        await waitForGameLogCapture(captureID)
        let waitRemaining = Self.gameLogCaptureWaitLimit - waitStarted.duration(to: .now)
        var gameLog: DiagnosticReport.GameLog?
        if includeGameLog {
            gameLog = await readDiagnosticGameLog()
            let latest = latestGameLogCaptureID
            if latest != captureID {
                await waitForGameLogCapture(latest, upTo: waitRemaining)
                gameLog = await readDiagnosticGameLog()
            }
        }
        return DiagnosticReport(
            application: .current(repoRoot: repoRoot),
            system: .current(),
            setupChecks: setupChecks,
            engines: engines,
            bottles: discoveredBottles,
            profiles: profiles,
            defaultStreamSettings: settings,
            profileStreamSettings: profileSettings,
            currentSession: .init(
                state: sessionState.label,
                profileName: openSession?.record.profileName,
                metrics: openSession?.record.metrics),
            recentSessions: sessionHistory,
            log: includeLog ? console.diagnosticLog : nil,
            gameLog: gameLog)
    }

    private func readDiagnosticGameLog() async -> DiagnosticReport.GameLog {
        let (running, history, root) = (runningGame, sessionHistory, dataRoot)
        let redactor = DiagnosticRedactor(dataFolder: (running?.dataRoot ?? root).path, appFolder: repoRoot.path)
        return await Task.detached {
            DiagnosticReport.GameLog.current(
                running: running, history: history, dataRoot: root, redactedWith: redactor)
        }.value
    }

    func export(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = L10n.string(.modelExportFailure, url.lastPathComponent, error.localizedDescription)
        }
    }

    private func appendLog(_ value: String, from source: ObjectIdentifier? = nil,
                           prefix: String = "", receivedAt: ContinuousClock.Instant = .now) {
        let lines = console.append(value, from: source, prefix: prefix)
        recordLines(lines)
        knownErrors.read(lines, from: source, receivedAt: receivedAt)
    }

    private func finishLog(from source: ObjectIdentifier, prefix: String, receivedAt: ContinuousClock.Instant) {
        let lines = console.finish(source, prefix: prefix)
        recordLines(lines)
        knownErrors.read(lines, from: source, receivedAt: receivedAt)
        knownErrors.close(source)
    }

    private func recordLines(_ lines: [String]) {
        for line in lines {
            if AlvrADBServerOwnership.shared.note(streamerLine: line) {
                noteADBServerInSessionMarker()
            }
            if let request = HeadsetRequest.parse(line),
               !headsetRequests.contains(where: { $0.hostname == request.hostname }),
               headsetRequest?.hostname != request.hostname {
                if headsetRequest == nil { headsetRequest = request }
                else { headsetRequests.append(request) }
            }
            if let metric = StreamLogMetricsParser.parse(line: line) {
                console.record(metric)
                if let target = openSession?.record.settings.fps {
                    openSession?.record.metrics.add(metric, targetFPS: target)
                }
            } else if let refusal = RuntimeConnectionRefusal.message(in: line) {
                alertMessage = refusal
            }
        }
    }

    private static func runUtility(_ executable: URL, arguments: [String]) async
        -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self))
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }
}

// MARK: - Add Game from Folder

/// Add Game from Folder as the app runs it: a new environment for the game,
/// prepared for VR, the folder copied into its `C:\Games`, and a launch
/// profile that starts the game directly. Only the environment the import
/// itself creates is ever prepared, written to or removed.
struct GameFolderImport: Equatable {
    enum Step: Int, CaseIterable, Comparable {
        case create, prepare, copy, profile

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Why an import stopped before the game was added. The text is made
    /// when it is shown, so a language change in between still reads right.
    enum Failure: Error, Equatable {
        case sessionActive
        case wineStopping
        case needsSetup
        case environmentName(GameFolderEnvironmentNameProblem)
        case refusal(GameFolderRefusal)
        /// Anything else, with the error's own description.
        case error(String)

        func message(environment: String) -> String {
            switch self {
            case .sessionActive: L10n.string(.folderImportStopSession)
            case .wineStopping: L10n.string(.modelWineStillStopping)
            case .needsSetup: L10n.string(.folderImportNeedsSetup)
            case .environmentName(let problem): problem.message(for: environment)
            case .refusal(let refusal): refusal.message
            case .error(let detail): L10n.string(.folderImportFailed, detail)
            }
        }
    }

    enum Outcome: Equatable {
        case added
        /// The user stopped the copy.
        case cancelled
        case failed(Failure)
    }

    let id: UUID
    let title: String
    let environment: String
    /// The copy's name in `C:\Games`.
    let folderName: String
    /// The step running now, or the one that failed.
    var step = Step.create
    /// 0...1 of the bytes copied; it only grows.
    var copyFraction = 0.0
    var isCancelling = false
    /// Nil while the import runs.
    var outcome: Outcome?
    /// The new environment when it stayed after a failure or a cancellation:
    /// removing it failed, or a profile names it.
    var keptEnvironment: String?

    var isRunning: Bool { outcome == nil }

    /// How the import ended, and that the new environment stayed if it did.
    var outcomeMessage: String? {
        let text: String
        switch outcome {
        case nil: return nil
        case .added?: text = L10n.string(.folderImportDone)
        case .cancelled?: text = L10n.string(.folderImportCancelled)
        case .failed(let failure)?: text = failure.message(environment: environment)
        }
        guard let keptEnvironment else { return text }
        return text + "\n" + L10n.string(.folderImportEnvironmentKept, keptEnvironment)
    }
}

/// The sheet's Cancel, which the copy reads on its own thread.
private final class GameFolderImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

extension BasaltAppModel {
    /// An import is creating, preparing, copying or saving: no game and no
    /// Windows program may start until it ends.
    var isImportingGameFolder: Bool { folderImport?.isRunning == true }

    /// The environment a running import creates. Bottles keeps Prepare and
    /// Delete away from it: the import prepares and fills it itself.
    var gameFolderImportEnvironment: String? {
        guard let state = folderImport, state.isRunning else { return nil }
        return state.environment
    }

    /// Names a new environment must not take besides the folders in Bottles:
    /// the Steam wizard's remembered environment, and every environment a
    /// profile names. A profile whose environment is gone would otherwise
    /// return with the new one, and be deleted with it if the import fails.
    var gameFolderImportReservedNames: [String] {
        [steamWizardCustomName] + bottles.map(\.name) + profiles.map(\.bottleName)
    }

    /// Why Add cannot start an import now, or nil. The import checks again
    /// before it creates anything, against the disk as it is then.
    var gameFolderImportBlocker: GameFolderImport.Failure? {
        if sessionState.isActive { return .sessionActive }
        if !engines.contains(where: { $0.kind == .pinned && $0.supportsBasaltDXMT }) {
            return .needsSetup
        }
        return nil
    }

    /// Adds the game in a scanned folder as a game of a new environment
    /// named `environment`: creates it like the Steam wizard, prepares it for
    /// VR, copies the folder into its `C:\Games`, then saves a profile that
    /// starts `executable` directly. Blocking work runs off the main actor;
    /// the steps and the copy's progress are published in `folderImport`.
    /// Only the copy can be cancelled. After a failure or a cancellation the
    /// environment this call created is removed again, and nothing else.
    func importGameFolder(_ scan: GameFolderScan, executable: GameFolderExecutable,
                          title: String, arguments: [String], environment: String) async {
        guard !isImportingGameFolder else {
            alertMessage = L10n.string(.folderImportBusy)
            return
        }
        let id = UUID()
        let cancellation = GameFolderImportCancellation()
        folderImportCancellation = cancellation
        folderImport = GameFolderImport(
            id: id, title: title, environment: environment, folderName: scan.destinationFolderName)
        if sessionState.isActive {
            endGameFolderImport(id, .failed(.sessionActive))
            return
        }
        if wineShutdown != nil {
            endGameFolderImport(id, .failed(.wineStopping))
            return
        }
        // Every step uses this manager, the cleanup too, even if the data
        // folder is changed meanwhile.
        let manager = manager
        let reserved = gameFolderImportReservedNames
        let inventory = scan.inventory
        let folderName = scan.destinationFolderName
        let executablePath = executable.path
        var created = false
        do {
            let engineID = try await Task.detached { () throws -> String in
                let engine = try Self.gameFolderImportEngine(
                    manager: manager, environment: environment, reserved: reserved)
                // The profile's paths are built once now, against where the
                // environment will be, so a name Windows cannot hold stops
                // the import before anything exists.
                let prefix = try manager.paths.bottleDirectory(environment)
                    .appendingPathComponent("prefix", isDirectory: true)
                _ = try GameFolderScan.profile(
                    named: environment, title: title, executable: executablePath,
                    arguments: arguments, folderName: folderName,
                    in: ManagedBottle(name: environment, engine: engine, prefix: prefix,
                                      engineRoot: engine.root, wineBinary: engine.wineBinary))
                return engine.id
            }.value
            try await Task.detached {
                _ = try manager.createBottle(name: environment, engineID: engineID)
            }.value
            created = true
            updateGameFolderImport(id) { $0.step = .prepare }
            try await Task.detached {
                _ = try manager.installDXMT(in: environment)
                _ = try manager.installRuntime(in: environment)
                _ = try manager.verify(environment)
            }.value
            updateGameFolderImport(id) { $0.step = .copy }
            let showCopy: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    self?.updateGameFolderImport(id) { $0.copyFraction = max($0.copyFraction, fraction) }
                }
            }
            try await Task.detached {
                var shownPercent = -1
                try manager.copyGameFolder(
                    inventory, intoBottle: environment, folderName: folderName,
                    progress: { progress in
                        // Whole percents only: every change redraws the window.
                        let percent = Int(progress.fraction * 100)
                        guard percent != shownPercent else { return }
                        shownPercent = percent
                        showCopy(progress.fraction)
                    },
                    isCancelled: { cancellation.isCancelled })
            }.value
            // A Cancel pressed while the last file finished still counts.
            if cancellation.isCancelled { throw GameFolderCopyError.cancelled }
            updateGameFolderImport(id) { $0.step = .profile }
            try await Task.detached {
                try Self.saveGameFolderProfile(
                    manager: manager, title: title, executable: executablePath,
                    arguments: arguments, folderName: folderName, environment: environment)
            }.value
            await refresh()
            endGameFolderImport(id, .added)
        } catch {
            let outcome = Self.gameFolderImportOutcome(for: error)
            var kept: String?
            if created {
                let removed = await Task.detached {
                    Self.removeGameFolderImportEnvironment(environment, manager: manager)
                }.value
                if !removed { kept = environment }
                await refresh()
            }
            endGameFolderImport(id, outcome, keptEnvironment: kept)
        }
    }

    /// Stops the copy at its next check, at most a megabyte later. Creating
    /// and preparing the environment run Wine to the end and cannot stop.
    func cancelGameFolderImport() {
        guard let state = folderImport, state.isRunning, state.step == .copy else { return }
        folderImportCancellation?.cancel()
        updateGameFolderImport(state.id) { $0.isCancelling = true }
    }

    /// Forgets an import that has ended, once its sheet has shown how.
    func clearGameFolderImport() {
        guard let state = folderImport, !state.isRunning else { return }
        folderImport = nil
    }

    private func updateGameFolderImport(_ id: UUID, _ change: (inout GameFolderImport) -> Void) {
        guard var state = folderImport, state.id == id, state.isRunning else { return }
        change(&state)
        if state != folderImport { folderImport = state }
    }

    /// Records how the import ended. Without its sheet on screen nobody would
    /// see that there, so the outcome becomes an alert instead, unless the
    /// game was added: its tile in the Library says so.
    private func endGameFolderImport(_ id: UUID, _ outcome: GameFolderImport.Outcome,
                                     keptEnvironment: String? = nil) {
        guard var state = folderImport, state.id == id else { return }
        state.outcome = outcome
        state.isCancelling = false
        state.keptEnvironment = keptEnvironment
        folderImportCancellation = nil
        if folderImportSheetPresented {
            folderImport = state
        } else {
            folderImport = nil
            if outcome != .added { alertMessage = state.outcomeMessage }
        }
    }

    /// The engine for the new environment, checked before anything is
    /// created: the pinned engine with the Basalt DXMT fork, as the Steam
    /// wizard picks it, every file Prepare takes from the build, and the
    /// name against the disk as it is now. Blocking.
    private nonisolated static func gameFolderImportEngine(
        manager: BottleManager, environment: String, reserved: [String]
    ) throws -> BottleEngine {
        guard let engine = manager.engines().first(where: { $0.kind == .pinned && $0.supportsBasaltDXMT }),
              hasVRBuild(repoRoot: manager.repoRoot) else {
            throw GameFolderImport.Failure.needsSetup
        }
        let taken = GameFolderScan.environmentFolderNames(in: manager.paths.bottles) + reserved
        if let problem = GameFolderScan.environmentNameProblem(environment, taken: taken) {
            throw GameFolderImport.Failure.environmentName(problem)
        }
        return engine
    }

    /// The files `installDXMT`, `installRuntime` and `verify` read from the
    /// build. Without one of them the new environment would be created and
    /// then fail to prepare.
    private nonisolated static func hasVRBuild(repoRoot: URL) -> Bool {
        let build = repoRoot.appendingPathComponent("runtime/build", isDirectory: true)
        let files = ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"]
            .map { "dxmt/fork-install/x86_64-windows/" + $0 }
            + ["dxmt/fork-install/x86_64-unix/winemetal.so", "bin/basalt_openxr.dll",
               "bin/basalt_openxr.json", "bin/loader_smoke.exe"]
        return files.allSatisfy {
            FileManager.default.fileExists(atPath: build.appendingPathComponent($0).path)
        }
    }

    /// Saves the game's profile under a name no profile file has, readable
    /// or not; `saveNewProfile` refuses to replace one in any case. Blocking.
    private nonisolated static func saveGameFolderProfile(
        manager: BottleManager, title: String, executable: String, arguments: [String],
        folderName: String, environment: String
    ) throws {
        let profiles = try manager.listProfiles().map(\.name)
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: manager.paths.profiles.path)) ?? []
        let existing = profiles + files.filter { $0.lowercased().hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
        let bottle = try manager.loadBottle(environment)
        let profile = try GameFolderScan.profile(
            named: ProfileNaming.unique(title, existing: existing), title: title,
            executable: executable, arguments: arguments, folderName: folderName, in: bottle)
        try manager.saveNewProfile(profile)
    }

    /// Removes the environment the import created, unless a profile names
    /// it: that profile belongs to another game, and removing the
    /// environment would delete it too. False when the environment stays.
    /// Blocking.
    private nonisolated static func removeGameFolderImportEnvironment(
        _ name: String, manager: BottleManager
    ) -> Bool {
        guard let profiles = try? manager.listProfiles(),
              !profiles.contains(where: { $0.bottleName == name }) else { return false }
        return (try? manager.deleteBottle(name)) != nil
    }

    private nonisolated static func gameFolderImportOutcome(
        for error: Error
    ) -> GameFolderImport.Outcome {
        if let failure = error as? GameFolderImport.Failure { return .failed(failure) }
        if (error as? GameFolderCopyError)?.isCancellation == true { return .cancelled }
        if let refusal = GameFolderRefusal(error: error) { return .failed(.refusal(refusal)) }
        return .failed(.error(error.localizedDescription))
    }
}
