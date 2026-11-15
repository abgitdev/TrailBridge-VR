import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

// MARK: - Pure pieces (unit-tested without Core Audio permission)

/// One output device as the tap's clock sees it.
public struct MacAudioClockCandidate: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
    public let hasInputStreams: Bool

    public init(id: AudioObjectID, uid: String, name: String,
                isBuiltIn: Bool, hasInputStreams: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.hasInputStreams = hasInputStreams
    }
}

public enum MacAudioTapPlan {
    /// The aggregate device needs one real output device as its clock. A
    /// built-in output never disappears mid-session, unlike a Bluetooth
    /// speaker; a device without input streams keeps the aggregate's input
    /// to the tap alone.
    public static func clock(
        among candidates: [MacAudioClockCandidate], defaultOutputID: AudioObjectID?
    ) -> MacAudioClockCandidate? {
        let outputOnly = candidates.filter { !$0.hasInputStreams }
        if let builtIn = outputOnly.first(where: \.isBuiltIn) { return builtIn }
        if let defaultOutputID,
           let preferred = outputOnly.first(where: { $0.id == defaultOutputID }) {
            return preferred
        }
        return outputOnly.first
            ?? candidates.first(where: \.isBuiltIn)
            ?? candidates.first(where: { $0.id == defaultOutputID })
            ?? candidates.first
    }

    /// A private aggregate that exists only for this process and holds the
    /// tap. `tapautostart` stays off: starting must not wait for sound.
    public static func aggregateDescription(
        aggregateUID: String, clockUID: String, tapUID: String
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "TrailBridge game audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: 1,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
    }
}

/// Warns when the tap keeps delivering exact digital silence while some
/// other process is playing. Before any sound, the likely cause is a missing
/// System Audio Recording permission: macOS reports it only this way, the tap
/// works and stays silent. After sound, the app playing went quiet; a game can
/// mute itself while its window on the Mac is not in front.
public struct MacAudioSilenceWatch: Sendable {
    public static let defaultSeconds = 10

    public enum Warning: Equatable, Sendable {
        case neverHeardSound
        case wentQuiet
    }

    private let seconds: Int
    private var silentSeconds = 0
    private var heardSound = false
    /// One warning per silent stretch; sound starts a new stretch.
    private var warnedThisStretch = false

    public init(seconds: Int = defaultSeconds) { self.seconds = seconds }

    /// Whether a silent second needs the check for another process playing.
    /// After this stretch's warning only sound matters, which needs no check.
    public var needsPlayingCheck: Bool { !warnedThisStretch }

    /// Call once per second. Returns a warning once per silent stretch.
    public mutating func record(capturedExactSilence: Bool,
                                otherProcessPlaying: Bool) -> Warning? {
        guard capturedExactSilence else {
            heardSound = true
            silentSeconds = 0
            warnedThisStretch = false
            return nil
        }
        guard otherProcessPlaying else {
            silentSeconds = 0
            return nil
        }
        silentSeconds += 1
        guard silentSeconds >= seconds, !warnedThisStretch else { return nil }
        warnedThisStretch = true
        return heardSound ? .wentQuiet : .neverHeardSound
    }
}

/// Hands blocks to the ALVR sender one per drain tick. The sender keeps a
/// single block in flight and drops a second one given at the same moment,
/// so several blocks finished together must not leave together. More than
/// `maximumWaiting` blocks (43 ms) means the sender fell behind: the oldest
/// go, because late sound is worth less than low latency.
public struct AudioBlockPacer: Sendable {
    public static let maximumWaiting = 4
    private var waiting: [Data] = []

    public init() {}

    /// Returns how many old blocks were dropped to stay within the limit.
    @discardableResult
    public mutating func add(_ blocks: [Data]) -> Int {
        waiting += blocks
        let excess = max(0, waiting.count - Self.maximumWaiting)
        if excess > 0 { waiting.removeFirst(excess) }
        return excess
    }

    public mutating func next() -> Data? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }

    public mutating func removeAll() { waiting.removeAll() }
}

/// The loudest sample in recent PCM16 blocks, for the `audio send` line.
public final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int32 = 0
    private var sawAudio = false

    public init() {}

    public func record(pcm16Stereo: Data) {
        var blockPeak: Int32 = 0
        pcm16Stereo.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let magnitude = abs(Int32(Int16(littleEndian: sample)))
                if magnitude > blockPeak { blockPeak = magnitude }
            }
        }
        lock.lock()
        sawAudio = true
        if blockPeak > peak { peak = blockPeak }
        lock.unlock()
    }

    /// dBFS of the loudest sample since the previous call; `-infinity` for
    /// exact silence and nil when no audio arrived at all.
    public func takePeakDecibels() -> Double? {
        lock.lock()
        defer {
            peak = 0
            sawAudio = false
            lock.unlock()
        }
        guard sawAudio else { return nil }
        return Self.decibels(peak: peak)
    }

    public static func decibels(peak: Int32) -> Double {
        guard peak > 0 else { return -.infinity }
        return 20 * log10(Double(peak) / 32_768)
    }
}

/// Converts interleaved Float32 stereo at any rate to 48 kHz and cuts it
/// into the 512-frame PCM16 blocks the ALVR audio stream already carries.
public final class MacAudioBlockMaker {
    public static let outputRate = 48_000.0
    public static let blockFrames = 512

    public let inputRate: Double
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []

    public init(inputRate: Double) throws {
        guard inputRate > 0,
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                channels: 2, interleaved: true),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate,
                channels: 2, interleaved: false) else {
            throw BasaltError("Unsupported Mac audio rate \(inputRate) Hz")
        }
        self.inputRate = inputRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputRate == Self.outputRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw BasaltError("Cannot convert Mac audio from \(Int(inputRate)) Hz to 48000 Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }

    /// Takes interleaved stereo frames and returns every complete PCM16
    /// block they finish. The resampler keeps its state between calls, so
    /// chunk boundaries do not click.
    public func blocks(fromInterleaved samples: UnsafeBufferPointer<Float>) throws -> [Data] {
        let frames = samples.count / 2
        guard frames > 0 else { return [] }
        if let converter {
            try convert(samples, frames: frames, with: converter)
        } else {
            pendingLeft.reserveCapacity(pendingLeft.count + frames)
            pendingRight.reserveCapacity(pendingRight.count + frames)
            for frame in 0..<frames {
                pendingLeft.append(samples[frame * 2])
                pendingRight.append(samples[frame * 2 + 1])
            }
        }
        var result = [Data]()
        while pendingLeft.count >= Self.blockFrames {
            let left = Array(pendingLeft.prefix(Self.blockFrames))
            let right = Array(pendingRight.prefix(Self.blockFrames))
            pendingLeft.removeFirst(Self.blockFrames)
            pendingRight.removeFirst(Self.blockFrames)
            result.append(try StereoPCM16Encoder.encode(left: left, right: right))
        }
        return result
    }

    private func convert(_ samples: UnsafeBufferPointer<Float>, frames: Int,
                         with converter: AVAudioConverter) throws {
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw BasaltError("Could not allocate the Mac audio input buffer")
        }
        input.frameLength = AVAudioFrameCount(frames)
        if let destination = input.floatChannelData?[0], let source = samples.baseAddress {
            destination.update(from: source, count: frames * 2)
        }
        let capacity = AVAudioFrameCount(
            (Double(frames) * Self.outputRate / inputRate).rounded(.up) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw BasaltError("Could not allocate the Mac audio output buffer")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw BasaltError("Mac audio conversion failed: "
                + (conversionError?.localizedDescription ?? "unknown error"))
        }
        let produced = Int(output.frameLength)
        guard produced > 0, let channels = output.floatChannelData else { return }
        pendingLeft.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: produced))
        pendingRight.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: produced))
    }
}

// MARK: - Core Audio tap

/// Captures what the Mac plays, except the excluded processes, through a
/// Core Audio process tap and a private aggregate device. The tap mutes the
/// Mac's own playback only while this process reads it, so Stop, a crash or
/// a kill gives the sound back to the Mac without any restore step.
@available(macOS 14.2, *)
public final class MacAudioTap: @unchecked Sendable {
    public var onPCM16: ((Data) -> Void)?
    /// Human-readable notes for the session log.
    public var onEvent: ((String) -> Void)?

    public private(set) var clockName = ""
    public private(set) var formatText = ""

    private let excludedProcessIDs: [pid_t]
    private let mutesMac: Bool
    private let queue = DispatchQueue(label: "basalt.audio.mac-tap", qos: .userInteractive)
    /// Core Audio waits for running listener blocks when one is removed, so
    /// they must not share `queue`, which removes them.
    private let listenerQueue = DispatchQueue(label: "basalt.audio.mac-tap.listener")
    private let ring = InterleavedStereoRing(capacityFrames: 48_000 * 2)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var clockID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var blockMaker: MacAudioBlockMaker?
    private var drainTimer: DispatchSourceTimer?
    private var silenceWatch = MacAudioSilenceWatch()
    private var secondPeak: Float = 0
    private var secondFrames = 0
    private var inputRate = 48_000.0
    private var running = false
    /// Set once by stop(); a start() still waiting on another thread must
    /// not bring the tap back after the session ended.
    private var stopRequested = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var skippedCallbacks = 0
    private var lastSkipNote: DispatchTime?
    private var lastErrorNote: DispatchTime?
    private var pacer = AudioBlockPacer()
    private var silentDrainTicks = 0
    private var lastRebuild: DispatchTime?
    private var nominalRateAtBuild: Double?
    private var receivedSinceBuild = false

    /// `excludingProcessIDs` keeps TrailBridge's own processes out of the
    /// mix; the self-test passes none so its tone is captured.
    public init(excludingProcessIDs: [pid_t], mutesMac: Bool = true) {
        excludedProcessIDs = excludingProcessIDs
        self.mutesMac = mutesMac
    }

    /// Starts capturing. macOS may show its System Audio Recording prompt
    /// here, so callers on a startup path run this off their own thread.
    public func start() throws {
        try queue.sync {
            guard !running, !stopRequested else { return }
            try build()
            running = true
            installListeners()
            startDrainTimer()
        }
    }

    /// Stops and destroys the tap and its device. Waits at most two seconds,
    /// so shutdown never hangs on Core Audio; the private objects die with
    /// the process anyway.
    @discardableResult
    public func stop() -> Bool {
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            stopRequested = true
            running = false
            drainTimer?.cancel()
            drainTimer = nil
            removeListeners()
            tearDown()
            finished.signal()
        }
        return finished.wait(timeout: .now() + 2) == .success
    }

    /// Builds the tap and aggregate without starting IO, so no permission
    /// prompt appears; for `audio-tap-selftest --describe`.
    public func describe() throws -> String {
        try queue.sync {
            try build(startIO: false)
            defer { tearDown() }
            return "clock \(clockName); \(formatText)"
        }
    }

    // MARK: Build and tear down (always on `queue`)

    private func build(startIO: Bool = true) throws {
        let excluded = excludedProcessIDs.compactMap(MacAudioHardware.processObject(for:))
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "TrailBridge game audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = mutesMac ? .mutedWhenTapped : .unmuted
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try MacAudioHardware.check(
            AudioHardwareCreateProcessTap(description, &newTap), "create the Mac audio tap")
        tapID = newTap

        do {
            let candidates = try MacAudioHardware.outputDevices()
            guard let clock = MacAudioTapPlan.clock(
                among: candidates, defaultOutputID: MacAudioHardware.defaultOutputDevice()) else {
                throw BasaltError("No Mac audio output device can clock the game audio tap")
            }
            let composition = MacAudioTapPlan.aggregateDescription(
                aggregateUID: "local.trailbridge.game-audio.\(UUID().uuidString)",
                clockUID: clock.uid, tapUID: description.uuid.uuidString)
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            try MacAudioHardware.check(
                AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate),
                "create the game audio device")
            aggregateID = newAggregate
            clockID = clock.id
            // A device name can carry a person's name ("Ada's AirPods"), and
            // session logs end up in diagnostic reports: say only its kind.
            clockName = clock.isBuiltIn ? "built-in output"
                : clock.id == MacAudioHardware.defaultOutputDevice() ? "default output"
                : "another output"

            let format = try MacAudioHardware.inputFormat(of: newAggregate)
                ?? MacAudioHardware.tapFormat(newTap)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw BasaltError("The Mac audio tap delivers an unsupported format")
            }
            inputRate = format.mSampleRate
            nominalRateAtBuild = MacAudioHardware.nominalSampleRate(newAggregate)
            formatText = "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, Float32"
            blockMaker = try MacAudioBlockMaker(inputRate: format.mSampleRate)
            ring.reset()

            guard startIO else { return }
            let ring = self.ring
            var procID: AudioDeviceIOProcID?
            try MacAudioHardware.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, newAggregate, nil) {
                    _, inputData, _, _, _ in
                    // Real-time thread: copy only, never wait.
                    ring.write(UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: inputData)))
                }, "attach to the game audio device")
            ioProcID = procID
            try MacAudioHardware.check(
                AudioDeviceStart(newAggregate, procID), "start the game audio device")
        } catch {
            tearDown()
            throw error
        }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        clockID = AudioObjectID(kAudioObjectUnknown)
        blockMaker = nil
        pacer.removeAll()
        silentDrainTicks = 0
        receivedSinceBuild = false
        secondPeak = 0
        secondFrames = 0
    }

    // MARK: Draining (on `queue`)

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()
    }

    /// Notes that could repeat every tick reach the log at most every 10 s.
    private func throttledNote(_ last: inout DispatchTime?, _ text: @autoclosure () -> String) {
        let now = DispatchTime.now()
        guard last.map({ now >= $0 + .seconds(10) }) ?? true else { return }
        last = now
        onEvent?(text())
    }

    private func drain() {
        guard running, let blockMaker else { return }
        skippedCallbacks += ring.takeOverflow()
        if skippedCallbacks > 0,
           lastSkipNote.map({ DispatchTime.now() >= $0 + .seconds(10) }) ?? true {
            onEvent?("skipped \(skippedCallbacks) Mac audio block(s) to keep latency bounded")
            skippedCallbacks = 0
            lastSkipNote = DispatchTime.now()
        }
        let samples = ring.read()
        if samples.isEmpty {
            // About 3 s without a callback after audio had flowed: the device
            // stopped. Build again. A device that never delivered is left
            // alone, so a pending permission prompt cannot cause a loop.
            if receivedSinceBuild { silentDrainTicks += 1 }
            if silentDrainTicks >= 600 {
                silentDrainTicks = 0
                rebuild(reason: "no Mac audio arrived for 3 seconds")
            }
        } else {
            silentDrainTicks = 0
            receivedSinceBuild = true
            if measureAndRebuildIfClockChanged(samples) { return }
            do {
                skippedCallbacks += pacer.add(try samples.withUnsafeBufferPointer {
                    try blockMaker.blocks(fromInterleaved: $0)
                })
            } catch {
                throttledNote(&lastErrorNote, error.localizedDescription)
            }
        }
        if let block = pacer.next() {
            onPCM16?(block)
        }
    }

    /// Once a second: the silence watch and a changed clock rate. Returns
    /// true when the tap was rebuilt and these samples belong to the old one.
    private func measureAndRebuildIfClockChanged(_ samples: [Float]) -> Bool {
        secondPeak = max(secondPeak, samples.reduce(Float(0)) { max($0, abs($1)) })
        secondFrames += samples.count / 2
        guard Double(secondFrames) >= inputRate else { return false }
        let silent = secondPeak == 0
        secondPeak = 0
        secondFrames = 0
        if let built = nominalRateAtBuild,
           let rate = MacAudioHardware.nominalSampleRate(aggregateID), rate > 0, rate != built {
            rebuild(reason: "the Mac audio clock changed from \(Int(built)) to \(Int(rate)) Hz")
            return true
        }
        guard !silent || silenceWatch.needsPlayingCheck else { return false }
        let othersPlaying = silent
            && MacAudioHardware.anyProcessPlaying(excluding: excludedProcessIDs)
        switch silenceWatch.record(capturedExactSilence: silent, otherProcessPlaying: othersPlaying) {
        case .neverHeardSound?:
            onEvent?("only silence for 10 s while another app has audio running. If the "
                + "headset stays silent, allow TrailBridge VR in System Settings > Privacy & "
                + "Security > Screen & System Audio Recording, or choose BlackHole")
        case .wentQuiet?:
            onEvent?("only silence for 10 s after sound played, while another app has audio "
                + "running. A game can mute itself while its window on the Mac is not in front")
        case nil:
            break
        }
        return false
    }

    // MARK: Device changes

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            // Object IDs can be reused after coreaudiod restarts, so "still
            // alive" proves nothing then: always build again.
            let restarted = UnsafeBufferPointer(start: addresses, count: Int(count))
                .contains { $0.mSelector == kAudioHardwarePropertyServiceRestarted }
            self.queue.async {
                if restarted {
                    self.rebuild(reason: "Core Audio restarted")
                } else {
                    self.rebuildIfNeeded()
                }
            }
        }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] {
            var address = MacAudioHardware.address(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        }
    }

    private func removeListeners() {
        guard let listenerBlock else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] {
            var address = MacAudioHardware.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listenerBlock)
        }
        self.listenerBlock = nil
    }

    /// The clock device can vanish (a speaker unplugged) and coreaudiod can
    /// restart; both stop the IO. Build everything again in either case.
    private func rebuildIfNeeded() {
        guard running else { return }
        let alive = clockID != kAudioObjectUnknown && aggregateID != kAudioObjectUnknown
            && MacAudioHardware.isAlive(clockID) && MacAudioHardware.isAlive(aggregateID)
        if !alive { rebuild(reason: "the Mac audio clock device went away") }
    }

    /// At most one rebuild every 5 s, so a device that keeps failing cannot
    /// make a loop.
    private func rebuild(reason: String) {
        guard running else { return }
        let now = DispatchTime.now()
        if let lastRebuild, now < lastRebuild + .seconds(5) { return }
        lastRebuild = now
        tearDown()
        // After a coreaudiod restart the old listeners are gone as well.
        removeListeners()
        installListeners()
        do {
            try build()
            onEvent?("\(reason); the tap was rebuilt on \(clockName) (\(formatText))")
        } catch {
            onEvent?("\(reason) and the tap could not be rebuilt: " + error.localizedDescription)
        }
    }
}

// MARK: - Real-time ring buffer

/// Single-producer, single-consumer buffer of interleaved stereo Float32.
/// The real-time writer only tries the lock; if the reader holds it, the
/// writer skips that callback and counts it instead of waiting.
final class InterleavedStereoRing: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// The reader copies here under the lock and allocates only after
    /// releasing it, so the writer rarely finds the lock taken.
    private let scratch: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var count = 0
    private var overflow = 0
    /// Callbacks skipped because the reader held the lock. Only the writer
    /// touches it; it is added to `overflow` once the writer has the lock.
    private var missedWhileLocked = 0

    init(capacityFrames: Int) {
        capacity = capacityFrames * 2
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        scratch = .allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        scratch.deallocate()
    }

    /// Only while no IO runs: after a rebuild the new IO thread is the writer.
    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        count = 0
        overflow = 0
        missedWhileLocked = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Mono is copied to both sides; with more than two channels the last
    /// two are the tap's stereo pair (sub-device inputs come first). Runs on
    /// Core Audio's real-time thread: no allocation, no waiting.
    func write(_ buffers: UnsafeMutableAudioBufferListPointer) {
        var left: UnsafePointer<Float>?
        var leftStride = 1
        var right: UnsafePointer<Float>?
        var rightStride = 1
        var frames = Int.max
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            frames = min(frames,
                         Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount))
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            for channel in 0..<channelCount {
                left = right
                leftStride = rightStride
                right = base + channel
                rightStride = channelCount
            }
        }
        guard let right, frames != Int.max, frames > 0 else { return }
        let leftChannel = left ?? right
        if left == nil { leftStride = rightStride }

        guard os_unfair_lock_trylock(&lock) else {
            missedWhileLocked &+= 1
            return
        }
        defer { os_unfair_lock_unlock(&lock) }
        overflow &+= missedWhileLocked
        missedWhileLocked = 0
        let writable = min(frames, (capacity - count) / 2)
        if writable < frames { overflow &+= 1 }
        var writeIndex = (readIndex + count) % capacity
        for frame in 0..<writable {
            storage[writeIndex] = leftChannel[frame * leftStride]
            storage[writeIndex + 1] = right[frame * rightStride]
            writeIndex = (writeIndex + 2) % capacity
        }
        count += writable * 2
    }

    func read() -> [Float] {
        os_unfair_lock_lock(&lock)
        let taken = count
        let first = min(taken, capacity - readIndex)
        scratch.update(from: storage + readIndex, count: first)
        if first < taken {
            (scratch + first).update(from: storage, count: taken - first)
        }
        readIndex = (readIndex + taken) % capacity
        count = 0
        os_unfair_lock_unlock(&lock)
        return Array(UnsafeBufferPointer(start: scratch, count: taken))
    }

    func takeOverflow() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let value = overflow
        overflow = 0
        return value
    }
}

// MARK: - Core Audio helpers

enum MacAudioHardware {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status != noErr else { return }
        throw BasaltError("Could not \(action) (Core Audio status \(statusText(status)))")
    }

    static func statusText(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return String(status)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        uint32(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : AudioObjectID($0) }
    }

    static func outputDevices() throws -> [MacAudioClockCandidate] {
        objectList(kAudioHardwarePropertyDevices).compactMap { id in
            guard hasStreams(id, scope: kAudioDevicePropertyScopeOutput),
                  uint32(id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MacAudioClockCandidate(
                id: id, uid: uid, name: name,
                isBuiltIn: uint32(id, kAudioDevicePropertyTransportType)
                    == kAudioDeviceTransportTypeBuiltIn,
                hasInputStreams: hasStreams(id, scope: kAudioDevicePropertyScopeInput))
        }
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format),
                  "read the Mac audio tap format")
        return format
    }

    /// The format of the last input stream: the tap follows the clock
    /// device's streams in the aggregate.
    static func inputFormat(of device: AudioObjectID) throws -> AudioStreamBasicDescription? {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
              let last = streams.last else { return nil }
        var formatAddress = Self.address(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(last, &formatAddress, 0, nil, &formatSize, &format)
            == noErr else { return nil }
        return format
    }

    /// Whether any process other than the excluded ones is playing now.
    static func anyProcessPlaying(excluding pids: [pid_t]) -> Bool {
        objectList(kAudioHardwarePropertyProcessObjectList).contains { process in
            guard uint32(process, kAudioProcessPropertyIsRunningOutput) == 1 else { return false }
            var address = address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else {
                return true
            }
            return !pids.contains(pid)
        }
    }
}
