import XCTest
@testable import BasaltCore

final class HeadsetReconnectControllerTests: XCTestCase {
    private actor Fixture {
        var attempts = 0
        var preparations = 0
        var preparationFailures = 0
        var failures = 0
        var sleeps = 0
        var closes = 0
        var requestedRates = [Float]()
        var disconnect: (@Sendable () -> Void)?
        var holdConnection = false
        var connectGate: CheckedContinuation<Void, Never>?

        func failNext(_ count: Int) { failures = count }
        func failPreparation(_ count: Int) { preparationFailures = count }
        func prepare() throws {
            preparations += 1
            if preparationFailures > 0 {
                preparationFailures -= 1
                throw BasaltError("forward unavailable")
            }
        }
        func drop() { disconnect?() }
        func closed() { closes += 1 }
        func hold() { holdConnection = true }
        func release() { connectGate?.resume(); connectGate = nil }
        func connect(_ endpoint: HeadsetReconnectController.Endpoint, rate: Float,
                     reconnect: Bool, disconnect: @escaping @Sendable () -> Void) async throws
            -> HeadsetReconnectController.Connection {
            attempts += 1
            requestedRates.append(rate)
            if failures > 0 {
                failures -= 1
                throw AlvrTrackingTimeoutError()
            }
            self.disconnect = disconnect
            if holdConnection { await withCheckedContinuation { connectGate = $0 } }
            return .init(refreshRate: 90) { Task { await self.closed() } }
        }
        func backoff(block: Bool) async throws {
            sleeps += 1
            if block { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String]()
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testRepeatedIdenticalFailuresAreLoggedOnce() async {
        let lines = Lines()
        let controller = HeadsetReconnectController(wired: true, refreshRate: 72, connect: { _, _, _, _ in
            throw BasaltError("adb forward: device [serial] not found")
        }, sleep: {}, log: { lines.append($0) })
        // The bounded startup path makes ten attempts with the same failure.
        do {
            try await controller.connectInitially(.init(host: "127.0.0.1"))
            XCTFail("expected the startup attempts to fail")
        } catch {}
        XCTAssertEqual(lines.snapshot, ["ALVR handshake failed: adb forward: device [serial] not found"])
    }

    func testSerialIsRedactedFromADBErrors() {
        XCTAssertEqual(
            AlvrWiredConnection.redactingSerial(
                in: "adb command failed: adb: device 'TESTQUEST00042' not found",
                arguments: ["-s", "TESTQUEST00042", "forward", "tcp:9943", "tcp:9943"]),
            "adb command failed: adb: device '[serial]' not found")
        XCTAssertEqual(
            AlvrWiredConnection.redactingSerial(in: "no devices", arguments: ["devices"]), "no devices")
    }

    private func controller(_ fixture: Fixture, wired: Bool = true,
                            blockingBackoff: Bool = false) -> HeadsetReconnectController {
        HeadsetReconnectController(wired: wired, refreshRate: 85,
                                  prepareWiredAttempt: { try await fixture.prepare() }, connect: {
            try await fixture.connect($0, rate: $1, reconnect: $2, disconnect: $3)
        }, sleep: { try await fixture.backoff(block: blockingBackoff) }, log: { _ in })
    }

    private func eventually(_ condition: () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Reconnect condition did not arrive", file: file, line: line)
    }

    func testDisconnectRetriesUntilSuccessAndRetainsNegotiatedRate() async throws {
        let fixture = Fixture(), endpoint = HeadsetReconnectController.Endpoint(host: "127.0.0.1")
        let controller = controller(fixture)
        try await controller.connectInitially(endpoint)
        await fixture.failNext(2)
        await fixture.drop()
        try await eventually {
            let attempts = await fixture.attempts
            let state = await controller.state
            return attempts == 4 && state == .connected
        }
        let rates = await fixture.requestedRates
        XCTAssertEqual(rates, [85, 90, 90, 90])
        let sleeps = await fixture.sleeps
        XCTAssertEqual(sleeps, 2)
        let preparations = await fixture.preparations
        XCTAssertEqual(preparations, 4)
        await controller.shutdown()
    }

    func testTrackingTimeoutIsRetried() async throws {
        let fixture = Fixture()
        await fixture.failNext(1)
        let controller = controller(fixture)
        try await controller.connectInitially(.init(host: "127.0.0.1"))
        let attempts = await fixture.attempts
        XCTAssertEqual(attempts, 2)
        let preparations = await fixture.preparations
        XCTAssertEqual(preparations, 2)
        await controller.shutdown()
    }

    func testFailedForwardRestorationRetriesBeforeOpeningHeadsetSocket() async throws {
        let fixture = Fixture()
        await fixture.failPreparation(1)
        let controller = controller(fixture)
        try await controller.connectInitially(.init(host: "127.0.0.1"))
        let preparations = await fixture.preparations
        let attempts = await fixture.attempts
        let sleeps = await fixture.sleeps
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps, 1)
        await controller.shutdown()
    }

    func testShutdownInterruptsBackoffAndPreventsFurtherAttempts() async throws {
        let fixture = Fixture()
        let controller = controller(fixture, blockingBackoff: true)
        try await controller.connectInitially(.init(host: "127.0.0.1"))
        await fixture.failNext(10)
        await fixture.drop()
        try await eventually { await fixture.sleeps == 1 }
        await controller.shutdown()
        await controller.offer(.init(host: "127.0.0.1"))
        await fixture.drop()
        let state = await controller.state
        let attempts = await fixture.attempts
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(attempts, 2)
    }

    func testShutdownBeforeFirstOfferNeverConnects() async {
        let fixture = Fixture()
        let controller = controller(fixture)
        await controller.shutdown()
        await controller.offer(.init(host: "127.0.0.1"))
        try? await controller.connectInitially(.init(host: "127.0.0.1"))
        let attempts = await fixture.attempts
        XCTAssertEqual(attempts, 0)
    }

    func testLateSuccessfulConnectionAfterShutdownIsClosed() async throws {
        let fixture = Fixture()
        await fixture.hold()
        let controller = controller(fixture)
        await controller.offer(.init(host: "127.0.0.1"))
        try await eventually { await fixture.attempts == 1 }
        await controller.shutdown()
        await fixture.release()
        try await eventually { await fixture.closes == 1 }
        let state = await controller.state
        XCTAssertEqual(state, .stopped)
    }

    func testSecondDisconnectAfterReconnect() async throws {
        let fixture = Fixture()
        let controller = controller(fixture)
        try await controller.connectInitially(.init(host: "127.0.0.1"))
        for expected in 2...3 {
            await fixture.drop()
            try await eventually {
                let attempts = await fixture.attempts
                let state = await controller.state
                return attempts == expected && state == .connected
            }
        }
        await controller.shutdown()
        try await eventually { await fixture.closes == 3 }
    }

    func testWirelessWaitsForDiscoveryAndIgnoresBeaconsWhileConnected() async throws {
        let fixture = Fixture(), endpoint = HeadsetReconnectController.Endpoint(host: "192.0.2.1")
        let controller = controller(fixture, wired: false)
        await controller.offer(endpoint)
        try await eventually { await controller.state == .connected }
        await controller.offer(endpoint)
        await fixture.drop()
        try await eventually { await controller.state == .waiting }
        let attempts = await fixture.attempts
        XCTAssertEqual(attempts, 1)
        let preparations = await fixture.preparations
        XCTAssertEqual(preparations, 0)
        await fixture.failNext(1)
        await controller.offer(endpoint)
        try await eventually { await controller.state == .waiting }
        await controller.offer(endpoint)
        try await eventually {
            let attempts = await fixture.attempts
            let state = await controller.state
            return attempts == 3 && state == .connected
        }
        await controller.shutdown()
    }
}
