import Foundation
import CoreMedia

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc

    public var label: String { self == .h264 ? "H.264" : "HEVC" }
    public var alvrDiscriminant: UInt32 { self == .h264 ? 0 : 1 }
    /// Highest encoder bitrate whose stream stays decodable. On an Apple M4
    /// with the streamer's VideoToolbox settings, HEVC Main stays at level
    /// 6.2 through 240 Mbps, and at 300 it declares level 7.1, which the
    /// Mac's own decoder cannot decode. H.264 High stays at level 5.2 through
    /// 300 Mbps and produces no frames at 500.
    public var maximumMegabits: Int { self == .h264 ? 300 : 240 }
    var mediaCodecType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }

    /// Input includes the NAL header, without a start code; slices are supported.
    public func nalType(_ nalu: Data) -> UInt8? {
        guard let first = nalu.first else { return nil }
        // Keep the original H.264 classifier's byte behavior.
        if self == .h264 { return first & 0x1f }
        guard first & 0x80 == 0, nalu.count >= 2, nalu[nalu.startIndex + 1] & 7 != 0 else { return nil }
        return (first >> 1) & 0x3f
    }

    public func isKeyframeNAL(_ nalu: Data) -> Bool {
        guard let type = nalType(nalu) else { return false }
        return self == .h264 ? type == 5 : (16...21).contains(type)
    }

    public func isParameterSet(_ nalu: Data) -> Bool {
        guard let type = nalType(nalu) else { return false }
        return self == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }
}

public enum VideoParameterSets {
    public static let startCode = Data([0, 0, 0, 1])

    /// Splits three- and four-byte start codes without interpreting codec payloads.
    public static func nalUnits(from annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var starts = [(offset: Int, codeLength: Int)]()
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index...index + 3].elementsEqual([0, 0, 0, 1]) {
                starts.append((index, 4))
                index += 4
            } else if bytes[index...index + 2].elementsEqual([0, 0, 1]) {
                starts.append((index, 3))
                index += 3
            } else { index += 1 }
        }
        return starts.enumerated().compactMap { position, start in
            let first = start.offset + start.codeLength
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            return first < end ? Data(bytes[first..<end]) : nil
        }
    }

    /// ALVR v20.14.1: concatenated Annex-B config NALs, HEVC VPS+SPS+PPS.
    /// See server_openvr/cpp/alvr_server/NalParsing.cpp, server_core/src/lib.rs and
    /// client_core/src/video_decoder/android.rs (MediaCodec csd-0).
    public static func extract(from annexB: Data, codec: VideoCodec) -> Data? {
        let sets = nalUnits(from: annexB).filter { codec.isParameterSet($0) }
        let result = sets.reduce(into: Data()) { $0.append(startCode); $0.append($1) }
        return result.isEmpty ? nil : result
    }
}

/// General profile_tier_level in a HEVC SPS or VPS. Remove emulation-prevention
/// bytes before reading RBSP offsets: SPS PTL starts at bit 8, VPS at bit 32.
struct HEVCProfileTierLevel: Equatable {
    let profileIDC: UInt8
    let levelIDC: UInt8

    init?(nalu: Data) {
        guard let type = VideoCodec.hevc.nalType(nalu), type == 32 || type == 33 else { return nil }
        var rbsp = [UInt8]()
        var zeros = 0
        for byte in nalu.dropFirst(2) {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        let offset = type == 33 ? 1 : 4
        // general_profile_space/tier/profile_idc (1 byte), compatibility (4),
        // constraint flags (6), general_level_idc (1).
        guard rbsp.count >= offset + 12 else { return nil }
        profileIDC = rbsp[offset] & 0x1f
        levelIDC = rbsp[offset + 11]
    }
}
