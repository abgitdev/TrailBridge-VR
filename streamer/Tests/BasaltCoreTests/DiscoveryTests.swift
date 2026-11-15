import XCTest
@testable import BasaltCore

final class DiscoveryTests: XCTestCase {
    /// Builds a beacon exactly the way the ALVR v20.14.0 client does.
    private func beacon(hostname: String = "1234.client.alvr",
                        protocolId: UInt64 = 0x0123_4567_89AB_CDEF,
                        magic: String = "ALVR") -> Data {
        var packet = Data(count: AlvrBeaconParser.packetSize)
        packet.replaceSubrange(0..<magic.utf8.count, with: Data(magic.utf8))
        withUnsafeBytes(of: protocolId.littleEndian) {
            packet.replaceSubrange(16..<24, with: $0)
        }
        let hostnameBytes = Data(hostname.utf8)
        packet.replaceSubrange(24..<24 + hostnameBytes.count, with: hostnameBytes)
        return packet
    }

    func testParsesValidBeacon() {
        let parsed = AlvrBeaconParser.parse(beacon())
        XCTAssertEqual(parsed, AlvrBeacon(protocolId: 0x0123_4567_89AB_CDEF,
                                          hostname: "1234.client.alvr"))
    }

    func testProtocolIdIsLittleEndian() {
        var packet = beacon(protocolId: 0)
        packet.replaceSubrange(16..<24, with: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(AlvrBeaconParser.parse(packet)?.protocolId, 1)
    }

    func testHostnameCanFillAll32Bytes() {
        let name = String(repeating: "h", count: 32)
        XCTAssertEqual(AlvrBeaconParser.parse(beacon(hostname: name))?.hostname, name)
    }

    func testRejectsWrongMagic() {
        XCTAssertNil(AlvrBeaconParser.parse(beacon(magic: "ELVR")))
    }

    func testRejectsNonZeroMagicPadding() {
        var packet = beacon()
        packet[10] = 0x42
        XCTAssertNil(AlvrBeaconParser.parse(packet))
    }

    func testRejectsWrongSize() {
        XCTAssertNil(AlvrBeaconParser.parse(beacon().dropLast()))
        XCTAssertNil(AlvrBeaconParser.parse(beacon() + Data([0])))
        XCTAssertNil(AlvrBeaconParser.parse(Data()))
    }

    func testRejectsInvalidUTF8Hostname() {
        var packet = beacon()
        packet.replaceSubrange(24..<28, with: Data([0xFF, 0xFE, 0xFD, 0xFC]))
        XCTAssertNil(AlvrBeaconParser.parse(packet))
    }

    func testListenerReceivesBeaconAndReportsEachClientOnce() throws {
        let received = expectation(description: "beacon reported")
        received.assertForOverFulfill = false
        var reports: [(AlvrBeacon, String)] = []
        let reportsLock = NSLock()

        // Ephemeral port so the test never collides with a running ALVR.
        let listener = try AlvrDiscoveryListener(port: 0) { beacon, ip in
            reportsLock.lock()
            reports.append((beacon, ip))
            reportsLock.unlock()
            received.fulfill()
        }
        defer { listener.stop() }
        XCTAssertNotEqual(listener.boundPort, 0)

        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { close(sender) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = listener.boundPort.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")

        // The client re-broadcasts every second; send a duplicate plus
        // junk to check both dedup and parser tolerance.
        for packet in [beacon(), beacon(), Data("not a beacon".utf8)] {
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sender, bytes.baseAddress, packet.count, 0,
                               $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            XCTAssertEqual(sent, packet.count)
        }

        wait(for: [received], timeout: 5)
        // Give the duplicate a moment to (wrongly) arrive before checking.
        Thread.sleep(forTimeInterval: 0.3)
        reportsLock.lock()
        defer { reportsLock.unlock() }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0.hostname, "1234.client.alvr")
        XCTAssertEqual(reports.first?.1, "127.0.0.1")
    }

    func testTrustFileFiltersDiscoveryBeforeOfferingAConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryTrust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HeadsetTrustStore(file: root.appendingPathComponent("trusted.json"))
        try store.prepare()
        let requested = expectation(description: "unknown requested once")
        let connected = expectation(description: "approved next beacon")
        let lock = NSLock()
        var requests = 0, connections = 0
        let listener = try AlvrDiscoveryListener(port: 0, repeatInterval: 0, trustFile: store.file, onRequest: { line in
            XCTAssertEqual(line, "Headset request: test.client.alvr at 127.0.0.1")
            lock.lock(); requests += 1; lock.unlock()
            requested.fulfill()
        }) { _, _ in
            lock.lock(); connections += 1; lock.unlock()
            connected.fulfill()
        }
        defer { listener.stop() }
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { close(sender) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = listener.boundPort.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        func sendBeacon() {
            let packet = beacon(hostname: "test.client.alvr")
            packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        XCTAssertEqual(sendto(sender, bytes.baseAddress, packet.count, 0, $0,
                                              socklen_t(MemoryLayout<sockaddr_in>.size)), packet.count)
                    }
                }
            }
        }
        sendBeacon(); sendBeacon()
        wait(for: [requested], timeout: 2)
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let beforeApproval = connections; lock.unlock()
        XCTAssertEqual(beforeApproval, 0)
        try store.setTrusted("test.client.alvr", trusted: true)
        sendBeacon()
        wait(for: [connected], timeout: 2)
        try store.setTrusted("test.client.alvr", trusted: false)
        sendBeacon()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let finalConnections = connections; let finalRequests = requests; lock.unlock()
        XCTAssertEqual(finalConnections, 1)
        XCTAssertEqual(finalRequests, 1)
    }

    func testBusyDiscoveryPortIsReportedWithThePortAndItsCause() throws {
        // A socket without SO_REUSEADDR holds the port against the listener.
        let holder = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        XCTAssertEqual(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(holder, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertThrowsError(try AlvrDiscoveryListener(port: port) { _, _ in }) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Cannot bind UDP port \(port) for discovery: another program is using "
                           + "this port (ALVR, MoltenVR or a second streamer?); quit it and try again")
        }
    }

    func testRecentClientTableIsBoundedAndForgetsExpiredEntries() {
        var recent = RecentBeaconClients()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(recent.shouldOffer("quest@192.0.2.1", at: start, repeatInterval: 5))
        XCTAssertFalse(recent.shouldOffer("quest@192.0.2.1", at: start + 4.9, repeatInterval: 5))
        XCTAssertTrue(recent.shouldOffer("quest@192.0.2.1", at: start + 5, repeatInterval: 5))

        // One trusted name from ever new addresses: the table stops at its
        // capacity instead of keeping every address.
        var offered = 0
        for index in 0..<10_000 where recent.shouldOffer(
            "quest@198.51.\(index / 256).\(index % 256)", at: start + 6, repeatInterval: 5) {
            offered += 1
        }
        XCTAssertEqual(recent.count, RecentBeaconClients.capacity)
        XCTAssertEqual(offered, RecentBeaconClients.capacity - 1)
        // Once their interval is over the old entries make room.
        XCTAssertTrue(recent.shouldOffer("quest@203.0.113.9", at: start + 12, repeatInterval: 5))
        XCTAssertEqual(recent.count, 1)
    }
}
