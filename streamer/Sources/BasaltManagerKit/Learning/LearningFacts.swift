import Foundation

/// A game's card in the Library that a step points at.
public struct LearningLibraryGame: Equatable, Sendable {
    /// The card's own id in the Library.
    public let id: String
    public let name: String
    /// Where the game is installed, as its card says: "Whisky", "CrossOver".
    public let place: String

    public init(id: String, name: String, place: String = "") {
        self.id = id
        self.name = name
        self.place = place
    }
}

/// The facts the Learning program, the invitation and the chapters are built
/// from. The app fills it from its model; nothing here asks the system.
public struct LearningFacts: Equatable, Sendable {
    // MARK: Mac

    /// The Setup page's checks; empty until the first refresh has finished.
    public var setupChecks = [SetupCheck]()
    /// The pinned engine is in the app's engine list. The Steam wizard and
    /// the folder import read that list, and only a full refresh fills it.
    public var pinnedEngineListed = false
    /// The app is busy with its own work.
    public var appBusy = false

    // MARK: Headset

    /// The USB headset as the Headset page last saw it; a placeholder
    /// (`noTools`) until that page has asked.
    public var headsetConnection = HeadsetStatus.Connection.noTools
    /// That headset has the ALVR client the app installs.
    public var headsetClientInstalled = false
    /// The version of that client, when the headset told it.
    public var headsetClientVersion: String?
    /// The Headset page's polling has had an answer, good or bad, since the
    /// app started.
    public var headsetChecked = false
    /// What its last question failed with; nil when it was answered.
    public var headsetScanError: String?

    // MARK: Sessions

    /// Finished sessions.
    public var sessionHistory = [SessionRecord]()
    public var session = LearningSessionPhase.idle
    /// A folder import is copying a game.
    public var importRunning = false

    // MARK: Games

    /// The games Play can launch, by the Stream page's rule.
    public var launchableGames = [String]()
    /// The one Play launches now; nil when none is launchable.
    public var selectedGame: String?
    public var openVRBadges = [String: OpenVRBadgeState]()
    /// The Library shows its two "Add…" buttons on the page: it is empty.
    public var libraryShowsAddButtons = false
    /// A Steam game in a TrailBridge environment whose card offers
    /// "Create Profile".
    public var steamGameWithoutProfile: LearningLibraryGame?
    /// A game in Whisky or CrossOver whose card offers "Copy…".
    public var externalGame: LearningLibraryGame?

    // MARK: Settings

    /// The connection in the shared stream settings.
    public var connection = StreamConnectionMode.wired
    /// The game Play launches, when it has its own stream settings.
    public var gameWithOwnSettings: String?
    /// The shared stream settings use the preset recommended for this Mac.
    public var recommendedPresetSelected = false
    /// The next launch sends the game's sound to the headset.
    public var gameAudioOn = false
    /// That sound is the Mac's own audio: macOS asks to record system audio,
    /// not for the microphone.
    public var gameAudioMac = false

    // MARK: Window

    /// The selected section, when it is one a chapter knows; nil otherwise.
    public var section: LearningDestination?
    /// A sheet is open over the page (Steam wizard, folder import, OpenVR
    /// support, game settings, a Headset download). Nothing is drawn then.
    public var pageSheetOpen = false

    // MARK: Progress

    public var progress = LearningProgress()
    public var chapters = LearningChapterRecords()
    /// The invitation was answered.
    public var firstRunAnswered = false
    /// `learning.json` exists but could not be read.
    public var progressDamaged = false

    public init() {}

    /// The Setup page's own rule for "ready": some checks, none of the
    /// required ones missing. No checks is never "ready".
    public var macReady: Bool {
        !setupChecks.isEmpty && missingRequiredChecks.isEmpty
    }

    var missingRequiredChecks: [SetupCheck] {
        setupChecks.filter { $0.required && $0.status != .ready }
    }

    /// Everything the Mac still lacks is supplied on the Setup page itself
    /// (the Wine the app downloads, Rosetta): nothing has to be built.
    var macFixedOnSetupPage: Bool {
        let missing = missingRequiredChecks
        return !missing.isEmpty && missing.allSatisfy(\.isFixedOnSetupPage)
    }

    /// A session once reached streaming. The quick path completes only in
    /// such a session, so its record counts after the history was cleared.
    public var hasStreamedSession: Bool {
        progress.quickPathCompleted || sessionHistory.contains { $0.streamingStartedAt != nil }
    }

    public var hasLaunchableGame: Bool { !launchableGames.isEmpty }

    /// The USB tools, by the Headset page's own rule.
    public var headsetTools: HeadsetTools {
        HeadsetTools(checked: headsetChecked, connection: headsetConnection, scanError: headsetScanError)
    }

    /// The Mac sees the headset on the cable, allowed or not. Developer
    /// Mode must be on then.
    var headsetSeen: Bool {
        headsetConnection == .unauthorized || headsetConnection == .connected
    }

    /// The headset has the ALVR version the app installs.
    var headsetHasTestedClient: Bool {
        headsetClientVersion == PinnedHeadsetDownload.testedALVR.version
    }

    /// The Headset page shows "Install on Headset…": its own condition.
    var headsetShowsInstall: Bool {
        headsetConnection == .connected && !headsetHasTestedClient
    }

    /// The launchable game whose OpenVR label asks for setup: the one Play
    /// launches when it does, else the first that does.
    var gameNeedingOpenVR: String? {
        if let selectedGame, openVRBadges[selectedGame] == .needsSetup { return selectedGame }
        return launchableGames.first { openVRBadges[$0] == .needsSetup }
    }

    /// The parts were built while the app was open: the Setup check sees the
    /// engine, the app's engine list does not yet. One full refresh on
    /// entering the "Game" chapter fills the list, when nothing else runs.
    public var needsEngineRefresh: Bool {
        let engineBuilt = setupChecks.contains { $0.id == "wine" && $0.status == .ready }
        return engineBuilt && !pinnedEngineListed && !appBusy && session == .idle
            && !importRunning && !pageSheetOpen
    }
}
