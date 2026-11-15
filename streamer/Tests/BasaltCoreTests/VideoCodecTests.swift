import XCTest
import Darwin
@testable import BasaltCore

/// Pinned Apple VideoToolbox HEVC Main 8-bit output from synthetic BGRA at
/// 2688x1408 / 72 Hz / 80 Mbps with low-latency RC. No game or account data.
private enum HEVCFixture {
    static let vps = hex("40010c03ffff016000000300b000000300000300b70000043024")
    static let sps = hex("420103016000000300b000000300000300b70000a0015020058162010ee452082e7e13d0bea1bd50feaa08f55413eaaa0af555417eaaaa0cf555541beaaaaa0ef5555541feaaaaaa043d55555529a81010101fc20104")
    static let pps = hex("4401c072f05b24")
    static let config = hex("0000000140010c03ffff016000000300b000000300000300b7000004302400000001420103016000000300b000000300000300b70000a0015020058162010ee452082e7e13d0bea1bd50feaa08f55413eaaa0af555417eaaaa0cf555541beaaaaa0ef5555541feaaaaaa043d55555529a81010101fc20104000000014401c072f05b24")
    // ServerControlPacket variant=1, CodecType::Hevc=1, u64 vector length,
    // followed by VPS+SPS+PPS, each prefixed with 00 00 00 01. Bincode fixint.
    static let decoderPayload = hex("010000000100000083000000000000000000000140010c03ffff016000000300b000000300000300b7000004302400000001420103016000000300b000000300000300b70000a0015020058162010ee452082e7e13d0bea1bd50feaa08f55413eaaa0af555417eaaaa0cf555541beaaaaa0ef5555541feaaaaaa043d55555529a81010101fc20104000000014401c072f05b24")

    static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<end], radix: 16)!)
            index = end
        }
        return data
    }
}

final class VideoCodecTests: XCTestCase {
    func testHEVCDecoderConfigMatchesPinnedALVR20141Payload() throws {
        let accessUnit = HEVCFixture.config + Data([0, 0, 1, 0x26, 0x01, 0xaa])
        let extracted = try XCTUnwrap(VideoParameterSets.extract(from: accessUnit, codec: .hevc))
        XCTAssertEqual(extracted, HEVCFixture.config)
        XCTAssertEqual(AlvrControlProbe.decoderConfigPayload(extracted, codec: .hevc),
                       HEVCFixture.decoderPayload)
    }

    func testRouterSendsPinnedHEVCDecoderConfigOverControlSocket() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(sockets[1], SOL_SOCKET, SO_RCVTIMEO,
                                 &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        let control = AlvrSessionHandshakeResult(clientState: .standby,
            negotiatedSettings: nil, streamReady: true, socket: sockets[0])
        let sender = try AlvrVideoStreamSender(host: "127.0.0.1", remotePort: 9999, localPort: 0)
        let router = AlvrVideoStreamRouter(codec: .hevc)
        router.install(sender, controlSession: control)
        router.send(annexB: HEVCFixture.config + Data([0, 0, 0, 1, 0x26, 1, 0xaa]), isIDR: true)
        var prefix = UInt32(HEVCFixture.decoderPayload.count).bigEndian
        var expected = withUnsafeBytes(of: &prefix) { Data($0) }
        expected.append(HEVCFixture.decoderPayload)
        var received = Data(count: expected.count)
        let count = received.withUnsafeMutableBytes {
            recv(sockets[1], $0.baseAddress!, $0.count, MSG_WAITALL)
        }
        XCTAssertEqual(count, expected.count)
        XCTAssertEqual(received, expected)
        withExtendedLifetime(control) {}
    }

    func testH264DecoderConfigBytesRemainUnchanged() {
        let config = Data([0, 0, 0, 1, 0x67, 0x64, 0, 0x2a, 0, 0, 0, 1, 0x68, 0xaa])
        let expected = Data([1, 0, 0, 0, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0]) + config
        XCTAssertEqual(AlvrControlProbe.decoderConfigPayload(config, codec: .h264), expected)
        XCTAssertEqual(VideoParameterSets.extract(from: config, codec: .h264), config)
    }

    func testHEVCNALClassificationUsesBothHeaderBytes() {
        for type: UInt8 in 0...63 {
            let nalu = Data([type << 1, 1, 0xab])
            XCTAssertEqual(VideoCodec.hevc.nalType(nalu), type)
            XCTAssertEqual(VideoCodec.hevc.isKeyframeNAL(nalu), (16...21).contains(type))
            XCTAssertEqual(VideoCodec.hevc.isParameterSet(nalu), (32...34).contains(type))
        }
        for nalu in [Data(), Data([0x40]), Data([0xc0, 1]), Data([0x40, 0])] {
            XCTAssertNil(VideoCodec.hevc.nalType(nalu))
            XCTAssertFalse(VideoCodec.hevc.isKeyframeNAL(nalu))
            XCTAssertFalse(VideoCodec.hevc.isParameterSet(nalu))
        }
        let padded = Data([0xff, 0x26, 0x01])
        XCTAssertEqual(VideoCodec.hevc.nalType(padded[1...]), 19)
        XCTAssertTrue(VideoCodec.h264.isKeyframeNAL(Data([0x65])))
        XCTAssertFalse(VideoCodec.h264.isKeyframeNAL(Data([0x41])))
    }

    func testParameterSetsAcceptMixedStartCodesAndExcludeAUDSEIAndSlices() throws {
        var stream = Data([0, 0, 1])
        stream.append(HEVCFixture.vps)
        stream.append(contentsOf: [0, 0, 0, 1])
        stream.append(HEVCFixture.sps)
        stream.append(contentsOf: [0, 0, 1])
        stream.append(HEVCFixture.pps)
        stream.append(contentsOf: [0, 0, 0, 1, 0x46, 1, 0x50]) // AUD
        stream.append(contentsOf: [0, 0, 1, 0x4e, 1, 0xaa]) // prefix SEI
        stream.append(contentsOf: [0, 0, 1, 0x28, 1, 0xaa]) // IDR_N_LP
        XCTAssertEqual(VideoParameterSets.extract(from: stream, codec: .hevc), HEVCFixture.config)
        let padded = Data([0xff, 0xff]) + stream
        XCTAssertEqual(VideoParameterSets.extract(from: padded[2...], codec: .hevc), HEVCFixture.config)
        for stream in [Data(), Data([0, 0, 1]), Data([0, 0, 1, 0x40]),
                       Data([0, 0, 1, 0x26, 1, 0xaa])] {
            XCTAssertNil(VideoParameterSets.extract(from: stream, codec: .hevc))
        }
    }

    func testAnnexBPackingPrependsHEVCParameterSetsOnlyOnKeyframes() {
        let raw = Data([0, 0, 0, 3, 0x26, 1, 0xaa, 0, 0, 0, 3, 0x02, 1, 0xbb])
        let slices = Data([0, 0, 0, 1, 0x26, 1, 0xaa, 0, 0, 0, 1, 0x02, 1, 0xbb])
        let sets = [HEVCFixture.vps, HEVCFixture.sps, HEVCFixture.pps]
        XCTAssertEqual(VideoEncoder.packAnnexB(lengthPrefixed: raw, parameterSets: sets,
                                              isKeyframe: true), HEVCFixture.config + slices)
        XCTAssertEqual(VideoEncoder.packAnnexB(lengthPrefixed: raw, parameterSets: sets,
                                              isKeyframe: false), slices)
        // Pin the existing H.264 prefix ordering through the same packing path.
        XCTAssertEqual(VideoEncoder.packAnnexB(lengthPrefixed: Data([0, 0, 0, 1, 0x65]),
            parameterSets: [Data([0x67]), Data([0x68])], isKeyframe: true),
            Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65]))
    }

    func testParsesMainProfileAndLevelFromRealHEVCSPSAndVPS() throws {
        for nalu in [HEVCFixture.sps, HEVCFixture.vps] {
            let profile = try XCTUnwrap(HEVCProfileTierLevel(nalu: nalu))
            XCTAssertEqual(profile.profileIDC, 1) // Main (8-bit)
            XCTAssertEqual(profile.levelIDC, 183) // Level 6.1
            let padded = Data([0xff, 0xff]) + nalu
            XCTAssertEqual(HEVCProfileTierLevel(nalu: padded[2...]), profile)
            for length in 0..<14 { XCTAssertNil(HEVCProfileTierLevel(nalu: nalu.prefix(length))) }
        }
        XCTAssertNil(HEVCProfileTierLevel(nalu: HEVCFixture.pps))
        XCTAssertNil(HEVCProfileTierLevel(nalu: Data([0x67, 0x64, 0, 0x2a])))
    }
}
