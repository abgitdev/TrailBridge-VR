import XCTest
import CoreAudio
@testable import BasaltCore

final class MacAudioTapTests: XCTestCase {
    // MARK: Options

    func testGameAudioMacNeedsHeadsetModeAndExcludesLoopbackDevice() throws {
        let options = try XCTUnwrap(StreamerOptions.parse(["--wired", "--game-audio", "mac"]))
        XCTAssertTrue(options.captureMacAudio)
        XCTAssertNil(options.audioDeviceName)
        XCTAssertTrue(try XCTUnwrap(StreamerOptions.parse(["--wireless", "--game-audio", "MAC"]))
            .captureMacAudio)
        XCTAssertThrowsError(try StreamerOptions.parse(["--game-audio", "mac"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--game-audio", "speakers"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--game-audio"]))
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--wired", "--game-audio", "mac", "--audio-device", "BlackHole 2ch"]))
    }

    func testEnvironmentSwitchReplacesTheChosenLoopbackDevice() throws {
        let options = try XCTUnwrap(StreamerOptions.parse(
            ["--wireless", "--audio-device", "BlackHole 2ch", "--route-audio"],
            environment: ["BASALT_GAME_AUDIO": "mac"]))
        XCTAssertTrue(options.captureMacAudio)
        XCTAssertNil(options.audioDeviceName)
        XCTAssertFalse(options.routeAudioToCaptureDevice)
        XCTAssertEqual(options.replacedAudioDeviceName, "BlackHole 2ch")
    }

    func testEnvironmentSwitchKeepsGameAudioOff() throws {
        let options = try XCTUnwrap(StreamerOptions.parse(
            ["--wireless"], environment: ["BASALT_GAME_AUDIO": "mac"]))
        XCTAssertFalse(options.captureMacAudio)
        XCTAssertNil(options.replacedAudioDeviceName)
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--wireless"], environment: ["BASALT_GAME_AUDIO": "blackhole"]))
        XCTAssertFalse(try XCTUnwrap(StreamerOptions.parse(
            ["--wireless", "--audio-device", "BlackHole 2ch"], environment: ["BASALT_GAME_AUDIO": ""]))
            .captureMacAudio)
    }

    // MARK: Plan

    private func device(_ id: AudioObjectID, _ name: String, builtIn: Bool = false,
                        inputs: Bool = false) -> MacAudioClockCandidate {
        MacAudioClockCandidate(id: id, uid: "uid-\(id)", name: name,
                               isBuiltIn: builtIn, hasInputStreams: inputs)
    }

    func testClockPrefersBuiltInOutputOverBluetoothDefault() {
        let candidates = [device(1, "Display"), device(2, "Bluetooth speaker"),
                          device(3, "Mac mini Speakers", builtIn: true)]
        XCTAssertEqual(MacAudioTapPlan.clock(among: candidates, defaultOutputID: 2)?.id, 3)
    }

    func testClockFallsBackToDefaultThenAnyOutputWithoutInputs() {
        XCTAssertEqual(MacAudioTapPlan.clock(
            among: [device(1, "Display"), device(2, "Speaker")], defaultOutputID: 2)?.id, 2)
        XCTAssertEqual(MacAudioTapPlan.clock(
            among: [device(1, "Interface", inputs: true), device(2, "Display")],
            defaultOutputID: 1)?.id, 2)
        XCTAssertEqual(MacAudioTapPlan.clock(
            among: [device(1, "Interface", inputs: true)], defaultOutputID: nil)?.id, 1)
        XCTAssertNil(MacAudioTapPlan.clock(among: [], defaultOutputID: nil))
    }

    func testAggregateIsPrivateClockedAndHoldsTheTapWithDriftCompensation() throws {
        let description = MacAudioTapPlan.aggregateDescription(
            aggregateUID: "aggregate", clockUID: "speakers", tapUID: "tap")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Int, 1)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Int, 0)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Int, 0)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "speakers")
        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, "aggregate")
        let subDevices = try XCTUnwrap(
            description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        XCTAssertEqual(subDevices.compactMap { $0[kAudioSubDeviceUIDKey] as? String }, ["speakers"])
        let taps = try XCTUnwrap(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?[kAudioSubTapUIDKey] as? String, "tap")
        XCTAssertEqual(taps.first?[kAudioSubTapDriftCompensationKey] as? Int, 1)
    }

    // MARK: Silence and level

    func testSilenceWatchWarnsOnceAfterTenSilentSecondsWhileSomethingPlays() {
        var watch = MacAudioSilenceWatch()
        for _ in 0..<9 {
            XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        }
        XCTAssertTrue(watch.needsPlayingCheck)
        XCTAssertEqual(watch.record(capturedExactSilence: true, otherProcessPlaying: true),
                       .neverHeardSound)
        XCTAssertFalse(watch.needsPlayingCheck)
        for _ in 0..<20 {
            XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        }
    }

    func testSilenceWatchStaysQuietForRealSilenceAndRestartsAfterSound() {
        var watch = MacAudioSilenceWatch(seconds: 3)
        for _ in 0..<30 {
            XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: false))
        }
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: false, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertEqual(watch.record(capturedExactSilence: true, otherProcessPlaying: true),
                       .wentQuiet)
    }

    /// A game that loses the front on the Mac goes quiet mid-session; that
    /// is not the missing permission, and each new stretch warns again.
    func testSilenceAfterSoundWarnsOncePerStretch() {
        var watch = MacAudioSilenceWatch(seconds: 2)
        XCTAssertNil(watch.record(capturedExactSilence: false, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertEqual(watch.record(capturedExactSilence: true, otherProcessPlaying: true),
                       .wentQuiet)
        XCTAssertFalse(watch.needsPlayingCheck)
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertNil(watch.record(capturedExactSilence: false, otherProcessPlaying: false))
        XCTAssertTrue(watch.needsPlayingCheck)
        XCTAssertNil(watch.record(capturedExactSilence: true, otherProcessPlaying: true))
        XCTAssertEqual(watch.record(capturedExactSilence: true, otherProcessPlaying: true),
                       .wentQuiet)
    }

    func testLevelMeterReportsPeakSilenceAndNothing() throws {
        let meter = AudioLevelMeter()
        XCTAssertNil(meter.takePeakDecibels())
        meter.record(pcm16Stereo: try StereoPCM16Encoder.encode(left: [0, 0], right: [0, 0]))
        XCTAssertEqual(meter.takePeakDecibels(), -.infinity)
        meter.record(pcm16Stereo: try StereoPCM16Encoder.encode(left: [0.5, -0.25], right: [0, 0]))
        meter.record(pcm16Stereo: try StereoPCM16Encoder.encode(left: [0.1], right: [-1]))
        XCTAssertEqual(try XCTUnwrap(meter.takePeakDecibels()), 0, accuracy: 0.01)
        XCTAssertNil(meter.takePeakDecibels())
    }

    func testAudioSendLineNamesPeakOrSilenceAndStaysOutOfDashboard() {
        let loud = StreamReport.audioSendLine(
            transport: "Wi-Fi", blocksPerSecond: 93.8, pcmMegabits: 1.536, wireMegabits: 1.563,
            maximumWriteMilliseconds: 0.1, drops: 0, peakDecibels: -6.02)
        XCTAssertTrue(loud.hasSuffix("0 drop(s), peak -6.0 dBFS"), loud)
        let silent = StreamReport.audioSendLine(
            transport: "Wi-Fi", blocksPerSecond: 93.8, pcmMegabits: 1.536, wireMegabits: 1.563,
            maximumWriteMilliseconds: 0.1, drops: 0, peakDecibels: -.infinity)
        XCTAssertTrue(silent.hasSuffix("peak silence"), silent)
        XCTAssertNil(StreamReport.parse(loud))
        XCTAssertNil(StreamReport.parse(silent))
    }

    // MARK: Blocks

    private func decode(_ block: Data) -> [Int16] {
        block.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) } }
    }

    func testFortyEightKilohertzPassesThroughIn512FrameBlocks() throws {
        let maker = try MacAudioBlockMaker(inputRate: 48_000)
        var interleaved = [Float]()
        for frame in 0..<1_000 {
            interleaved += [Float(frame % 100) / 200, -Float(frame % 100) / 200]
        }
        let first = try interleaved.withUnsafeBufferPointer { try maker.blocks(fromInterleaved: $0) }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.count, MacAudioBlockMaker.blockFrames * 4)
        let samples = decode(try XCTUnwrap(first.first))
        XCTAssertEqual(samples[2], Int16(Float(1) / 200 * 32_768))
        XCTAssertEqual(samples[3], Int16(-Float(1) / 200 * 32_768))
        let more = [Float](repeating: 0, count: 24 * 2)
        XCTAssertEqual(try more.withUnsafeBufferPointer { try maker.blocks(fromInterleaved: $0) }.count, 1)
    }

    func testFortyFourKilohertzBecomesSmoothFortyEightKilohertz() throws {
        let maker = try MacAudioBlockMaker(inputRate: 44_100)
        var blocks = [Data]()
        var frame = 0
        // One second of a 440 Hz tone in 441-frame chunks, like a Core Audio callback.
        for _ in 0..<100 {
            var chunk = [Float]()
            for _ in 0..<441 {
                let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100) * 0.5)
                chunk += [value, value]
                frame += 1
            }
            blocks += try chunk.withUnsafeBufferPointer { try maker.blocks(fromInterleaved: $0) }
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 90)
        XCTAssertLessThanOrEqual(blocks.count, 94)
        let left = blocks.flatMap(decode).enumerated().filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
        // Skip the converter's start-up, then expect no jumps at chunk joins.
        let steady = Array(left.dropFirst(2_000))
        let largestStep = zip(steady, steady.dropFirst()).map { abs(Int($1) - Int($0)) }.max() ?? 0
        XCTAssertLessThan(largestStep, 1_200)
        var crossings = 0
        for (previous, next) in zip(steady, steady.dropFirst()) where (previous < 0) != (next < 0) {
            crossings += 1
        }
        let frequency = Double(crossings) / 2 / (Double(steady.count) / 48_000)
        XCTAssertEqual(frequency, 440, accuracy: 10)
    }

    func testPacerReleasesOneBlockPerTickAndDropsTheOldestBacklog() {
        var pacer = AudioBlockPacer()
        let blocks = (0..<7).map { Data([UInt8($0)]) }
        XCTAssertEqual(pacer.add(Array(blocks[0..<2])), 0)
        XCTAssertEqual(pacer.next(), blocks[0])
        XCTAssertEqual(pacer.next(), blocks[1])
        XCTAssertNil(pacer.next())
        XCTAssertEqual(pacer.add(Array(blocks[0..<7])), 3)
        XCTAssertEqual(pacer.next(), blocks[3])
        pacer.removeAll()
        XCTAssertNil(pacer.next())
    }

    // MARK: Ring

    private func bufferList(_ channels: [[Float]], interleaved: Bool)
        -> (UnsafeMutableAudioBufferListPointer, [UnsafeMutablePointer<Float>]) {
        var storage = [UnsafeMutablePointer<Float>]()
        let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels.count)
        let frames = channels[0].count
        if interleaved {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels.count)
            for frame in 0..<frames {
                for (index, channel) in channels.enumerated() {
                    pointer[frame * channels.count + index] = channel[frame]
                }
            }
            storage.append(pointer)
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels.count),
                                  mDataByteSize: UInt32(frames * channels.count * 4),
                                  mData: pointer)
        } else {
            for (index, channel) in channels.enumerated() {
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.update(from: channel, count: frames)
                storage.append(pointer)
                list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                          mData: pointer)
            }
        }
        return (list, storage)
    }

    private func release(_ list: UnsafeMutableAudioBufferListPointer,
                         _ storage: [UnsafeMutablePointer<Float>]) {
        storage.forEach { $0.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func testRingInterleavesSeparateAndSharedChannelsAndDoublesMono() {
        let ring = InterleavedStereoRing(capacityFrames: 16)
        var (list, storage) = bufferList([[1, 2], [-1, -2]], interleaved: false)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [1, -1, 2, -2])

        (list, storage) = bufferList([[3, 4], [-3, -4]], interleaved: true)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [3, -3, 4, -4])

        (list, storage) = bufferList([[5, 6]], interleaved: false)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [5, 5, 6, 6])

        // Sub-device inputs come first; the tap is the last stereo pair.
        (list, storage) = bufferList([[9, 9], [8, 8], [7, 7]], interleaved: true)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [8, 7, 8, 7])
        XCTAssertEqual(ring.read(), [])
    }

    func testRingKeepsWhatFitsAndCountsTheOverflow() {
        let ring = InterleavedStereoRing(capacityFrames: 3)
        let (list, storage) = bufferList([[1, 2], [1, 2]], interleaved: false)
        ring.write(list)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [1, 1, 2, 2, 1, 1])
        XCTAssertEqual(ring.takeOverflow(), 1)
        XCTAssertEqual(ring.takeOverflow(), 0)
    }

    func testRingWritesAndReadsAcrossTheEndOfItsStorage() {
        let ring = InterleavedStereoRing(capacityFrames: 3)
        var (list, storage) = bufferList([[1, 2], [-1, -2]], interleaved: false)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [1, -1, 2, -2])
        // The read position is now at frame 2 of 3: this write wraps.
        (list, storage) = bufferList([[3, 4, 5], [-3, -4, -5]], interleaved: false)
        ring.write(list)
        release(list, storage)
        XCTAssertEqual(ring.read(), [3, -3, 4, -4, 5, -5])
        XCTAssertEqual(ring.takeOverflow(), 0)
    }
}
