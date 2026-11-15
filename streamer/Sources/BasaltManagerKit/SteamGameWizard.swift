import Foundation
import BasaltBottleKit

/// The month a game was last checked in a headset. A later update of the
/// game can break it, so the month is shown next to "Verified in headset".
public struct VerifiedMonth: Equatable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// "November 2026" or "ноябрь 2026 г.", in the app's language.
    public func text(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else {
            return "\(year)-\(month)"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("LLLLy")
        return formatter.string(from: date)
    }
}

public struct SteamCatalogGame: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let appID: String?
    public let environmentName: String?
    public let status: String
    public let note: String
    public let needsOpenVR: Bool
    /// When the game was last checked in a headset; nil when it never was.
    public var verifiedIn: VerifiedMonth? = nil
    public var isVerified: Bool { appID != nil }

    /// Every game in `verified` was checked in a headset in this month.
    static let november2026 = VerifiedMonth(year: 2026, month: 11)

    public static let verified: [Self] = [
        .init(id: "2669380", name: "BRUTALISTICK VR", appID: "2669380",
              environmentName: "brutalistick-vr", status: "Проверена в шлеме",
              note: "Проверена на Mac mini M4 и Quest 3: запуск, руки, ходьба — работает стабильно.", needsOpenVR: true,
              verifiedIn: november2026),
        .init(id: "1032430", name: "Blood Trail", appID: "1032430",
              environmentName: "blood-trail", status: "Проверена в шлеме",
              note: "Проверена на Mac mini M4 и Quest 3: уровни, стрельба, частицы, сессия 54 минуты. Направление ходьбы зависит от настройки контроллера; бега на контроллерах нет.", needsOpenVR: true,
              verifiedIn: november2026),
        // VTOL VR draws both eyes in one pass; GameCompatibilityFix
        // vtolVRSeparateEyePasses makes the right eye work.
        .init(id: "667970", name: "VTOL VR", appID: "667970",
              environmentName: "vtol-vr", status: "Проверена в шлеме",
              note: "Проверена на Mac mini M4 и Quest 3: полёт с ботами, оба глаза. TrailBridge сам меняет настройку отрисовки игры, без неё правый глаз чёрный.", needsOpenVR: true,
              verifiedIn: november2026),
        // BONELAB runs its own OpenXR loader and needs no OpenComposite.
        .init(id: "1592190", name: "BONELAB", appID: "1592190",
              environmentName: "bonelab", status: "Проверена в шлеме",
              note: "Проверена на Mac mini M4 и Quest 3: запуск и игра через собственный OpenXR игры. Проверялась короткими сеансами.", needsOpenVR: false,
              verifiedIn: november2026),
        .init(id: "629730", name: "Blade & Sorcery", appID: "629730",
              environmentName: "blade-sorcery", status: "Проверена в шлеме",
              note: "Проверена на Mac mini M4 и Quest 3: меню и игра. Проверялась короткими сеансами.", needsOpenVR: true,
              verifiedIn: november2026),
    ]
    public static let other = Self(id: "other", name: "Другая игра", appID: nil,
        environmentName: nil, status: "Не проверена",
        note: "В TrailBridge эта игра не проверялась. Может не запуститься или работать с ошибками.", needsOpenVR: false)
    public static let all = verified + [other]

    public func bottleName(custom: String = "steam-games") throws -> String {
        try BottleName.validate(environmentName ?? custom, kind: "environment name")
    }
}

extension SteamCatalogGame {
    /// Whether a launch profile already starts this game, the way the
    /// wizard's last step recognises an added game.
    public func isAdded(in profiles: [LaunchProfile]) -> Bool {
        guard let appID else { return false }
        return profiles.contains {
            $0.source == .steam && ($0.arguments.contains(appID)
                || $0.environment["SteamAppId"] == appID || $0.environment["SteamGameId"] == appID)
        }
    }

    /// The game the wizard offers when it starts over after one was added:
    /// the first verified game not yet in the Library, else the first one.
    public static func firstNotAdded(profiles: [LaunchProfile]) -> Self {
        verified.first { !$0.isAdded(in: profiles) } ?? verified[0]
    }

    /// Whether a launch profile starts one of the games verified in a
    /// headset: a Steam profile whose SteamAppId or SteamGameId is in
    /// `verified`. Every other profile is not verified, games added from a
    /// folder among them, so the Library can say so on their tiles.
    public static func isVerified(profile: LaunchProfile) -> Bool {
        guard profile.source == .steam else { return false }
        let verifiedIDs = Set(verified.compactMap(\.appID))
        return ["SteamAppId", "SteamGameId"].contains { key in
            profile.environment[key].map { verifiedIDs.contains($0) } ?? false
        }
    }
}

public enum SteamBootstrapState: Equatable, Sendable {
    case notStarted, updating, finished

    /// Bootstrap is append-only. Suppressed launches provide no update evidence;
    /// among ordinary launches only the newest section can prove completion.
    public static func parse(_ text: String?) -> Self {
        guard let text, !text.isEmpty else { return .notStarted }
        let sections = text.components(separatedBy: "Startup - updater built").dropFirst()
        guard let section = sections.last(where: { section in
            !section.components(separatedBy: .newlines).contains {
                $0.contains("Startup - Steam Client launched with:") && $0.contains("-inhibitbootstrap")
            }
        }) else { return .notStarted }
        guard let verification = section.range(of: "Verification complete", options: .backwards),
              !section.contains("Unable to read and verify install manifest") else { return .updating }
        let tail = section[verification.upperBound...]
        return tail.contains("Downloading update") || tail.contains("Update complete") ? .updating : .finished
    }
}

/// A monotonic timestamp is supplied by the caller. A changed/missing log resets
/// the window, even if the new contents also contain a successful verification.
public struct SteamBootstrapReadiness: Sendable {
    public static let stabilityWindow: TimeInterval = 5
    private var previous: String?
    private var unchangedSince: TimeInterval?
    public init() {}

    /// `requireStability` is false when no first-run update is in progress: the
    /// log of an already installed Steam cannot change, so there is nothing to wait for.
    public mutating func observe(log: String?, helperExists: Bool, manifestExists: Bool,
                                 now: TimeInterval, requireStability: Bool = true) -> Bool {
        if log != previous || unchangedSince == nil {
            previous = log
            unchangedSince = now
        }
        return SteamBootstrapState.parse(log) == .finished && helperExists && manifestExists
            && (!requireStability || now - (unchangedSince ?? now) >= Self.stabilityWindow)
    }

    public mutating func observe(steam: URL, now: TimeInterval, requireStability: Bool = true,
                                 fileManager: FileManager = .default) -> Bool {
        let root = steam.deletingLastPathComponent()
        return observe(log: try? String(contentsOf: root.appendingPathComponent("logs/bootstrap_log.txt"), encoding: .utf8),
            helperExists: fileManager.fileExists(atPath: root.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe").path),
            manifestExists: fileManager.fileExists(atPath: root.appendingPathComponent("package/steam_client_win64.installed").path),
            now: now, requireStability: requireStability)
    }
}

/// The installer normally starts Steam just before it exits, and that client
/// keeps writing its log. Only a silent log means the user unticked "Run Steam".
public enum SteamBootstrapStartDecision {
    public static let grace: TimeInterval = 20
    public static func shouldStartPlainSteam(logAtExit: String?, logNow: String?) -> Bool {
        logNow == logAtExit
    }
}

public enum SteamInstallerExitDecision: Equatable {
    case cancelled, startBootstrap, waitForStability, openSignIn
    public static func decide(steamExists: Bool, bootstrapState: SteamBootstrapState, ready: Bool) -> Self {
        guard steamExists else { return .cancelled }
        if ready { return .openSignIn }
        return bootstrapState == .finished ? .waitForStability : .startBootstrap
    }
}

/// "Wait again" after a timed-out update. The client may have been closed or
/// crashed meanwhile; waiting again for it alone would only time out again. A
/// client this app started that still runs is left alone, and a confirmed
/// update needs no new client. Otherwise a silent update log starts a plain
/// bootstrap, as after the installer exits.
public enum SteamSetupRetryDecision: Equatable {
    case watch, startPlainSteamIfLogStaysSilent
    public static func decide(ownedClientRunning: Bool, ready: Bool) -> Self {
        ownedClientRunning || ready ? .watch : .startPlainSteamIfLogStaysSilent
    }
}

public enum SteamBootstrapWaitDecision: Equatable {
    case wait, openSignIn, timedOut
    public static let timeout: TimeInterval = 15 * 60
    public static func decide(ready: Bool, elapsed: TimeInterval) -> Self {
        if ready { return .openSignIn }
        return elapsed >= timeout ? .timedOut : .wait
    }
}

/// What a watch over Steam's first update does after one look.
public enum SteamRecoveryDecision: Equatable, Sendable {
    case wait
    /// Stop what is left of Steam and start it again.
    case restart
    /// The automatic restarts are used up and Steam is still stuck: the
    /// user is told, and decides.
    case stuck
}

/// A client that dies in the middle of its first update leaves no Wine
/// process in the environment and an update log that never moves again;
/// nothing is on screen, and waiting alone ends only at the timeout. The
/// second updater generation can hit a Wine page fault a second after it
/// starts; the same Steam started again then finishes the update. Such a
/// client is started again up to `restarts` times per wait.
/// Wine keeps its server while any process of the environment runs, so a
/// healthy update is never without one for `confirmation` seconds.
public struct SteamClientLoss: Sendable {
    public static let confirmation: TimeInterval = 10
    public static let restarts = 2
    private var goneSince: TimeInterval?
    private var restartsUsed = 0
    public init() {}

    /// `running` is nil when it cannot be told, or while the app is about to
    /// start the client itself; that counts as running.
    public mutating func observe(running: Bool?, now: TimeInterval) -> SteamRecoveryDecision {
        guard running == false else {
            goneSince = nil
            return .wait
        }
        let since = goneSince ?? now
        goneSince = since
        guard now - since >= Self.confirmation else { return .wait }
        guard restartsUsed < Self.restarts else { return .stuck }
        restartsUsed += 1
        // The restarted client gets its own ten seconds to appear.
        goneSince = now
        return .restart
    }
}

/// A client whose first update stands still while it runs: the process is
/// there, but the update log has not moved for `limit` seconds on a download
/// step. Steam can sit at full CPU for minutes after "Add pending download"
/// with nothing downloaded; stopped and started again, it then finishes
/// the update. Such a client is restarted up to `restarts` times per wait.
/// A healthy download writes a line every few seconds; the steps after it
/// ("Verification complete", a suppressed update) stay still on purpose and
/// never count.
public struct SteamUpdateStall: Sendable {
    public static let limit: TimeInterval = 60
    public static let restarts = 2
    static let downloadSteps = [
        "Checking for available updates", "Downloading manifest", "Manifest download:",
        "Add pending download", "Downloading update", "Extracting package", "Installing update",
    ]
    private var signature: String?
    private var unchangedSince: TimeInterval?
    private var restartsUsed = 0
    public init() {}

    public static func isDownloadStep(_ line: String) -> Bool {
        downloadSteps.contains { line.contains($0) }
    }

    /// `log` is the update log's text, nil when it cannot be read; `running`
    /// as for `SteamClientLoss`, where only a running client can stand still.
    public mutating func observe(log: String?, running: Bool?, now: TimeInterval) -> SteamRecoveryDecision {
        guard running == true, let log else {
            signature = nil
            unchangedSince = nil
            return .wait
        }
        let lastLine = log.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let current = "\(log.utf8.count)|\(lastLine)"
        guard current == signature, let since = unchangedSince else {
            signature = current
            unchangedSince = now
            return .wait
        }
        guard Self.isDownloadStep(lastLine), now - since >= Self.limit else { return .wait }
        guard restartsUsed < Self.restarts else { return .stuck }
        restartsUsed += 1
        // A restarted client that never writes again is given its own minute.
        unchangedSince = now
        return .restart
    }
}

/// A game download that stands still while Steam runs. Steam writes the
/// game's manifest only when a download starts, pauses or ends, so whether it
/// moves is told by what the environment's processes read and write and by
/// Steam's content log. This only tells the user: a download can also wait
/// on purpose (a pause the manifest does not show yet, a full disk, Steam's
/// own schedule), so Steam is never restarted for it automatically.
public struct SteamDownloadStall: Sendable {
    public static let limit: TimeInterval = 180
    /// Less than this in `limit` seconds is Steam's own bookkeeping, not a download.
    public static let minimumActivity: UInt64 = 1 << 20
    private struct Baseline: Sendable { let activity: UInt64; let contentLog: Int? }
    private var baseline: Baseline?
    private var since: TimeInterval?
    public init() {}

    /// `downloading` when the manifest shows a download that runs and is not
    /// paused; `activity` is the environment's I/O counter, nil when it
    /// cannot be told. True while the download stands still.
    public mutating func observe(downloading: Bool, activity: UInt64?, contentLogSize: Int?,
                                 now: TimeInterval) -> Bool {
        guard downloading, let activity else {
            baseline = nil
            since = nil
            return false
        }
        if let base = baseline, let since,
           Self.distance(base.activity, activity) < Self.minimumActivity, base.contentLog == contentLogSize {
            return now - since >= Self.limit
        }
        baseline = Baseline(activity: activity, contentLog: contentLogSize)
        since = now
        return false
    }

    /// The counter is a sum over processes, so it also falls when one ends.
    private static func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }
}

public enum SteamBootstrapWaiter {
    @MainActor
    public static func wait(isCurrent: () -> Bool, readReady: () -> Bool,
                            clientRunning: () -> Bool? = { nil },
                            restartClient: () -> Void = {},
                            readLog: () -> String? = { nil },
                            restartStalledClient: () -> Void = {},
                            reportStuck: (Bool) -> Void = { _ in },
                            now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws -> SteamBootstrapWaitDecision {
        let started = now()
        var loss = SteamClientLoss()
        var stall = SteamUpdateStall()
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let decision = SteamBootstrapWaitDecision.decide(ready: readReady(), elapsed: now() - started)
            if decision != .wait {
                reportStuck(false)
                return decision
            }
            let running = clientRunning()
            let lost = loss.observe(running: running, now: now())
            let stalled = lost == .restart ? .wait : stall.observe(log: readLog(), running: running, now: now())
            if lost == .restart {
                restartClient()
            } else if stalled == .restart {
                restartStalledClient()
            }
            reportStuck(lost == .stuck || stalled == .stuck)
            try await pause()
        }
    }
}

/// What went wrong with Steam in one environment, for the user to see.
public enum SteamTrouble: Equatable, Sendable {
    /// The first update stands still after the automatic restarts.
    case updateStuck
    /// A game download has not moved for `SteamDownloadStall.limit` seconds.
    case downloadStuck
    /// Some of the environment's processes outlived even a forced stop.
    case stopFailed(String)
}

public enum SteamSetupActivity: Equatable {
    case installer, updating, timedOut, cancelled, stopped, openingSignIn
    public var message: String {
        switch self {
        case .installer: "Откроется установщик Windows. Пройдите его шаги и сами примите соглашение Steam."
        case .updating: "Ждём завершения обновления Steam. После проверки откроем окно входа."
        case .timedOut: "За 15 минут обновление не подтвердилось. Проверьте окно Steam и повторите проверку."
        case .cancelled: "Установка отменена: Steam не найден. Можно повторить установку."
        case .stopped: "Ожидание остановлено. Можно продолжить позже."
        case .openingSignIn: "Закрываем Steam и ждём завершения его процессов. Затем попробуем открыть окно входа."
        }
    }
}

public enum SteamWizardStep: Int, CaseIterable {
    case choose = 1, create, prepare, steam, signIn, game, profile, done
    public var title: String {
        switch self {
        case .choose: "Выберите игру"
        case .create: "Создайте окружение"
        case .prepare: "Подготовьте окружение"
        case .steam: "Установите Steam"
        case .signIn: "Войдите в Steam"
        case .game: "Установите игру"
        case .profile: "Добавьте игру в библиотеку"
        case .done: "Игра добавлена"
        }
    }
}

public struct SteamWizardFacts {
    public var chosen = false
    public var bottleExists = false
    public var prepared = false
    public var steamExists = false
    public var bootstrapReady = false
    public var installingSteam = false
    public var loggedOn = false
    public var gameInstalled = false
    /// Steam has the game in its download queue: the wizard waits, and
    /// "Download Game" has nothing more to do.
    public var gameDownloading = false
    public var profileExists = false
    public init() {}
    public var nextStep: SteamWizardStep {
        if !chosen { return .choose }
        if !bottleExists { return .create }
        if !prepared { return .prepare }
        // A fresh sign-in proves the client works even when its update was
        // never confirmed, e.g. after Stop or a timeout and "Open Steam".
        if installingSteam || !steamExists || (!bootstrapReady && !loggedOn) { return .steam }
        // Installed games and profiles survive signing out or restarting the app.
        if gameInstalled { return profileExists ? .done : .profile }
        if !loggedOn { return .signIn }
        return .game
    }
}

/// A game Steam is downloading or updating, as its manifest says. Steam
/// writes the manifest when a download starts, pauses or ends, not while it
/// runs, so the downloaded bytes in it are not live; only the total is shown.
public struct SteamDownloadState: Equatable, Sendable {
    /// What the whole download takes, when the manifest says.
    public let bytesToDownload: Int64?
    /// Started and not paused: only then can it stand still.
    public var isRunning: Bool = false

    /// Nil when the manifest shows no download or update under way, or
    /// shows a game that is installed and idle.
    public static func parse(manifest text: String) -> Self? {
        guard let state = try? SteamUpdateState.parse(text), state.isUpdating else { return nil }
        let total = SteamLibraryDiscovery.value(for: "BytesToDownload", in: text).flatMap(Int64.init)
        return .init(bytesToDownload: total.flatMap { $0 > 0 ? $0 : nil }, isRunning: state.isDownloadRunning)
    }
}

public struct SteamWizardDiskState: Sendable {
    public let bottle: DiscoveredBottle?
    public let games: [SteamGame]
    public let installedAppIDs: Set<String>
    public let profiles: [LaunchProfile]
    /// Games Steam is downloading or updating now, by app ID.
    public var downloads: [String: SteamDownloadState] = [:]

    public static func read(name: String, manager: BottleManager,
                             fileManager: FileManager = .default) throws -> Self {
        let directory = try manager.paths.bottleDirectory(name)
        guard fileManager.fileExists(atPath: directory.path) else {
            return .init(bottle: nil, games: [], installedAppIDs: [], profiles: [])
        }
        // An existing directory with damaged metadata is an error, never a
        // reason to create over it. loadBottle also validates managed paths.
        let managed = try manager.loadBottle(name)
        let bottle = DiscoveredBottle(name: managed.name, origin: .managed,
            prefix: URL(fileURLWithPath: managed.prefixPath), managed: managed)
        let games = SteamLibraryDiscovery(fileManager: fileManager).discover(in: bottle).filter { !$0.isTool }
        var installed = Set<String>()
        var downloads = [String: SteamDownloadState]()
        for game in games {
            let profile = LaunchProfile(name: "status", bottleName: name, source: .steam,
                executable: "steam.exe", environment: ["SteamAppId": game.appID])
            guard let manifest = try? SteamUpdateState.manifestURL(profile: profile, prefix: bottle.prefix, fileManager: fileManager),
                  let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            if (try? SteamUpdateState.parse(text).isReady) == true {
                installed.insert(game.appID)
            } else if let download = SteamDownloadState.parse(manifest: text) {
                downloads[game.appID] = download
            }
        }
        return .init(bottle: bottle, games: games.sorted { $0.name < $1.name },
            installedAppIDs: installed, profiles: try manager.listProfiles(), downloads: downloads)
    }
}

public enum SteamWizardCopy {
    public static let endToEndCaveat = "Сам мастер пока не проверен от начала до конца на чистом окружении."
    public static func failure(_ lead: String, detail: String) -> String { lead + "\n" + detail }
}
