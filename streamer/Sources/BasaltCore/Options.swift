import Foundation
import Network

public enum EncoderPriority: String, CaseIterable, Sendable {
    case speed, quality
}

public enum QuestPostProcessingLevel: String, CaseIterable, Sendable {
    case off, normal, quality

    // ALVR v20.14.1 session settings use schema choices, not Rust enum strings.
    var alvrVariant: String {
        switch self {
        case .off: "Disabled"
        case .normal: "Normal"
        case .quality: "Quality"
        }
    }
}

/// Command-line options for the streamer. Parsing is pure so it can be
/// unit-tested.
///
/// `bindHost` defaults to loopback: running the demo never exposes the
/// screen stream beyond the local machine unless the user opts in with
/// `--bind`.
public struct StreamerOptions: Equatable {
    public static let fpsRange = 1...240
    /// The selected codec may allow less; see `VideoCodec.maximumMegabits`.
    public static let megabitsRange = 1...(VideoCodec.allCases.map(\.maximumMegabits).max() ?? 240)

    public var port: UInt16 = 9999
    /// `--port` or `--bind` was given: the caller wants the debug stream.
    public var debugStreamRequested = false
    public var fps = 72
    public var megabits = 30
    public var perEyeResolution = PerEyeResolution.quality
    public var latencyPreset = StreamLatencyPreset.low
    public var codec = VideoCodec.h264
    public var allowHEVCRateControlFallback = false
    public var encoderPriority = EncoderPriority.speed
    public var lowLatencyRateControl = true
    public var questSupersampling = QuestPostProcessingLevel.off
    public var questSharpening = QuestPostProcessingLevel.off
    public var bindHost = "127.0.0.1"
    public var discover = false
    public var wired = false
    public var trustFile: String?
    public var runtimeControlFile: String?
    /// Diagnostic copy of the encoded stream; off unless given.
    public var recordVideoFile: String?
    public var audioDeviceName: String?
    public var routeAudioToCaptureDevice = false
    public var listAudioDevices = false
    /// Capture what the Mac plays through a Core Audio process tap
    /// (macOS 14.2+) instead of a loopback device such as BlackHole.
    public var captureMacAudio = false
    /// The loopback device that `BASALT_GAME_AUDIO=mac` replaced, for the log.
    public var replacedAudioDeviceName: String?

    public init() {}

    public static let usage = """
        usage: basalt-streamer [options]

        Captures the main display, hardware-encodes H.264 or HEVC (low-latency),
        and serves the raw Annex-B stream to connected TCP clients.

        options:
          --port <n>    TCP port to listen on (default 9999); with --wireless
                        or --wired the port opens only if --port or --bind
                        is given
          --fps <n>     capture frame rate, 1–240 (default 72)
          --mbps <n>    encoder bitrate in Mbit/s, 1–300 for H.264, 1–240 for HEVC (default 30)
          --resolution <preset|WIDTHxHEIGHT>
                        per-eye headset resolution: performance (896x944),
                        balanced (1152x1216), quality (1344x1408, default),
                        or custom even dimensions
          --latency <balanced|low|ultra>
                        Quest decoder buffering (default low; ultra targets
                        one frame with less history and may expose jitter)
          --codec <h264|hevc>
                        video codec (default h264; HEVC Main 8-bit is opt-in)
          --allow-hevc-rc-fallback
                        allow HEVC session creation without low-latency RC
                        only if creation with it fails (may add latency)
          --encoder-priority <speed|quality>
                        VideoToolbox encoding priority (default speed)
          --low-latency-rc <on|off>
                        request low-latency rate control (default on);
                        off omits the encoder specification key
          --quest-supersampling <off|normal|quality>
          --quest-sharpening <off|normal|quality>
                        Quest compositor effects (default both off: omit key).
                        off maps to ALVR Disabled when the other effect is on
          --bind <ip>   address to listen on (default 127.0.0.1, i.e.
                        this machine only; 0.0.0.0 accepts LAN clients
                        and exposes your screen to the network)
          --wireless    discover an ALVR headset on the local network,
                        negotiate a session, and stream over Wi-Fi/UDP
          --trust-file <path>
                        connect only to approved ALVR hostnames in this JSON file
          --discover    legacy alias for --wireless
          --wired       connect to an authorized USB headset through adb and
                        stream the ALVR session over forwarded TCP ports
          --runtime <control-file>
                        stream frames submitted by the BasaltVR OpenXR
                        runtime instead of capturing the desktop; writes
                        "<port> <token> <width> <height>" to <control-file>, which the game
                        bottle receives as BASALT_CONTROL
          --audio-device <name>
                        capture 48 kHz stereo game audio from the matching
                        CoreAudio input (normally "BlackHole 2ch") and send
                        raw PCM on the ALVR stream; requires headset mode
          --route-audio route the Mac's default application output to the
                        selected audio device for this session, then restore
                        the previous output on shutdown; requires
                        --audio-device
          --list-audio-devices
                        print CoreAudio input devices and exit
          --game-audio mac
                        capture what the Mac itself plays (all apps except
                        TrailBridge; macOS 14.2+) and send it as 48 kHz stereo
                        PCM; the Mac stays silent while the session runs;
                        requires headset mode, not with --audio-device.
                        BASALT_GAME_AUDIO=mac in the environment turns a
                        given --audio-device/--route-audio into this
          --help        show this help
        """

    /// Returns nil when --help was requested. `environment` is read only for
    /// BASALT_GAME_AUDIO, a switch for testing builds of the app.
    public static func parse(_ argv: [String],
                             environment: [String: String] = [:]) throws -> StreamerOptions? {
        var options = StreamerOptions()
        var arguments = argv

        func nextValue(for flag: String) throws -> String {
            guard !arguments.isEmpty else { throw BasaltError("\(flag) requires a value") }
            return arguments.removeFirst()
        }
        func number<T: FixedWidthInteger>(for flag: String) throws -> T {
            let value = try nextValue(for: flag)
            guard let parsed = T(value), parsed > 0 else {
                throw BasaltError("\(flag) expects a positive number, got '\(value)'")
            }
            return parsed
        }

        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--port":
                options.port = try number(for: flag)
                options.debugStreamRequested = true
            case "--fps":
                options.fps = try number(for: flag)
                guard fpsRange.contains(options.fps) else {
                    throw BasaltError("--fps must be between \(fpsRange.lowerBound) and \(fpsRange.upperBound)")
                }
            case "--mbps":
                options.megabits = try number(for: flag)
                guard megabitsRange.contains(options.megabits) else {
                    throw BasaltError("--mbps must be between \(megabitsRange.lowerBound) and \(megabitsRange.upperBound)")
                }
            case "--resolution":
                options.perEyeResolution = try PerEyeResolution.parse(nextValue(for: flag))
            case "--latency":
                let value = try nextValue(for: flag).lowercased()
                guard let preset = StreamLatencyPreset(rawValue: value) else {
                    throw BasaltError("--latency expects balanced, low, or ultra")
                }
                options.latencyPreset = preset
            case "--codec":
                guard let codec = VideoCodec(rawValue: try nextValue(for: flag).lowercased()) else {
                    throw BasaltError("\(flag) expects h264 or hevc")
                }
                options.codec = codec
            case "--allow-hevc-rc-fallback": options.allowHEVCRateControlFallback = true
            case "--encoder-priority":
                guard let priority = EncoderPriority(rawValue: try nextValue(for: flag).lowercased()) else {
                    throw BasaltError("\(flag) expects speed or quality")
                }
                options.encoderPriority = priority
            case "--low-latency-rc":
                let value = try nextValue(for: flag).lowercased()
                guard value == "on" || value == "off" else {
                    throw BasaltError("\(flag) expects on or off")
                }
                options.lowLatencyRateControl = value == "on"
            case "--quest-supersampling", "--quest-sharpening":
                guard let level = QuestPostProcessingLevel(rawValue: try nextValue(for: flag).lowercased()) else {
                    throw BasaltError("\(flag) expects off, normal, or quality")
                }
                if flag == "--quest-supersampling" {
                    options.questSupersampling = level
                } else {
                    options.questSharpening = level
                }
            case "--bind":
                let host = try nextValue(for: flag)
                guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
                    throw BasaltError("--bind expects an IP address, got '\(host)'")
                }
                options.bindHost = host
                options.debugStreamRequested = true
            case "--wireless", "--discover": options.discover = true
            case "--wired": options.wired = true
            case "--trust-file": options.trustFile = try nextValue(for: flag)
            case "--runtime": options.runtimeControlFile = try nextValue(for: flag)
            case "--record-video": options.recordVideoFile = try nextValue(for: flag)
            case "--audio-device":
                let name = try nextValue(for: flag)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw BasaltError("--audio-device expects a non-empty device name")
                }
                options.audioDeviceName = name
            case "--route-audio": options.routeAudioToCaptureDevice = true
            case "--list-audio-devices": options.listAudioDevices = true
            case "--game-audio":
                guard try nextValue(for: flag).lowercased() == "mac" else {
                    throw BasaltError("\(flag) expects mac")
                }
                options.captureMacAudio = true
            case "--help", "-h": return nil
            default: throw BasaltError("Unknown flag \(flag) (try --help)")
            }
        }
        guard options.megabits <= options.codec.maximumMegabits else {
            throw BasaltError("--mbps above \(options.codec.maximumMegabits) makes \(options.codec.label) "
                + "streams that decoders cannot read; use at most \(options.codec.maximumMegabits)")
        }
        guard !(options.discover && options.wired) else {
            throw BasaltError("--wireless and --wired cannot be used together")
        }
        guard options.audioDeviceName == nil || options.discover || options.wired else {
            throw BasaltError("--audio-device requires --wireless or --wired")
        }
        guard !options.routeAudioToCaptureDevice || options.audioDeviceName != nil else {
            throw BasaltError("--route-audio requires --audio-device")
        }
        guard !(options.captureMacAudio && options.audioDeviceName != nil) else {
            throw BasaltError("--game-audio mac and --audio-device cannot be used together")
        }
        guard !options.captureMacAudio || options.discover || options.wired else {
            throw BasaltError("--game-audio requires --wireless or --wired")
        }
        if let override = environment["BASALT_GAME_AUDIO"], !override.isEmpty {
            guard override.lowercased() == "mac" else {
                throw BasaltError("BASALT_GAME_AUDIO expects mac, got '\(override)'")
            }
            // A choice of Off stays off: only a chosen device is replaced.
            if let device = options.audioDeviceName {
                options.replacedAudioDeviceName = device
                options.audioDeviceName = nil
                options.routeAudioToCaptureDevice = false
                options.captureMacAudio = true
            }
        }
        return options
    }

    /// Whether to serve the raw encoded stream to TCP clients (`ffplay`).
    /// The desktop demo always does. A headset session streams over ALVR and
    /// nothing reads this port, so there it opens only when asked for with
    /// `--port` or `--bind`; the app passes neither.
    public var opensDebugStream: Bool {
        debugStreamRequested || !(discover || wired)
    }

    public var bindIsLoopback: Bool {
        if let address = IPv4Address(bindHost) { return address.isLoopback }
        if let address = IPv6Address(bindHost) { return address.isLoopback }
        return false
    }
}
