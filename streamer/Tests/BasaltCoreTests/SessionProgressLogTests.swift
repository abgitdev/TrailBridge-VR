import XCTest
@testable import BasaltCore

final class SessionProgressLogTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        var now: UInt64 = 0
        var lines: [String] = []
        func makeLog(runtimeMode: Bool = true) -> SessionProgressLog {
            SessionProgressLog(runtimeMode: runtimeMode, clock: { self.now }, log: { self.lines.append($0) })
        }
    }

    func testNoCallbacksStillReportsMissingHandshakeAndDuration() {
        let fixture = Fixture(), progress = fixture.makeLog()
        fixture.now = 5_000_000_000
        progress.check()
        XCTAssertEqual(fixture.lines.count, 1)
        XCTAssertTrue(fixture.lines[0].contains("waiting for headset handshake (StreamReady) for 5.0 s"))
        // A stage that was never reached is ordinary waiting, not a stall.
        XCTAssertFalse(fixture.lines[0].contains("stalled"))
        XCTAssertTrue(fixture.lines[0].contains("first frame from the game=never"))
        fixture.now = 10_000_000_000
        progress.check()
        XCTAssertEqual(fixture.lines.count, 1)
        fixture.now = 20_000_000_000
        progress.check()
        XCTAssertEqual(fixture.lines.count, 2)
    }

    func testEveryMissingStageIsDistinguishable() {
        for missing in SessionProgressLog.Stage.allCases {
            let fixture = Fixture(), progress = fixture.makeLog()
            for stage in SessionProgressLog.Stage.allCases where stage != missing {
                progress.record(stage)
            }
            fixture.now = 6_000_000_000
            // Keep recurring stages fresh so only the missing stage stalls.
            for stage in SessionProgressLog.Stage.allCases where stage != missing {
                progress.record(stage)
            }
            progress.check()
            XCTAssertTrue(fixture.lines.last?.contains("waiting for \(missing.name) for 6.0 s") == true)
        }
    }

    func testFlowStallAndRecoveryWithoutPerFrameLogSpam() {
        let fixture = Fixture(), progress = fixture.makeLog()
        for _ in 0..<100 {
            for stage in SessionProgressLog.Stage.allCases { progress.record(stage) }
        }
        XCTAssertEqual(fixture.lines.count, SessionProgressLog.Stage.allCases.count)
        fixture.now = 7_000_000_000
        progress.record(.tracking)
        progress.check()
        XCTAssertTrue(fixture.lines.last?.contains("stalled: no frames from the game for 7.0 s") == true)
        for stage in SessionProgressLog.Stage.allCases { progress.record(stage) }
        progress.check()
        XCTAssertTrue(fixture.lines.last?.contains("flow resumed") == true)
    }

    func testReconnectRejectsOldSenderCallbacksAndKeepsGameProgress() {
        let fixture = Fixture(), progress = fixture.makeLog()
        let old = progress.beginHeadsetAttempt()
        for stage in SessionProgressLog.Stage.allCases { progress.record(stage) }
        fixture.now = 1_000_000_000
        let current = progress.beginHeadsetAttempt()
        XCTAssertNotEqual(old, current)
        progress.record(.headsetHandshake, attempt: old)
        fixture.now = 7_000_000_000
        progress.check()
        XCTAssertTrue(fixture.lines.last?.contains("headset handshake (StreamReady)=never") == true)
        XCTAssertTrue(fixture.lines.last?.contains("runtime connected=1") == true)
        progress.record(.headsetHandshake, attempt: current)
        progress.runtimeConnected()
        progress.check()
        XCTAssertTrue(fixture.lines.last?.contains("first frame from the game=never") == true)
    }

    func testFailedAttemptsKeepTheOutageStartAndStayQuiet() {
        let fixture = Fixture(), progress = fixture.makeLog()
        let first = progress.beginHeadsetAttempt()
        for stage in SessionProgressLog.Stage.allCases { progress.record(stage, attempt: first) }
        let before = fixture.lines.count
        // The cable is pulled: one attempt a second, none reaches a handshake.
        for second in 1...12 {
            fixture.now = UInt64(second) * 1_000_000_000
            progress.record(.gameFrame)
            progress.record(.encodedFrame)
            progress.beginHeadsetAttempt()
        }
        // Only the first attempt of the outage is announced.
        XCTAssertEqual(fixture.lines.count - before, 1)
        progress.check()
        // The report names the headset and counts from the start of the outage.
        XCTAssertTrue(fixture.lines.last?.contains("waiting for headset handshake (StreamReady) for 11.0 s") == true)
        // The next report waits for the usual 15 s, not for the next attempt.
        fixture.now = 14_000_000_000
        progress.beginHeadsetAttempt()
        progress.record(.gameFrame)
        progress.record(.encodedFrame)
        let reports = fixture.lines.count
        progress.check()
        XCTAssertEqual(fixture.lines.count, reports)
    }

    func testDesktopSourceDoesNotWaitForRuntime() {
        let fixture = Fixture(), progress = fixture.makeLog(runtimeMode: false)
        fixture.now = 6_000_000_000
        for stage: SessionProgressLog.Stage in [.headsetHandshake, .tracking, .encodedFrame, .sentFrame, .headsetStatistics] {
            progress.record(stage)
        }
        progress.check()
        XCTAssertFalse(fixture.lines.contains { $0.contains("stalled") })
    }
}
