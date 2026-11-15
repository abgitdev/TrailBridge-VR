import Foundation

/// The facts the "Ready for VR" card and the quick path's pre-check are built
/// from. The app fills it from its model; nothing here asks the system.
public struct LearningReadinessSnapshot: Equatable, Sendable {
    /// The Setup page's checks; empty until the first refresh has finished.
    public var setupChecks = [SetupCheck]()
    /// The last attempt to read the setup checks failed.
    public var setupCheckFailed = false

    /// The connection the next launch uses.
    public var connection = StreamConnectionMode.wired
    /// False until the Learning page's own single USB poll has answered.
    public var headsetPolled = false
    /// That poll could not ask adb.
    public var headsetPollFailed = false
    /// The poll was left out on purpose: a session is running, or the
    /// Headset page is installing something. Nothing is being checked, so
    /// the row must not say "Checking…".
    public var headsetPollSkipped = false
    public var headsetStatus = HeadsetStatus(connection: .noTools)
    /// Finished sessions, for the last time Wi-Fi streaming worked.
    public var sessionHistory = [SessionRecord]()

    /// The profile Play would launch, by the Stream page's rule; nil when no
    /// game is launchable.
    public var gameName: String?
    /// That game's OpenVR label, when it was inspected.
    public var openVRBadge: OpenVRBadgeState?

    /// The launch uses the Mac's own audio rather than a device.
    public var macAudio = false
    /// This macOS can capture its own audio (14.2 and newer).
    public var macAudioSupported = true
    /// The game audio device in the settings the launch will use; nil with
    /// `macAudio` false is "off".
    public var audioDeviceName: String?
    /// Whether that device is among the Mac's audio devices now.
    public var audioDeviceAvailable = false

    public var session = LearningSessionPhase.idle
    /// A folder import is copying a game.
    public var importRunning = false
    /// The "Game" chapter waits while Steam downloads a game. Stopping
    /// Steam would break the download off, so the card does not offer it.
    public var gameDownloading = false

    public init() {}
}

/// One line of the "Ready for VR" card.
public struct LearningReadinessRow: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case mac, headset, game, audio }

    public enum Status: Equatable, Sendable {
        /// Not known yet: never shown as ready.
        case checking
        /// The check itself did not work.
        case failed
        case ready
        case missing
        /// A neutral fact, neither good nor bad.
        case info
    }

    public enum Detail: Equatable, Sendable {
        case checking
        case checkFailed
        case macReady
        case macMissing(requiredSteps: Int)
        case usbToolsMissing
        case usbNotConnected
        case usbApprovalNeeded
        case usbConnected
        case usbNotChecked
        case wifiLastSession(Date)
        case wifiNotChecked
        case game(String)
        case noGame
        case audio(String)
        case audioOff
        case audioUnavailable(String)
    }

    public let kind: Kind
    public let status: Status
    public let detail: Detail
    /// The connection the headset row speaks about; nil for other rows.
    public let connection: StreamConnectionMode?
    /// The game's OpenVR label still asks for setup. A guess from files, so
    /// it warns and never blocks.
    public let showsOpenVRNote: Bool

    public var id: Kind { kind }
    /// An optional row never stands in the way of starting.
    public var isOptional: Bool { kind == .audio }

    init(kind: Kind, status: Status, detail: Detail,
         connection: StreamConnectionMode? = nil, showsOpenVRNote: Bool = false) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.connection = connection
        self.showsOpenVRNote = showsOpenVRNote
    }

    public var title: String {
        switch kind {
        case .mac: return L10n.string(.learningRowMac)
        case .headset: return L10n.string(.sidebarHeadset)
        case .game: return L10n.string(.streamGame)
        case .audio: return L10n.string(.streamAudio)
        }
    }

    /// "USB cable" or "Wi-Fi" beside the headset row's title.
    public var caption: String? {
        connection.map { L10n.string($0 == .wired ? .connectionUSB : .connectionWiFi) }
    }

    public var text: String {
        switch detail {
        case .checking: return L10n.string(.learningChecking)
        case .checkFailed: return L10n.string(.learningCheckFailed)
        case .macReady: return L10n.string(.setupCheckReady)
        case .macMissing(let count): return L10n.string(.sidebarMissingSteps, Int64(count))
        case .usbToolsMissing: return L10n.string(.headsetToolsNeeded)
        case .usbNotConnected: return L10n.string(.headsetNotConnected)
        case .usbApprovalNeeded: return L10n.string(.headsetApprovalNeeded)
        case .usbConnected: return L10n.string(.headsetConnected)
        case .wifiLastSession(let date):
            return L10n.string(.learningLastSession, Self.dateText(date))
        case .usbNotChecked, .wifiNotChecked: return L10n.string(.learningNotChecked)
        case .game(let name): return name
        case .noGame: return L10n.string(.streamNoGames)
        case .audio(let name): return name
        case .audioOff: return L10n.string(.streamNoAudio)
        case .audioUnavailable(let name): return L10n.string(.settingsAudioUnavailable, name)
        }
    }

    /// The warning line under the game row.
    public var note: String? {
        guard showsOpenVRNote else { return nil }
        return L10n.string(.learningOpenVRNote,
                           L10n.string(.libraryOpenVRSetup), L10n.string(.sidebarLibrary),
                           L10n.string(.commonStop))
    }

    /// The Stream page's history date, in the interface language.
    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = L10n.string(.streamHistoryDateFormat)
        formatter.shortMonthSymbols = L10n.string(.streamHistoryMonths).components(separatedBy: "|")
        return formatter.string(from: date)
    }
}

/// What the Learning page's main button does now.
public enum LearningPrimaryAction: Equatable, Sendable {
    public enum Wait: Equatable, Sendable {
        /// The Mac's setup checks have not arrived yet.
        case checking
        /// A game is being added from a folder.
        case importRunning
        /// Steam is downloading a game for the "Game" chapter.
        case gameDownload
    }

    case startQuickPath
    case open(LearningDestination)
    /// Stop the Windows program (Steam, an installer) that holds the session.
    case stopWindowsApp
    /// Read the Mac's setup checks again.
    case recheck
    /// Nothing to press yet.
    case wait(Wait)

    public var title: String {
        switch self {
        case .startQuickPath, .wait(.importRunning), .wait(.gameDownload):
            return L10n.string(.learningStartQuickPath)
        case .open(.setup): return L10n.string(.learningOpenSetup)
        case .open(.library): return L10n.string(.streamOpenLibrary)
        case .open(.stream): return L10n.string(.sidebarOpenStream)
        case .open(let destination): return L10n.string(.learningOpenSection, destination.title)
        case .stopWindowsApp: return L10n.string(.commonStop)
        case .recheck: return L10n.string(.learningRecheck)
        case .wait(.checking): return L10n.string(.learningChecking)
        }
    }

    public var isEnabled: Bool {
        if case .wait = self { return false }
        return true
    }

    /// Why the button is not "start", when no row of the card says it.
    public var note: String? {
        switch self {
        case .open(.stream): return L10n.string(.learningBlockedSession)
        case .stopWindowsApp: return L10n.string(.learningBlockedWindowsApp)
        case .wait(.importRunning): return L10n.string(.learningBlockedImport)
        case .wait(.gameDownload): return L10n.string(.learningBlockedDownload)
        default: return nil
        }
    }
}

/// The "Ready for VR" card and the quick path's pre-check, from one snapshot.
public struct LearningReadiness: Equatable, Sendable {
    public let rows: [LearningReadinessRow]
    public let primaryAction: LearningPrimaryAction

    public var canStartQuickPath: Bool { primaryAction == .startQuickPath }

    /// The card's own "Check again" in its header. Hidden while the main
    /// button is "Check again" itself: two buttons would do the same.
    public var showsRecheckInHeader: Bool { primaryAction != .recheck }

    public init(_ snapshot: LearningReadinessSnapshot) {
        let mac = Self.macRow(snapshot)
        let headset = Self.headsetRow(snapshot)
        let game = Self.gameRow(snapshot)
        rows = [mac, headset, game, Self.audioRow(snapshot)]
        primaryAction = Self.primaryAction(snapshot, mac: mac, headset: headset, game: game)
    }

    public func row(_ kind: LearningReadinessRow.Kind) -> LearningReadinessRow? {
        rows.first { $0.kind == kind }
    }

    /// The Setup page's own rule for "ready": some checks, none of the
    /// required ones missing. No checks yet is "checking", never "ready".
    private static func macRow(_ snapshot: LearningReadinessSnapshot) -> LearningReadinessRow {
        if snapshot.setupCheckFailed {
            return LearningReadinessRow(kind: .mac, status: .failed, detail: .checkFailed)
        }
        if snapshot.setupChecks.isEmpty {
            return LearningReadinessRow(kind: .mac, status: .checking, detail: .checking)
        }
        let missing = snapshot.setupChecks.filter { $0.required && $0.status != .ready }.count
        return missing == 0
            ? LearningReadinessRow(kind: .mac, status: .ready, detail: .macReady)
            : LearningReadinessRow(kind: .mac, status: .missing, detail: .macMissing(requiredSteps: missing))
    }

    private static func headsetRow(_ snapshot: LearningReadinessSnapshot) -> LearningReadinessRow {
        func row(_ status: LearningReadinessRow.Status, _ detail: LearningReadinessRow.Detail) -> LearningReadinessRow {
            LearningReadinessRow(kind: .headset, status: status, detail: detail,
                                 connection: snapshot.connection)
        }
        switch snapshot.connection {
        case .wifi:
            // Nothing can be asked of a Wi-Fi headset before Play, so this row
            // is never red: only when streaming over Wi-Fi last worked.
            if let date = lastWiFiSession(in: snapshot.sessionHistory) {
                return row(.info, .wifiLastSession(date))
            }
            return row(.info, .wifiNotChecked)
        case .wired:
            if snapshot.headsetPollSkipped { return row(.info, .usbNotChecked) }
            // The status is a placeholder until the first poll answers.
            guard snapshot.headsetPolled else { return row(.checking, .checking) }
            if snapshot.headsetPollFailed { return row(.failed, .checkFailed) }
            switch snapshot.headsetStatus.connection {
            case .noTools: return row(.missing, .usbToolsMissing)
            case .none: return row(.missing, .usbNotConnected)
            case .unauthorized: return row(.missing, .usbApprovalNeeded)
            case .connected:
                // The poll looks for the stable ALVR package only, and Play
                // accepts the other ALVR packages too. Without the stable one
                // the row is neutral: connected, and nothing known to be missing.
                return row(snapshot.headsetStatus.clientInstalled ? .ready : .info, .usbConnected)
            }
        }
    }

    /// When a Wi-Fi session last reached streaming; attempts that never got
    /// that far do not count.
    static func lastWiFiSession(in history: [SessionRecord]) -> Date? {
        history.filter { $0.settings.connection == .wifi }.compactMap(\.streamingStartedAt).max()
    }

    private static func gameRow(_ snapshot: LearningReadinessSnapshot) -> LearningReadinessRow {
        guard let name = snapshot.gameName else {
            return LearningReadinessRow(kind: .game, status: .missing, detail: .noGame)
        }
        return LearningReadinessRow(kind: .game, status: .ready, detail: .game(name),
                                    showsOpenVRNote: snapshot.openVRBadge == .needsSetup)
    }

    private static func audioRow(_ snapshot: LearningReadinessSnapshot) -> LearningReadinessRow {
        if snapshot.macAudio {
            let name = L10n.string(.settingsMacAudio)
            return snapshot.macAudioSupported
                ? LearningReadinessRow(kind: .audio, status: .ready, detail: .audio(name))
                : LearningReadinessRow(kind: .audio, status: .missing, detail: .audioUnavailable(name))
        }
        guard let name = snapshot.audioDeviceName else {
            return LearningReadinessRow(kind: .audio, status: .info, detail: .audioOff)
        }
        return snapshot.audioDeviceAvailable
            ? LearningReadinessRow(kind: .audio, status: .ready, detail: .audio(name))
            : LearningReadinessRow(kind: .audio, status: .missing, detail: .audioUnavailable(name))
    }

    /// The first thing that stands in the way decides the button. The sound
    /// row never does, and the headset row only when a fresh USB check found
    /// no tools to talk to the headset: Play cannot work without them. Its
    /// other states do not block: a USB headset can be connected after this
    /// check, and a Wi-Fi one cannot be checked at all.
    private static func primaryAction(
        _ snapshot: LearningReadinessSnapshot, mac: LearningReadinessRow,
        headset: LearningReadinessRow, game: LearningReadinessRow
    ) -> LearningPrimaryAction {
        if snapshot.session.isVRSession { return .open(.stream) }
        if snapshot.session == .windowsApp {
            return snapshot.gameDownloading ? .wait(.gameDownload) : .stopWindowsApp
        }
        if snapshot.importRunning { return .wait(.importRunning) }
        switch mac.status {
        case .failed: return .recheck
        case .checking: return .wait(.checking)
        case .missing: return .open(.setup)
        case .ready, .info: break
        }
        if game.status != .ready { return .open(.library) }
        if headset.detail == .usbToolsMissing { return .open(.headset) }
        return .startQuickPath
    }
}
