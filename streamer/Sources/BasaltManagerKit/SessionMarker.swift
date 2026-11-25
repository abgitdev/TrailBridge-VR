import Foundation
import CoreAudio
import BasaltBottleKit
import BasaltCore

/// What a running session would leave behind if the app died: written to the
/// data folder when a session starts and removed once it has stopped. The
/// next start that finds a marker whose app is gone cleans up after it.
public struct SessionMarker: Codable, Equatable, Sendable {
    public static let fileName = "ActiveSession.json"

    /// A process with its start time and executable, so that another process
    /// that later got the same pid is never taken for it.
    public struct ProcessIdentity: Codable, Equatable, Sendable {
        public var pid: Int32
        public var startSeconds: UInt64
        public var startMicroseconds: UInt64
        public var executable: String

        public init(_ process: BottleProcess) {
            pid = process.pid
            startSeconds = process.startSeconds
            startMicroseconds = process.startMicroseconds
            executable = process.executable
        }

        /// The process that has `pid` now; nil when there is none.
        public static func of(
            _ pid: Int32, access: any BottleProcessAccess = SystemBottleProcessAccess()
        ) -> ProcessIdentity? {
            (try? access.processes())?.first { $0.pid == pid }.map(ProcessIdentity.init)
        }

        /// Exactly this process, executable included: the test before a signal.
        func isSame(as process: BottleProcess) -> Bool {
            process.pid == pid && process.startSeconds == startSeconds
                && process.startMicroseconds == startMicroseconds
                && process.executable == executable
        }

        /// Whether this process still runs, by pid and start time alone. An
        /// app whose folder or disk was renamed while it runs is still that
        /// app; `executable` only says what it was.
        func isRunning(access: any BottleProcessAccess) throws -> Bool {
            try access.isRunning(pid: pid, startSeconds: startSeconds,
                                 startMicroseconds: startMicroseconds)
        }
    }

    /// Recorded only for a session that routes game audio to a loopback
    /// device (BlackHole): the streamer then changes the Mac's output.
    public struct AudioRoute: Codable, Equatable, Sendable {
        /// The Mac's output before the session.
        public var previousOutputUID: String
        /// The loopback device the session switches the output to.
        public var routedOutputUID: String

        /// Nil when nothing would change, or when either device is unknown.
        public init?(previousOutputUID: String?, routedOutputUID: String?) {
            guard let previousOutputUID, let routedOutputUID,
                  previousOutputUID != routedOutputUID else { return nil }
            self.previousOutputUID = previousOutputUID
            self.routedOutputUID = routedOutputUID
        }

        /// The switch a session with these settings is about to make.
        public static func expected(for settings: StreamLaunchSettings) -> AudioRoute? {
            guard case .device(let name) = settings.gameAudioChoice, !name.isEmpty,
                  let device = try? GameAudioDeviceDiscovery.matchingInputDevice(name) else {
                return nil
            }
            let output = SystemAudioOutput()
            return AudioRoute(previousOutputUID: output.defaultOutputUID(),
                              routedOutputUID: output.uid(of: device.id))
        }
    }

    /// The app instance that runs the session.
    public var app: ProcessIdentity
    public var streamer: ProcessIdentity?
    /// The environments in which Wine may run: the session's own first, then
    /// those in which an earlier stop could not stop it.
    public var bottles: [String]
    public var audio: AudioRoute?
    /// True when that app run started the app's own adb server, which then
    /// is its to stop.
    public var adbServerStarted: Bool

    public init(app: ProcessIdentity, streamer: ProcessIdentity? = nil,
                bottles: [String], audio: AudioRoute? = nil, adbServerStarted: Bool = false) {
        self.app = app
        self.streamer = streamer
        self.bottles = bottles
        self.audio = audio
        self.adbServerStarted = adbServerStarted
    }

    /// The marker of a session `app` starts in `bottle`. The environments
    /// `earlier`, the marker found in the data folder, still lists stay
    /// listed after it: Wine could not be stopped there.
    public init(app: ProcessIdentity, startingIn bottle: String, audio: AudioRoute?,
                adbServerStarted: Bool, keeping earlier: SessionMarker?) {
        self.init(app: app, bottles: [bottle] + (earlier?.bottles ?? []).filter { $0 != bottle },
                  audio: audio, adbServerStarted: adbServerStarted)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        app = try values.decode(ProcessIdentity.self, forKey: .app)
        streamer = try values.decodeIfPresent(ProcessIdentity.self, forKey: .streamer)
        bottles = try values.decode([String].self, forKey: .bottles)
        audio = try values.decodeIfPresent(AudioRoute.self, forKey: .audio)
        // A marker written before this was recorded says nothing about adb.
        adbServerStarted = try values.decodeIfPresent(Bool.self, forKey: .adbServerStarted) ?? false
    }
}

/// The marker's file in the data folder, on whichever disk that is.
public struct SessionMarkerStore: Sendable {
    public let file: URL

    public init(dataRoot: URL) {
        file = dataRoot.appendingPathComponent(SessionMarker.fileName)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    public func write(_ marker: SessionMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: file, options: .atomic)
    }

    /// Nil when there is no marker or it cannot be read.
    public func load() -> SessionMarker? {
        guard case .marker(let marker) = read() else { return nil }
        return marker
    }

    public enum Contents: Equatable, Sendable {
        /// Nothing is at the marker's path.
        case absent
        /// Something is there and could not be read at this moment: no
        /// permission, a read error on a share. It may be a good marker.
        case unreadable
        /// Bytes that were read and are not a marker.
        case damaged
        case marker(SessionMarker)
    }

    public func read() -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            // Not following a link: whatever is at the path is "there".
            return (try? FileManager.default.attributesOfItem(atPath: file.path)) == nil
                ? .absent : .unreadable
        }
        guard let marker = try? JSONDecoder().decode(SessionMarker.self, from: data) else {
            return .damaged
        }
        return .marker(marker)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The session `marker` was written for is over. With everything of it
    /// stopped, the marker goes, or stays for the environments it kept from
    /// earlier. Otherwise all of it stays, for the next start to stop.
    public func end(_ marker: SessionMarker, stopped: Bool) {
        guard stopped else { return }
        let kept = Array(marker.bottles.dropFirst())
        guard !kept.isEmpty else { return remove() }
        try? write(SessionMarker(app: marker.app, bottles: kept,
                                 adbServerStarted: marker.adbServerStarted))
    }
}

/// The Mac's default audio output, by device UID.
public protocol AudioOutputAccess: Sendable {
    func defaultOutputUID() -> String?
    func setDefaultOutput(uid: String) -> Bool
}

public struct SystemAudioOutput: AudioOutputAccess {
    public init() {}

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public func defaultOutputUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return uid(of: device)
    }

    public func uid(of device: AudioDeviceID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    public func setDefaultOutput(uid: String) -> Bool {
        var translate = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let found = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(Self.system, &translate,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        // A device that is no longer connected has no id.
        guard found == noErr, device != kAudioObjectUnknown else { return false }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(Self.system, &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }
}

/// Cleans up after a session whose app is gone: a crash, a force quit, or a
/// quit that ran out of time.
public enum LeftoverSession {
    public struct Cleanup: Equatable, Sendable {
        public var stoppedStreamer = false
        /// The environments whose Wine was stopped.
        public var bottles = [String]()
        public var restoredOutput = false
        public var stoppedADBServer = false
        /// The environments whose Wine could not be stopped, or not in time.
        /// The marker stays for them and the next start tries again.
        public var unfinished = [String]()
    }

    /// Does nothing and returns nil when there is no marker, or when the app
    /// that wrote it still runs. Otherwise stops the streamer if the marker's
    /// process is still that streamer, stops the adb server if the marker
    /// says that app run started it, stops Wine in the marker's environments
    /// through `stopWine`, puts the Mac's audio output back if it is still on
    /// the loopback device, and removes the marker. A marker that was read
    /// and is not one is removed; one that could not be read is kept.
    ///
    /// All of it takes about `bound` seconds at most: `stopWine` is told how
    /// long it may take, and gives up with an error after that. The marker
    /// then stays, for the environments that are left alone. One that no
    /// longer exists (`bottleExists`) has no Wine left to stop.
    public static func cleanUp(
        in store: SessionMarkerStore,
        access: any BottleProcessAccess = SystemBottleProcessAccess(),
        audio: any AudioOutputAccess = SystemAudioOutput(),
        bound: TimeInterval = 15,
        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        stopADBServer: () -> Void = {},
        bottleExists: (_ bottle: String) -> Bool = { _ in true },
        stopWine: (_ bottle: String, _ timeout: TimeInterval) throws -> Void
    ) -> Cleanup? {
        let marker: SessionMarker
        switch store.read() {
        case .absent:
            return nil
        case .unreadable:
            // It may be a good marker that only cannot be read right now:
            // it stays, and the next start looks again.
            return nil
        case .damaged:
            // Nothing can be learned from it, and it would stay forever.
            store.remove()
            return nil
        case .marker(let read):
            marker = read
        }
        // Without the process list nobody can tell whose session it is.
        guard let running = try? access.processes(),
              (try? marker.app.isRunning(access: access)) == false else { return nil }
        let deadline = uptime() + bound
        var cleanup = Cleanup()
        // First, so that the streamer puts the audio output back itself.
        cleanup.stoppedStreamer = stop(marker.streamer, among: running, access: access)
        // After the streamer, which still removes its adb forwards.
        if marker.adbServerStarted {
            stopADBServer()
            cleanup.stoppedADBServer = true
        }
        for bottle in marker.bottles where bottleExists(bottle) {
            let left = deadline - uptime()
            if left > 0, (try? stopWine(bottle, left)) != nil {
                cleanup.bottles.append(bottle)
            } else {
                cleanup.unfinished.append(bottle)
            }
        }
        if let uid = outputToRestore(marker.audio, currentOutputUID: audio.defaultOutputUID()) {
            cleanup.restoredOutput = audio.setDefaultOutput(uid: uid)
        }
        if cleanup.unfinished.isEmpty {
            store.remove()
        } else {
            // What is done is not done again at the next start.
            try? store.write(SessionMarker(app: marker.app, bottles: cleanup.unfinished))
        }
        return cleanup
    }

    /// The output to put back, and only while the Mac's output is still the
    /// loopback device: a choice the user has made since then stays.
    public static func outputToRestore(_ route: SessionMarker.AudioRoute?,
                                       currentOutputUID: String?) -> String? {
        guard let route, currentOutputUID == route.routedOutputUID else { return nil }
        return route.previousOutputUID
    }

    /// Asks the streamer to stop, then waits about three seconds for its
    /// teardown before killing it. A process that only shares the pid is
    /// never signalled: `access.signal` checks the identity once more.
    private static func stop(_ identity: SessionMarker.ProcessIdentity?,
                             among running: [BottleProcess],
                             access: any BottleProcessAccess) -> Bool {
        guard let identity, let process = running.first(where: identity.isSame(as:)),
              access.signal(SIGTERM, process: process) else { return false }
        for _ in 0..<30 {
            access.pause()
            guard let running = try? access.processes(), running.contains(process) else {
                return true
            }
        }
        _ = access.signal(SIGKILL, process: process)
        return true
    }
}

public enum SessionTeardown {
    /// Gives a pending operation time to finish while the main actor can
    /// still publish its result.
    @MainActor
    public static func wait(upTo timeout: Duration, until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done() {
            let now = clock.now
            guard now < deadline else { return }
            do { try await clock.sleep(until: min(deadline, now + .milliseconds(20))) }
            catch { return }
        }
    }

    /// Blocks until `done` answers true or `seconds` have passed; returns the
    /// last answer. For quitting, where the app waits for the streamer to
    /// restore the Mac's audio output, but never for long.
    public static func wait(
        upTo seconds: TimeInterval, interval: TimeInterval = 0.02,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        until done: () -> Bool
    ) -> Bool {
        var waited: TimeInterval = 0
        while !done() {
            guard waited < seconds else { return false }
            sleep(interval)
            waited += interval
        }
        return true
    }
}
