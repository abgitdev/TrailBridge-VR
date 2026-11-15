import XCTest
import VideoToolbox
import CoreMedia
import CoreVideo
@testable import BasaltCore

final class VideoEncoderRoundTripTests: XCTestCase {
    func testHEVCNativeRoundTrip() throws { try roundTrip(.hevc) }
    func testH264NativeRoundTrip() throws { try roundTrip(.h264) }

    private func roundTrip(_ codec: VideoCodec) throws {
        var encoderList: CFArray?
        XCTAssertEqual(VTCopyVideoEncoderList(nil, &encoderList), noErr)
        let encoders = (encoderList as? [[String: Any]]) ?? []
        guard encoders.contains(where: {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec.mediaCodecType
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }) else {
            throw XCTSkip("\(codec.label) hardware encode unavailable")
        }
        let frames = CapturedFrames()
        // Explicitly exercise the opt-in fallback if this OS rejects HEVC LLRC.
        // Production defaults remain strict; this never skips a codec/decoder error.
        let encoder = try VideoEncoder(width: 2688, height: 1408, fps: 72,
                                       bitrate: 80_000_000, codec: codec,
                                       allowHEVCRateControlFallback: true) { data, keyframe, pts in
            frames.append(data, keyframe: keyframe, pts: pts)
        }
        // Exercise mutation after PrepareToEncodeFrames, as the headset
        // handshake follows encoder creation. Keep the HEVC baseline at 72.
        let refreshRate: Int32 = codec == .h264 ? 90 : 72
        try encoder.updateFrameRate(Float(refreshRate))
        for invalid: Float in [.nan, .infinity, 0, -1, 241] {
            XCTAssertThrowsError(try encoder.updateFrameRate(invalid))
        }
        encoder.onError = { error in frames.recordError(error.localizedDescription) }
        for index in 0..<10 {
            var maybeBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2688, 1408,
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &maybeBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(maybeBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<1408 {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<2688 {
                    row[x * 4] = UInt8(truncatingIfNeeded: x / 8 + index * 13)
                    row[x * 4 + 1] = UInt8(truncatingIfNeeded: y / 8 + index * 7)
                    row[x * 4 + 2] = UInt8(truncatingIfNeeded: (x + y) / 16 + index * 3)
                    row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let completed = DispatchSemaphore(value: 0)
            XCTAssertTrue(encoder.encode(buffer, pts: CMTime(value: Int64(index), timescale: refreshRate)) {
                completed.signal()
            })
            // Flush only if needed to drain an encoder that buffers without LLRC.
            if !encoder.lowLatencyRateControlEnabled { encoder.flush() }
            XCTAssertEqual(completed.wait(timeout: .now() + 10), .success)
        }
        encoder.flush()
        XCTAssertTrue(frames.errors.isEmpty, frames.errors.joined(separator: ", "))
        XCTAssertEqual(frames.values.count, 10)
        let stats = try XCTUnwrap(encoder.takeLatencyStatistics())
        XCTAssertEqual(stats.sampleCount, 10)
        print(String(format: "native round-trip %@ 2688x1408 80Mbps %dHz: encode p50=%.3f ms p95=%.3f ms, low-latency-rc=%@",
                     codec.label, refreshRate, stats.p50Milliseconds, stats.p95Milliseconds,
                     encoder.lowLatencyRateControlEnabled ? "on" : "off (explicit fallback)"))
        let first = try XCTUnwrap(frames.values.first)
        XCTAssertTrue(first.keyframe)
        let sets = VideoParameterSets.nalUnits(from: first.data).filter { codec.isParameterSet($0) }
        XCTAssertEqual(sets.compactMap { codec.nalType($0) }, codec == .hevc ? [32, 33, 34] : [7, 8])
        if codec == .hevc {
            XCTAssertEqual(try XCTUnwrap(sets.compactMap { HEVCProfileTierLevel(nalu: $0) }.first).profileIDC, 1)
        }
        let format = try makeFormat(sets: sets, codec: codec)
        var maybeDecoder: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
            decompressionSessionOut: &maybeDecoder), noErr)
        let decoder = try XCTUnwrap(maybeDecoder)
        defer { VTDecompressionSessionInvalidate(decoder) }
        let decoded = CapturedFrames()
        for frame in frames.values {
            let nalus = VideoParameterSets.nalUnits(from: frame.data).filter { !codec.isParameterSet($0) }
            if frame.keyframe { XCTAssertTrue(nalus.contains { codec.isKeyframeNAL($0) }) }
            var avcc = Data()
            for nalu in nalus {
                var length = UInt32(nalu.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(nalu)
            }
            var maybeBlock: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0,
                blockBufferOut: &maybeBlock), kCMBlockBufferNoErr)
            let block = try XCTUnwrap(maybeBlock)
            XCTAssertEqual(avcc.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
            }, kCMBlockBufferNoErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: refreshRate),
                                            presentationTimeStamp: frame.pts, decodeTimeStamp: .invalid)
            var size = avcc.count
            var maybeSample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &maybeSample), noErr)
            let sample = try XCTUnwrap(maybeSample)
            XCTAssertEqual(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
                    if status != noErr { decoded.recordError("decode callback \(status)") }
                    if let image {
                        if CVPixelBufferGetWidth(image) != 2688 || CVPixelBufferGetHeight(image) != 1408 {
                            decoded.recordError("unexpected decoded dimensions")
                        }
                        decoded.append(Data(), keyframe: false, pts: pts)
                    }
                }, noErr)
        }
        XCTAssertEqual(VTDecompressionSessionFinishDelayedFrames(decoder), noErr)
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(decoder), noErr)
        XCTAssertEqual(decoded.values.count, 10)
        XCTAssertTrue(decoded.errors.isEmpty, decoded.errors.joined(separator: ", "))
        XCTAssertEqual(decoded.values.map(\.pts), frames.values.map(\.pts))
        print("native round-trip \(codec.label): decoded \(decoded.values.count)/10 frames without error")
    }

    private func makeFormat(sets: [Data], codec: VideoCodec) throws -> CMFormatDescription {
        // NSData keeps each pointer alive until the synchronous CoreMedia call completes.
        let storage = sets.map { $0 as NSData }
        let pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = storage.map(\.length)
        var format: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                if codec == .hevc {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil,
                        parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                        parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4,
                        extensions: nil, formatDescriptionOut: &format)
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                    parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                    parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        withExtendedLifetime(storage) {}
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
}

private final class CapturedFrames: @unchecked Sendable {
    struct Frame { let data: Data; let keyframe: Bool; let pts: CMTime }
    private let lock = NSLock()
    private var stored = [Frame]()
    private var failures = [String]()
    var values: [Frame] { lock.lock(); defer { lock.unlock() }; return stored }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    func append(_ data: Data, keyframe: Bool, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Frame(data: data, keyframe: keyframe, pts: pts))
    }
    func recordError(_ message: String) {
        lock.lock(); defer { lock.unlock() }; failures.append(message)
    }
}
