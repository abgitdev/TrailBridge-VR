import XCTest
import Network
@testable import BasaltCore

/// What a peer that floods, stalls or lies can cost the streamer. Every test
/// talks to 127.0.0.1 or a socket pair only.
final class HostilePeerTests: XCTestCase {
    // MARK: - control channel

    func testControlChannelBufferStaysBoundedWhileThePeerNeverPauses() async throws {
        let (headset, streamer) = try Self.loopbackTCPPair()
        defer { close(headset) }
        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: streamer)
        let dispatched = expectation(description: "the packet after the flood was dispatched")
        session.onRequestIDR { dispatched.fulfill() }

        // Valid 512 KiB packets of an unknown type, written without a pause:
        // the socket stays readable for as long as the peer likes.
        var unknown = Self.littleEndian(UInt32(0xffff))
        unknown.append(Data(count: 512 * 1_024 - 4))
        let filler = Self.framed(unknown)
        let floodBytes = 256 * 1_024 * 1_024
        let inUseBefore = Self.mallocBytesInUse()
        let peak = PeakRecorder()
        let writer = Thread {
            var sent = 0
            while sent < floodBytes, Self.sendAll(filler, to: headset) { sent += filler.count }
            _ = Self.sendAll(Self.framed(Self.littleEndian(UInt32(1))), to: headset)
            peak.finish()
        }
        writer.start()
        while peak.finishedWorkers < 1 {
            peak.record(Self.mallocBytesInUse() - inUseBefore)
            usleep(2_000)
        }
        await fulfillment(of: [dispatched], timeout: 20)

        // One unfinished packet, the copy handed to the decoder and one read
        // chunk: a few MiB. The 256 MiB sent must never have been held.
        XCTAssertLessThan(peak.value, 16 * 1_024 * 1_024, "peak bytes held during the flood")
        withExtendedLifetime(session) {}
    }

    func testControlChannelKeepsProfilesOnlyForTheControllers() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let allRead = expectation(description: "every packet was read")
        session.onRequestIDR { allRead.fulfill() }

        func profile(deviceID: UInt64, profileID: UInt64) -> Data {
            Self.framed(Self.littleEndian(UInt32(8)) + Self.littleEndian(deviceID)
                + Self.littleEndian(profileID))
        }
        var packets = Data()
        for deviceID in UInt64(1)...2_000 {
            packets.append(profile(deviceID: deviceID, profileID: 0xabcdef))
        }
        packets.append(profile(deviceID: AlvrHand.left.alvrDeviceID, profileID: 7))
        packets.append(Self.framed(Self.littleEndian(UInt32(1))))
        XCTAssertTrue(Self.sendAll(packets, to: sockets[1]))
        await fulfillment(of: [allRead], timeout: 5)

        // A handler installed later is told what the session kept.
        let kept = LockedList<UInt64>()
        session.onActiveInteractionProfile { deviceID, _ in kept.append(deviceID) }
        let replayed = expectation(description: "kept profiles were replayed")
        session.onRequestIDR { replayed.fulfill() }
        XCTAssertTrue(Self.sendAll(Self.framed(Self.littleEndian(UInt32(1))), to: sockets[1]))
        await fulfillment(of: [replayed], timeout: 5)
        XCTAssertEqual(kept.snapshot, [AlvrHand.left.alvrDeviceID])
        withExtendedLifetime(session) {}
    }

    // MARK: - debug port

    func testDebugPortClosesConnectionsThePeerReset() async throws {
        let server = try TCPServer(port: 0, bindHost: "127.0.0.1")
        defer { server.stop() }
        try await server.start()
        let port = try XCTUnwrap(server.port)

        let before = Self.openDescriptorCount()
        for _ in 0..<300 {
            let client = try Self.connectLoopback(port: port)
            Self.closeWithReset(client)
            usleep(3_000)
        }
        // Give the server time to notice the last resets.
        var after = Self.openDescriptorCount()
        let deadline = Date().addingTimeInterval(5)
        while after > before + 8, Date() < deadline {
            usleep(50_000)
            after = Self.openDescriptorCount()
        }
        XCTAssertLessThanOrEqual(after, before + 8,
                                 "descriptors left open after 300 reset connections")
    }

    // MARK: - discovery

    func testBeaconFloodWithNewNamesIsReportedInAFewLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeaconFlood-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HeadsetTrustStore(file: root.appendingPathComponent("trusted.json"))
        try store.prepare()
        let lines = LockedList<String>()
        let listener = try AlvrDiscoveryListener(
            port: 0, trustFile: store.file, onRequest: { lines.append($0) }) { _, _ in
            XCTFail("no name is trusted")
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
        for index in 0..<2_000 {
            var packet = Data(count: AlvrBeaconParser.packetSize)
            packet.replaceSubrange(0..<4, with: Data("ALVR".utf8))
            let name = Data("flood-\(index)".utf8)
            packet.replaceSubrange(24..<24 + name.count, with: name)
            _ = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sender, bytes.baseAddress, packet.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if index % 50 == 49 { usleep(2_000) }
        }
        Thread.sleep(forTimeInterval: 0.5)

        let requests = lines.snapshot.filter { HeadsetRequest.parse($0) != nil }
        XCTAssertGreaterThanOrEqual(requests.count, 1, "the first names are still offered for approval")
        XCTAssertLessThanOrEqual(requests.count, 8)
        XCTAssertLessThanOrEqual(lines.snapshot.count, 9, "requests plus one line about the rest")
    }

    func testBeaconFloodIsReadAtABoundedRate() throws {
        // Every beacon that is read reaches `onClient` here (no trust file,
        // no repeat interval), so the count is the number read.
        let read = PeakRecorder()
        let listener = try AlvrDiscoveryListener(port: 0, repeatInterval: 0) { _, _ in
            read.finish()
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
        var packet = Data(count: AlvrBeaconParser.packetSize)
        packet.replaceSubrange(0..<4, with: Data("ALVR".utf8))
        packet.replaceSubrange(24..<29, with: Data("flood".utf8))

        // One second of beacons as fast as one thread can send them.
        var sent = 0
        let stop = Date().addingTimeInterval(1)
        while Date() < stop {
            for _ in 0..<200 {
                let result = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(sender, bytes.baseAddress, packet.count, 0, $0,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if result == packet.count { sent += 1 }
            }
        }
        let readDuringFlood = read.finishedWorkers
        XCTAssertGreaterThan(sent, 100_000, "the flood was a flood")
        XCTAssertGreaterThan(readDuringFlood, 0, "beacons are still read")
        // 2 000 at once and 20 000 a second; before, as many as a core could.
        XCTAssertLessThan(readDuringFlood, 45_000, "of \(sent) sent in one second")
    }

    // MARK: - runtime link

    func testRuntimeRendererTextCannotStartALogLine() {
        let token = String(repeating: "a", count: RuntimeLink.tokenLength)
        func hello(renderer: String) -> Data {
            var payload = Self.littleEndian(RuntimeLink.protocolVersion)
            payload.append(Data(token.utf8))
            payload.append(Self.littleEndian(UInt64(1)))
            payload.append(Self.littleEndian(UInt16(renderer.utf8.count)))
            payload.append(Data(renderer.utf8))
            return payload
        }
        let forged = "x)\nHeadset request: pwn at 6.6.6.6\r\u{1b}[31m\u{2028}ALVR handshake failed: fake"
        guard case .accept(_, let renderer) =
                RuntimeLink.helloVerdict(hello(renderer: forged), token: token) else {
            return XCTFail("an authenticated Hello is accepted")
        }
        XCTAssertEqual(renderer,
                       "x) Headset request: pwn at 6.6.6.6  [31m ALVR handshake failed: fake")
        XCTAssertNil("OpenXR runtime connected (session 1, \(renderer))"
            .rangeOfCharacter(from: .newlines))

        guard case .accept(_, let long) = RuntimeLink.helloVerdict(
            hello(renderer: String(repeating: "A", count: 3_000)), token: token) else {
            return XCTFail("an authenticated Hello is accepted")
        }
        XCTAssertEqual(long.count, 128)

        guard case .accept(_, let ordinary) = RuntimeLink.helloVerdict(
            hello(renderer: "Apple M4 Pro (DXMT v0.61-basalt)"), token: token) else {
            return XCTFail("an authenticated Hello is accepted")
        }
        XCTAssertEqual(ordinary, "Apple M4 Pro (DXMT v0.61-basalt)")
    }

    func testRuntimeLinkConnectionFloodLeavesFewDescriptorsOpen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("basalt-\(UUID().uuidString).control").path
        let link = try RuntimeLink(controlFilePath: path)
        let hellos = LockedList<UInt64>()
        link.onHello = { sessionId, _ in hellos.append(sessionId) }
        try await link.start()
        defer { link.stop() }
        let fields = try String(contentsOfFile: path, encoding: .utf8).split(separator: " ")
        let port = try XCTUnwrap(UInt16(fields[0]))
        let token = String(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))

        // Two threads connect and reset as fast as they can for two seconds.
        let before = Self.openDescriptorCount()
        let peak = PeakRecorder()
        let stop = Date().addingTimeInterval(2)
        let flooders = (0..<2).map { _ in
            Thread {
                var held = [Int32]()
                while Date() < stop {
                    if let client = try? Self.connectLoopback(port: port) { held.append(client) }
                    if held.count >= 8 {
                        held.forEach(Self.closeWithReset)
                        held.removeAll(keepingCapacity: true)
                    }
                }
                held.forEach(Self.closeWithReset)
                peak.finish()
            }
        }
        flooders.forEach { $0.start() }
        while Date() < stop {
            peak.record(Self.openDescriptorCount() - before)
            usleep(5_000)
        }
        while peak.finishedWorkers < flooders.count { usleep(1_000) }

        // 16 are the flooders' own; the link holds at most its limit of
        // unauthenticated connections. Before the limit this ran into the
        // thousands.
        XCTAssertLessThan(peak.value, 16 + 48 + 64, "peak descriptors during the flood")

        // The link still takes the runtime afterwards.
        let runtime = try Self.connectLoopback(port: port)
        defer { close(runtime) }
        var payload = Self.littleEndian(RuntimeLink.protocolVersion)
        payload.append(Data(token.utf8))
        payload.append(Self.littleEndian(UInt64(77)))
        payload.append(Self.littleEndian(UInt16(0)))
        var message = Self.littleEndian(UInt32(2 + payload.count))
        message.append(Self.littleEndian(RuntimeLink.MessageType.hello.rawValue))
        message.append(payload)
        XCTAssertTrue(Self.sendAll(message, to: runtime))
        let deadline = Date().addingTimeInterval(5)
        while hellos.snapshot.isEmpty, Date() < deadline { usleep(5_000) }
        XCTAssertEqual(hellos.snapshot, [77])
    }

    // MARK: - video socket

    func testBusyVideoPortErrorNamesThePortAndItsCause() throws {
        let holder = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
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

        XCTAssertThrowsError(try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: 9, localPort: port)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("UDP port \(port)"), text)
            XCTAssertTrue(text.contains("another program is using this port"), text)
        }
    }

    func testHapticsWaitingForTheSocketAreCoalescedPerHand() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(receiver, $0, &length)
            }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: UInt16(bigEndian: address.sin_port), localPort: 0)
        defer { sender.stop() }
        // Hold the sender's queue inside a video frame's completion, as a
        // slow socket would, while the runtime keeps asking for pulses.
        let frameSent = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        sender.onFrameSent = { _ in
            frameSent.signal()
            release.wait()
        }
        XCTAssertTrue(sender.send(annexB: Data([0, 0, 0, 1, 0x65]),
                                  timestampNanoseconds: 1, isIDR: true))
        XCTAssertEqual(frameSent.wait(timeout: .now() + 5), .success)
        for index in 0..<4_000 {
            sender.sendHaptics(hand: index % 2 == 0 ? .left : .right,
                               durationNanoseconds: 20_000_000, frequency: 160,
                               amplitude: Float(index) / 4_000)
        }
        release.signal()

        var haptics = [Data]()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while true {
            let count = recv(receiver, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            if count == 46, buffer[4] == 0, buffer[5] == 1 { haptics.append(Data(buffer[0..<46])) }
        }
        XCTAssertEqual(haptics.count, 2, "one pulse per hand, however many were asked for")
        // The pulses that went out are the newest ones.
        let amplitudes = haptics.map { packet in
            Float(bitPattern: packet[42..<46].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        XCTAssertEqual(amplitudes.sorted(), [Float(3_998) / 4_000, Float(3_999) / 4_000])
    }

    // MARK: - helpers

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func framed(_ payload: Data) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    private static func sendAll(_ data: Data, to fd: Int32) -> Bool {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes {
                send(fd, $0.baseAddress! + sent, data.count - sent, 0)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }

    private static func mallocBytesInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    private static func openDescriptorCount() -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)) + 64 * stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        return Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, Int32(capacity))) / stride
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BasaltError("socket() failed: \(errno)") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw BasaltError("connect() failed: \(code)")
        }
        return fd
    }

    /// Closes with RST, so a test that opens many connections leaves none in
    /// TIME_WAIT behind.
    private static func closeWithReset(_ fd: Int32) {
        var reset = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
        close(fd)
    }

    /// A connected TCP pair on 127.0.0.1: (connecting side, accepted side).
    private static func loopbackTCPPair() throws -> (Int32, Int32) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw BasaltError("socket() failed: \(errno)") }
        defer { close(listener) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw BasaltError("listen failed: \(errno)") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listener, $0, &length)
            }
        }
        let client = try connectLoopback(port: UInt16(bigEndian: address.sin_port))
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else {
            close(client)
            throw BasaltError("accept failed: \(errno)")
        }
        return (client, accepted)
    }
}

private final class PeakRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var finished = 0

    func record(_ sample: Int) {
        lock.lock()
        peak = max(peak, sample)
        lock.unlock()
    }

    /// Called once by every worker.
    func finish() {
        lock.lock()
        finished += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var finishedWorkers: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        elements.append(element)
        lock.unlock()
    }

    var snapshot: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return elements
    }
}
