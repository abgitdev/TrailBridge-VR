import Foundation

/// Adapts Wi-Fi quality to transport pressure, delivery and decoder feedback.
/// Game cadence and tracking-to-display latency include server render time;
/// neither is evidence of network congestion, even below the headset refresh.
public final class AdaptiveVideoBitrateController: @unchecked Sendable {
    public struct Adjustment: Equatable, Sendable {
        public enum Reason: String, Sendable {
            case transportCongestion = "decrease: send congestion"
            case deliveryDeficit = "decrease: frame delivery deficit"
            case networkDelay = "decrease: network feedback delay"
            case decoderBacklog = "decrease: decoder queue"
            case recovery = "recovery: sustained clean feedback"
        }

        public let bitrate: Int
        public let reason: Reason
    }

    private static let decreaseCooldownNanoseconds: UInt64 = 2_000_000_000
    private static let unhealthyDurationNanoseconds: UInt64 = 1_000_000_000
    private static let healthyRecoveryNanoseconds: UInt64 = 12_000_000_000
    private static let recoveryStepNanoseconds: UInt64 = 4_000_000_000
    private static let congestionWindowNanoseconds: UInt64 = 2_000_000_000
    private static let feedbackWindowNanoseconds: UInt64 = 2_000_000_000
    /// Recovery needs typical feedback within this margin of the baseline.
    private static let cleanDelayMarginNanoseconds: UInt64 = 15_000_000
    /// A feedback window judges recovery by this share of its frames, so a
    /// keyframe or a single queued frame cannot restart the clean period.
    private static let cleanPercentile = 0.75
    private static let minimumWindowFeedback = 5
    private static let holdReportIntervalNanoseconds: UInt64 = 10_000_000_000
    private static let maximumPendingFrames = 512
    /// Statistics come from the headset. Reject corrupt samples before doing
    /// latency arithmetic, including components used to estimate transit time.
    static let maximumPlausibleLatencyNanoseconds: UInt64 = 10_000_000_000

    public let configuredBitrate: Int
    public let minimumBitrate: Int

    private let targetFrameIntervalNanoseconds: UInt64
    private let recoveryStep: Int
    private let lock = NSLock()
    private var bitrate: Int
    private var baselineFeedbackNanoseconds: UInt64?
    private struct PendingFrame {
        let sentAt: UInt64
        var ambiguous = false
    }
    private var pendingFrames: [UInt64: PendingFrame] = [:]
    /// Keys of `pendingFrames` in send order, starting at `pendingOrderStart`.
    /// Keys that feedback already matched stay behind until they reach the
    /// front or the next rebuild, so each send costs amortised O(1).
    private var pendingOrder: [UInt64] = []
    private var pendingOrderStart = 0
    private var lastSentTimestamp: UInt64?
    private var feedbackWindowStart: UInt64?
    private var sentFrames = 0
    private var receivedFrames = 0
    private var deliveryDeficit = false
    private var lastStatistics: UInt64?
    private var unhealthySince: UInt64?
    private var healthySince: UInt64?
    private var lastDecrease: UInt64?
    private var lastIncrease: UInt64?
    private var lastCongestion: UInt64?
    private var congestionCount = 0
    /// Matched feedback delays and decoder queues of the open feedback window.
    private var windowDelays: [UInt64] = []
    private var windowDecoderQueues: [UInt64] = []
    /// A congestion event or a decrease happened in the open window.
    private var windowPressure = false
    /// Why the last closed window was not clean; nil when it was.
    private var holdReason: String?
    private var closedWindowBelowTarget = false
    private var lastHoldReport: UInt64?

    public init(configuredBitrate: Int, targetFramesPerSecond: Double,
                minimumBitrate: Int? = nil, initialBitrate: Int? = nil) {
        precondition(configuredBitrate > 0)
        precondition(targetFramesPerSecond.isFinite && targetFramesPerSecond > 0)
        precondition(minimumBitrate.map { $0 > 0 } ?? true)
        precondition(initialBitrate.map { $0 > 0 } ?? true)
        self.configuredBitrate = configuredBitrate
        self.minimumBitrate = min(
            configuredBitrate,
            minimumBitrate ?? max(8_000_000, configuredBitrate / 3))
        // Fixed additive steps: 2 Mbps at 80 Mbps, at least 1 Mbps otherwise.
        recoveryStep = max(1_000_000, configuredBitrate / 40)
        // A reconnect creates fresh feedback state but reuses the encoder.
        bitrate = min(configuredBitrate,
                      max(self.minimumBitrate, initialBitrate ?? configuredBitrate))
        // The rate is negotiated with the headset. Kept within 1...1000 fps,
        // the interval always fits and can be doubled without overflow.
        targetFrameIntervalNanoseconds =
            UInt64(1_000_000_000 / min(max(targetFramesPerSecond, 1), 1_000))
    }

    public var currentBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        return bitrate
    }

    /// Match client feedback to completed sends using the Quest target clock,
    /// but measure elapsed time entirely on the host's monotonic clock. This
    /// excludes game rendering and encoding before the send. Reused tracking
    /// timestamps cannot be matched reliably and must not count as packet loss.
    public func recordFrameSent(
        _ report: AlvrVideoSendReport,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = report.timestampNanoseconds
        if let lastSentTimestamp, timestamp <= lastSentTimestamp {
            pendingFrames[timestamp]?.ambiguous = true
            return
        }
        lastSentTimestamp = timestamp
        if feedbackWindowStart == nil { feedbackWindowStart = nowNanoseconds }
        sentFrames += 1
        if pendingFrames.count >= Self.maximumPendingFrames {
            evictEarliestPendingFrame()
        }
        pendingFrames[timestamp] = PendingFrame(sentAt: nowNanoseconds)
        pendingOrder.append(timestamp)
        if pendingOrder.count >= Self.maximumPendingFrames * 4 {
            // At most 512 keys are still pending, so a rebuild drops at least
            // 1,536 spent ones and the next rebuild is 1,536 sends away.
            pendingOrder = pendingOrder[pendingOrderStart...].filter {
                pendingFrames[$0] != nil
            }
            pendingOrderStart = 0
        }
    }

    /// Removes the earliest-sent pending frame, which is also the one with the
    /// smallest `sentAt`: timestamps enter in strictly increasing order
    /// (`recordFrameSent` ignores any other), so a key never returns once it
    /// leaves `pendingFrames`, and sends are reported one at a time on the
    /// monotonic host clock. At up to 120 fps the evicted frame was sent at
    /// least 512 sends, over 4 s, ago, beyond the 2 s feedback window, so
    /// feedback could not have matched it anyway.
    private func evictEarliestPendingFrame() {
        while pendingOrderStart < pendingOrder.count {
            let timestamp = pendingOrder[pendingOrderStart]
            pendingOrderStart += 1
            if pendingFrames.removeValue(forKey: timestamp) != nil { return }
        }
    }

    /// Two nearby socket-pressure events distinguish sustained congestion
    /// from one large IDR. Every event interrupts the clean recovery period.
    public func recordTransportCongestion(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Adjustment? {
        lock.lock()
        defer { lock.unlock() }
        healthySince = nil
        windowPressure = true
        if let lastCongestion,
           nowNanoseconds >= lastCongestion,
           nowNanoseconds - lastCongestion <= Self.congestionWindowNanoseconds {
            congestionCount += 1
        } else {
            congestionCount = 1
        }
        lastCongestion = nowNanoseconds
        guard congestionCount >= 2 else { return nil }
        return reduceBitrate(at: nowNanoseconds, reason: .transportCongestion)
    }

    public func recordClientStatistics(
        _ statistics: AlvrClientStatistics,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Adjustment? {
        lock.lock()
        defer { lock.unlock() }
        guard statistics.frameIntervalNanoseconds > 0,
              statistics.totalPipelineLatencyNanoseconds > 0,
              [statistics.totalPipelineLatencyNanoseconds,
               statistics.videoDecodeNanoseconds,
               statistics.videoDecoderQueueNanoseconds,
               statistics.renderingNanoseconds,
               statistics.vsyncQueueNanoseconds].allSatisfy({
                  $0 <= Self.maximumPlausibleLatencyNanoseconds
              }) else {
            healthySince = nil
            unhealthySince = nil
            return nil
        }
        if let lastStatistics, nowNanoseconds < lastStatistics { return nil }
        // Waiting for the headset's first report counts as silence too.
        if lastStatistics.map({ nowNanoseconds - $0 > Self.feedbackWindowNanoseconds }) ?? true {
            // Silence is neither sustained health nor sustained trouble, and
            // frames sent meanwhile say nothing about delivery either.
            healthySince = nil
            unhealthySince = nil
            sentFrames = 0
            receivedFrames = 0
            deliveryDeficit = false
            windowDelays.removeAll(keepingCapacity: true)
            windowDecoderQueues.removeAll(keepingCapacity: true)
            windowPressure = false
            feedbackWindowStart = nowNanoseconds
        }
        lastStatistics = nowNanoseconds

        var feedbackDelay: UInt64?
        if let frame = pendingFrames.removeValue(
            forKey: statistics.targetTimestampNanoseconds),
           nowNanoseconds >= frame.sentAt,
           nowNanoseconds - frame.sentAt <= Self.feedbackWindowNanoseconds {
            receivedFrames += 1
            let elapsed = nowNanoseconds - frame.sentAt
            let clientWork = statistics.videoDecodeNanoseconds
                + statistics.videoDecoderQueueNanoseconds
                + statistics.renderingNanoseconds
            // This is a round-trip feedback proxy, not a one-way network
            // measurement. Remove measured client work; vsync queue is a
            // prediction after submission, not elapsed time before feedback.
            if !frame.ambiguous, elapsed >= clientWork {
                let delay = elapsed - clientWork
                feedbackDelay = delay
                windowDelays.append(delay)
                baselineFeedbackNanoseconds = min(
                    baselineFeedbackNanoseconds ?? delay, delay)
            }
        }
        windowDecoderQueues.append(statistics.videoDecoderQueueNanoseconds)
        if let start = feedbackWindowStart,
           nowNanoseconds >= start,
           nowNanoseconds - start >= Self.feedbackWindowNanoseconds {
            // Allow in-flight frames, window skew and frames the headset skips
            // itself: in heavy scenes the headset may display about 12% fewer
            // frames than were sent while socket writes and feedback delay stay
            // clean. Network trouble that stays below this limit still shows up
            // as delay or send pressure.
            // Counts are unique frame targets, not refresh-rate expectations.
            deliveryDeficit = sentFrames >= 10
                && receivedFrames + max(3, sentFrames / 4) < sentFrames
            closeHealthWindow(startedAt: start, sent: sentFrames, received: receivedFrames)
            sentFrames = 0
            receivedFrames = 0
            feedbackWindowStart = nowNanoseconds
        }

        let decoderBacklog = statistics.videoDecoderQueueNanoseconds
            > targetFrameIntervalNanoseconds * 2
        let delayGrowth = feedbackDelay.map {
            $0 > (baselineFeedbackNanoseconds ?? $0) + 25_000_000
        } ?? false
        let reason: Adjustment.Reason? = decoderBacklog ? .decoderBacklog
            : deliveryDeficit ? .deliveryDeficit
            : delayGrowth ? .networkDelay : nil
        // One late keyframe or a single queued frame must not reduce the
        // target; it takes a full second of unhealthy feedback.
        if let reason {
            if unhealthySince == nil { unhealthySince = nowNanoseconds }
            if let unhealthySince,
               nowNanoseconds - unhealthySince >= Self.unhealthyDurationNanoseconds {
                return reduceBitrate(at: nowNanoseconds, reason: reason)
            }
            return nil
        }
        unhealthySince = nil

        // Recovery is judged by whole feedback windows (`closeHealthWindow`),
        // so one late keyframe or queued frame no longer restarts the clean
        // period. A window still open can only extend health already proven.
        guard bitrate < configuredBitrate, let healthySince,
              nowNanoseconds >= healthySince,
              nowNanoseconds - healthySince >= Self.healthyRecoveryNanoseconds,
              lastIncrease.map({ nowNanoseconds - $0 >= Self.recoveryStepNanoseconds })
                ?? true else { return nil }
        // Subtract first so even an extreme configured bitrate cannot overflow.
        bitrate += min(recoveryStep, configuredBitrate - bitrate)
        lastIncrease = nowNanoseconds
        return Adjustment(bitrate: bitrate, reason: .recovery)
    }

    private func reduceBitrate(at nowNanoseconds: UInt64,
                              reason: Adjustment.Reason) -> Adjustment? {
        if let lastDecrease,
           nowNanoseconds < lastDecrease
            || nowNanoseconds - lastDecrease < Self.decreaseCooldownNanoseconds {
            return nil
        }
        let reduced = max(minimumBitrate, bitrate - bitrate / 5)
        guard reduced < bitrate else { return nil }
        bitrate = reduced
        lastDecrease = nowNanoseconds
        lastIncrease = nil
        healthySince = nil
        unhealthySince = nil
        windowPressure = true
        congestionCount = 0
        return Adjustment(bitrate: bitrate, reason: reason)
    }

    /// Judges one feedback window for recovery. Clean means no send pressure
    /// or decrease, no delivery deficit, enough matched feedback, and three
    /// quarters of its frames close to the delay baseline and decoded within
    /// one frame interval. A clean window starts or extends the healthy
    /// period, which never begins within the congestion window of an event.
    private func closeHealthWindow(startedAt start: UInt64, sent: Int, received: Int) {
        defer {
            windowDelays.removeAll(keepingCapacity: true)
            windowDecoderQueues.removeAll(keepingCapacity: true)
            windowPressure = false
        }
        closedWindowBelowTarget = bitrate < configuredBitrate
        let delay = Self.percentile(windowDelays, Self.cleanPercentile)
        let queue = Self.percentile(windowDecoderQueues, Self.cleanPercentile) ?? 0
        let baseline = baselineFeedbackNanoseconds ?? 0
        let reason: String?
        if windowPressure {
            reason = "send congestion or a decrease"
        } else if deliveryDeficit {
            reason = "frame delivery deficit, \(received) of \(sent) frames confirmed"
        } else if windowDelays.count < Self.minimumWindowFeedback {
            reason = "too little matched headset feedback (\(windowDelays.count) frames)"
        } else if let delay, delay > baseline + Self.cleanDelayMarginNanoseconds {
            reason = String(format: "feedback delay %.0f ms for most frames, baseline %.0f ms",
                            Double(delay) / 1e6, Double(baseline) / 1e6)
        } else if queue > targetFrameIntervalNanoseconds {
            reason = String(format: "decoder queue %.0f ms for most frames", Double(queue) / 1e6)
        } else {
            reason = nil
        }
        holdReason = reason
        guard reason == nil else {
            healthySince = nil
            return
        }
        if healthySince == nil {
            let quietFrom = lastCongestion.map { $0 + Self.congestionWindowNanoseconds } ?? 0
            healthySince = max(start, quietFrom)
        }
    }

    private static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    /// While the target is below the configured bitrate, at most one line
    /// every 10 s saying why it is held, for the session log.
    public func takeHoldReport(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard bitrate < configuredBitrate, closedWindowBelowTarget,
              lastHoldReport.map({ nowNanoseconds >= $0
                  && nowNanoseconds - $0 >= Self.holdReportIntervalNanoseconds }) ?? true
        else { return nil }
        lastHoldReport = nowNanoseconds
        let state: String
        if let holdReason {
            state = holdReason
        } else if let healthySince, nowNanoseconds >= healthySince {
            state = "clean for \((nowNanoseconds - healthySince) / 1_000_000_000) s of "
                + "\(Self.healthyRecoveryNanoseconds / 1_000_000_000)"
        } else {
            state = "waiting for clean feedback"
        }
        return String(format: "Wi-Fi bitrate held at %.1f of %.1f Mbps: ",
                      Double(bitrate) / 1e6, Double(configuredBitrate) / 1e6) + state
    }
}
