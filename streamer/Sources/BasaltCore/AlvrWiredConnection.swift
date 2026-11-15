import Foundation

public enum AlvrADBDeviceParser {
    public static func authorizedUSBSerial(from output: String) -> String? {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device",
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
                return nil
            }
            return String(fields[0])
        }.first
    }

    public static func hasUnauthorizedDevice(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).dropFirst().contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "unauthorized"
        }
    }

    public static func installedALVRPackage(from output: String) -> String? {
        let installed = Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst("package:".count)) : nil
        })
        return ["alvr.client", "alvr.client.stable", "alvr.client.dev"]
            .first(where: installed.contains)
    }

    public static func activityIsResumed(from output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .hasPrefix("mResumed=true")
        }
    }
}

public enum AlvrADBExecutableLocator {
    public static let standardFallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = standardFallbackDirectories,
        dataRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var visited = Set<String>()
        let managed = (dataRoot ?? environment["BASALT_DATA_DIR"].map { URL(fileURLWithPath: $0) })
            .map { $0.appendingPathComponent("Tools/platform-tools").path }
        // PATH comes first so scripts/tools/adb keeps its developer isolation.
        for directory in pathDirectories + [managed].compactMap({ $0 }) + fallbackDirectories
            where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("adb")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

public enum AlvrADBEnvironment {
    public static func values(dataRoot: URL, base: [String: String]) -> [String: String] {
        var environment = base
        // The chosen data folder, not the one the app was started with:
        // scripts/tools/adb finds the downloaded Platform Tools through it.
        environment["BASALT_DATA_DIR"] = dataRoot.path
        environment["ANDROID_USER_HOME"] = dataRoot.appendingPathComponent("Tools/Android").path
        environment["ANDROID_ADB_LOG_PATH"] = dataRoot.appendingPathComponent("Tools/adb.log").path
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        // Use the same managed server for setup and streaming, separate from
        // other tools. scripts/tools/adb overrides this with its developer policy.
        environment["ADB_SERVER_SOCKET"] = "tcp:localhost:5039"
        return environment
    }
}

/// The wired setup failures the management app explains to the user. It finds
/// them by these texts in the streamer's output, so keep the wording here and
/// let `AlvrWiredFailureTests` pin it.
public enum AlvrWiredFailure {
    public static let adbMissing =
        "Could not find adb; open Headset in TrailBridge and choose Get Android Platform Tools."
    public static let debuggingUnauthorized =
        "Quest USB debugging is unauthorized; accept the USB debugging prompt in the headset"
    public static let noAuthorizedQuest =
        "No authorized USB Quest found by adb; connect a data-capable cable and enable Developer Mode"
    public static let clientMissing =
        "No ALVR client package is installed on the USB headset"
    public static let pausedBehindLockScreen =
        "ALVR is paused behind the Quest lock screen. Put on and unlock the headset, keep the ALVR client open, then try Play VR again."
}

/// Owns ALVR's native USB setup for one authorized Android headset. `adb forward`
/// exposes the headset's control and stream listeners on localhost;
/// the negotiated wired flag makes ALVR use TCP for stream traffic.
public final class AlvrWiredConnection: @unchecked Sendable {
    public let serial: String
    public let packageName: String
    private let lock = NSLock()
    private var stopped = false

    private init(serial: String, packageName: String) {
        self.serial = serial
        self.packageName = packageName
    }

    public static func setup() throws -> AlvrWiredConnection {
        let devices = try runADB(["devices", "-l"])
        guard let serial = AlvrADBDeviceParser.authorizedUSBSerial(from: devices) else {
            if AlvrADBDeviceParser.hasUnauthorizedDevice(in: devices) {
                throw BasaltError(AlvrWiredFailure.debuggingUnauthorized)
            }
            throw BasaltError(AlvrWiredFailure.noAuthorizedQuest)
        }

        let packages = try runADB(["-s", serial, "shell", "pm", "list", "packages"])
        guard let package = AlvrADBDeviceParser.installedALVRPackage(from: packages) else {
            throw BasaltError(AlvrWiredFailure.clientMissing)
        }

        let ports = [AlvrDiscoveryListener.alvrPort, AlvrVideoStreamSender.defaultPort]
        var forwardedPorts = [UInt16]()
        do {
            for port in ports {
                _ = try runADB(["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"])
                forwardedPorts.append(port)
            }

            // Bringing the activity to the foreground is idempotent and avoids
            // force-stopping a VR-focused client. On Quest, an adb force-stop
            // followed by an immediate relaunch can leave the NativeActivity
            // resumed but temporarily denied HEAD_TRACKER access by Horizon.
            // Wake first: Android otherwise accepts the launch and immediately
            // pauses the activity, leaving ALVR's forwarded ports closed.
            _ = try? runADB(["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            _ = try runADB(["-s", serial, "shell", "monkey", "-p", package, "1"])

            var resumed = false
            for _ in 0..<20 {
                let activity = try runADB([
                    "-s", serial, "shell", "dumpsys", "activity", package,
                ])
                if AlvrADBDeviceParser.activityIsResumed(from: activity) {
                    resumed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard resumed else {
                throw BasaltError(AlvrWiredFailure.pausedBehindLockScreen)
            }
        } catch {
            // `setup()` has not returned an owner yet, so roll back any port
            // created before the failing command ourselves.
            for port in forwardedPorts {
                _ = try? runADB(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
            throw error
        }
        return AlvrWiredConnection(serial: serial, packageName: package)
    }

    /// A USB cable reconnect can discard adb's forwards. Recreate just those
    /// mappings; waking or relaunching ALVR belongs to initial setup only.
    public func restoreForwards() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        for port in [AlvrDiscoveryListener.alvrPort, AlvrVideoStreamSender.defaultPort] {
            _ = try Self.runADB(["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"])
        }
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        for port in [AlvrDiscoveryListener.alvrPort, AlvrVideoStreamSender.defaultPort] {
            _ = try? Self.runADB(["-s", serial, "forward", "--remove", "tcp:\(port)"])
        }
    }

    deinit { stop() }

    /// adb repeats the device serial in its own error text. The session log
    /// is copied into reports, so keep the serial out of it.
    static func redactingSerial(in text: String, arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "-s"), arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty else { return text }
        return text.replacingOccurrences(of: arguments[index + 1], with: "[serial]")
    }

    /// Tells the management app, which reads this output, that the adb
    /// server now running was started for this session.
    private static func announceServerStart(in output: String) {
        if AlvrADBServerOwnership.announcesServerStart(output) {
            print(AlvrADBServerOwnership.startedLine)
        }
    }

    @discardableResult
    private static func runADB(_ arguments: [String]) throws -> String {
        guard let adb = AlvrADBExecutableLocator.find() else {
            throw BasaltError(AlvrWiredFailure.adbMissing)
        }
        let process = Process()
        process.executableURL = adb
        process.arguments = arguments
        if let path = ProcessInfo.processInfo.environment["BASALT_DATA_DIR"] {
            let root = URL(fileURLWithPath: path)
            let directory = root.appendingPathComponent("Tools/Android")
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw BasaltError("Android tools folder resolves outside the data folder")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            process.environment = AlvrADBEnvironment.values(dataRoot: root, base: ProcessInfo.processInfo.environment)
        }
        do {
            let output = try AlvrADBProcess.run(process)
            announceServerStart(in: output)
            return output
        } catch {
            announceServerStart(in: error.localizedDescription)
            let operation = arguments.first == "-s" ? arguments.dropFirst(2).first : arguments.first
            throw BasaltError("adb \(operation ?? "command"): "
                + redactingSerial(in: error.localizedDescription, arguments: arguments))
        }
    }
}
