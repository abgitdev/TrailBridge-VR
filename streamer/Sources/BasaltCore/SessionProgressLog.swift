import Foundation

/// Always-on milestones plus a low-rate watchdog. Its clock and output are
/// injectable so stalls can be tested without media devices or a headset.
public final class SessionProgressLog: @unchecked Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case headsetHandshake, tracking, runtimeConnected, gameFrame, encodedFrame, sentFrame, headsetStatistics

        var name: String {
            switch self {
            case .headsetHandshake: "headset handshake (StreamReady)"
            case .tracking: "headset tracking"
            case .runtimeConnected: "runtime connected"
            case .gameFrame: "first frame from the game"
            case .encodedFrame: "first frame encoded"
            case .sentFrame: "first frame sent"
            case .headsetStatistics: "first statistics from the headset"
            }
        }

        /// What stops when a stage that was already flowing goes quiet.
        var flowName: String {
            switch self {
            case .headsetHandshake: "headset handshake"
            case .tracking: "headset tracking"
            case .runtimeConnected: "runtime connection"
            case .gameFrame: "frames from the game"
            case .encodedFrame: "encoded frames"
            case .sentFrame: "sent frames"
            case .headsetStatistics: "statistics from the headset"
            }
        }
    }

    private struct Activity {
        var last: UInt64
        var count: UInt64
    }
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let log: @Sendable (String) -> Void
    private let started: UInt64
    private var activity: [Stage: Activity] = [:]
    private var headsetAttempt: UInt64 = 0
    private var headsetStarted: UInt64
    private var runtimeStarted: UInt64
    private var lastStalled: Stage?
    private var lastReport: UInt64?
    private var timer: DispatchSourceTimer?
    private let runtimeMode: Bool

    public init(runtimeMode: Bool = true,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.clock = clock
        self.log = log
        self.runtimeMode = runtimeMode
        started = clock()
        headsetStarted = started
        runtimeStarted = started
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "basalt.session-progress"))
        source.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        source.setEventHandler { [weak self] in self?.check() }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    deinit { stop() }

    /// Returns a generation so delayed callbacks from an old sender cannot
    /// make a reconnect look healthy. Runtime activity survives reconnects.
    @discardableResult
    public func beginHeadsetAttempt() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        // A retry after an attempt that never reached the handshake belongs
        // to the same outage: keep its start time and stay quiet, so the
        // report says how long the headset has been away and one line per
        // second does not push the start of the session out of the log.
        let continuesOutage = headsetAttempt > 0 && activity[.headsetHandshake] == nil
        headsetAttempt &+= 1
        for stage: Stage in [.headsetHandshake, .tracking, .sentFrame, .headsetStatistics] {
            activity[stage] = nil
        }
        if !continuesOutage {
            headsetStarted = clock()
            lastStalled = nil
            lastReport = nil
            log("Session progress: headset attempt \(headsetAttempt) started")
        }
        return headsetAttempt
    }

    public func runtimeConnected() {
        lock.lock()
        runtimeStarted = clock()
        for stage: Stage in [.runtimeConnected, .gameFrame, .encodedFrame, .sentFrame, .headsetStatistics] {
            activity[stage] = nil
        }
        lastStalled = nil
        lastReport = nil
        lock.unlock()
        record(.runtimeConnected)
    }

    public func record(_ stage: Stage, attempt: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard attempt == nil || attempt == headsetAttempt else { return }
        let now = clock()
        let previous = activity[stage]
        activity[stage] = Activity(last: now, count: (previous?.count ?? 0) + 1)
        if previous == nil {
            log("Session progress: \(stage.name) after \(seconds(now - started)) s")
        }
    }

    /// Logs the earliest missing/stale pipeline stage, plus every stage's
    /// age/count. Reports continue even if no video callback ever arrives.
    public func check() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let stages = Stage.allCases.filter { runtimeMode || ($0 != .runtimeConnected && $0 != .gameFrame) }
        let stalled = stages.first { stage in
            if let value = activity[stage] {
                // These are milestones, rather than recurring events.
                if stage == .headsetHandshake || stage == .runtimeConnected { return false }
                return now - value.last >= 5_000_000_000
            }
            return now - baseline(stage) >= 5_000_000_000
        }
        guard let stalled else {
            if let lastStalled {
                log("Session progress: flow resumed after waiting for \(lastStalled.name)")
            }
            lastStalled = nil
            lastReport = nil
            return
        }
        guard lastStalled != stalled || lastReport == nil || now - lastReport! >= 15_000_000_000 else { return }
        let since = activity[stalled]?.last ?? baseline(stalled)
        let details = stages.map { stage in
            guard let value = activity[stage] else { return "\(stage.name)=never" }
            return "\(stage.name)=\(value.count), age \(seconds(now - value.last)) s"
        }.joined(separator: "; ")
        if activity[stalled] == nil {
            // Not reached yet: normal while the headset or the game starts.
            log("Session progress: waiting for \(stalled.name) for \(seconds(now - since)) s; \(details)")
        } else {
            log("Session progress stalled: no \(stalled.flowName) for \(seconds(now - since)) s; \(details)")
        }
        lastStalled = stalled
        lastReport = now
    }

    private func baseline(_ stage: Stage) -> UInt64 {
        switch stage {
        case .headsetHandshake, .tracking: headsetStarted
        case .runtimeConnected, .gameFrame, .encodedFrame: runtimeStarted
        case .sentFrame, .headsetStatistics: max(runtimeStarted, headsetStarted)
        }
    }

    private func seconds(_ nanos: UInt64) -> String {
        String(format: "%.1f", Double(nanos) / 1_000_000_000)
    }
}
