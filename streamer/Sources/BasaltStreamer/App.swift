import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import BasaltCore

/// Counts a recurring event and logs only its first and every 120th
/// occurrence, so a sustained stall cannot flood stderr.
private final class ThrottledEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ message: (_ count: Int) -> String) {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 || current.isMultiple(of: 120) {
            fputs(message(current) + "\n", stderr)
        }
    }

    func recordDroppedFrame(stage: String) {
        record { "\(stage): dropped \($0) frame(s) to bound latency" }
    }
}

@main
struct BasaltStreamerApp {
    static func main() async {
        // The M7 management app captures this process through pipes. Keep
        // operational lines live instead of block-buffering them until exit.
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "runtime-link-selftest" {
            await RuntimeLinkSelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "audio-loopback-selftest" {
            AudioLoopbackSelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "audio-tap-selftest" {
            AudioTapSelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
            return
        }

        let options: StreamerOptions?
        do {
            options = try StreamerOptions.parse(
                Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        guard let options else {
            print(StreamerOptions.usage)
            return
        }

        if options.listAudioDevices {
            do {
                let devices = try GameAudioDeviceDiscovery.inputDevices()
                if devices.isEmpty {
                    print("No CoreAudio input devices found.")
                } else {
                    for device in devices {
                        print("\(device.name)\t\(Int(device.sampleRate)) Hz")
                    }
                }
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }

        do {
            try await run(options)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            if let hint = ScreenCaptureError.permissionHint(for: error) {
                fputs(hint + "\n", stderr)
            }
            exit(1)
        }
    }

    static func run(_ options: StreamerOptions) async throws {
        // Handle SIGINT/SIGTERM from the start: --route-audio switches the Mac
        // output and --wired opens adb forwards before the headset handshake,
        // and the manager may stop a session that never finished starting.
        // When the manager is gone its pipes are closed: a line written to
        // them must fail quietly, not kill this process before it has put
        // the Mac's audio output back.
        signal(SIGPIPE, SIG_IGN)
        let shutdown = ShutdownSignals()
        let systemState = SystemStateRestorer()
        do {
            try await runSession(options, shutdown: shutdown, systemState: systemState)
        } catch {
            systemState.restore()
            throw error
        }
    }

    private static func runSession(
        _ options: StreamerOptions,
        shutdown: ShutdownSignals,
        systemState: SystemStateRestorer
    ) async throws {
        // Runtime mode replaces desktop capture with frames the BasaltVR
        // OpenXR runtime submits over the control socket.
        let runtimeMode = options.runtimeControlFile != nil
        let capture = ScreenCapture()
        if !runtimeMode {
            try await capture.prepare(fps: options.fps)
        }
        // Balanced-resolution, near-native Quest aspect ratio for the temporary
        // monoscopic desktop preview. The real OpenXR path supplies native
        // per-eye game textures through RuntimeStereoComposer instead.
        let previewPerEyeWidth = options.perEyeResolution.width
        let previewPerEyeHeight = options.perEyeResolution.height
        let headsetMode = options.discover || options.wired
        let progress = headsetMode ? SessionProgressLog(runtimeMode: runtimeMode) : nil
        progress?.start()
        defer { progress?.stop() }
        let stereoComposer = (headsetMode && !runtimeMode)
            ? try StereoFrameComposer(sourceWidth: capture.width, sourceHeight: capture.height,
                                      perEyeWidth: previewPerEyeWidth,
                                      height: previewPerEyeHeight,
                                      contentScale: 0.84,
                                      convergenceShiftPixels: 12)
            : nil
        let encodedWidth = runtimeMode
            ? previewPerEyeWidth * 2
            : (stereoComposer?.outputWidth ?? capture.width)
        let encodedHeight = runtimeMode
            ? previewPerEyeHeight
            : (stereoComposer?.height ?? capture.height)
        let negotiateViewWidth = runtimeMode
            ? previewPerEyeWidth
            : (stereoComposer?.perEyeWidth ?? capture.width)
        let negotiateViewHeight = runtimeMode
            ? previewPerEyeHeight
            : (stereoComposer?.height ?? capture.height)

        // The raw-stream port for `ffplay`. A headset session has no reader
        // for it, so it stays closed there unless asked for.
        let server = options.opensDebugStream
            ? try TCPServer(port: options.port, bindHost: options.bindHost) : nil
        server?.onFailure = { error in
            fputs("server error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        let alvrVideo = AlvrVideoStreamRouter(codec: options.codec)
        var gameAudio: GameAudioCapture?
        let macAudio = options.captureMacAudio ? startMacAudio(options, alvrVideo: alvrVideo) : nil
        if let audioDeviceName = options.audioDeviceName {
            if options.routeAudioToCaptureDevice {
                let device = try GameAudioDeviceDiscovery.matchingInputDevice(audioDeviceName)
                let route = try GameAudioOutputRoute(to: device)
                systemState.audioOutputRoute = route
                print("Game audio output routed to \(device.name) for this session")
            }
            let capture = try GameAudioCapture(deviceNameContains: audioDeviceName)
            capture.onPCM16 = { pcm in
                gameAudioLevel.record(pcm16Stereo: pcm)
                alvrVideo.sendAudioPCM16(pcm)
            }
            try capture.start()
            gameAudio = capture
            print("Game audio capture ready: \(capture.device.name), 48000 Hz stereo PCM16")
        }
        let latencyReporter = PipelineLatencyReporter()
        let headsetLatencyReporter = HeadsetLatencyReporter()
        let calibrationLogGate = CalibrationLogGate()
        let videoRecorder: EncodedVideoRecorder? = options.recordVideoFile.flatMap { path in
            do {
                let recorder = try EncodedVideoRecorder(path: path)
                print("Recording the encoded video for diagnostics")
                return recorder
            } catch {
                // A diagnostic must never prevent the session from starting.
                fputs("video recording disabled: \(error.localizedDescription)\n", stderr)
                return nil
            }
        }
        let encoder = try VideoEncoder(
            width: encodedWidth,
            height: encodedHeight,
            fps: options.fps,
            bitrate: options.megabits * 1_000_000,
            codec: options.codec,
            priority: options.encoderPriority,
            lowLatencyRateControl: options.lowLatencyRateControl,
            allowHEVCRateControlFallback: options.allowHEVCRateControlFallback) { annexB, isKeyframe, capturePTS in
                progress?.record(.encodedFrame)
                if !runtimeMode {
                    latencyReporter.recordEncoded(capturePTS: capturePTS)
                }
                videoRecorder?.append(
                    annexB: annexB, isKeyframe: isKeyframe,
                    questTimestampNanoseconds: VideoEncoder.questTrackingTimestampNanoseconds(from: capturePTS))
                server?.broadcast(annexB)
                if runtimeMode {
                    guard let runtimeTrackingTimestamp =
                            VideoEncoder.questTrackingTimestampNanoseconds(from: capturePTS) else {
                        fputs("encoded runtime frame lost its Quest tracking timestamp\n", stderr)
                        return
                    }
                    alvrVideo.send(
                        annexB: annexB, isIDR: isKeyframe,
                        timestampNanoseconds: runtimeTrackingTimestamp)
                } else {
                    alvrVideo.send(annexB: annexB, isIDR: isKeyframe)
                }
            }
        encoder.onError = { error in
            fputs("encoder error: \(error.localizedDescription)\n", stderr)
        }
        let streamRecovery = StreamRecoveryController(
            encoder: encoder,
            minimumIDRIntervalNanoseconds: options.wired
                ? 1_000_000_000 : 2_000_000_000)

        // A client joining mid-stream needs an IDR frame before it can
        // decode anything.
        server?.onClientConnected = { encoder.forceKeyframe() }
        let droppedFrames = ThrottledEventLog()
        capture.onFrame = { pixelBuffer, pts in
            // Avoid spending GPU time composing a stereo frame that the
            // bounded encoder cannot accept. `encode` repeats this check
            // atomically in case a slot changes between here and submission.
            guard !headsetMode || alvrVideo.hasSender else { return }
            guard encoder.canAcceptFrame else {
                droppedFrames.recordDroppedFrame(stage: "encoder busy (capture)")
                return
            }

            let frame: CVPixelBuffer
            if let stereoComposer {
                guard let composed = stereoComposer.compose(pixelBuffer) else { return }
                frame = composed
            } else {
                frame = pixelBuffer
            }
            guard encoder.encode(frame, pts: pts) else {
                droppedFrames.recordDroppedFrame(stage: "encoder busy (capture)")
                return
            }
        }
        capture.onError = { error in
            fputs("capture stopped: \(error.localizedDescription)\n", stderr)
            raise(SIGTERM)
        }

        var runtimeLink: RuntimeLink?
        if let controlFile = options.runtimeControlFile {
            let runtimeComposer = try RuntimeStereoComposer(
                perEyeWidth: previewPerEyeWidth, height: previewPerEyeHeight)
            let link = try RuntimeLink(
                controlFilePath: controlFile,
                recommendedViewSize: options.perEyeResolution,
                waitForNegotiatedRefreshRate: headsetMode,
                // Wi-Fi drops out too (headset asleep, out of range); a game
                // that submits no frames during the gap needs the keep-alive.
                keepAliveWithoutTracking: true)
            link.onHello = { sessionId, renderer in
                progress?.runtimeConnected()
                print(RuntimeLink.connectedLogPrefix + "(session \(sessionId), \(renderer))")
                encoder.forceKeyframe()
            }
            link.onTeardown = {
                print("OpenXR runtime disconnected")
            }
            link.onProtocolError = { reason in
                fputs(RuntimeLink.connectionRefusedLogPrefix + reason + "\n", stderr)
            }
            link.onFrame = { frame, consumption in
                progress?.record(.gameFrame)
                // No GPU read has been scheduled, so acknowledge immediately.
                // The runtime and game keep advancing while ALVR reconnects.
                guard !headsetMode || alvrVideo.hasSender else {
                    consumption.complete()
                    return
                }
                guard encoder.canAcceptFrame else {
                    droppedFrames.recordDroppedFrame(stage: "encoder busy (runtime)")
                    consumption.complete()
                    return
                }
                guard let firstView = frame.views.first,
                      let lastView = frame.views.last else {
                    consumption.complete()
                    return
                }
                guard let pts = VideoEncoder.presentationTime(
                        questTrackingTimestampNanoseconds:
                            frame.questTrackingTimestampNanoseconds) else {
                    fputs("runtime supplied an invalid Quest tracking timestamp\n", stderr)
                    consumption.complete()
                    return
                }
                // A zero-sized rect tells the compositor the view covers the
                // whole image, so a malformed rect degrades to the previous
                // full-image behaviour.
                func rectVector(
                    _ rect: (x: Int32, y: Int32, width: Int32, height: Int32)
                ) -> SIMD4<Float> {
                    guard rect.width > 0, rect.height > 0 else {
                        return SIMD4<Float>(0, 0, 0, 0)
                    }
                    return SIMD4<Float>(
                        Float(rect.x), Float(rect.y),
                        Float(rect.width), Float(rect.height))
                }
                let leftRect = rectVector(firstView.rect)
                let rightRect = rectVector(lastView.rect)
                let scheduled = runtimeComposer.composeAsync(
                    left: firstView.surface, right: lastView.surface,
                    leftRect: leftRect, rightRect: rightRect) {
                    composed in
                    // Metal has finished reading the runtime swapchains. Let
                    // Beat Saber render its next frame before VideoToolbox
                    // finishes with this compositor output.
                    consumption.complete()
                    guard let composed else { return }
                    guard encoder.encode(
                            composed.pixelBuffer, pts: pts,
                            completion: { _ = composed }) else {
                        droppedFrames.recordDroppedFrame(stage: "encoder busy (runtime)")
                        return
                    }
                }
                guard scheduled else {
                    droppedFrames.recordDroppedFrame(stage: "compositor busy (runtime)")
                    consumption.complete()
                    return
                }
            }
            runtimeLink = link
        }

        if options.wired {
            print("USB setup: checking adb authorization, forwards, and ALVR activity")
            let connection = try await Task.detached(priority: .utility) {
                try AlvrWiredConnection.setup()
            }.value
            systemState.wiredConnection = connection
            print("USB Quest \(connection.serial) is authorized; adb control/video forwards are ready.")
        }
        let wiredConnection = systemState.wiredConnection
        let liveRuntimeLink = runtimeLink
        let reconnect = HeadsetReconnectController(wired: options.wired, refreshRate: Float(options.fps),
            prepareWiredAttempt: {
                try await Task.detached(priority: .utility) {
                    try wiredConnection?.restoreForwards()
                }.value
            }) {
            endpoint, refreshRate, isReconnect, onDisconnect in
            try Task.checkCancellation()
            return try await connectHeadset(
                host: endpoint.host, expectedProtocolId: endpoint.protocolID, wired: options.wired,
                requestedViewWidth: negotiateViewWidth,
                requestedViewHeight: negotiateViewHeight,
                requestedRefreshRate: refreshRate, isReconnect: isReconnect,
                onDisconnect: onDisconnect,
                stereoComposer: stereoComposer, options: options,
                alvrVideo: alvrVideo, runtimeLink: liveRuntimeLink,
                headsetLatencyReporter: headsetLatencyReporter,
                calibrationLogGate: calibrationLogGate,
                encoder: encoder, streamRecovery: streamRecovery,
                progress: progress)
        }
        var discovery: AlvrDiscoveryListener?
        if options.discover {
            discovery = try AlvrDiscoveryListener(trustFile: options.trustFile.map { URL(fileURLWithPath: $0) }) { beacon, ip in
                Task {
                    await reconnect.offer(.init(host: ip, protocolID: beacon.protocolId))
                }
            }
        }

        func tearDown() async {
            print("\nShutting down…")
            discovery?.stop()
            await reconnect.shutdown()
            runtimeLink?.stop()
            gameAudio?.stop()
            macAudio?.stop()
            systemState.restore()
            if !runtimeMode {
                await capture.stop()
            }
            server?.stop()
        }

        try await server?.start()
        if options.wired {
            do {
                _ = try await shutdown.unlessRequested {
                    try await reconnect.connectInitially(.init(host: "127.0.0.1"))
                }
            } catch {
                await tearDown()
                throw BasaltError("Could not start wired ALVR session: \(error.localizedDescription)")
            }
        }
        guard !shutdown.isRequested else {
            await tearDown()
            return
        }
        if let runtimeLink {
            try await runtimeLink.start()
        } else {
            try await capture.start()
        }

        let sourceLine = runtimeMode
            ? "OpenXR runtime frames via \(options.runtimeControlFile ?? "?") (BASALT_CONTROL)"
            : "capturing \(capture.width)x\(capture.height) @ \(options.fps) fps"
        let debugStreamLine = server.map {
            "listening on tcp://\(options.bindHost):\($0.port ?? options.port)"
        } ?? "raw-stream TCP port closed (pass --port <n> to open it)"
        print("""
        BasaltVR streamer — \(runtimeMode ? "M4 tracked OpenXR source" : "M1 capture") + M2/M6 ALVR media
          \(sourceLine)
          encoding \(encodedWidth)x\(encodedHeight)\(runtimeMode || stereoComposer != nil ? " side-by-side stereo" : "")
          \(options.codec == .h264 ? "H.264 High" : "HEVC Main") \(options.megabits) Mbps, VideoToolbox priority \(options.encoderPriority.rawValue), low-latency RC \(encoder.lowLatencyRateControlEnabled ? "on" : "off")
          \(debugStreamLine)
        """)
        if server != nil {
            if options.bindIsLoopback {
                print("  local-only (pass --bind <ip> to accept LAN clients)")
            } else {
                print("  ⚠️  bound to \(options.bindHost): anyone on your network can connect and watch this screen")
            }
        }
        if options.discover {
            print("  ALVR: discovery/control \(AlvrDiscoveryListener.alvrPort), UDP video \(AlvrVideoStreamSender.defaultPort)")
        } else if options.wired {
            print("  ALVR: USB via adb, TCP control \(AlvrDiscoveryListener.alvrPort)/video \(AlvrVideoStreamSender.defaultPort)")
        }
        if headsetMode {
            print("  stream settings: \(previewPerEyeWidth)x\(previewPerEyeHeight) per eye, "
                  + "\(options.latencyPreset.rawValue) latency")
            print("  game audio: " + (gameAudio.map {
                "\($0.device.name), 48 kHz stereo PCM16"
            } ?? (macAudio != nil ? "the Mac's own output (see the Game audio lines)"
                : "disabled (pass --game-audio mac or --audio-device 'BlackHole 2ch')")))
        }
        if server != nil {
            print("""

            View the stream:
              ffplay -probesize 32 -analyzeduration 0 -fflags nocache -flags low_delay -framedrop -f \(options.codec == .h264 ? "h264" : "hevc") tcp://127.0.0.1:\(options.port)
            """)
        }
        print("\nCtrl-C to stop.")

        // Capture and networking run on their own queues; park main until
        // SIGINT/SIGTERM, then tear down cleanly (stops the capture stream
        // and closes client sockets instead of dying mid-write).
        await shutdown.wait()
        await tearDown()
        // Write the frames still queued and close the files; without this the
        // end of a diagnostic recording is lost when the session stops.
        videoRecorder?.finish()
    }

    /// Starts the Mac's own audio capture off the startup path: macOS may
    /// show its System Audio Recording prompt while it starts. A failure
    /// costs the game audio, never the VR session.
    private static func startMacAudio(
        _ options: StreamerOptions, alvrVideo: AlvrVideoStreamRouter
    ) -> MacAudioCapture? {
        if let replaced = options.replacedAudioDeviceName {
            print("Game audio: BASALT_GAME_AUDIO=mac replaces \(replaced) with the Mac's own output")
        }
        guard #available(macOS 14.2, *) else {
            fputs("Game audio unavailable: capturing the Mac's own output needs macOS 14.2 "
                + "or newer; choose BlackHole for game audio\n", stderr)
            return nil
        }
        let tap = MacAudioTap(excludingProcessIDs: [getpid(), getppid()])
        tap.onPCM16 = { pcm in
            gameAudioLevel.record(pcm16Stereo: pcm)
            alvrVideo.sendAudioPCM16(pcm)
        }
        tap.onEvent = { print("Game audio: \($0)") }
        Thread.detachNewThread {
            do {
                try tap.start()
                print("Game audio: capturing the Mac's own output (all apps except TrailBridge), "
                    + "48000 Hz stereo PCM16; Mac speakers stay silent during the session. "
                    + "Tap \(tap.formatText), clock \(tap.clockName)")
            } catch {
                fputs("Game audio unavailable: \(error.localizedDescription). The session "
                    + "continues without game audio; choose BlackHole if this repeats\n", stderr)
            }
        }
        return MacAudioCapture(stop: {
            print(tap.stop() ? "Game audio tap stopped"
                : "Game audio tap did not stop within 2 s; it ends with this process")
        })
    }

    private static func connectHeadset(
        host: String,
        expectedProtocolId: UInt64?,
        wired: Bool,
        requestedViewWidth: Int,
        requestedViewHeight: Int,
        requestedRefreshRate: Float,
        isReconnect: Bool,
        onDisconnect: @escaping @Sendable () -> Void,
        stereoComposer: StereoFrameComposer?,
        options: StreamerOptions,
        alvrVideo: AlvrVideoStreamRouter,
        runtimeLink: RuntimeLink?,
        headsetLatencyReporter: HeadsetLatencyReporter,
        calibrationLogGate: CalibrationLogGate,
        encoder: VideoEncoder,
        streamRecovery: StreamRecoveryController,
        progress: SessionProgressLog?
    ) async throws -> HeadsetReconnectController.Connection {
        let attempt = progress?.beginHeadsetAttempt()
        let handshake = try await AlvrControlProbe.negotiateSession(
            host: host,
            requestedViewWidth: UInt32(requestedViewWidth),
            requestedViewHeight: UInt32(requestedViewHeight),
            preferredRefreshRate: requestedRefreshRate,
            latencyPreset: options.latencyPreset,
            wired: wired,
            questSupersampling: options.questSupersampling,
            questSharpening: options.questSharpening)
        var installed = false
        defer { if !installed { handshake.stop() } }
        try Task.checkCancellation()
        guard case .accepted(let protocolId, let displayName, _, let capabilities) =
                handshake.clientState else {
            throw BasaltError("ALVR headset is in standby")
        }
        if let expectedProtocolId, protocolId != expectedProtocolId {
            throw BasaltError("ALVR protocol mismatch between discovery and control packet")
        }
        let negotiated = try requireNegotiatedSettings(handshake.negotiatedSettings)
        if let capabilities {
            print("  headset capabilities: \(capabilities.width)x\(capabilities.height) per eye; "
                + "refresh rates [\(capabilities.refreshRatesLogText)] Hz; "
                + "microphone \(capabilities.microphoneSampleRate) Hz")
            print("  codecs: H.264 high-profile=\(capabilities.supportsHighProfile), "
                + "10-bit=\(capabilities.supports10Bit), AV1=\(capabilities.supportsAV1)")
            print("  prepared stereo desktop preview: \(negotiated.width)x\(negotiated.height) per eye "
                + "@ \(String(format: "%.0f", negotiated.refreshRate)) Hz, H.264")
        } else {
            print("  headset did not provide streaming capabilities")
        }
        guard handshake.streamReady else {
            throw BasaltError("Quest did not report StreamReady")
        }
        progress?.record(.headsetHandshake, attempt: attempt)

        handshake.onRequestIDR { streamRecovery.requestIDR() }
        handshake.onViewsConfig { config in
            stereoComposer?.updateViews(config)
            runtimeLink?.publishViewsConfig(config)
            if calibrationLogGate.shouldLog(ipdMeters: config.ipdMeters) {
                let ipd = String(format: "%.1f", config.ipdMeters * 1_000)
                print("  calibrated desktop preview from headset IPD/FOV (IPD \(ipd) mm)")
            }
        }
        handshake.onButtons { entries in
            runtimeLink?.publishButtons(entries)
        }
        handshake.onActiveInteractionProfile { deviceID, profileID in
            runtimeLink?.publishInteractionProfile(deviceID: deviceID, profileID: profileID)
        }
        handshake.onDisconnect {
            runtimeLink?.resetInputs()
            onDisconnect()
        }
        let transport: AlvrStreamTransport = wired ? .tcp : .udp
        let videoSender: AlvrVideoStreamSender
        if wired {
            // TCP connect can poll for five seconds. Like the control
            // handshake and adb, keep it off Swift's cooperative executor.
            videoSender = try await Task.detached(priority: .utility) {
                try AlvrVideoStreamSender(host: host, transport: .tcp)
            }.value
        } else {
            videoSender = try AlvrVideoStreamSender(host: host, transport: transport)
        }
        defer { if !installed { videoSender.stop() } }
        let transportReporter = VideoTransportReporter(name: wired ? "USB" : "Wi-Fi", encoder: encoder)
        let audioReporter = AudioTransportReporter(name: wired ? "USB" : "Wi-Fi")
        let adaptiveBitrate = wired ? nil : AdaptiveVideoBitrateController(
            configuredBitrate: options.megabits * 1_000_000,
            targetFramesPerSecond: Double(negotiated.refreshRate),
            initialBitrate: encoder.currentAverageBitrate)
        func applyAdaptiveBitrate(_ adjustment: AdaptiveVideoBitrateController.Adjustment) {
            guard encoder.updateAverageBitrate(adjustment.bitrate) else { return }
            print("  Wi-Fi congestion control: encoder adjusted to "
                  + String(format: "%.1f Mbps", Double(adjustment.bitrate) / 1_000_000)
                  + " (\(adjustment.reason.rawValue))")
        }
        videoSender.onError = { error in
            fputs("ALVR stream send error: \(error.localizedDescription)\n", stderr)
            runtimeLink?.resetInputs()
            onDisconnect()
        }
        videoSender.onFrameSent = { report in
            progress?.record(.sentFrame, attempt: attempt)
            adaptiveBitrate?.recordFrameSent(report)
            transportReporter.record(report)
        }
        videoSender.onAudioSent = { report in
            audioReporter.record(report)
        }
        let networkDrops = ThrottledEventLog()
        videoSender.onFrameDropped = {
            networkDrops.record { "ALVR network busy: dropped \($0) stale video frame(s)" }
        }
        videoSender.onAudioDropped = {
            audioReporter.recordDrop()
        }
        videoSender.onCongestion = {
            // Packet loss corrupts the current H.264 access unit. Ask
            // VideoToolbox for a fresh recovery point. Repeated pressure also
            // lowers the encoder target before another large IDR is emitted.
            if let adjustment = adaptiveBitrate?.recordTransportCongestion() {
                applyAdaptiveBitrate(adjustment)
            }
            streamRecovery.requestIDR()
        }
        videoSender.onStatistics = { statistics in
            progress?.record(.headsetStatistics, attempt: attempt)
            headsetLatencyReporter.record(statistics)
            if let adjustment = adaptiveBitrate?.recordClientStatistics(statistics) {
                applyAdaptiveBitrate(adjustment)
            }
            if let hold = adaptiveBitrate?.takeHoldReport() {
                print("  " + hold)
            }
        }
        videoSender.onHeadPose = { timestamp, pose in
            progress?.record(.tracking, attempt: attempt)
            runtimeLink?.publishHeadPose(
                timestampNanoseconds: timestamp, pose: pose)
        }
        videoSender.onControllerMotion = { timestamp, hand, motion in
            runtimeLink?.publishControllerMotion(
                timestampNanoseconds: timestamp, hand: hand, motion: motion)
        }
        videoSender.onControllerMask = { timestamp, activeMask in
            runtimeLink?.publishControllerMask(
                timestampNanoseconds: timestamp, activeMask: activeMask)
        }
        runtimeLink?.onHaptic { [weak videoSender] hand, duration, frequency, amplitude in
            videoSender?.sendHaptics(
                hand: hand, durationNanoseconds: duration,
                frequency: frequency, amplitude: amplitude)
        }
        videoSender.start()

        // StreamReady means the client's control state advanced, but an ALVR
        // client left stale by a prior wired session can accept both TCP
        // connections without sending its tracking uplink. Video headers must
        // use the Quest clock, so the router intentionally drops frames until
        // that uplink exists. Treat tracking as part of connection readiness
        // and let the wired retry loop replace a half-open session.
        let trackingDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while videoSender.timestampForVideoFrame() == nil {
            guard DispatchTime.now().uptimeNanoseconds < trackingDeadline else {
                throw AlvrTrackingTimeoutError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        videoSender.onTrackingReady { streamRecovery.forceIDR() }
        // Reconfigure both VideoToolbox rate properties before the control
        // file can release the game. Also covers requested 85 -> negotiated 90.
        let streamRefreshRate = isReconnect ? requestedRefreshRate : negotiated.refreshRate
        if negotiated.width != UInt32(requestedViewWidth)
            || negotiated.height != UInt32(requestedViewHeight)
            || (isReconnect && negotiated.refreshRate != requestedRefreshRate) {
            print("ALVR negotiated \(negotiated.width)x\(negotiated.height) @ \(negotiated.refreshRate) Hz; "
                + "keeping encoder \(requestedViewWidth)x\(requestedViewHeight) @ \(streamRefreshRate) Hz")
        }
        if !isReconnect { try encoder.updateFrameRate(streamRefreshRate) }
        try await runtimeLink?.configureRefreshRate(streamRefreshRate)
        try Task.checkCancellation()
        alvrVideo.install(videoSender, controlSession: handshake)
        installed = true
        // The next IDR sends fresh parameter sets through the new control socket.
        streamRecovery.forceIDR()
        print("ALVR control accepted by '\(displayName)': StreamConfig sent, "
            + "StartStream sent, and Quest replied StreamReady.")
        if wired {
            print("  ALVR TCP video stream connected through USB at \(host):\(AlvrVideoStreamSender.defaultPort); "
                + "tracking uplink ready; sending H.264 frames.")
        } else {
            print("  ALVR UDP video stream connected to \(host):\(AlvrVideoStreamSender.defaultPort); "
                + "sending H.264 desktop frames.")
        }
        return .init(refreshRate: streamRefreshRate) {
            alvrVideo.uninstall(videoSender)
            handshake.stop()
            runtimeLink?.resetInputs()
        }
    }
}

private func requireNegotiatedSettings(_ settings: AlvrNegotiatedSettings?) throws
    -> AlvrNegotiatedSettings {
    guard let settings else { throw BasaltError("ALVR negotiation did not produce streaming settings") }
    return settings
}

/// Periodically reports the local capture-to-encode portion of the pipeline.
/// Headset decode, Wi-Fi transit, and display scanout happen after this value,
/// so it gives us a useful boundary when diagnosing real-device latency.
private final class PipelineLatencyReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let hostClock = CMClockGetHostTimeClock()
    private var sampleCount = 0
    private var totalMilliseconds = 0.0
    private var maximumMilliseconds = 0.0
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    func recordEncoded(capturePTS: CMTime) {
        let elapsed = CMTimeSubtract(CMClockGetTime(hostClock), capturePTS)
        let milliseconds = CMTimeGetSeconds(elapsed) * 1_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 10_000 else { return }
        let now = DispatchTime.now()

        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(5)
        }
        sampleCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let average = totalMilliseconds / Double(sampleCount)
        let maximum = maximumMilliseconds
        let elapsedSeconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let framesPerSecond = Double(sampleCount) / elapsedSeconds
        sampleCount = 0
        totalMilliseconds = 0
        maximumMilliseconds = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(5)
        lock.unlock()

        print("  local encode: " + String(format: "%.1f fps; ", framesPerSecond)
              + String(format: "capture→encode %.1f ms average, %.1f ms max",
                       average, maximum))
    }
}

/// Aggregates ALVR statistics measured on the Quest. Unlike the local metric,
/// total pipeline latency starts when headset tracking is sampled and ends at
/// the target display vsync, spanning server, network, decode, and compositor.
private final class HeadsetLatencyReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private var totalMilliseconds = 0.0
    private var maximumMilliseconds = 0.0
    private var decodeMilliseconds = 0.0
    private var decoderQueueMilliseconds = 0.0
    private var vsyncQueueMilliseconds = 0.0
    private var frameIntervalMilliseconds = 0.0
    private var frameIntervalSampleCount = 0
    private var hasSeenFrameInterval = false
    private var nextReport: DispatchTime?

    func record(_ statistics: AlvrClientStatistics) {
        let milliseconds = Double(statistics.totalPipelineLatencyNanoseconds) / 1_000_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 10_000 else { return }

        lock.lock()
        if nextReport == nil {
            nextReport = DispatchTime.now() + .seconds(2)
        }
        sampleCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        decodeMilliseconds += Double(statistics.videoDecodeNanoseconds) / 1_000_000
        decoderQueueMilliseconds += Double(statistics.videoDecoderQueueNanoseconds) / 1_000_000
        vsyncQueueMilliseconds += Double(statistics.vsyncQueueNanoseconds) / 1_000_000
        if hasSeenFrameInterval {
            frameIntervalMilliseconds += Double(statistics.frameIntervalNanoseconds) / 1_000_000
            frameIntervalSampleCount += 1
        } else {
            // The first interval is measured from client statistics-manager
            // construction, not from a prior displayed stream frame.
            hasSeenFrameInterval = true
        }
        guard let nextReport, DispatchTime.now() >= nextReport else {
            lock.unlock()
            return
        }
        let count = Double(sampleCount)
        let average = totalMilliseconds / count
        let maximum = maximumMilliseconds
        let decode = decodeMilliseconds / count
        let decoderQueue = decoderQueueMilliseconds / count
        let vsyncQueue = vsyncQueueMilliseconds / count
        let averageFrameInterval = frameIntervalSampleCount > 0
            ? frameIntervalMilliseconds / Double(frameIntervalSampleCount) : 0
        let framesPerSecond = averageFrameInterval > 0 ? 1_000 / averageFrameInterval : nil
        sampleCount = 0
        totalMilliseconds = 0
        maximumMilliseconds = 0
        decodeMilliseconds = 0
        decoderQueueMilliseconds = 0
        vsyncQueueMilliseconds = 0
        frameIntervalMilliseconds = 0
        frameIntervalSampleCount = 0
        self.nextReport = .now() + .seconds(2)
        lock.unlock()

        print(StreamReport.questLine(
            framesPerSecond: framesPerSecond,
            averageLatencyMilliseconds: average,
            maximumLatencyMilliseconds: maximum,
            decodeMilliseconds: decode,
            decoderQueueMilliseconds: decoderQueue,
            vsyncQueueMilliseconds: vsyncQueue))
    }
}

/// Reports what Basalt actually handed to the ALVR stream socket. Keeping
/// this separate from Quest decode statistics distinguishes a slow USB/UDP
/// write from a client decoder or compositor stall.
private final class VideoTransportReporter: @unchecked Sendable {
    private let name: String
    private weak var encoder: VideoEncoder?
    private let lock = NSLock()
    private var frameCount = 0
    private var wireBytes = 0
    private var largestAccessUnitBytes = 0
    private var maximumSendMilliseconds = 0.0
    private var idrCount = 0
    private var repeatedTimestampCount = 0
    private var lastTimestampNanoseconds: UInt64?
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    init(name: String, encoder: VideoEncoder) {
        self.name = name
        self.encoder = encoder
        // Discard callbacks accumulated before this transport was connected.
        _ = encoder.takeLatencyStatistics()
    }

    func record(_ report: AlvrVideoSendReport) {
        let now = DispatchTime.now()
        let sendMilliseconds = Double(report.durationNanoseconds) / 1_000_000

        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(2)
        }
        frameCount += 1
        wireBytes += report.wireBytes
        largestAccessUnitBytes = max(largestAccessUnitBytes, report.accessUnitBytes)
        maximumSendMilliseconds = max(maximumSendMilliseconds, sendMilliseconds)
        if report.isIDR { idrCount += 1 }
        if report.timestampNanoseconds == lastTimestampNanoseconds {
            repeatedTimestampCount += 1
        }
        lastTimestampNanoseconds = report.timestampNanoseconds
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let elapsedSeconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let framesPerSecond = Double(frameCount) / elapsedSeconds
        let megabitsPerSecond = Double(wireBytes) * 8 / elapsedSeconds / 1_000_000
        let largestKilobytes = Double(largestAccessUnitBytes) / 1_024
        let maximumSend = maximumSendMilliseconds
        let idrs = idrCount
        let repeatedTimestamps = repeatedTimestampCount
        frameCount = 0
        wireBytes = 0
        largestAccessUnitBytes = 0
        maximumSendMilliseconds = 0
        idrCount = 0
        repeatedTimestampCount = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(2)
        lock.unlock()

        let encodeLatency = encoder?.takeLatencyStatistics().map {
            String(format: "; encode latency p50 %.2f ms, p95 %.2f ms, max %.2f ms (%d callbacks)",
                   $0.p50Milliseconds, $0.p95Milliseconds, $0.maximumMilliseconds, $0.sampleCount)
        } ?? ""
        print(StreamReport.videoSendLine(
            transport: name,
            framesPerSecond: framesPerSecond,
            megabitsPerSecond: megabitsPerSecond,
            maximumWriteMilliseconds: maximumSend,
            largestFrameKibibytes: largestKilobytes,
            idrCount: idrs,
            repeatedTimestamps: repeatedTimestamps) + encodeLatency)
    }
}

/// The loudest game audio sample between two `audio send` lines, from
/// whichever source captures it.
private let gameAudioLevel = AudioLevelMeter()

/// Hides the availability of `MacAudioTap` from the session code.
private final class MacAudioCapture: @unchecked Sendable {
    private let stopCapture: () -> Void
    init(stop: @escaping () -> Void) { stopCapture = stop }
    func stop() { stopCapture() }
}

private final class AudioTransportReporter: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var blocks = 0
    private var pcmBytes = 0
    private var wireBytes = 0
    private var maximumSendMilliseconds = 0.0
    private var drops = 0
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    init(name: String) { self.name = name }

    func record(_ report: AlvrAudioSendReport) {
        let now = DispatchTime.now()
        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(2)
        }
        blocks += 1
        pcmBytes += report.pcmBytes
        wireBytes += report.wireBytes
        maximumSendMilliseconds = max(
            maximumSendMilliseconds,
            Double(report.durationNanoseconds) / 1_000_000)
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let seconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let blocksPerSecond = Double(blocks) / seconds
        let pcmMegabits = Double(pcmBytes) * 8 / seconds / 1_000_000
        let wireMegabits = Double(wireBytes) * 8 / seconds / 1_000_000
        let maximumSend = maximumSendMilliseconds
        let dropped = drops
        blocks = 0
        pcmBytes = 0
        wireBytes = 0
        maximumSendMilliseconds = 0
        drops = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(2)
        lock.unlock()

        print(StreamReport.audioSendLine(
            transport: name,
            blocksPerSecond: blocksPerSecond,
            pcmMegabits: pcmMegabits,
            wireMegabits: wireMegabits,
            maximumWriteMilliseconds: maximumSend,
            drops: dropped,
            peakDecibels: gameAudioLevel.takePeakDecibels()))
    }

    func recordDrop() {
        lock.lock()
        drops += 1
        let count = drops
        lock.unlock()
        if count == 1 || count.isMultiple(of: 200) {
            fputs("ALVR audio busy: dropped \(count) self-contained PCM block(s)\n", stderr)
        }
    }
}

/// Coordinates Quest decoder feedback with VideoToolbox. IDR requests are
/// rate-limited because a saturated decoder asks for recovery repeatedly; an
/// unbounded keyframe response makes saturation substantially worse.
private final class StreamRecoveryController: @unchecked Sendable {
    private weak var encoder: VideoEncoder?
    private let minimumIDRIntervalNanoseconds: UInt64
    private let lock = NSLock()
    private var lastIDRNanoseconds: UInt64 = 0

    init(encoder: VideoEncoder, minimumIDRIntervalNanoseconds: UInt64) {
        self.encoder = encoder
        self.minimumIDRIntervalNanoseconds = minimumIDRIntervalNanoseconds
    }

    func requestIDR() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard lastIDRNanoseconds == 0
                || now &- lastIDRNanoseconds >= minimumIDRIntervalNanoseconds else {
            lock.unlock()
            return
        }
        lastIDRNanoseconds = now
        lock.unlock()
        encoder?.forceKeyframe()
    }

    func forceIDR() {
        lock.lock()
        lastIDRNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        encoder?.forceKeyframe()
    }

}

private final class CalibrationLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasLogged = false

    func shouldLog(ipdMeters: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLogged else { return false }
        hasLogged = true
        return true
    }
}

/// Observes SIGINT and SIGTERM from creation, so a signal that arrives
/// while the session is still starting is never lost. The exit of the
/// process that started this one counts as the same request: a manager that
/// crashed or was force quit cannot send a signal.
private final class ShutdownSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sources: [DispatchSourceSignal] = []
    private var parentWatch: ProcessExitWatch?

    init() {
        parentWatch = ProcessExitWatch.parent { [weak self] in self?.fire() }
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
            sources.append(source)
        }
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    /// Suspends until shutdown is requested; returns at once if it already was.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !requested else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Runs `operation` until it finishes, or returns nil as soon as shutdown
    /// is requested. The operation is then cancelled and abandoned: blocking
    /// handshake sockets do not observe cancellation, and the process exits
    /// once teardown completes.
    func unlessRequested<T>(_ operation: @escaping () async throws -> T) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let outcome = FirstOutcome(continuation)
            let task = Task {
                do {
                    outcome.resume(with: .success(try await operation()))
                } catch {
                    outcome.resume(with: .failure(error))
                }
            }
            Task {
                await self.wait()
                task.cancel()
                outcome.resume(with: .success(nil))
            }
        }
    }

    private func fire() {
        lock.lock()
        requested = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class FirstOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Mac state a session changes outside this process. Restored on every exit
/// path, including a startup that failed or was interrupted.
private final class SystemStateRestorer: @unchecked Sendable {
    var audioOutputRoute: GameAudioOutputRoute?
    var wiredConnection: AlvrWiredConnection?

    func restore() {
        if let audioOutputRoute {
            self.audioOutputRoute = nil
            do {
                switch try audioOutputRoute.restore() {
                case .restored(let name):
                    print("Restored Mac audio output to \(name)")
                case .noRealOutputFound:
                    print("No real Mac audio output found; output remains on \(audioOutputRoute.device.name)")
                case .unchanged:
                    break
                }
            } catch {
                fputs("Could not restore the previous Mac audio output: "
                    + "\(error.localizedDescription)\n", stderr)
            }
        }
        wiredConnection?.stop()
    }
}
