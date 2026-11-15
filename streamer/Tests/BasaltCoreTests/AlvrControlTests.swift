import XCTest
@testable import BasaltCore

final class AlvrControlTests: XCTestCase {
    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func acceptedPrefix(protocolId: UInt64, name: String) -> Data {
        let nameData = Data(name.utf8)
        var packet = littleEndian(UInt32(0))
        packet.append(littleEndian(protocolId))
        packet.append(littleEndian(UInt64(nameData.count)))
        packet.append(nameData)
        packet.append(littleEndian(UInt32(0))) // IpAddr::V4
        packet.append(contentsOf: [192, 168, 1, 10])
        return packet
    }

    private static func framed(_ payload: Data) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    private static func receiveExactly(_ count: Int, fd: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else { return nil }
            offset += received
        }
        return data
    }

    private static func receiveFrame(fd: Int32) -> Data? {
        guard let prefix = receiveExactly(4, fd: fd) else { return nil }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        return receiveExactly(length, fd: fd)
    }

    func testDecodesAcceptedPacketPrefix() throws {
        var packet = Self.acceptedPrefix(protocolId: 0x0123_4567_89AB_CDEF, name: "Quest 3")
        packet.append(0) // None

        XCTAssertEqual(try AlvrClientConnectionDecoder.decode(packet),
                       .accepted(protocolId: 0x0123_4567_89AB_CDEF, displayName: "Quest 3",
                                 serverIP: "192.168.1.10", capabilities: nil))
    }

    /// The streamer prints the name and the manager reads the streamer's
    /// output line by line, so a name must stay inside one short line.
    func testDisplayNameCannotStartALogLineOfItsOwn() throws {
        let forged = "Quest 3\nHeadset request: other.client.alvr at 10.0.0.9\r\n"
            + "OpenXR runtime connection refused: x\u{2028}y\u{85}z\u{1B}[2J\u{202E}\t"
            + String(repeating: "A", count: 400)
        var packet = Self.acceptedPrefix(protocolId: 20, name: forged)
        packet.append(0) // None

        guard case .accepted(_, let displayName, _, _) =
                try AlvrClientConnectionDecoder.decode(packet) else {
            return XCTFail("expected an accepted connection")
        }
        XCTAssertTrue(displayName.hasPrefix("Quest 3 Headset request: other.client.alvr at 10.0.0.9 "),
                      displayName)
        XCTAssertEqual(displayName.unicodeScalars.count,
                       AlvrClientConnectionDecoder.maximumDisplayNameLength)
        XCTAssertEqual(displayName.split(whereSeparator: \.isNewline).count, 1)
        for scalar in displayName.unicodeScalars {
            XCTAssertFalse(
                [.control, .format, .lineSeparator, .paragraphSeparator]
                    .contains(scalar.properties.generalCategory),
                "U+\(String(scalar.value, radix: 16))")
        }
        // An ordinary name is untouched, in any script.
        var plain = Self.acceptedPrefix(protocolId: 20, name: "Quest 3 — гостиная")
        plain.append(0)
        guard case .accepted(_, let plainName, _, _) =
                try AlvrClientConnectionDecoder.decode(plain) else {
            return XCTFail("expected an accepted connection")
        }
        XCTAssertEqual(plainName, "Quest 3 — гостиная")
    }

    func testDecodesVideoCapabilitiesAndEmbeddedJSON() throws {
        var packet = Self.acceptedPrefix(protocolId: 20, name: "Quest 3")
        packet.append(1) // Some
        packet.append(Self.littleEndian(UInt32(2064)))
        packet.append(Self.littleEndian(UInt32(2208)))

        let json = Data("{\"encoder_av1\":false,\"prefer_full_range\":false}".utf8)
        packet.append(Self.littleEndian(UInt64(2 + json.count)))
        for rate: Float in [72, 90] { packet.append(Self.littleEndian(rate.bitPattern)) }
        for byte in json { packet.append(Self.littleEndian((-Float(byte)).bitPattern)) }
        packet.append(Self.littleEndian(UInt32(48_000)))

        guard case .accepted(_, _, _, let capabilities?) =
                try AlvrClientConnectionDecoder.decode(packet) else {
            return XCTFail("Expected accepted capabilities")
        }
        XCTAssertEqual(capabilities.width, 2064)
        XCTAssertEqual(capabilities.height, 2208)
        XCTAssertEqual(capabilities.refreshRates, [72, 90])
        XCTAssertEqual(capabilities.microphoneSampleRate, 48_000)
        XCTAssertFalse(capabilities.supportsAV1)
        XCTAssertFalse(capabilities.prefersFullRange)
        XCTAssertTrue(capabilities.supportsHighProfile)
    }

    func testUnusableEncodingGammaFallsBackBeforeReachingStreamConfigJSON() throws {
        func capabilities(gammaJSON: String) throws -> AlvrVideoCapabilities {
            var packet = Self.acceptedPrefix(protocolId: 20, name: "Quest 3")
            packet.append(1) // Some
            packet.append(Self.littleEndian(UInt32(2064)))
            packet.append(Self.littleEndian(UInt32(2208)))
            let json = Data("{\"preferred_encoding_gamma\":\(gammaJSON)}".utf8)
            packet.append(Self.littleEndian(UInt64(1 + json.count)))
            packet.append(Self.littleEndian(Float(90).bitPattern))
            for byte in json { packet.append(Self.littleEndian((-Float(byte)).bitPattern)) }
            packet.append(Self.littleEndian(UInt32(48_000)))
            guard case .accepted(_, _, _, let capabilities?) =
                    try AlvrClientConnectionDecoder.decode(packet) else {
                throw BasaltError("Expected accepted capabilities")
            }
            return capabilities
        }

        XCTAssertEqual(try capabilities(gammaJSON: "2.2").preferredEncodingGamma, 2.2)
        // 1e39 overflows Float to +inf, which JSONSerialization cannot encode.
        for unusable in ["1e39", "-1", "0", "1000"] {
            let decoded = try capabilities(gammaJSON: unusable)
            XCTAssertEqual(decoded.preferredEncodingGamma, 1, unusable)
            let settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: decoded)
            XCTAssertNoThrow(try AlvrStreamConfigEncoder.payload(settings: settings))
        }
    }

    func testDecodesStandby() throws {
        XCTAssertEqual(try AlvrClientConnectionDecoder.decode(Self.littleEndian(UInt32(1))), .standby)
    }

    func testDecodesStreamingControlEvents() throws {
        XCTAssertEqual(try AlvrClientControlDecoder.decode(Self.littleEndian(UInt32(1))),
                       .requestIDR)
        XCTAssertEqual(try AlvrClientControlDecoder.decode(Self.littleEndian(UInt32(2))),
                       .keepAlive)

        var views = Self.littleEndian(UInt32(4))
        for value: Float in [0.064, -0.9, 1.0, 0.8, -0.8,
                             -1.0, 0.9, 0.8, -0.8] {
            views.append(Self.littleEndian(value.bitPattern))
        }
        guard case .viewsConfig(let config) = try AlvrClientControlDecoder.decode(views) else {
            return XCTFail("Expected ALVR views configuration")
        }
        XCTAssertEqual(config.ipdMeters, 0.064, accuracy: 0.0001)
        XCTAssertEqual(config.fov.count, 2)
        XCTAssertEqual(config.fov[0].left, -0.9)
        XCTAssertEqual(config.fov[1].right, 0.9)

        var buttons = Self.littleEndian(UInt32(7))
        buttons.append(Self.littleEndian(UInt64(2)))
        buttons.append(Self.littleEndian(UInt64(0x1111)))
        buttons.append(Self.littleEndian(UInt32(0)))
        buttons.append(1)
        buttons.append(Self.littleEndian(UInt64(0x2222)))
        buttons.append(Self.littleEndian(UInt32(1)))
        buttons.append(Self.littleEndian(Float(0.75).bitPattern))
        XCTAssertEqual(try AlvrClientControlDecoder.decode(buttons), .buttons([
            AlvrButtonEntry(pathID: 0x1111, value: .binary(true)),
            AlvrButtonEntry(pathID: 0x2222, value: .scalar(0.75)),
        ]))

        var profile = Self.littleEndian(UInt32(8))
        profile.append(Self.littleEndian(UInt64(0xe521_d8da_be2d_07a2)))
        profile.append(Self.littleEndian(UInt64(0x0812_fd85_c843_84a6)))
        XCTAssertEqual(try AlvrClientControlDecoder.decode(profile),
                       .activeInteractionProfile(
                           deviceID: 0xe521_d8da_be2d_07a2,
                           profileID: 0x0812_fd85_c843_84a6))
    }

    func testLiveControlSessionDispatchesIDRAndViewsConfig() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }

        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let idrReceived = expectation(description: "IDR request dispatched")
        let viewsReceived = expectation(description: "views config dispatched")
        session.onRequestIDR { idrReceived.fulfill() }
        session.onViewsConfig { config in
            XCTAssertEqual(config.ipdMeters, 0.064, accuracy: 0.0001)
            viewsReceived.fulfill()
        }

        var views = Self.littleEndian(UInt32(4))
        for value: Float in [0.064, -0.9, 1.0, 0.8, -0.8,
                             -1.0, 0.9, 0.8, -0.8] {
            views.append(Self.littleEndian(value.bitPattern))
        }
        let packets = Self.framed(Self.littleEndian(UInt32(1))) + Self.framed(views)
        XCTAssertEqual(packets.withUnsafeBytes {
            send(sockets[1], $0.baseAddress, packets.count, 0)
        }, packets.count)

        await fulfillment(of: [idrReceived, viewsReceived], timeout: 2)
        withExtendedLifetime(session) {}
    }

    func testLiveControlSessionDoesNotKeepTheBytesItHasRead() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }

        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let allRead = expectation(description: "the packet after the filler was dispatched")
        session.onRequestIDR { allRead.fulfill() }

        // 24 MiB of valid packets of an unknown type, which the session reads
        // and drops, then one IDR request to tell when it got through them.
        var unknown = Self.littleEndian(UInt32(0xffff))
        unknown.append(Data(count: 512 * 1_024 - 4))
        let filler = Self.framed(unknown)
        let fillerCount = 48
        let inUseBefore = Self.mallocBytesInUse()
        for packet in Array(repeating: filler, count: fillerCount) + [Self.framed(Self.littleEndian(UInt32(1)))] {
            var sent = 0
            while sent < packet.count {
                let count = packet.withUnsafeBytes {
                    send(sockets[1], $0.baseAddress! + sent, packet.count - sent, 0)
                }
                guard count > 0 else { return XCTFail("send failed: \(errno)") }
                sent += count
            }
        }
        await fulfillment(of: [allRead], timeout: 10)

        // At most one unfinished packet may stay buffered, never the history.
        XCTAssertLessThan(Self.mallocBytesInUse() - inUseBefore, 4 * 1_024 * 1_024,
                          "after receiving \(fillerCount * filler.count) bytes")
        withExtendedLifetime(session) {}
    }

    private static func mallocBytesInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    func testReceiveBufferHoldsAtMostOnePacketAndOneChunk() {
        var buffer = AlvrControlReceiveBuffer()
        var largest = Self.littleEndian(UInt32(0xffff))
        largest.append(Data(count: AlvrControlProbe.maximumPacketBytes - 4))
        var stream = Data()
        for _ in 0..<3 { stream.append(Self.framed(largest)) }
        stream.append(Self.framed(Self.littleEndian(UInt32(1))))

        var packets = 0, lastPacket = Data(), mostHeld = 0
        var offset = 0
        while offset < stream.count {
            let end = min(offset + AlvrControlReceiveBuffer.chunkBytes, stream.count)
            buffer.append(stream[offset..<end])
            offset = end
            mostHeld = max(mostHeld, buffer.count)
            while case .packet(let payload) = buffer.nextPacket() {
                packets += 1
                lastPacket = payload
            }
            buffer.releaseConsumedBytes()
        }
        XCTAssertEqual(packets, 4)
        XCTAssertEqual(lastPacket, Self.littleEndian(UInt32(1)))
        XCTAssertEqual(buffer.count, 0)
        XCTAssertLessThanOrEqual(mostHeld, AlvrControlReceiveBuffer.maximumBytes)
        XCTAssertEqual(AlvrControlReceiveBuffer.maximumBytes,
                       4 + 1_024 * 1_024 + 16_384)
    }

    func testReceiveBufferRefusesLengthsItWouldHaveToWaitFor() {
        var buffer = AlvrControlReceiveBuffer()
        buffer.append(Data([0, 0x10]))
        XCTAssertEqual(buffer.nextPacket(), .incomplete)
        buffer.append(Data([0, 1])) // 1 MiB + 1
        XCTAssertEqual(buffer.nextPacket(),
                       .invalid(length: AlvrControlProbe.maximumPacketBytes + 1))

        var empty = AlvrControlReceiveBuffer()
        empty.append(Data([0, 0, 0, 0, 9]))
        XCTAssertEqual(empty.nextPacket(), .invalid(length: 0))

        var huge = AlvrControlReceiveBuffer()
        huge.append(Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertEqual(huge.nextPacket(), .invalid(length: 0xffff_ffff))

        var largestAllowed = AlvrControlReceiveBuffer()
        largestAllowed.append(Data([0, 0x10, 0, 0, 7]))
        XCTAssertEqual(largestAllowed.nextPacket(), .incomplete)
    }

    func testLiveControlSessionClosesOnAnOversizedLength() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let disconnected = expectation(description: "session closed")
        session.onDisconnect { disconnected.fulfill() }
        session.onRequestIDR { XCTFail("nothing after the bad length is handled") }
        // 1 MiB + 1 announced, then a packet that would be valid on its own.
        let bytes = Data([0, 0x10, 0, 1]) + Self.framed(Self.littleEndian(UInt32(1)))
        XCTAssertEqual(bytes.withUnsafeBytes { send(sockets[1], $0.baseAddress, bytes.count, 0) },
                       bytes.count)
        await fulfillment(of: [disconnected], timeout: 2)
        withExtendedLifetime(session) {}
    }

    func testRefreshRatesLogTextShowsTheFirstFewAndACount() {
        func capabilities(_ rates: [Float]) -> AlvrVideoCapabilities {
            AlvrVideoCapabilities(
                width: 2_064, height: 2_208, refreshRates: rates, microphoneSampleRate: 48_000,
                supportsFoveatedEncoding: true, supportsHighProfile: true, supports10Bit: true,
                supportsAV1: false, prefers10Bit: false, prefersFullRange: true,
                preferredEncodingGamma: 1, prefersHDR: false)
        }
        XCTAssertEqual(capabilities([72, 80, 90, 120]).refreshRatesLogText, "72, 80, 90, 120")
        XCTAssertEqual(capabilities([]).refreshRatesLogText, "")
        XCTAssertEqual(capabilities(Array(repeating: 72, count: 8)).refreshRatesLogText,
                       "72, 72, 72, 72, 72, 72, 72, 72")
        let flood = capabilities(Array(repeating: 72, count: 16_383) + [90])
        XCTAssertEqual(flood.refreshRatesLogText,
                       "72, 72, 72, 72, 72, 72, 72, 72 and 16376 more")
        XCTAssertLessThan(flood.refreshRatesLogText.utf8.count, 64)
    }

    func testLiveControlSessionReportsDisconnectOnce() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)

        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let disconnected = expectation(description: "control disconnect dispatched")
        disconnected.expectedFulfillmentCount = 1
        session.onDisconnect { disconnected.fulfill() }

        close(sockets[1])
        sockets[1] = -1
        await fulfillment(of: [disconnected], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        withExtendedLifetime(session) {}
    }

    func testLiveControlButtonCacheIsBoundedAndUpdatesExistingPaths() {
        var values: [UInt64: AlvrButtonValue] = [:]
        let initial = (1...65).map {
            AlvrButtonEntry(pathID: UInt64($0), value: .scalar(Float($0)))
        }
        let retained = AlvrSessionHandshakeResult.retainButtonEntries(
            initial, in: &values)
        XCTAssertEqual(retained.count,
                       AlvrSessionHandshakeResult.maximumRetainedButtonPaths)
        XCTAssertEqual(values.count,
                       AlvrSessionHandshakeResult.maximumRetainedButtonPaths)
        XCTAssertNil(values[65])

        let update = AlvrButtonEntry(pathID: 1, value: .scalar(0.25))
        XCTAssertEqual(AlvrSessionHandshakeResult.retainButtonEntries(
            [update], in: &values), [update])
        XCTAssertEqual(values[1], .scalar(0.25))
    }

    func testRejectsMalformedPackets() {
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(Data()))
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(Self.littleEndian(UInt32(99))))

        var hugeString = Self.littleEndian(UInt32(0))
        hugeString.append(Self.littleEndian(UInt64(1)))
        hugeString.append(Self.littleEndian(UInt64(4_097)))
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(hugeString))
    }

    func testProbeReadsFramedPacketOverLoopback() async throws {
        let server = try TCPServer(port: 0, bindHost: "127.0.0.1")
        defer { server.stop() }
        try await server.start()

        var payload = Self.acceptedPrefix(protocolId: 42, name: "Loopback Quest")
        payload.append(0)

        var framed = Data()
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        server.onClientConnected = { server.broadcast(framed) }

        let result = try await AlvrControlProbe.connect(
            host: "127.0.0.1", port: try XCTUnwrap(server.port))
        XCTAssertEqual(result, .accepted(protocolId: 42, displayName: "Loopback Quest",
                                         serverIP: "192.168.1.10", capabilities: nil))
    }

    func testNegotiatesUntilStreamReadyOverOneConnection() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listener, $0, &boundSize)
            }
        }

        let serverFinished = expectation(description: "mock headset completed handshake")
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            var accepted = Self.acceptedPrefix(protocolId: 42, name: "Mock Quest")
            accepted.append(1)
            accepted.append(Self.littleEndian(UInt32(1680)))
            accepted.append(Self.littleEndian(UInt32(1760)))
            accepted.append(Self.littleEndian(UInt64(1)))
            accepted.append(Self.littleEndian(Float(90).bitPattern))
            accepted.append(Self.littleEndian(UInt32(44_100)))
            let packet = Self.framed(accepted)
            _ = packet.withUnsafeBytes { send(client, $0.baseAddress, packet.count, 0) }

            guard Self.receiveFrame(fd: client) != nil,
                  Self.receiveFrame(fd: client) == Data([0, 0, 0, 0]) else { return }
            let ready = Self.framed(Data([3, 0, 0, 0]))
            _ = ready.withUnsafeBytes { send(client, $0.baseAddress, ready.count, 0) }
            serverFinished.fulfill()
        }

        let result = try await AlvrControlProbe.negotiateSession(
            host: "127.0.0.1", port: UInt16(bigEndian: bound.sin_port))
        XCTAssertTrue(result.streamReady)
        XCTAssertEqual(result.negotiatedSettings?.refreshRate, 90)
        await fulfillment(of: [serverFinished], timeout: 5)
    }

    func testProbeGateSuppressesOverlapAndCompletedClients() {
        let gate = AlvrControlProbeGate()
        XCTAssertTrue(gate.begin(clientKey: "quest@127.0.0.1"))
        XCTAssertFalse(gate.begin(clientKey: "quest@127.0.0.1"))

        gate.finish(clientKey: "quest@127.0.0.1", succeeded: false)
        XCTAssertTrue(gate.begin(clientKey: "quest@127.0.0.1"))

        gate.finish(clientKey: "quest@127.0.0.1", succeeded: true)
        XCTAssertFalse(gate.begin(clientKey: "quest@127.0.0.1"))
        XCTAssertTrue(gate.begin(clientKey: "another@127.0.0.1"))
    }
}
