import Foundation
import AVFoundation
import BasaltCore

/// `basalt-streamer audio-tap-selftest [--describe] [--seconds N]`
///
/// Plays a quiet 440 Hz tone and checks that the Mac audio tap hears it.
/// Starting the tap is what makes macOS ask for System Audio Recording, so
/// this also asks for the permission while the person is at the Mac. A tap
/// without the permission delivers exact silence, which fails the test.
/// `--describe` builds the tap and its device without starting them: no
/// prompt, no sound, only the clock device and the format.
enum AudioTapSelfTest {
    private final class Measurement: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var peak: Int32 = 0
        private var crossings = 0
        private var previous: Int16 = 0

        func consume(_ pcm: Data) {
            lock.lock()
            defer { lock.unlock() }
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                var index = 0
                while index + 1 < samples.count {
                    let left = Int16(littleEndian: samples[index])
                    peak = max(peak, abs(Int32(left)))
                    if (previous < 0) != (left < 0) { crossings += 1 }
                    previous = left
                    index += 2
                }
                frames += samples.count / 2
            }
        }

        /// Peak in dBFS and the tone frequency estimated from zero crossings.
        func result() -> (frames: Int, peakDecibels: Double, frequency: Double) {
            lock.lock()
            defer { lock.unlock() }
            let seconds = Double(frames) / MacAudioBlockMaker.outputRate
            return (frames, AudioLevelMeter.decibels(peak: peak),
                    seconds > 0 ? Double(crossings) / 2 / seconds : 0)
        }

        func reset() {
            lock.lock()
            frames = 0
            peak = 0
            crossings = 0
            lock.unlock()
        }
    }

    static func run(_ arguments: [String]) {
        var describeOnly = false
        var seconds = 20.0
        var remaining = arguments
        while !remaining.isEmpty {
            let flag = remaining.removeFirst()
            switch flag {
            case "--describe": describeOnly = true
            case "--seconds" where !remaining.isEmpty:
                seconds = Double(remaining.removeFirst()) ?? seconds
            default:
                fputs("usage: basalt-streamer audio-tap-selftest [--describe] [--seconds N]\n", stderr)
                exit(2)
            }
        }
        guard #available(macOS 14.2, *) else {
            fputs("FAIL: capturing the Mac's own output needs macOS 14.2 or newer\n", stderr)
            exit(1)
        }
        do {
            // The tone is this process's own sound, so nothing is excluded.
            let tap = MacAudioTap(excludingProcessIDs: [])
            if describeOnly {
                print("Mac audio tap: \(try tap.describe())")
                return
            }
            let measurement = Measurement()
            tap.onPCM16 = { measurement.consume($0) }
            tap.onEvent = { print("note: \($0)") }

            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
                  let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
                  let channels = tone.floatChannelData else {
                throw BasaltError("Could not allocate the test tone")
            }
            tone.frameLength = tone.frameCapacity
            for frame in 0..<Int(tone.frameLength) {
                let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000) * 0.1)
                channels[0][frame] = value
                channels[1][frame] = value
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.scheduleBuffer(tone, at: nil, options: [.loops])
            player.play()
            defer {
                player.stop()
                engine.stop()
            }

            try tap.start()
            defer { tap.stop() }
            print("Tap \(tap.formatText), clock \(tap.clockName). "
                + "Playing a quiet 440 Hz tone; the Mac stays silent while the tap reads it.")
            print("If macOS asks to record this computer's audio, allow it.")

            // Look at one second at a time: the permission can arrive late.
            let deadline = Date().addingTimeInterval(seconds)
            var last = measurement.result()
            while Date() < deadline {
                measurement.reset()
                Thread.sleep(forTimeInterval: 1)
                last = measurement.result()
                if last.frames > 24_000, last.peakDecibels > -30,
                   abs(last.frequency - 440) < 40 {
                    print("PASS: the tap captured the tone at "
                        + String(format: "%.1f dBFS, about %.0f Hz", last.peakDecibels, last.frequency)
                        + " (\(last.frames) frames in the last second, 48000 Hz stereo)")
                    return
                }
            }
            let level = last.peakDecibels.isFinite
                ? String(format: "peak %.1f dBFS, about %.0f Hz", last.peakDecibels, last.frequency)
                : "exact silence"
            throw BasaltError("the tap did not hear the tone: \(level), \(last.frames) frames "
                + "in the last second. Exact silence means System Audio Recording is not "
                + "allowed: System Settings > Privacy & Security > Screen & System Audio Recording")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
