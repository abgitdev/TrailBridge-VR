import XCTest
@testable import BasaltCore

final class HeadsetBeaconGateTests: XCTestCase {
    /// A trust file that exists only in memory, with a clock the test moves.
    private final class Fixture {
        var names: [String] = []
        var version = 1
        var unreadable = false
        var clock: UInt64 = 1_000_000_000
        private(set) var reads = 0
        private(set) var looks = 0
        private(set) var lines: [String] = []
        private(set) var gate: HeadsetBeaconGate!

        init() {
            gate = HeadsetBeaconGate(
                file: URL(fileURLWithPath: "/fixture/trust.json"),
                now: { [unowned self] in clock },
                signature: { [unowned self] _ in
                    looks += 1
                    return TrustFileSignature(inode: UInt64(version), size: 2,
                                              modifiedSeconds: 0, modifiedNanoseconds: 0)
                },
                read: { [unowned self] _ in
                    reads += 1
                    if unreadable { throw BasaltError("bad JSON") }
                    return names
                })
        }

        func save(_ names: [String]) {
            self.names = names
            version += 1
        }

        @discardableResult
        func beacon(_ hostname: String, ip: String = "192.0.2.1") -> Bool {
            gate.accept(hostname: hostname, ip: ip) { lines.append($0) }
        }

        func advance(seconds: Double) {
            clock += UInt64(seconds * 1_000_000_000)
        }

        var requests: [String] { lines.filter { HeadsetRequest.parse($0) != nil } }
        var summaries: [String] {
            lines.filter { $0.hasPrefix(HeadsetBeaconGate.hiddenRequestsLogPrefix) }
        }
    }

    func testWithoutATrustFileEveryNameIsAccepted() {
        let gate = HeadsetBeaconGate(file: nil)
        XCTAssertTrue(gate.accept(hostname: "Quest", ip: "192.0.2.1") { _ in
            XCTFail("No request without a trust file")
        })
    }

    func testUnknownReportedOnceApprovalOnNextBeaconAndForget() {
        let fixture = Fixture()
        for _ in 0..<3 {
            XCTAssertFalse(fixture.beacon("Quest 3"))
            fixture.advance(seconds: 1)
        }
        XCTAssertEqual(fixture.lines, ["Headset request: Quest 3 at 192.0.2.1"])
        // Approval: the very next beacon connects.
        fixture.save(["Quest 3"])
        XCTAssertTrue(fixture.beacon("Quest 3", ip: "192.0.2.2"))
        // Forget: the very next beacon does not.
        fixture.save([])
        XCTAssertFalse(fixture.beacon("Quest 3", ip: "192.0.2.2"))
        XCTAssertEqual(fixture.lines.count, 1)
    }

    func testUnreadableOrMalformedTrustFailsClosed() {
        let fixture = Fixture()
        fixture.names = ["Quest"]
        fixture.unreadable = true
        XCTAssertFalse(fixture.beacon("Quest"))
        XCTAssertFalse(fixture.beacon("Quest\nforged log"))
        XCTAssertEqual(fixture.lines, ["Headset request: Quest at 192.0.2.1"])
        // Readable again: trusted on the next beacon.
        fixture.unreadable = false
        fixture.version += 1
        XCTAssertTrue(fixture.beacon("Quest"))
    }

    func testTrustFileIsReadWhenItChangesNotForEveryBeacon() {
        let fixture = Fixture()
        fixture.names = ["Quest 3"]
        // An hour of one headset's beacons, one per second.
        for _ in 0..<3_600 {
            XCTAssertTrue(fixture.beacon("Quest 3"))
            fixture.advance(seconds: 1)
        }
        // One read at the start, then the safety re-read every two seconds;
        // before, it was one read per beacon.
        XCTAssertLessThanOrEqual(fixture.reads, 1 + 3_600 / 2)

        // A flood: 100 000 beacons within one second cost a bounded number
        // of looks at the file and no read of it.
        let readsBefore = fixture.reads, looksBefore = fixture.looks
        for index in 0..<100_000 {
            fixture.beacon("flood-\(index)")
            fixture.clock += 10_000 // 10 µs
        }
        XCTAssertLessThanOrEqual(fixture.reads - readsBefore, 1)
        XCTAssertLessThanOrEqual(fixture.looks - looksBefore,
                                 HeadsetBeaconGate.trustCheckBurst + 20 + 1)
    }

    func testApprovalStillAppliesWhileBeaconsFlood() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.beacon("Quest 3"))
        fixture.save(["Quest 3"])
        // The flood uses up the looks at the file; the next one is at most
        // 50 ms away, so the headset's beacon a second later connects.
        for index in 0..<10_000 {
            fixture.beacon("flood-\(index)")
            fixture.clock += 100_000 // 0.1 ms
        }
        XCTAssertTrue(fixture.beacon("Quest 3"))
    }

    func testAFloodOfNewNamesGetsAFewLinesAndKeepsNothing() {
        let fixture = Fixture()
        for index in 0..<100_000 {
            XCTAssertFalse(fixture.beacon("flood-\(index)"))
            fixture.clock += 10_000 // 10 µs: 100 000 names in one second
        }
        XCTAssertEqual(fixture.requests.count, HeadsetBeaconGate.requestBurst)
        XCTAssertEqual(fixture.summaries.count, 1)
        XCTAssertEqual(fixture.lines.count, HeadsetBeaconGate.requestBurst + 1)
        XCTAssertEqual(fixture.gate.rememberedRequestCount, HeadsetBeaconGate.requestBurst)

        // Ten more seconds of it: one more request and one count of the rest.
        for index in 100_000..<200_000 {
            fixture.beacon("flood-\(index)")
            fixture.clock += 100_000 // 0.1 ms
        }
        XCTAssertEqual(fixture.requests.count, HeadsetBeaconGate.requestBurst + 1)
        XCTAssertEqual(fixture.summaries.count, 2)
        // Every beacon is either offered or counted (the last ones are
        // still waiting for the next line).
        let counted = fixture.summaries.compactMap {
            Int($0.dropFirst(HeadsetBeaconGate.hiddenRequestsLogPrefix.count).prefix { $0.isNumber })
        }
        XCTAssertEqual(counted.count, 2)
        XCTAssertEqual(counted.first, 1)
        XCTAssertGreaterThan(counted.reduce(0, +), 180_000)
        XCTAssertLessThanOrEqual(counted.reduce(0, +) + fixture.requests.count, 200_000)
        // The line about the rest is not taken for a headset asking.
        XCTAssertNil(HeadsetRequest.parse(fixture.summaries[1]))
        XCTAssertNil(fixture.summaries[1].rangeOfCharacter(from: .newlines))
    }

    func testARealHeadsetIsOfferedAgainOnceTheFloodIsOver() {
        let fixture = Fixture()
        for index in 0..<1_000 { fixture.beacon("flood-\(index)") }
        XCTAssertFalse(fixture.beacon("Quest 3"))
        XCTAssertFalse(fixture.requests.contains("Headset request: Quest 3 at 192.0.2.1"))
        fixture.advance(seconds: 10)
        XCTAssertFalse(fixture.beacon("Quest 3"))
        XCTAssertEqual(fixture.requests.last, "Headset request: Quest 3 at 192.0.2.1")
    }

    func testOnlyTheNewestReportedNamesAreRemembered() {
        let fixture = Fixture()
        // One new name every ten seconds never meets the rate limit.
        for index in 0..<200 {
            fixture.beacon("quest-\(index)")
            fixture.advance(seconds: 10)
        }
        XCTAssertEqual(fixture.requests.count, 200)
        XCTAssertEqual(fixture.summaries.count, 0)
        XCTAssertEqual(fixture.gate.rememberedRequestCount,
                       HeadsetBeaconGate.maximumRememberedRequests)
        // A remembered name stays quiet; a forgotten one may ask again.
        fixture.beacon("quest-199")
        XCTAssertEqual(fixture.requests.count, 200)
        fixture.beacon("quest-0")
        XCTAssertEqual(fixture.requests.count, 201)
    }

    func testAllowanceRefillsOnePerIntervalUpToItsBurst() {
        var allowance = RefillingAllowance(burst: 2, intervalNanoseconds: 100)
        XCTAssertTrue(allowance.take(at: 1_000))
        XCTAssertTrue(allowance.take(at: 1_000))
        XCTAssertFalse(allowance.take(at: 1_099))
        XCTAssertTrue(allowance.take(at: 1_100))
        XCTAssertFalse(allowance.take(at: 1_150))
        // A long quiet time earns the burst, not more.
        XCTAssertTrue(allowance.take(at: 1_000_000))
        XCTAssertTrue(allowance.take(at: 1_000_000))
        XCTAssertFalse(allowance.take(at: 1_000_000))
        // A clock that steps back takes nothing away and gives nothing.
        XCTAssertFalse(allowance.take(at: 500))
    }

    func testSignatureFollowsARewrittenFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrustSignature-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HeadsetTrustStore(file: root.appendingPathComponent("trusted.json"))
        XCTAssertNil(TrustFileSignature.of(store.file))
        try store.setTrusted("Quest", trusted: true)
        let first = try XCTUnwrap(TrustFileSignature.of(store.file))
        XCTAssertEqual(TrustFileSignature.of(store.file), first)
        try store.setTrusted("Other", trusted: true)
        XCTAssertNotEqual(TrustFileSignature.of(store.file), first)
    }
}
