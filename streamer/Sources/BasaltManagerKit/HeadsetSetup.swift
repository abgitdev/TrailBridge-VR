import Foundation
import CryptoKit
import BasaltCore
import BasaltBottleKit

public struct PinnedHeadsetDownload: Equatable, Sendable {
    public enum Digest: Sendable { case sha1, sha256 }
    public let version: String
    public let url: URL
    public let checksum: String
    public let digest: Digest

    // Stable channel-0, macosx archive in Google's repository index:
    // https://dl.google.com/android/repository/repository2-3.xml
    // Google publishes SHA-1 for this archive, not SHA-256.
    public static let platformTools = Self(version: "37.0.1",
        url: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!,
        checksum: "6ae73f4de6452dc57e62ec02b68eed92a4c21661", digest: .sha1)
    // Tested client: the official ALVR 20.14.1 release APK and its SHA-256.
    public static let testedALVR = Self(version: "20.14.1",
        url: URL(string: "https://github.com/alvr-org/ALVR/releases/download/v20.14.1/alvr_client_android.apk")!,
        checksum: "be68feeb02665e3d69f1cdbcabf38ea4d15c42868a7ec6b5e698dbefee4e4e36", digest: .sha256)
    public static let googleTerms = URL(string: "https://developer.android.com/studio/terms")!

    public func verify(_ data: Data, requestedURL: URL) throws {
        guard requestedURL == url else { throw BottleToolError("The download URL does not match the pinned release.") }
        let actual: String
        switch digest {
        case .sha1: actual = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256: actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard actual == checksum else { throw BottleToolError("The download checksum does not match. Nothing was installed. Please try again.") }
    }

    /// Whether the file's bytes are the pinned ones. Read in pieces, so a
    /// large archive is never held in memory.
    public func matches(fileAt file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            switch digest {
            case .sha1: sha1.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            }
        }
        let actual: String
        switch digest {
        case .sha1: actual = sha1.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256: actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return actual == checksum
    }

    /// The hosts the download may end at after redirects.
    public var trustedHosts: [String] {
        url.host == "dl.google.com" ? ["dl.google.com"]
            : ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
    }

    /// Whether the address a download ended at is one of this pin's own.
    public func isTrustedSource(_ finalURL: URL) -> Bool {
        finalURL.scheme == "https" && trustedHosts.contains(finalURL.host ?? "")
    }
}

public struct HeadsetStatus: Equatable, Sendable {
    public enum Connection: Equatable, Sendable { case noTools, none, unauthorized, connected }
    public let connection: Connection
    public let serial: String?
    public let model: String?
    public let clientInstalled: Bool
    public let clientVersion: String?

    public init(connection: Connection, serial: String? = nil, model: String? = nil,
                clientInstalled: Bool = false, clientVersion: String? = nil) {
        self.connection = connection; self.serial = serial; self.model = model
        self.clientInstalled = clientInstalled; self.clientVersion = clientVersion
    }

    public static func parse(devices: String, package: String = "") -> Self {
        if let serial = AlvrADBDeviceParser.authorizedUSBSerial(from: devices) {
            let fields = devices.split(whereSeparator: \.isNewline).first {
                $0.split(whereSeparator: \.isWhitespace).first == Substring(serial)
            }?.split(whereSeparator: \.isWhitespace) ?? []
            let model = fields.first { $0.hasPrefix("model:") }.map {
                String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
            } ?? "Android headset"
            let version = package.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.first { $0.hasPrefix("versionName=") }.map { String($0.dropFirst(12)) }
            return Self(connection: .connected, serial: serial, model: model,
                        clientInstalled: package.contains("Package [alvr.client.stable]"), clientVersion: version)
        }
        return Self(connection: AlvrADBDeviceParser.hasUnauthorizedDevice(in: devices) ? .unauthorized : .none)
    }
}

public struct HeadsetCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

public protocol HeadsetCommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> HeadsetCommandResult
}

public struct HeadsetProcessRunner: HeadsetCommandRunning {
    public init() {}
    public func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> HeadsetCommandResult {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        // Bound an unresponsive adb/unzip; the reader drains the pipe while it runs.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        return HeadsetCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

public enum HeadsetInstallError: Error, LocalizedError {
    case signatureMismatch
    case newerVersionInstalled
    public var errorDescription: String? {
        switch self {
        case .signatureMismatch: "The installed ALVR client has a different signature."
        case .newerVersionInstalled: "Android cannot replace the newer installed ALVR client with this tested version in place."
        }
    }
}

/// Blocking process work belongs on a background task, never the main actor.
// FileManager operations are thread-safe; no delegate or mutable state is shared.
public struct HeadsetSetup: @unchecked Sendable {
    public let dataRoot: URL
    private let fileManager: FileManager
    private let runner: any HeadsetCommandRunning
    private let locateOverride: (@Sendable () -> URL?)?
    private let serverOwnership: AlvrADBServerOwnership
    public init(dataRoot: URL, runner: any HeadsetCommandRunning = HeadsetProcessRunner(),
                fileManager: FileManager = .default,
                locate: (@Sendable () -> URL?)? = nil,
                serverOwnership: AlvrADBServerOwnership = .shared) {
        self.dataRoot = dataRoot; self.runner = runner; self.fileManager = fileManager
        self.locateOverride = locate
        self.serverOwnership = serverOwnership
    }
    private func locate() -> URL? {
        if let locateOverride { return locateOverride() }
        return AlvrADBExecutableLocator.find(dataRoot: dataRoot, fileManager: fileManager)
    }
    public var adbAvailable: Bool { locate() != nil }
    private var environment: [String: String] {
        AlvrADBEnvironment.values(dataRoot: dataRoot, base: ProcessInfo.processInfo.environment)
    }
    private func adb(_ arguments: [String]) throws -> HeadsetCommandResult {
        guard let executable = locate() else { throw BottleToolError("Get Android Platform Tools first.") }
        _ = try Self.directory("Tools/Android", in: dataRoot)
        let result = try runner.run(executable, arguments, environment: environment)
        serverOwnership.note(output: result.output)
        return result
    }
    /// Stops the adb server when a command of this app run started it, as
    /// the app does on quit and before it removes itself. A server that was
    /// already running is somebody else's and stays. Returns whether it asked.
    @discardableResult
    public func stopServerIfStartedHere(
        stop: (URL, [String: String]) -> Void = { AlvrADBServer.stop(adb: $0, environment: $1) }
    ) -> Bool {
        guard serverOwnership.takeStarted() else { return false }
        return stopServerLeftByEarlierRun(stop: stop)
    }
    /// Stops the app's own adb server (its own port, never the one other
    /// tools use) without asking who started it. Only for a server that an
    /// app run which is gone started, as its session marker says. Returns
    /// whether it asked.
    @discardableResult
    public func stopServerLeftByEarlierRun(
        stop: (URL, [String: String]) -> Void = { AlvrADBServer.stop(adb: $0, environment: $1) }
    ) -> Bool {
        guard let executable = locate() else { return false }
        stop(executable, environment)
        return true
    }
    public func inspect() throws -> HeadsetStatus {
        guard adbAvailable else { return .init(connection: .noTools) }
        let devices = try checked(adb(["devices", "-l"]))
        let status = HeadsetStatus.parse(devices: devices)
        guard let serial = status.serial else { return status }
        let package = try checked(adb(["-s", serial, "shell", "dumpsys", "package", "alvr.client.stable"]))
        return .parse(devices: devices, package: package)
    }
    private func checked(_ result: HeadsetCommandResult) throws -> String {
        guard result.status == 0 else { throw BottleToolError("Headset command failed: \(result.output)") }
        return result.output
    }
    public func installClient(apk: URL, serial: String, replacingOldClient: Bool = false) throws {
        // Recheck the exact bytes even for a previously cached APK.
        try PinnedHeadsetDownload.testedALVR.verify(Data(contentsOf: apk), requestedURL: PinnedHeadsetDownload.testedALVR.url)
        try installVerifiedClient(apk: apk, serial: serial, replacingOldClient: replacingOldClient)
    }
    /// Internal seam for runner tests; production entry always verifies the APK first.
    func installVerifiedClient(apk: URL, serial: String, replacingOldClient: Bool) throws {
        if replacingOldClient { _ = try checked(adb(["-s", serial, "uninstall", "alvr.client.stable"])) }
        let result = try adb(["-s", serial, "install", "-r", apk.path])
        if result.output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || result.output.localizedCaseInsensitiveContains("signatures do not match") {
            throw HeadsetInstallError.signatureMismatch
        }
        if result.output.contains("INSTALL_FAILED_VERSION_DOWNGRADE") {
            throw HeadsetInstallError.newerVersionInstalled
        }
        _ = try checked(result)
        guard result.output.contains("Success") else { throw BottleToolError("ALVR installation did not report success: \(result.output)") }
    }

    public func installPlatformTools(zip: URL) throws {
        try PinnedHeadsetDownload.platformTools.verify(Data(contentsOf: zip), requestedURL: PinnedHeadsetDownload.platformTools.url)
        let directory = try Self.directory("Tools", in: dataRoot)
        let stage = directory.appendingPathComponent("platform-tools-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        _ = try checked(runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, stage.path], environment: environment))
        let extracted = stage.appendingPathComponent("platform-tools")
        guard fileManager.isExecutableFile(atPath: extracted.appendingPathComponent("adb").path) else {
            throw BottleToolError("Google's archive did not contain adb.")
        }
        let target = directory.appendingPathComponent("platform-tools")
        guard !fileManager.fileExists(atPath: target.path) else { throw BottleToolError("Platform Tools already exist. Nothing was replaced.") }
        try fileManager.moveItem(at: extracted, to: target)
    }

    /// A folder inside the data folder, created when it is not there. The
    /// data folder itself is never created: without it (its disk is not
    /// connected) this throws `DataFolderUnavailable`.
    public static func directory(_ relative: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(relative)
        try ManagedFolder.create(directory, inside: root, outside: outsideDataFolder)
        return directory
    }
    /// What `directory` throws, as a `BottleToolError`, for a folder that a
    /// link takes out of the data folder.
    public static let outsideDataFolder = "The download folder resolves outside the data folder."

    public static func download(_ pin: PinnedHeadsetDownload, into directory: URL,
                                fetch: (@Sendable (URL) async throws -> (Data, URL))? = nil) async throws -> URL {
        let (data, finalURL): (Data, URL)
        if let fetch { (data, finalURL) = try await fetch(pin.url) }
        else { (data, finalURL) = try await Self.fetch(pin.url) }
        guard pin.isTrustedSource(finalURL) else {
            throw BottleToolError("The download was redirected to an unexpected source.")
        }
        try pin.verify(data, requestedURL: pin.url)
        let file = directory.appendingPathComponent(pin.url.lastPathComponent)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else {
            throw BottleToolError("Download files must not be symbolic links.")
        }
        try data.write(to: file, options: .atomic)
        return file
    }
    private static func fetch(_ url: URL) async throws -> (Data, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, let final = response.url else {
            throw BottleToolError("Download failed. Check your internet connection and try again.")
        }
        return (data, final)
    }
}
