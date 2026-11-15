import Foundation
import BasaltCore

/// The launch failures Learning knows how to fix.
public enum LaunchFailureCause: String, CaseIterable, Sendable {
    /// The streamer was still waiting for the headset when startup timed out.
    case waitingForHeadset
    /// No adb executable for a USB session.
    case adbMissing
    /// The Quest shows the USB debugging prompt, or it was declined.
    case debuggingUnauthorized
    /// adb sees no authorized Quest on USB.
    case noAuthorizedQuest
    /// No ALVR client on the USB headset.
    case clientMissing
    /// ALVR did not come to the foreground: the Quest is locked.
    case pausedBehindLockScreen
    /// Steam opened but nobody signed in.
    case steamNotSignedIn
}

/// The one thing the advice can offer to do.
public enum LaunchFailureAction: Equatable, Sendable {
    case open(LearningDestination)
    case restartQuickPath

    public var title: String {
        switch self {
        case .open(let destination): return L10n.string(.learningOpenSection, destination.title)
        case .restartQuickPath: return L10n.string(.learningStartQuickPath)
        }
    }
}

/// What the app knows about the launch that failed. Some advice depends on it.
public struct LaunchFailureContext: Equatable, Sendable {
    /// The connection the launch used: the game's own stream settings, else
    /// the shared ones.
    public var connection: StreamConnectionMode
    /// The game Play launches, when it has its own stream settings; nil when
    /// it uses the shared ones. Its connection is then changed in those own
    /// settings: the Settings section would change nothing for it.
    public var gameWithOwnSettings: String?

    public init(connection: StreamConnectionMode, gameWithOwnSettings: String? = nil) {
        self.connection = connection
        self.gameWithOwnSettings = gameWithOwnSettings
    }
}

/// Plain advice for one cause. The texts are read in the current interface
/// language each time, with control names taken from the controls' own keys.
public struct LaunchFailureAdvice: Equatable, Sendable {
    public let cause: LaunchFailureCause
    public let context: LaunchFailureContext

    public init(cause: LaunchFailureCause, context: LaunchFailureContext) {
        self.cause = cause
        self.context = context
    }

    /// What went wrong, in a few words.
    public var title: String {
        switch cause {
        case .waitingForHeadset: return L10n.string(.learningCauseWaitingHeadset)
        case .adbMissing: return L10n.string(.learningCauseNoADB)
        case .debuggingUnauthorized: return L10n.string(.learningCauseUnauthorized)
        case .noAuthorizedQuest: return L10n.string(.learningCauseNoUSBQuest)
        case .clientMissing: return L10n.string(.learningCauseNoClient)
        case .pausedBehindLockScreen: return L10n.string(.learningCauseLockScreen)
        case .steamNotSignedIn: return L10n.string(.learningCauseSteamSignIn)
        }
    }

    /// What to do about it.
    public var text: String {
        let play = L10n.string(.libraryPlay)
        switch cause {
        case .waitingForHeadset:
            // Over USB, ALVR opens by itself: what holds it back is a headset
            // that is off the head or locked.
            return L10n.string(context.connection == .wired
                               ? .learningFixWaitingHeadsetUSB : .learningFixWaitingHeadset, play)
        case .adbMissing:
            let headset = L10n.string(.sidebarHeadset)
            let tools = L10n.string(.headsetGetTools)
            let connection = L10n.string(.streamConnection)
            let wifi = L10n.string(.connectionWiFi)
            // The way to Wi-Fi goes through the settings the game really uses.
            if let game = context.gameWithOwnSettings {
                return L10n.string(.learningFixNoADBOwn, headset, tools,
                                   L10n.string(.sidebarStream), L10n.string(.streamAdjust),
                                   L10n.string(.streamProfileSettings, game), connection, wifi)
            }
            return L10n.string(.learningFixNoADB, headset, tools,
                               L10n.string(.sidebarSettings), connection, wifi)
        case .debuggingUnauthorized:
            return L10n.string(.learningFixUnauthorized)
        case .noAuthorizedQuest:
            return L10n.string(.learningFixNoUSBQuest)
        case .clientMissing:
            return L10n.string(.learningFixNoClient,
                               L10n.string(.sidebarHeadset), L10n.string(.headsetInstall))
        case .pausedBehindLockScreen:
            return L10n.string(.learningFixLockScreen, play)
        case .steamNotSignedIn:
            return L10n.string(.learningFixSteamSignIn,
                               L10n.string(.commonSteam), L10n.string(.steamOpenSignIn),
                               L10n.string(.steamClose), play)
        }
    }

    public var action: LaunchFailureAction {
        switch cause {
        case .waitingForHeadset, .pausedBehindLockScreen: return .restartQuickPath
        case .adbMissing, .debuggingUnauthorized, .noAuthorizedQuest, .clientMissing: return .open(.headset)
        case .steamNotSignedIn: return .open(.steam)
        }
    }

    /// The action to offer now. Leaving a section closes that section's open
    /// sheet, so while one is open the advice is text only.
    public func availableAction(pageSheetOpen: Bool) -> LaunchFailureAction? {
        pageSheetOpen ? nil : action
    }
}

/// Finds the cause of a launch failure from its message alone: the session
/// keeps only the text. The streamer's texts are BasaltCore constants; the
/// app's own texts are looked up in every language table, so advice is still
/// found after the interface language changes.
public enum LaunchFailureAdvisor {
    public static func cause(for message: String) -> LaunchFailureCause? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        for (text, cause) in streamerTexts where message.contains(text) { return cause }
        for (key, cause) in appKeys {
            for language in AppLanguage.allCases {
                guard let text = LocalizationTables.table(for: language)?.strings[key]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if message.contains(text) { return cause }
            }
        }
        return nil
    }

    public static func advice(
        for message: String, context: LaunchFailureContext
    ) -> LaunchFailureAdvice? {
        cause(for: message).map { LaunchFailureAdvice(cause: $0, context: context) }
    }

    private static let streamerTexts: [(String, LaunchFailureCause)] = [
        (AlvrWiredFailure.adbMissing, .adbMissing),
        (AlvrWiredFailure.debuggingUnauthorized, .debuggingUnauthorized),
        (AlvrWiredFailure.noAuthorizedQuest, .noAuthorizedQuest),
        (AlvrWiredFailure.clientMissing, .clientMissing),
        (AlvrWiredFailure.pausedBehindLockScreen, .pausedBehindLockScreen),
    ]

    private static let appKeys: [(L10nKey, LaunchFailureCause)] = [
        (.modelWaitingHeadset, .waitingForHeadset),
        (.modelSteamNotSignedIn, .steamNotSignedIn),
    ]
}
