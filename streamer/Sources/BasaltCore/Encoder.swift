import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 / HEVC encoder with bounded submission and shared diagnostics.
/// Emits Annex-B, with codec parameter sets before every keyframe.
public final class VideoEncoder {
    public typealias Output = (_ annexB: Data, _ isKeyframe: Bool, _ capturePTS: CMTime) -> Void

    public let codec: VideoCodec
    public let lowLatencyRateControlEnabled: Bool

    private let session: VTCompressionSession
    private let output: Output
    private let lock = NSLock()
    private var forceKeyframeFlag = false
    private var framesInFlight = 0
    private var averageBitrate: Int
    private let maximumFramesInFlight = 2
    private var reportedPropertyFailures = Set<String>()
    private var reportedSPS = false
    private var latencyWindow = EncodeLatencyWindow()

    /// Encoding failures are asynchronous and cannot be thrown from `encode`.
    public var onError: ((Error) -> Void)?

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    public init(width: Int, height: Int, fps: Int, bitrate: Int,
        codec: VideoCodec = .h264,
        priority: EncoderPriority = .speed, lowLatencyRateControl: Bool = true,
        allowHEVCRateControlFallback: Bool = false,
        output: @escaping Output) throws {
        self.codec = codec
        self.output = output
        averageBitrate = bitrate

        // Low-latency rate control disables lookahead and B-frames. Basalt
        // separately bounds the submission pipeline to two frames.
        var specification: [CFString: Any] = [:]
        if codec == .hevc {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
        }
        if lowLatencyRateControl {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = kCFBooleanTrue
        }

        var maybeSession: VTCompressionSession?
        func createSession() -> OSStatus {
            VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: codec.mediaCodecType,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &maybeSession)
        }
        var status = createSession()
        var effectiveLowLatency = lowLatencyRateControl
        if status != noErr, codec == .hevc, lowLatencyRateControl {
            print("encoder: HEVC session creation with low-latency RC rejected: \(status)")
            guard allowHEVCRateControlFallback else {
                throw BasaltError("HEVC low-latency RC session creation failed (\(status)); "
                    + "--allow-hevc-rc-fallback explicitly permits retry without it")
            }
            if let failedSession = maybeSession { VTCompressionSessionInvalidate(failedSession) }
            maybeSession = nil
            specification.removeValue(forKey: kVTVideoEncoderSpecification_EnableLowLatencyRateControl)
            print("encoder: explicitly allowed HEVC fallback WITHOUT low-latency RC; latency may increase")
            effectiveLowLatency = false
            status = createSession()
        }
        lowLatencyRateControlEnabled = effectiveLowLatency
        guard status == noErr, let session = maybeSession else {
            throw BasaltError("VTCompressionSessionCreate failed (\(status))")
        }
        self.session = session

        // Individual property failures are non-fatal (low-latency mode
        // rejects some keys on some OS versions); best-effort configure.
        var failures: [PropertyFailure] = []
        func set(_ key: CFString, _ value: CFTypeRef) {
            Self.setProperty(session, key: key, value: value, failures: &failures)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        let profile = codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        if codec == .h264 {
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1))
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            priority == .speed ? kCFBooleanTrue : kCFBooleanFalse)
        Self.configureBitrate(session, bitrate: bitrate, failures: &failures)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2))
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            failures.append(PropertyFailure(name: "PrepareToEncodeFrames", status: prepareStatus))
        }
        reportPropertyFailures(failures)

        // The C API writes through void* and returns a retained CF value.
        var hardwareValue: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(
            session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil, valueOut: &hardwareValue)
        let hardware = hardwareValue?.takeRetainedValue()
        let hardwareDescription = hardwareStatus == noErr
            ? (hardware as? NSNumber).map { String($0.boolValue) } ?? "unknown"
            : "unknown (status \(hardwareStatus))"
        print("encoder: hardware=\(hardwareDescription), requested profile/level="
              + "\(profile), priority=\(priority.rawValue), "
              + "low-latency-rc=\(effectiveLowLatency ? "on" : "off")")
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Forces every submitted frame out of the encoder. Adds latency, so the
    /// streaming path never calls this; tests use it for deterministic
    /// frame-in/frame-out behavior regardless of VideoToolbox's internal
    /// frame delay.
    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Request that the next encoded frame be an IDR keyframe (used when a
    /// new client connects so it can start decoding immediately).
    public func forceKeyframe() {
        lock.lock()
        forceKeyframeFlag = true
        lock.unlock()
    }

    /// The encoder target survives headset reconnects with this session.
    public var currentAverageBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        return averageBitrate
    }

    /// VideoToolbox supports changing its rate target while a session is
    /// running. Wireless feedback uses this to shed load without tearing down
    /// the OpenXR or ALVR session.
    @discardableResult
    public func updateAverageBitrate(_ bitrate: Int) -> Bool {
        guard bitrate > 0 else { return false }
        lock.lock()
        guard bitrate != averageBitrate else {
            lock.unlock()
            return true
        }
        averageBitrate = bitrate
        lock.unlock()
        var failures: [PropertyFailure] = []
        let status = Self.configureBitrate(session, bitrate: bitrate, failures: &failures)
        reportPropertyFailures(failures)
        if status != noErr {
            reportError("Could not update VideoToolbox bitrate", status: status)
            return false
        }
        return true
    }

    /// Apply the actual ALVR rate before publishing runtime readiness. These
    /// are mutable VideoToolbox properties, so reconnects can update them too.
    public func updateFrameRate(_ refreshRate: Float) throws {
        guard refreshRate.isFinite, refreshRate > 0, refreshRate <= 240 else {
            throw BasaltError("Invalid encoder refresh rate")
        }
        let properties: [(CFString, NSNumber)] = [
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: refreshRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval,
             NSNumber(value: Int((Double(refreshRate) * 2).rounded())))
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw BasaltError("Could not set negotiated encoder \(key): \(status)")
            }
        }
    }

    public var canAcceptFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return framesInFlight < maximumFramesInFlight
    }

    /// Drained by the existing transport stats window. Sorting happens outside
    /// the encoder lock; the callback only reads a clock and stores one UInt64.
    public func takeLatencyStatistics() -> EncodeLatencyStatistics? {
        lock.lock()
        let window = latencyWindow
        latencyWindow = EncodeLatencyWindow()
        lock.unlock()
        return window.statistics
    }

    /// Uses the Quest clock as VideoToolbox's per-frame metadata carrier in
    /// runtime mode. With frame reordering disabled, the identical PTS is
    /// returned alongside the corresponding encoded access unit.
    public static func presentationTime(
        questTrackingTimestampNanoseconds timestamp: UInt64
    ) -> CMTime? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return CMTime(value: Int64(timestamp), timescale: 1_000_000_000)
    }

    public static func questTrackingTimestampNanoseconds(from presentationTime: CMTime)
        -> UInt64? {
        guard presentationTime.isNumeric, presentationTime.value >= 0 else { return nil }
        let nanoseconds = CMTimeConvertScale(
            presentationTime, timescale: 1_000_000_000, method: .default)
        guard nanoseconds.isNumeric, nanoseconds.value >= 0 else { return nil }
        return UInt64(nanoseconds.value)
    }

    /// Submits a frame if one of two bounded encoder slots is available.
    /// Callers should drop new frames when both are occupied rather than
    /// build a latency queue.
    ///
    /// `completion` runs exactly once: after VideoToolbox finishes with
    /// `pixelBuffer`, or immediately when the frame is rejected.
    @discardableResult
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        lock.lock()
        guard framesInFlight < maximumFramesInFlight else {
            lock.unlock()
            completion?()
            return false
        }
        framesInFlight += 1
        let force = forceKeyframeFlag
        forceKeyframeFlag = false
        lock.unlock()

        let frameProperties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil

        var infoFlags = VTEncodeInfoFlags()
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags) { [weak self] status, infoFlags, sampleBuffer in
                let elapsed = DispatchTime.now().uptimeNanoseconds &- submittedAt
                guard let self else {
                    completion?()
                    return
                }
                self.lock.lock()
                self.framesInFlight -= 1
                self.latencyWindow.record(elapsed)
                self.lock.unlock()

                if status != noErr {
                    self.reportError("VideoToolbox encode callback failed", status: status)
                    completion?()
                    return
                }
                if !infoFlags.contains(.frameDropped), let sampleBuffer {
                    self.emit(sampleBuffer)
                }
                completion?()
            }
        guard status == noErr else {
            lock.lock()
            framesInFlight -= 1
            if force { forceKeyframeFlag = true }
            lock.unlock()
            reportError("VTCompressionSessionEncodeFrame failed", status: status)
            completion?()
            return false
        }
        return true
    }

    private func reportError(_ context: String, status: OSStatus) {
        onError?(BasaltError("\(context) (\(status))"))
    }

    private struct PropertyFailure {
        let name: String
        let status: OSStatus
    }

    private func reportPropertyFailures(_ failures: [PropertyFailure]) {
        for failure in failures {
            let message = "encoder property \(failure.name) rejected: \(failure.status)"
            lock.lock()
            let first = reportedPropertyFailures.insert(message).inserted
            lock.unlock()
            if first { print(message) }
        }
    }

    @discardableResult
    private static func setProperty(
        _ session: VTCompressionSession, key: CFString, value: CFTypeRef,
        failures: inout [PropertyFailure]
    ) -> OSStatus {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            failures.append(PropertyFailure(name: key as String, status: status))
        }
        return status
    }

    @discardableResult
    private static func configureBitrate(
        _ session: VTCompressionSession, bitrate: Int, failures: inout [PropertyFailure]
    ) -> OSStatus {
        let averageStatus = setProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate), failures: &failures)
        // AverageBitRate alone permits very large transient IDRs. A one-second
        // data-rate ceiling still allows recovery frames while preventing
        // them from monopolizing a marginal Wi-Fi queue.
        let bytesPerSecond = max(1, bitrate / 8 * 5 / 4)
        setProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray,
            failures: &failures)
        return averageStatus
    }

    // MARK: AVCC → Annex-B

    /// Rewrites AVCC framing ([4-byte big-endian length][NALU]...) as
    /// Annex-B (start-code delimited). Slice-safe; stops at the first
    /// malformed length instead of reading out of bounds.
    public static func annexB(fromAVCC raw: Data) -> Data {
        var annexB = Data()
        var offset = raw.startIndex
        while offset + 4 <= raw.endIndex {
            let naluLength = raw[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard naluLength > 0, offset + naluLength <= raw.endIndex else { break }
            annexB.append(startCode)
            annexB.append(raw[offset..<offset + naluLength])
            offset += naluLength
        }
        return annexB
    }

    static func parameterSets(from format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        func get(_ index: Int, _ pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                 _ size: UnsafeMutablePointer<Int>?, _ count: UnsafeMutablePointer<Int>?) -> OSStatus {
            if codec == .hevc {
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                    parameterSetSizeOut: size, parameterSetCountOut: count,
                    nalUnitHeaderLengthOut: nil)
            }
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                parameterSetSizeOut: size, parameterSetCountOut: count,
                nalUnitHeaderLengthOut: nil)
        }
        guard get(0, nil, nil, &count) == noErr else { return [] }
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard get(index, &pointer, &size, nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }

    /// VideoToolbox uses four-byte NAL lengths for both supported codecs.
    static func packAnnexB(lengthPrefixed raw: Data, parameterSets: [Data], isKeyframe: Bool) -> Data {
        var result = Data()
        if isKeyframe {
            for nalu in parameterSets { result.append(startCode); result.append(nalu) }
        }
        result.append(annexB(fromAVCC: raw))
        return result
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true) as? [[String: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKeyframe = !notSync

        var parameterSets = [Data]()

        // Preserve VideoToolbox's parameter-set order (HEVC: VPS, SPS, PPS).
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(from: format, codec: codec)
            for nalu in parameterSets {
                let h264Profile = codec == .h264 ? H264SPSProfile(nalu: nalu) : nil
                let hevcProfile = codec == .hevc ? HEVCProfileTierLevel(nalu: nalu) : nil
                if h264Profile != nil || hevcProfile != nil {
                    lock.lock()
                    let first = !reportedSPS
                    reportedSPS = true
                    lock.unlock()
                    if first, let profile = h264Profile {
                        print("encoder first SPS: profile_idc=\(profile.profileIDC), "
                              + "level_idc=\(profile.levelIDC)")
                    } else if first, let profile = hevcProfile {
                        print("encoder first VPS/SPS: general_profile_idc=\(profile.profileIDC), "
                              + "general_level_idc=\(profile.levelIDC)")
                    }
                }
            }
        }

        // VideoToolbox emits AVCC framing; rewrite as Annex-B.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        // Empty Data has no base address; the copy below would trap.
        guard totalLength > 0 else { return }
        var raw = Data(count: totalLength)
        let copyStatus = raw.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength,
                                       destination: buffer.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        let annexB = Self.packAnnexB(lengthPrefixed: raw, parameterSets: parameterSets, isKeyframe: isKeyframe)

        guard !annexB.isEmpty else { return }
        output(annexB, isKeyframe, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

/// Compatibility name; existing callers retain the H.264 default.
public typealias H264Encoder = VideoEncoder

/// The first three SPS payload bytes precede any variable-length fields or
/// emulation-prevention bytes. Input is one NAL unit, including its header.
struct H264SPSProfile: Equatable {
    let profileIDC: UInt8
    let levelIDC: UInt8

    init?(nalu: Data) {
        let start = nalu.startIndex
        guard nalu.count >= 4, nalu[start] & 0x80 == 0,
              nalu[start] & 0x1f == 7 else { return nil }
        profileIDC = nalu[start + 1]
        levelIDC = nalu[start + 3]
    }
}

public struct EncodeLatencyStatistics {
    public let sampleCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double
}

/// Normally holds <=480 callbacks per two-second report (CLI max 240 fps).
/// Bound storage when there is no transport draining stats: percentiles use
/// the latest 4096 callbacks, while count and maximum cover the entire window.
struct EncodeLatencyWindow {
    static let capacity = 4096
    private var samples: [UInt64] = []
    private var count = 0
    private var maximum: UInt64 = 0

    mutating func record(_ nanoseconds: UInt64) {
        if samples.count < Self.capacity {
            samples.append(nanoseconds)
        } else {
            samples[count % Self.capacity] = nanoseconds
        }
        count += 1
        maximum = max(maximum, nanoseconds)
    }

    var statistics: EncodeLatencyStatistics? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            let index = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
            return Double(sorted[index]) / 1_000_000
        }
        return EncodeLatencyStatistics(sampleCount: count,
                                       p50Milliseconds: percentile(0.5),
                                       p95Milliseconds: percentile(0.95),
                                       maximumMilliseconds: Double(maximum) / 1_000_000)
    }
}
