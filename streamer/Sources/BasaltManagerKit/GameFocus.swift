import Foundation
import Darwin

/// Decides when to bring the game's window back to the front during a
/// session. Some games mute themselves while their window on the Mac is not
/// in front (Blood Trail does). The person is in the headset and cannot
/// click the window, so another app taking the front, such as an app
/// relaunching after an update, would leave the game silent.
///
/// The game comes back only when it already had the front in this session,
/// the headset is connected, an ordinary app window covers it (never a system
/// prompt), and nobody has used the Mac's keyboard or mouse for a while. A
/// person working at the Mac keeps the front they chose.
public struct GameFocusPolicy: Sendable {
    public static let idleSeconds: TimeInterval = 5
    public static let retrySeconds: TimeInterval = 10

    public enum Front: Equatable, Sendable {
        case game
        /// An ordinary window of another app, including this one.
        case otherApp
        /// A system prompt (permission, password, Gatekeeper), or no app.
        case systemPrompt
    }

    private var gameHadFront = false
    private var lastAttempt: Date?

    public init() {}

    /// Call every couple of seconds. True means bring the game forward now.
    public mutating func shouldBringGameForward(front: Front, headsetConnected: Bool,
                                                idleSeconds: TimeInterval, now: Date) -> Bool {
        if front == .game {
            gameHadFront = true
            return false
        }
        guard gameHadFront, headsetConnected, front == .otherApp,
              idleSeconds >= Self.idleSeconds else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retrySeconds { return false }
        lastAttempt = now
        return true
    }
}

/// The game process and the processes it started, such as a launcher's game.
public enum GameProcessFamily {
    public static let maximumDepth = 8

    /// True when `pid` is `gamePID` or descends from it. `parent` returns a
    /// process's parent, or nil when the process is gone.
    public static func contains(_ pid: pid_t, gamePID: pid_t,
                                parent: (pid_t) -> pid_t?) -> Bool {
        guard gamePID > 1 else { return false }
        var current = pid
        for _ in 0...maximumDepth {
            if current == gamePID { return true }
            guard current > 1, let next = parent(current), next != current else { return false }
            current = next
        }
        return false
    }

    public static func systemParent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
