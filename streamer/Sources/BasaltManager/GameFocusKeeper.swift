import AppKit
import BasaltManagerKit

/// Brings the game's window back to the front during a session, as
/// `GameFocusPolicy` decides, so a game that mutes itself without the front
/// keeps its sound in the headset.
@MainActor
final class GameFocusKeeper {
    static let checkSeconds: TimeInterval = 2
    /// Apps that show system prompts; the game never covers them.
    static let promptBundleIDs: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.SecurityAgent",
        "com.apple.CoreServicesUIAgent",
        "com.apple.coreautha",
        "com.apple.LocalAuthenticationUIService",
    ]

    private var timer: Timer?
    private var policy = GameFocusPolicy()
    private var gamePID: pid_t = 0
    private var gameApp: NSRunningApplication?
    private var headsetConnected: () -> Bool = { false }
    private var log: (String) -> Void = { _ in }
    private var reportedFailure = false
    private var attempt = 0

    func start(gamePID: pid_t, headsetConnected: @escaping () -> Bool,
               log: @escaping (String) -> Void) {
        stop()
        guard gamePID > 1 else { return }
        self.gamePID = gamePID
        self.headsetConnected = headsetConnected
        self.log = log
        let timer = Timer(timeInterval: Self.checkSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        policy = GameFocusPolicy()
        gamePID = 0
        gameApp = nil
        reportedFailure = false
        attempt += 1
    }

    private func check() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front: GameFocusPolicy.Front
        if let frontApp, isGame(frontApp) {
            gameApp = frontApp
            front = .game
        } else if let frontApp, frontApp.activationPolicy == .regular,
                  let bundleID = frontApp.bundleIdentifier,
                  !Self.promptBundleIDs.contains(bundleID) {
            front = .otherApp
        } else {
            front = .systemPrompt
        }
        guard policy.shouldBringGameForward(
            front: front, headsetConnected: headsetConnected(),
            idleSeconds: Self.idleSeconds(), now: Date()),
            let gameApp, !gameApp.isTerminated else { return }
        bringForward(gameApp)
    }

    private func isGame(_ app: NSRunningApplication) -> Bool {
        GameProcessFamily.contains(app.processIdentifier, gamePID: gamePID,
                                   parent: GameProcessFamily.systemParent(of:))
    }

    /// Seconds since the last keyboard, mouse or trackpad input on the Mac.
    /// Reading it needs no permission.
    private static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Since macOS 14 an app in the background cannot activate another app:
    /// `activate()` returns false (checked on macOS 27.2). Launch Services may
    /// still make this app active when asked to open it, and the active app
    /// may hand activation over. This app's window shows for a moment.
    private func bringForward(_ game: NSRunningApplication) {
        let attempt = self.attempt
        let gamePID = game.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { [weak self] _, error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.attempt == attempt else { return }
                if failed {
                    self.reportFailure()
                    return
                }
                await self.handOver(to: gamePID, attempt: attempt)
            }
        }
    }

    private func handOver(to gamePID: pid_t, attempt: Int) async {
        // Opening reports back before this app is active; wait up to a second.
        for _ in 0..<20 where !NSApp.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard self.attempt == attempt,
              let game = NSRunningApplication(processIdentifier: gamePID),
              !game.isTerminated else { return }
        if NSApp.isActive, game.activate(from: .current, options: [.activateAllWindows]) {
            log(L10n.string(.modelGameBroughtForward))
        } else {
            reportFailure()
        }
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        log(L10n.string(.modelGameBringForwardFailed))
    }
}
