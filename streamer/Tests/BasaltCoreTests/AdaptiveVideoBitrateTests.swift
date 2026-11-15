import XCTest
@testable import BasaltCore

final class AdaptiveVideoBitrateTests: XCTestCase {
    func testGameLimitedFrameRateAndPipelineLatencyDoNotReduceBitrate() {
        let simulation = Simulation()
        simulation.run(seconds: 3)
        for fps in [56.8, 38.7, 33.0, 60.0, 45.0] {
            simulation.run(seconds: 5, fps: fps, pipelineLatency: 365_000_000)
        }
        XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testNegotiatedRefreshOnlySetsDecoderQueueBudget() {
        let fast = Simulation(refreshRate: 90)
        fast.run(seconds: 2, fps: 78, decoderQueue: 24_000_000)
        XCTAssertEqual(fast.adjustments.first?.reason, .decoderBacklog)
        XCTAssertEqual(fast.adjustments.first?.bitrate, 64_000_000)

        let slow = Simulation(refreshRate: 72)
        slow.run(seconds: 2, fps: 78, decoderQueue: 24_000_000)
        XCTAssertTrue(slow.adjustments.isEmpty)
    }

    func testExtremeTargetFrameRatesDoNotTrap() {
        // 1e-12 fps is a frame interval of 1e21 ns, beyond UInt64.
        for rate in [1e-12, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
            let simulation = Simulation(refreshRate: rate)
            simulation.run(seconds: 2)
            XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000, "\(rate)")
        }
        // The lowest rate counts as 1 fps: the 40 ms decoder queue that is a
        // backlog at 72 Hz is none against a one-second frame interval.
        let slow = Simulation(refreshRate: 1e-12)
        slow.run(seconds: 3, decoderQueue: 40_000_000)
        XCTAssertTrue(slow.adjustments.isEmpty)
    }

    func testSustainedDecoderBacklogReducesAtFullFrameRate() {
        let simulation = Simulation()
        simulation.run(seconds: 3, decoderQueue: 40_000_000)
        XCTAssertEqual(simulation.adjustments.first?.reason, .decoderBacklog)
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 64_000_000)
    }

    func testBriefDecoderSpikeDoesNotReduce() {
        let simulation = Simulation()
        simulation.run(seconds: 2)
        simulation.run(seconds: 0.5, decoderQueue: 40_000_000)
        simulation.run(seconds: 3)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testNetworkFeedbackDelayGrowthReducesWithoutFrameRateShortfall() {
        let simulation = Simulation()
        simulation.run(seconds: 3)
        simulation.run(seconds: 3, networkDelay: 45_000_000)
        XCTAssertEqual(simulation.adjustments.first?.reason, .networkDelay)
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 64_000_000)
    }

    func testFrameLossRelativeToSentFramesReduces() {
        let simulation = Simulation()
        simulation.run(seconds: 3)
        simulation.run(seconds: 6, dropEvery: 3)
        XCTAssertEqual(simulation.adjustments.first?.reason, .deliveryDeficit)
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 64_000_000)
    }

    func testModerateFeedbackLossWithoutOtherSignsKeepsBitrate() {
        // In heavy scenes the headset may display about 12% fewer frames than
        // were sent while socket writes and feedback delay stay clean.
        let simulation = Simulation()
        simulation.run(seconds: 10, dropEvery: 8)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testSmallFeedbackLossFitsWindowTolerance() {
        let simulation = Simulation()
        simulation.run(seconds: 8, dropEvery: 25)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testRepeatedTrackingTimestampsAreNotPacketLoss() {
        let simulation = Simulation()
        simulation.run(seconds: 8, fps: 45, repeatEvery: 3)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testRepeatedGameTimestampsDoNotPreventRecoveryWithFreshFeedback() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 100, fps: 45, repeatEvery: 3)
        XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
        XCTAssertEqual(simulation.adjustments.count, 20)
        XCTAssertTrue(simulation.adjustments.allSatisfy { $0.reason == .recovery })
    }

    func testOneCongestionEventDoesNotPenalizeAnIDR() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)
        XCTAssertNil(controller.recordTransportCongestion(nowNanoseconds: 0))
        XCTAssertEqual(controller.currentBitrate, 35_000_000)
    }

    func testRepeatedTransportCongestionRespectsCooldownAndFloor() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)
        XCTAssertNil(controller.recordTransportCongestion(nowNanoseconds: 0))
        let first = controller.recordTransportCongestion(nowNanoseconds: 500_000_000)
        XCTAssertEqual(first?.bitrate, 28_000_000)
        XCTAssertEqual(first?.reason, .transportCongestion)
        XCTAssertNil(controller.recordTransportCongestion(nowNanoseconds: 1_000_000_000))
        XCTAssertNil(controller.recordTransportCongestion(nowNanoseconds: 1_500_000_000))
        XCTAssertEqual(controller.recordTransportCongestion(
            nowNanoseconds: 2_500_000_000)?.bitrate, 22_400_000)
        for second in 3...40 {
            _ = controller.recordTransportCongestion(
                nowNanoseconds: UInt64(second) * 1_000_000_000)
        }
        XCTAssertEqual(controller.currentBitrate, controller.minimumBitrate)
    }

    func testCleanGameLimitedStreamRecoversInFixedStepsAndStopsAtConfigured() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        XCTAssertEqual(simulation.controller.currentBitrate, 40_960_000)
        simulation.run(seconds: 12, fps: 45, pipelineLatency: 150_000_000)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 100, fps: 45, pipelineLatency: 150_000_000)
        let changes = simulation.adjustments
        XCTAssertEqual(changes.count, 20)
        XCTAssertTrue(changes.allSatisfy { $0.reason == .recovery })
        XCTAssertEqual(changes.first?.bitrate, 42_960_000)
        for index in 1..<changes.count {
            XCTAssertEqual(changes[index].bitrate,
                           min(80_000_000, changes[index - 1].bitrate + 2_000_000))
            XCTAssertGreaterThanOrEqual(
                simulation.adjustmentTimes[index] - simulation.adjustmentTimes[index - 1],
                4_000_000_000)
        }
        XCTAssertTrue(changes.allSatisfy { $0.bitrate <= 80_000_000 })
        XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
    }

    func testRecoveryUsesAtLeastOneMegabitSteps() {
        let simulation = Simulation(configuredBitrate: 10_000_000)
        _ = simulation.controller.recordTransportCongestion(nowNanoseconds: 0)
        _ = simulation.controller.recordTransportCongestion(nowNanoseconds: 500_000_000)
        simulation.now = 1_000_000_000
        simulation.run(seconds: 30)
        XCTAssertEqual(simulation.adjustments.map(\.bitrate), [9_000_000, 10_000_000])
    }

    func testReconnectRecoversFromTheExistingEncoderTarget() {
        let simulation = Simulation(initialBitrate: 40_960_000)
        XCTAssertEqual(simulation.controller.currentBitrate, 40_960_000)
        simulation.run(seconds: 100)
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 42_960_000)
        XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
        XCTAssertEqual(simulation.adjustments.count, 20)
        XCTAssertTrue(simulation.adjustments.allSatisfy { $0.reason == .recovery })
    }

    func testCongestionDuringRecoveryBacksOffWithoutWaitingForIncreaseCooldown() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 14)
        XCTAssertEqual(simulation.adjustments.map(\.bitrate), [42_960_000])
        XCTAssertNil(simulation.controller.recordTransportCongestion(
            nowNanoseconds: simulation.now))
        let decreased = simulation.controller.recordTransportCongestion(
            nowNanoseconds: simulation.now + 500_000_000)
        XCTAssertEqual(decreased?.bitrate, 34_368_000)
        XCTAssertEqual(decreased?.reason, .transportCongestion)
        simulation.now += 600_000_000
        simulation.adjustments.removeAll()
        simulation.adjustmentTimes.removeAll()
        simulation.run(seconds: 12)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 4)
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 36_368_000)
    }

    func testSinglePressureEventRestartsCleanRecoveryPeriod() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 10)
        XCTAssertNil(simulation.controller.recordTransportCongestion(
            nowNanoseconds: simulation.now))
        simulation.run(seconds: 13)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 2)
        XCTAssertEqual(simulation.adjustments.first?.reason, .recovery)
    }

    func testLatencyHysteresisPreventsBothDecreaseAndPrematureRecovery() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 4)
        // +20 ms is between the +15 ms clean and +25 ms congested thresholds.
        simulation.run(seconds: 30, networkDelay: 26_000_000)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 11)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 3)
        XCTAssertEqual(simulation.adjustments.first?.reason, .recovery)
    }

    func testKeyframeSizedDelayEveryTwoSecondsDoesNotBlockRecovery() {
        // One delivery stall over Wi-Fi lowers the target, and it must still
        // come back. The encoder sends a keyframe every 2 s; its feedback
        // arrives later.
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 60, spikeEvery: 144, spikeDelay: 20_000_000)
        XCTAssertFalse(simulation.adjustments.isEmpty)
        XCTAssertTrue(simulation.adjustments.allSatisfy { $0.reason == .recovery })
    }

    func testOccasionalDecoderQueueSpikeDoesNotBlockRecovery() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 60, spikeEvery: 144, spikeDecoderQueue: 20_000_000)
        XCTAssertFalse(simulation.adjustments.isEmpty)
        XCTAssertTrue(simulation.adjustments.allSatisfy { $0.reason == .recovery })
    }

    func testMostlyDelayedFeedbackStillHoldsTheTarget() {
        // Half of the frames +20 ms late: no longer an outlier, so the
        // hysteresis band keeps holding, as before.
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 4)
        simulation.run(seconds: 60, spikeEvery: 2, spikeDelay: 20_000_000)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testHoldReportSaysWhyTheTargetStaysLowAtMostEveryTenSeconds() {
        let full = Simulation()
        full.run(seconds: 30)
        XCTAssertNil(full.controller.takeHoldReport(nowNanoseconds: full.now))

        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 4)
        simulation.run(seconds: 10, spikeEvery: 2, spikeDelay: 20_000_000)
        let held = try? XCTUnwrap(simulation.controller.takeHoldReport(
            nowNanoseconds: simulation.now))
        XCTAssertEqual(held, "Wi-Fi bitrate held at 41.0 of 80.0 Mbps: "
                       + "feedback delay 26 ms for most frames, baseline 6 ms")
        XCTAssertNil(simulation.controller.takeHoldReport(nowNanoseconds: simulation.now + 9_000_000_000))

        simulation.run(seconds: 10)
        let clean = simulation.controller.takeHoldReport(nowNanoseconds: simulation.now)
        XCTAssertEqual(clean?.contains("clean for"), true, clean ?? "")
    }

    func testStatisticsGapCannotCountAsSustainedHealth() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 10)
        simulation.now += 20_000_000_000
        simulation.run(seconds: 10)
        XCTAssertTrue(simulation.adjustments.isEmpty)
        simulation.run(seconds: 4)
        XCTAssertEqual(simulation.adjustments.first?.reason, .recovery)
    }

    func testFramesSentWhileHeadsetIsSilentAreNotCountedAsLoss() {
        let simulation = Simulation()
        simulation.run(seconds: 4)
        simulation.run(seconds: 6, dropEvery: 1)
        simulation.run(seconds: 4)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testFramesSentBeforeTheFirstHeadsetReportAreNotCountedAsLoss() {
        let simulation = Simulation()
        simulation.run(seconds: 4, dropEvery: 1)
        simulation.run(seconds: 4)
        XCTAssertTrue(simulation.adjustments.isEmpty)
    }

    func testImplausibleLatencyAndComponentsAreIgnoredWithoutOverflow() {
        let simulation = Simulation()
        simulation.run(seconds: 3)
        for value in [UInt64.max,
                      AdaptiveVideoBitrateController.maximumPlausibleLatencyNanoseconds + 1] {
            XCTAssertNil(simulation.controller.recordClientStatistics(
                statistics(latency: value), nowNanoseconds: simulation.now))
            XCTAssertNil(simulation.controller.recordClientStatistics(
                statistics(decoderQueue: value), nowNanoseconds: simulation.now))
        }
        simulation.run(seconds: 3, networkDelay: 45_000_000)
        XCTAssertEqual(simulation.adjustments.first?.reason, .networkDelay)
    }

    func testUnmatchedFeedbackCannotRecoverOrPoisonNetworkBaseline() {
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        for second in 5...30 {
            XCTAssertNil(simulation.controller.recordClientStatistics(
                statistics(), nowNanoseconds: UInt64(second) * 1_000_000_000))
        }
        simulation.now = 31_000_000_000
        simulation.run(seconds: 14)
        XCTAssertEqual(simulation.adjustments.first?.reason, .recovery)
    }

    func testSessionPatternKeepsQualityAndRecoversAnAlreadyReducedTarget() {
        // A synthetic session: healthy startup, CPU-heavy scenes with large
        // tracking-to-display latency, then steady 71-72 fps. Send and receive
        // cadence agree; decoder queue and post-send feedback stay small.
        let full = Simulation()
        let reduced = Simulation()
        reduced.backOffToSessionBitrate()
        for simulation in [full, reduced] {
            simulation.run(seconds: 3, pipelineLatency: 60_000_000)
            for fps in [57.0, 42.0, 53.0, 38.7, 33.0, 56.8] {
                simulation.run(seconds: 10, fps: fps, pipelineLatency: 100_000_000)
                simulation.run(seconds: 0.3, fps: fps, pipelineLatency: 365_000_000)
            }
            simulation.run(seconds: 120, fps: 71.8, pipelineLatency: 80_000_000)
            XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
        }
        XCTAssertTrue(full.adjustments.isEmpty)
        XCTAssertEqual(reduced.adjustments.count, 20)
        XCTAssertTrue(reduced.adjustments.allSatisfy { $0.reason == .recovery })
    }

    func testDecisionsUnchangedFarPastThePendingFrameCap() {
        // The headset skips every eighth frame, as in heavy scenes. About
        // 1,080 of the frames sent in 120 s are never matched, so the pending
        // set reaches its 512-frame cap after about 57 s and every later send
        // evicts one. Recovery, loss and delay decisions stay unchanged.
        let simulation = Simulation()
        simulation.backOffToSessionBitrate()
        simulation.run(seconds: 120, dropEvery: 8)
        XCTAssertEqual(simulation.adjustments.count, 20)
        XCTAssertTrue(simulation.adjustments.allSatisfy { $0.reason == .recovery })
        XCTAssertEqual(simulation.adjustments.first?.bitrate, 42_960_000)
        XCTAssertEqual(simulation.controller.currentBitrate, 80_000_000)
        simulation.adjustments.removeAll()
        simulation.adjustmentTimes.removeAll()
        simulation.run(seconds: 4, dropEvery: 3)
        simulation.run(seconds: 6, dropEvery: 8)
        simulation.run(seconds: 3, networkDelay: 45_000_000, dropEvery: 8)
        XCTAssertEqual(simulation.adjustments.map(\.reason),
                       [.deliveryDeficit, .networkDelay])
        XCTAssertEqual(simulation.adjustments.map(\.bitrate), [64_000_000, 51_200_000])
    }

    func testPendingCapEvictsTheEarliestSentFrames() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 80_000_000, targetFramesPerSecond: 72)
        let millisecond: UInt64 = 1_000_000
        // A first report opens the delivery window, so the sends below count.
        XCTAssertNil(controller.recordClientStatistics(statistics(), nowNanoseconds: 0))
        // 600 sends in 0.6 s: the 512-frame cap keeps 89...600.
        for timestamp: UInt64 in 1...600 {
            controller.recordFrameSent(frame(timestamp),
                                       nowNanoseconds: timestamp * millisecond)
        }
        // Feedback 1 s after each send of 1...450: only 89...450 still match.
        for timestamp: UInt64 in 1...450 {
            XCTAssertNil(controller.recordClientStatistics(
                statistics(target: timestamp),
                nowNanoseconds: (1_000 + timestamp) * millisecond))
        }
        // 362 matched + 150 tolerated < 600 sent. Keeping 1...88 instead
        // (450 matched) would not be a deficit.
        XCTAssertNil(controller.recordClientStatistics(
            statistics(), nowNanoseconds: 2_000 * millisecond))
        let adjustment = controller.recordClientStatistics(
            statistics(), nowNanoseconds: 3_000 * millisecond)
        XCTAssertEqual(adjustment?.reason, .deliveryDeficit)
        XCTAssertEqual(adjustment?.bitrate, 64_000_000)
    }

    func testFeedbackOlderThanTheWindowIsNotMatched() {
        // Simulated feedback arrives 15 ms of client work plus the network
        // delay after its send. The window allows exactly 2 s.
        let onTime = Simulation()
        onTime.run(seconds: 8, networkDelay: 1_985_000_000)
        XCTAssertTrue(onTime.adjustments.isEmpty)

        let late = Simulation()
        late.run(seconds: 8, networkDelay: 1_985_000_001)
        XCTAssertEqual(late.adjustments.first?.reason, .deliveryDeficit)
        XCTAssertEqual(late.adjustments.first?.bitrate, 64_000_000)
    }

    private func statistics(target: UInt64 = 1, latency: UInt64 = 100_000_000,
                            decoderQueue: UInt64 = 2_000_000) -> AlvrClientStatistics {
        AlvrClientStatistics(
            targetTimestampNanoseconds: target, frameIntervalNanoseconds: 13_888_889,
            videoDecodeNanoseconds: 10_000_000, videoDecoderQueueNanoseconds: decoderQueue,
            renderingNanoseconds: 3_000_000, vsyncQueueNanoseconds: 30_000_000,
            totalPipelineLatencyNanoseconds: latency)
    }

    private func frame(_ timestamp: UInt64) -> AlvrVideoSendReport {
        AlvrVideoSendReport(
            timestampNanoseconds: timestamp,
            accessUnitBytes: 100_000, wireBytes: 102_000, shardCount: 80,
            isIDR: false, durationNanoseconds: 500_000)
    }

    /// Virtual clock with interleaved sends and delayed per-frame feedback.
    /// No sockets, sleeps, encoder, game or headset are involved.
    private final class Simulation {
        let controller: AdaptiveVideoBitrateController
        var now: UInt64 = 0
        var adjustments: [AdaptiveVideoBitrateController.Adjustment] = []
        var adjustmentTimes: [UInt64] = []
        private var frameIndex = 0
        private var lastTimestamp: UInt64 = 0
        private var pending: [(at: UInt64, statistics: AlvrClientStatistics)] = []

        init(configuredBitrate: Int = 80_000_000, refreshRate: Double = 72,
             initialBitrate: Int? = nil) {
            controller = AdaptiveVideoBitrateController(
                configuredBitrate: configuredBitrate, targetFramesPerSecond: refreshRate,
                initialBitrate: initialBitrate)
        }

        func backOffToSessionBitrate() {
            for second: UInt64 in [0, 2, 4] {
                _ = controller.recordTransportCongestion(
                    nowNanoseconds: second * 1_000_000_000)
                _ = controller.recordTransportCongestion(
                    nowNanoseconds: second * 1_000_000_000 + 500_000_000)
            }
            now = 5_000_000_000
        }

        func run(seconds: Double, fps: Double = 72,
                 pipelineLatency: UInt64 = 100_000_000,
                 decoderQueue: UInt64 = 2_000_000,
                 networkDelay: UInt64 = 6_000_000,
                 dropEvery: Int? = nil, repeatEvery: Int? = nil,
                 spikeEvery: Int? = nil, spikeDelay: UInt64 = 0,
                 spikeDecoderQueue: UInt64? = nil) {
            let end = now + UInt64(seconds * 1_000_000_000)
            let interval = UInt64(1_000_000_000 / fps)
            var sendAt = now
            while sendAt < end {
                receive(through: sendAt)
                frameIndex += 1
                if repeatEvery.map({ frameIndex % $0 != 0 }) ?? true {
                    lastTimestamp += 1
                }
                controller.recordFrameSent(AlvrVideoSendReport(
                    timestampNanoseconds: lastTimestamp,
                    accessUnitBytes: 100_000, wireBytes: 102_000, shardCount: 80,
                    isIDR: false, durationNanoseconds: 500_000), nowNanoseconds: sendAt)
                if dropEvery.map({ frameIndex % $0 != 0 }) ?? true {
                    // One frame in `spikeEvery`, like a keyframe, arrives late
                    // or waits longer in the headset's decoder queue.
                    let spike = spikeEvery.map { frameIndex % $0 == 0 } ?? false
                    let queue = spike ? spikeDecoderQueue ?? decoderQueue : decoderQueue
                    let statistics = AlvrClientStatistics(
                        targetTimestampNanoseconds: lastTimestamp,
                        frameIntervalNanoseconds: interval,
                        videoDecodeNanoseconds: 10_000_000,
                        videoDecoderQueueNanoseconds: queue,
                        renderingNanoseconds: 3_000_000,
                        vsyncQueueNanoseconds: 30_000_000,
                        totalPipelineLatencyNanoseconds: pipelineLatency)
                    pending.append((sendAt + 10_000_000 + queue + 3_000_000
                                    + networkDelay + (spike ? spikeDelay : 0), statistics))
                    pending.sort { $0.at < $1.at }
                }
                sendAt += interval
            }
            receive(through: end)
            now = end
        }

        private func receive(through time: UInt64) {
            while let event = pending.first, event.at <= time {
                pending.removeFirst()
                if let adjustment = controller.recordClientStatistics(
                    event.statistics, nowNanoseconds: event.at) {
                    adjustments.append(adjustment)
                    adjustmentTimes.append(event.at)
                }
            }
        }
    }
}
