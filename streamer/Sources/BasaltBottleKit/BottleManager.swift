import Foundation

public struct BottleToolError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BottleEngineKind: String, Codable, CaseIterable, Sendable {
    case pinned
    case whisky
    case gptk
}

public struct BottleEngine: Equatable, Sendable {
    public let id: String
    public let kind: BottleEngineKind
    public let wineBinary: URL
    public let wineserverBinary: URL
    public let root: URL
    public let supportsBasaltDXMT: Bool

    public init(id: String, kind: BottleEngineKind, wineBinary: URL,
                wineserverBinary: URL, root: URL,
                supportsBasaltDXMT: Bool) {
        self.id = id
        self.kind = kind
        self.wineBinary = wineBinary
        self.wineserverBinary = wineserverBinary
        self.root = root
        self.supportsBasaltDXMT = supportsBasaltDXMT
    }
}

public struct ManagedBottle: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var engineKind: BottleEngineKind
    public var engineID: String
    public var prefixPath: String
    public var engineRootPath: String
    public var wineBinaryPath: String
    public var createdAt: Date
    public var dxmtInstalled: Bool
    public var runtimeInstalled: Bool

    public init(name: String, engine: BottleEngine, prefix: URL,
                engineRoot: URL, wineBinary: URL, createdAt: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        engineKind = engine.kind
        engineID = engine.id
        prefixPath = prefix.path
        engineRootPath = engineRoot.path
        wineBinaryPath = wineBinary.path
        self.createdAt = createdAt
        dxmtInstalled = false
        runtimeInstalled = false
    }

    /// Both the DXMT handoff and the OpenXR runtime are installed.
    public var isReadyForVR: Bool { dxmtInstalled && runtimeInstalled }
}

public enum LaunchSource: String, Codable, CaseIterable, Sendable {
    case direct
    case steam
    case bsmanager
    case itch
}

public struct LaunchProfile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var bottleName: String
    public var source: LaunchSource
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    /// Install folder of the game (a Windows path), for games whose executable
    /// is not at the top of it (a launcher, or `bin/win64`). Prepare VR looks
    /// for the game's OpenVR DLLs here. When nil, the `steamapps/common/<Game>`
    /// folder of `executable` is used, or the executable's own folder.
    public var gameRoot: String?
    /// The game's name as the user typed it when adding the game, shown in
    /// the Library. Nil means the Library derives a name from the executable,
    /// as for every profile saved before this field existed. Optional and
    /// left out of the file when nil, so the format version stays 1 and
    /// existing profiles keep their exact bytes.
    public var title: String?

    public init(name: String, bottleName: String, source: LaunchSource,
                executable: String, arguments: [String] = [],
                workingDirectory: String? = nil,
                environment: [String: String] = [:],
                gameRoot: String? = nil,
                title: String? = nil) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        self.bottleName = bottleName
        self.source = source
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.gameRoot = gameRoot
        self.title = title
    }
}

public struct CommandOutput: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let removedLeftoverProcesses: Int
    public let leftoverSweepSkipped: Bool
    public let forcedStop: Bool

    public init(status: Int32, output: String, removedLeftoverProcesses: Int = 0,
                leftoverSweepSkipped: Bool = false, forcedStop: Bool = false) {
        self.status = status
        self.output = output
        self.removedLeftoverProcesses = removedLeftoverProcesses
        self.leftoverSweepSkipped = leftoverSweepSkipped
        self.forcedStop = forcedStop
    }

    /// The combined output without surrounding whitespace, for error messages.
    public var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A fully resolved, validated process invocation for a launch profile.
/// Native front ends use this to own the child process lifecycle while the
/// CLI continues to use the synchronous command runner below.
public struct BottleLaunchCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL?
    public var frameTrace: FrameTraceSession? = nil
    /// Names of the profile's variables that were left out of `environment`
    /// (`BottleManager.withoutLoaderVariables`), sorted; for one log line.
    public var droppedEnvironment = [String]()
    /// The game a `steam.exe -applaunch` profile was resolved to, or nil when
    /// the profile names its executable itself; for one log line.
    public var steamLaunch: SteamDirectLaunch? = nil

    public init(executable: URL, arguments: [String],
                environment: [String: String], currentDirectory: URL?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public protocol BottleCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, timeout: TimeInterval) throws -> CommandOutput
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput
    /// Like `run`, for a game: the child gets an empty stdin that stays open until it
    /// exits (see `HeldOpenStandardInput`), not the caller's stdin.
    func runKeepingInputOpen(executable: URL, arguments: [String],
                             environment: [String: String],
                             currentDirectory: URL?) throws -> CommandOutput
}

extension BottleCommandRunning {
    public func run(executable: URL, arguments: [String], environment: [String: String],
                    currentDirectory: URL?, timeout: TimeInterval) throws -> CommandOutput {
        try run(executable: executable, arguments: arguments,
                environment: environment, currentDirectory: currentDirectory)
    }

    public func runKeepingInputOpen(executable: URL, arguments: [String],
                                    environment: [String: String],
                                    currentDirectory: URL?) throws -> CommandOutput {
        try run(executable: executable, arguments: arguments,
                environment: environment, currentDirectory: currentDirectory)
    }
}

public struct ProcessBottleCommandRunner: BottleCommandRunning {
    /// With a value, a command still running after that many seconds is
    /// stopped and reported as an error. Nil waits for as long as it takes.
    public let timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) { self.timeout = timeout }

    public func run(executable: URL, arguments: [String],
                    environment: [String: String], currentDirectory: URL?) throws
        -> CommandOutput {
        try execute(executable: executable, arguments: arguments, environment: environment,
                    currentDirectory: currentDirectory, keepsInputOpen: false, timeout: timeout)
    }

    public func run(executable: URL, arguments: [String],
                    environment: [String: String], currentDirectory: URL?,
                    timeout: TimeInterval) throws -> CommandOutput {
        try execute(executable: executable, arguments: arguments, environment: environment,
                    currentDirectory: currentDirectory, keepsInputOpen: false,
                    timeout: min(self.timeout ?? timeout, timeout))
    }

    public func runKeepingInputOpen(executable: URL, arguments: [String],
                                    environment: [String: String],
                                    currentDirectory: URL?) throws -> CommandOutput {
        try execute(executable: executable, arguments: arguments, environment: environment,
                    currentDirectory: currentDirectory, keepsInputOpen: true, timeout: timeout)
    }

    private func execute(executable: URL, arguments: [String],
                         environment: [String: String], currentDirectory: URL?,
                         keepsInputOpen: Bool, timeout: TimeInterval?) throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.removeValue(forKey: "BASALT_FRAME_TRACE")
        mergedEnvironment.removeValue(forKey: "BASALT_RECORD_VIDEO")
        for (key, value) in environment { mergedEnvironment[key] = value }
        process.environment = mergedEnvironment
        process.currentDirectoryURL = currentDirectory
        // Wine intentionally leaves wineserver and Windows service processes
        // alive after commands such as wineboot exit. Those descendants inherit
        // stdout/stderr, so reading a Pipe to EOF can block forever even though
        // the Process we launched has already terminated. A temporary regular
        // file lets us wait only for the direct child and then read its output.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BasaltVR-command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(
            atPath: outputURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw BottleToolError("Could not create temporary command output")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw BottleToolError("Could not open temporary command output: \(error.localizedDescription)")
        }
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        var input: HeldOpenStandardInput?
        do {
            if keepsInputOpen {
                input = try HeldOpenStandardInput.run(process)
            } else {
                try process.run()
            }
        } catch {
            throw BottleToolError("Could not run \(executable.path): \(error.localizedDescription)")
        }
        if let timeout {
            let uptime = { ProcessInfo.processInfo.systemUptime }
            let deadline = uptime() + timeout
            while process.isRunning, uptime() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                // One that ignores SIGTERM must not outlast the bound either.
                let grace = uptime() + 0.2
                while process.isRunning, uptime() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                input?.close()
                throw BottleToolError(String(
                    format: "%@ did not finish in %.0f s and was stopped",
                    executable.lastPathComponent, timeout))
            }
        }
        process.waitUntilExit()
        input?.close()
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}

/// An environment or a game profile whose file the app cannot read. It is
/// listed so that it does not vanish without a word while its name stays
/// taken; nothing in it is changed.
public struct DamagedItem: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// The file is there but could not be read: no permission, a folder
        /// or a dangling link at its path, a read error on a share.
        case unreadable(String)
        /// The bytes were read and are not what the app writes.
        case damaged(String)
        /// Written by another version of the app.
        case unsupportedVersion(Int)

        /// A short technical note, for "Details".
        public var detail: String {
            switch self {
            case .unreadable(let why): "the file could not be opened (\(why))"
            case .damaged(let why): "the file is damaged (\(why))"
            case .unsupportedVersion(let version): "unsupported metadata version \(version)"
            }
        }
    }

    /// The environment's folder name, or the profile's file name without
    /// `.json`: the name that stays taken.
    public let name: String
    /// `bottle.json` or the profile file.
    public let file: URL
    public let reason: Reason

    public var id: String { file.path }
}

public enum BottleName {
    public static func validate(_ value: String, kind: String = "name") throws -> String {
        guard !value.isEmpty, value.count <= 64,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                          options: .regularExpression) != nil else {
            throw BottleToolError(
                "Invalid \(kind) '\(value)'; use 1-64 ASCII letters, digits, '.', '_', or '-', starting with a letter or digit")
        }
        return value
    }
}

public struct BasaltManagedPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var profiles: URL { root.appendingPathComponent("Profiles", isDirectory: true) }

    public func bottleDirectory(_ name: String) throws -> URL {
        let safeName = try BottleName.validate(name, kind: "bottle name")
        return bottles.appendingPathComponent(safeName, isDirectory: true)
    }

    public func bottleMetadata(_ name: String) throws -> URL {
        try bottleDirectory(name).appendingPathComponent("bottle.json")
    }

    public func profileFile(_ name: String) throws -> URL {
        let safeName = try BottleName.validate(name, kind: "profile name")
        return profiles.appendingPathComponent(safeName).appendingPathExtension("json")
    }

    public func contains(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }
}

public enum BottleEngineDiscovery {
    public static let pinnedDXMTEngineID = "pinned-wine-11.10-dxmt-0.80"

    /// Where the app keeps the Wine it downloads, inside the data folder.
    public static let downloadedWineFolder = "Tools/wine-11.10"
    /// Wine's own root inside the published app bundle.
    public static let wineRootInBundle = "Wine Devel.app/Contents/Resources/wine"
    /// The downloaded Wine's root in `dataRoot`, there or not.
    public static func downloadedWineRoot(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(downloadedWineFolder, isDirectory: true)
            .appendingPathComponent(wineRootInBundle, isDirectory: true)
    }

    /// Whether `root` holds a pinned Wine that can run. The Basalt winemetal
    /// fork supplies a Cocoa fallback when this Wine driver hides DXMT's
    /// optional Metal-view bridge exports; requiring the driver itself also
    /// keeps incomplete Wine bundles out.
    public static func isUsablePinnedWine(_ root: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: root.appendingPathComponent("bin/wine").path)
            && fileManager.isExecutableFile(atPath: root.appendingPathComponent("bin/wineserver").path)
            && fileManager.fileExists(
                atPath: root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so").path)
    }

    /// The pinned Wine is the one built in a source checkout, else the one
    /// the app downloaded into `dataRoot`; both are the same engine.
    public static func discover(repoRoot: URL,
                                dataRoot: URL? = nil,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> [BottleEngine] {
        var engines = [BottleEngine]()

        let pinnedRoots = [
            repoRoot.appendingPathComponent(
                "runtime/build/dxmt/toolchain/wine-11.10", isDirectory: true)
                .appendingPathComponent(wineRootInBundle, isDirectory: true),
        ] + (dataRoot.map { [downloadedWineRoot(dataRoot: $0)] } ?? [])
        let fork = repoRoot.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        if let pinnedRoot = pinnedRoots.first(where: {
            isUsablePinnedWine($0, fileManager: fileManager)
        }) {
            engines.append(BottleEngine(
                id: pinnedDXMTEngineID, kind: .pinned,
                wineBinary: pinnedRoot.appendingPathComponent("bin/wine"),
                wineserverBinary: pinnedRoot.appendingPathComponent("bin/wineserver"),
                root: pinnedRoot, supportsBasaltDXMT: fileManager.fileExists(atPath: fork.path)))
        }

        let whiskyRoot = home.appendingPathComponent(
            "Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine",
            isDirectory: true)
        let whiskyWine = whiskyRoot.appendingPathComponent("bin/wine64")
        let whiskyServer = whiskyRoot.appendingPathComponent("bin/wineserver")
        if fileManager.isExecutableFile(atPath: whiskyWine.path),
           fileManager.isExecutableFile(atPath: whiskyServer.path) {
            engines.append(BottleEngine(
                id: "whisky-shared", kind: .whisky,
                wineBinary: whiskyWine, wineserverBinary: whiskyServer,
                root: whiskyRoot, supportsBasaltDXMT: false))
        }

        let gptkRoots = [
            URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine"),
            URL(fileURLWithPath: "/Applications/Game Porting Toolkit 2.app/Contents/Resources/wine"),
            URL(fileURLWithPath: "/usr/local/apple/apple_gptk"),
        ]
        for (index, root) in gptkRoots.enumerated() {
            let wine64 = root.appendingPathComponent("bin/wine64")
            let wine = fileManager.isExecutableFile(atPath: wine64.path)
                ? wine64 : root.appendingPathComponent("bin/wine")
            let server = root.appendingPathComponent("bin/wineserver")
            if fileManager.isExecutableFile(atPath: wine.path),
               fileManager.isExecutableFile(atPath: server.path) {
                engines.append(BottleEngine(
                    id: "gptk-\(index + 1)", kind: .gptk,
                    wineBinary: wine, wineserverBinary: server,
                    root: root, supportsBasaltDXMT: false))
            }
        }
        return engines
    }
}

public final class BottleManager: @unchecked Sendable {
    public static let wineStopLimit: TimeInterval = 10

    public let paths: BasaltManagedPaths
    public let repoRoot: URL
    private let fileManager: FileManager
    private let runner: any BottleCommandRunning
    private let processAccess: any BottleProcessAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// False for a folder that was chosen or checked before, which is then
    /// never created by `prepare()`.
    private let createsDataFolder: Bool
    /// The disk the data folder was on when this manager first saw it.
    private let volumeLock = NSLock()
    private var openedVolume: VolumeIdentity?

    /// Touches no file. With `createsDataFolder` off, `prepare()` never
    /// creates the data folder itself: the app passes that for every folder
    /// it has already found in place (a chosen one, a saved one), so that a
    /// folder whose disk has left is not built again on another disk.
    public init(root: URL, repoRoot: URL,
                fileManager: FileManager = .default,
                runner: any BottleCommandRunning = ProcessBottleCommandRunner(),
                processAccess: any BottleProcessAccess = SystemBottleProcessAccess(),
                createsDataFolder: Bool = true) {
        self.createsDataFolder = createsDataFolder
        paths = BasaltManagedPaths(root: root)
        self.repoRoot = repoRoot.standardizedFileURL
        self.fileManager = fileManager
        self.runner = runner
        self.processAccess = processAccess
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = ProcessInfo.processInfo.environment["BASALT_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(
            "Library/Application Support/BasaltVR", isDirectory: true)
    }

    /// The data folder with the disk it was on when this manager first saw
    /// it; nil while it has never been there.
    public var openedDataFolder: OpenedDataFolder? {
        volumeLock.withLock { openedVolume }.map { OpenedDataFolder(folder: paths.root, volume: $0) }
    }

    /// Makes the data folder's own folders. The data folder itself is
    /// created only when this manager may create it and has never seen it
    /// (a first start with the default folder, the command-line tool). Once
    /// it was there, it is never created again: a folder that is gone, or
    /// that is now on another disk, means its disk was disconnected, and
    /// `DataFolderUnavailable` is thrown instead of building an empty data
    /// folder on the disk underneath.
    public func prepare() throws {
        let current = VolumeIdentity.of(paths.root)
        let opened = volumeLock.withLock { () -> VolumeIdentity? in
            if openedVolume == nil { openedVolume = current }
            return openedVolume
        }
        if let opened {
            guard let current, current.isSameVolume(as: opened) else {
                throw DataFolderUnavailable(folder: paths.root)
            }
        } else {
            guard createsDataFolder else { throw DataFolderUnavailable(folder: paths.root) }
            try fileManager.createDirectory(at: paths.root,
                                            withIntermediateDirectories: true)
            let created = VolumeIdentity.of(paths.root)
            volumeLock.withLock { openedVolume = created }
        }
        // One level each, inside the folder that exists: never the root again.
        for directory in [paths.bottles, paths.profiles] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch CocoaError.fileNoSuchFile {
                throw DataFolderUnavailable(folder: paths.root)
            }
        }
        let resolvedRoot = paths.root.resolvingSymlinksInPath()
        for directory in [paths.bottles, paths.profiles] {
            let resolved = directory.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
                throw BottleToolError(
                    "Managed directory resolves outside the Basalt data root: \(directory.path)")
            }
        }
    }

    public func engines() -> [BottleEngine] {
        BottleEngineDiscovery.discover(repoRoot: repoRoot, dataRoot: paths.root,
                                       fileManager: fileManager)
    }

    public func listBottles() throws -> [ManagedBottle] {
        try scanBottles().bottles
    }

    /// The environments whose `bottle.json` is there but cannot be read.
    /// A folder with no `bottle.json` is not an environment and is not listed.
    public func listDamagedBottles() throws -> [DamagedItem] {
        try scanBottles().damaged
    }

    private func scanBottles() throws -> (bottles: [ManagedBottle], damaged: [DamagedItem]) {
        guard fileManager.fileExists(atPath: paths.bottles.path) else { return ([], []) }
        var discovered: [BottleEngine]?
        var bottles = [ManagedBottle](), damaged = [DamagedItem]()
        for directory in try fileManager.contentsOfDirectory(
            at: paths.bottles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let metadata = directory.appendingPathComponent("bottle.json")
            switch contents(ManagedBottle.self, of: metadata) {
            case .missing:
                continue
            case .failure(let reason):
                damaged.append(DamagedItem(
                    name: directory.lastPathComponent, file: metadata, reason: reason))
            case .value(let bottle):
                guard isManagedItem(directory, named: try? paths.bottleDirectory(bottle.name)) else {
                    continue
                }
                bottles.append(withCurrentPaths(bottle) {
                    if discovered == nil { discovered = engines() }
                    return discovered ?? []
                })
            }
        }
        return (bottles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                damaged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private enum FileContents<Value> {
        /// Nothing is at the path.
        case missing
        case value(Value)
        case failure(DamagedItem.Reason)
    }

    /// Reads one metadata file, telling a file that is not there from one
    /// that is there and cannot be read, and from one that is not metadata.
    private func contents<Value: Decodable>(_ type: Value.Type, of file: URL) -> FileContents<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            // Not following a link: a dangling one is there, and unreadable.
            guard (try? fileManager.attributesOfItem(atPath: file.path)) != nil else { return .missing }
            return .failure(.unreadable(error.localizedDescription))
        }
        do {
            return .value(try decoder.decode(type, from: data))
        } catch {
            return .failure(.damaged(Self.describe(error)))
        }
    }

    /// What is wrong with the JSON, in a few words: Foundation's own text
    /// ("The data couldn't be read because it isn't in the correct format")
    /// names neither the file nor the field.
    static func describe(_ error: any Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "'\(key.stringValue)' is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "'\(path(context))' has the wrong type"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "'\(path(context))' is not valid"
        default: return error.localizedDescription
        }
    }

    /// Moves a damaged environment's whole folder, with the profiles of its
    /// games, or a damaged profile's file to the Trash. Only for an item
    /// that is still listed as damaged, and never through a link.
    public func removeDamaged(
        _ item: DamagedItem,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let file = item.file.standardizedFileURL
        if try listDamagedProfiles().contains(where: { $0.file.standardizedFileURL.path == file.path }) {
            try trash(file)
            return
        }
        guard try listDamagedBottles().contains(where: { $0.file.standardizedFileURL.path == file.path }) else {
            throw BottleToolError("'\(item.name)' is no longer listed as damaged")
        }
        let directory = file.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().path == paths.bottles.standardizedFileURL.path,
              directory.resolvingSymlinksInPath().path.hasPrefix(
                paths.bottles.resolvingSymlinksInPath().path + "/"),
              (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
            throw BottleToolError("Refusing to remove a bottle outside the managed folder")
        }
        for profile in try listProfiles() where profile.bottleName == item.name {
            try trash(try paths.profileFile(profile.name))
        }
        try trash(directory)
    }

    /// A bottle or profile is listed only from the item the app itself reads
    /// under that name, so no two listed ones share a name. A copy made in
    /// Finder ("x copy", whose metadata still says "x") is another item: it is
    /// not listed and not touched. The same name in another case on a
    /// case-insensitive volume is the same item and stays listed.
    private func isManagedItem(_ found: URL, named expected: URL?) -> Bool {
        guard let expected else { return false }
        if found.lastPathComponent == expected.lastPathComponent { return true }
        guard found.lastPathComponent.caseInsensitiveCompare(expected.lastPathComponent) == .orderedSame,
              let foundID = try? found.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let expectedID = try? expected.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return foundID.isEqual(expectedID)
    }

    public func loadBottle(_ name: String) throws -> ManagedBottle {
        let metadata = try paths.bottleMetadata(name)
        let stored: ManagedBottle
        switch contents(ManagedBottle.self, of: metadata) {
        case .missing:
            throw BottleToolError("Managed bottle '\(name)' does not exist")
        case .failure(let reason):
            throw BottleToolError("Managed bottle '\(name)' cannot be read: \(reason.detail)")
        case .value(let value):
            stored = value
        }
        guard stored.formatVersion == ManagedBottle.currentFormatVersion else {
            throw BottleToolError("Bottle '\(name)' uses unsupported metadata version \(stored.formatVersion)")
        }
        // A data folder that was renamed, moved, or mounted under another
        // name: the paths are brought to the current folder in memory, and
        // the checks below then run on them exactly as on stored ones.
        let bottle = withCurrentPaths(stored, engines: engines)
        let directory = try paths.bottleDirectory(name).standardizedFileURL
        let expectedPrefix = directory.appendingPathComponent(
            "prefix", isDirectory: true).standardizedFileURL
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath).standardizedFileURL
        let wine = URL(fileURLWithPath: bottle.wineBinaryPath).standardizedFileURL
        // Paths, not URLs: the same folder can be written as two unequal URLs.
        guard bottle.name == name, prefix.path == expectedPrefix.path else {
            throw BottleToolError("Bottle '\(name)' metadata does not match its managed directory")
        }
        let resolvedRoot = paths.root.resolvingSymlinksInPath()
        guard prefix.resolvingSymlinksInPath().path.hasPrefix(
                resolvedRoot.path + "/") else {
            throw BottleToolError("Bottle '\(name)' prefix resolves outside the managed root")
        }
        guard wine.path.hasPrefix(engineRoot.path + "/") else {
            throw BottleToolError("Bottle '\(name)' Wine executable is outside its engine")
        }
        if bottle.engineKind == .pinned {
            let expectedEngine = directory.appendingPathComponent(
                "engine", isDirectory: true).standardizedFileURL
            guard engineRoot.path == expectedEngine.path,
                  wine.path == expectedEngine.appendingPathComponent("bin/wine").path else {
                throw BottleToolError(
                    "Bottle '\(name)' pinned engine escapes its managed directory")
            }
        } else {
            guard let discovered = engines().first(where: {
                $0.id == bottle.engineID && $0.kind == bottle.engineKind
            }), discovered.root.standardizedFileURL == engineRoot,
               discovered.wineBinary.standardizedFileURL == wine else {
                throw BottleToolError(
                    "Bottle '\(name)' shared \(bottle.engineKind.rawValue) engine is no longer available")
            }
        }
        return bottle
    }

    /// `bottle.json` stores absolute paths, written when the bottle was made.
    /// The data folder may since have been renamed, moved, or mounted under
    /// another name (it can be on an internal, external or network disk), so
    /// this returns the bottle with the paths it has under the data folder in
    /// use now. Nothing is written: `bottle.json` gets the current paths the
    /// next time the app saves the bottle for another reason.
    ///
    /// A stored path that already is the current one is kept as written. The
    /// prefix and a pinned engine live in the bottle's own directory, so a
    /// stored path that names the same place under another root
    /// (`<other root>/Bottles/<name>/prefix`) becomes the current one; any
    /// other path is left alone, and `loadBottle` refuses it. A shared engine
    /// lives outside the data folder and gets the paths discovery gives it
    /// now, the same ones a new bottle would get. Either way a `bottle.json`
    /// cannot point the app at a place the app would not have chosen itself.
    private func withCurrentPaths(_ stored: ManagedBottle,
                                  engines: () -> [BottleEngine]) -> ManagedBottle {
        guard let directory = try? paths.bottleDirectory(stored.name).standardizedFileURL else {
            return stored
        }
        var bottle = stored
        let own = ["Bottles", stored.name]
        bottle.prefixPath = Self.currentPath(
            stored.prefixPath,
            expected: directory.appendingPathComponent("prefix", isDirectory: true),
            tail: own + ["prefix"])
        if stored.engineKind == .pinned {
            let engine = directory.appendingPathComponent("engine", isDirectory: true)
            bottle.engineRootPath = Self.currentPath(
                stored.engineRootPath, expected: engine, tail: own + ["engine"])
            bottle.wineBinaryPath = Self.currentPath(
                stored.wineBinaryPath, expected: engine.appendingPathComponent("bin/wine"),
                tail: own + ["engine", "bin", "wine"])
        } else if let engine = engines().first(where: {
            $0.id == stored.engineID && $0.kind == stored.engineKind
        }) {
            if URL(fileURLWithPath: stored.engineRootPath).standardizedFileURL
                != engine.root.standardizedFileURL {
                bottle.engineRootPath = engine.root.path
            }
            if URL(fileURLWithPath: stored.wineBinaryPath).standardizedFileURL
                != engine.wineBinary.standardizedFileURL {
                bottle.wineBinaryPath = engine.wineBinary.path
            }
        }
        return bottle
    }

    /// `stored` when it is `expected` or does not end in `tail`; otherwise the
    /// path of `expected`, the same place under the current data folder.
    static func currentPath(_ stored: String, expected: URL, tail: [String]) -> String {
        let components = URL(fileURLWithPath: stored).standardizedFileURL.pathComponents
        let current = expected.standardizedFileURL
        guard components != current.pathComponents,
              components.count > tail.count, Array(components.suffix(tail.count)) == tail else {
            return stored
        }
        return current.path
    }

    /// A profile stores its working directory as a path on this Mac, which for
    /// a game in a managed bottle lies inside the bottle's prefix. `stored`
    /// when it is inside `prefix` now, or is not a path into a prefix of
    /// `bottleName` at all (a folder elsewhere on the Mac); otherwise the same
    /// place inside `prefix`, for a data folder whose path has changed.
    static func currentHostPath(_ stored: String, bottleName: String, prefix: URL) -> String {
        let components = URL(fileURLWithPath: stored).standardizedFileURL.pathComponents
        let current = prefix.standardizedFileURL
        let marker = ["Bottles", bottleName, "prefix"]
        guard stored.hasPrefix("/"),
              Array(components.prefix(current.pathComponents.count)) != current.pathComponents,
              components.count > marker.count,
              let start = (1...(components.count - marker.count)).first(where: {
                  Array(components[$0..<($0 + marker.count)]) == marker
              }) else { return stored }
        return components[(start + marker.count)...].reduce(current) {
            $0.appendingPathComponent($1)
        }.path
    }

    public func createBottle(name: String, engineID: String) throws -> ManagedBottle {
        try createBottle(name: name, engineID: engineID, initializePrefix: true)
    }

    private func createBottle(name: String, engineID: String,
                              initializePrefix: Bool) throws -> ManagedBottle {
        try prepare()
        let directory = try paths.bottleDirectory(name)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw BottleToolError("Managed bottle '\(name)' already exists")
        }
        guard let engine = engines().first(where: { $0.id == engineID }) else {
            throw BottleToolError("Wine engine '\(engineID)' is not available")
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        // A half-made bottle keeps its name taken and has no delete action, so
        // every failure after this point removes the directory again.
        var created = false
        defer { if !created { try? fileManager.removeItem(at: directory) } }
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let selectedEngineRoot: URL
        let selectedWine: URL
        if engine.kind == .pinned {
            let isolated = directory.appendingPathComponent("engine", isDirectory: true)
            let clone = try runner.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", engine.root.path, isolated.path],
                environment: [:], currentDirectory: nil)
            guard clone.status == 0 else {
                throw BottleToolError("Could not clone the pinned Wine engine: \(clone.trimmedOutput)")
            }
            selectedEngineRoot = isolated
            selectedWine = isolated.appendingPathComponent("bin/wine")
        } else {
            selectedEngineRoot = engine.root
            selectedWine = engine.wineBinary
        }

        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        var bottle = ManagedBottle(
            name: name, engine: engine, prefix: prefix,
            engineRoot: selectedEngineRoot, wineBinary: selectedWine)
        try saveBottle(bottle)

        guard initializePrefix else {
            created = true
            return bottle
        }

        let bootBinary = selectedEngineRoot.appendingPathComponent("bin/wineboot")
        let boot: CommandOutput
        if fileManager.isExecutableFile(atPath: bootBinary.path) {
            boot = try bottleCommand(
                bottle: bottle, executable: bootBinary, arguments: ["-u"],
                extraEnvironment: [:])
        } else {
            boot = try wineCommand(
                bottle: bottle, arguments: ["wineboot", "-u"],
                extraEnvironment: [:])
        }
        guard boot.status == 0 else {
            throw BottleToolError("wineboot failed for '\(name)': \(boot.trimmedOutput)")
        }
        bottle = try loadBottle(name)
        try suppressCrashDialogs(in: name)
        created = true
        return bottle
    }

    /// Creates an isolated Basalt bottle, then APFS-clones an existing Wine
    /// prefix into it. The source is never patched or modified. This is the
    /// supported bridge from Whisky/CrossOver into the Basalt VR runtime.
    public func importPrefix(name: String, engineID: String,
                             sourcePrefix: URL) throws -> ManagedBottle {
        let source = sourcePrefix.standardizedFileURL
        guard fileManager.fileExists(atPath: source.appendingPathComponent("drive_c").path),
              fileManager.fileExists(atPath: source.appendingPathComponent("system.reg").path) else {
            throw BottleToolError("Import source is not a complete Wine prefix: \(source.path)")
        }
        guard !paths.contains(source) else {
            throw BottleToolError("A managed Basalt prefix cannot be imported as an external bottle")
        }
        // Do not boot an imported prefix here. wineboot processes Windows Run
        // entries, which can launch Steam's updater and turn a file copy into an
        // unexpected interactive/network operation. The first intentional Wine
        // launch will update the cloned prefix with the selected engine.
        let bottle = try createBottle(
            name: name, engineID: engineID, initializePrefix: false)
        do {
            let destination = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            let copy = try runner.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", source.path + "/.", destination.path],
                environment: [:], currentDirectory: nil)
            guard copy.status == 0 else {
                throw BottleToolError(
                    "Could not copy the external prefix: "
                        + copy.trimmedOutput)
            }
            try suppressSteamAutoLaunch(in: destination)
            return try loadBottle(name)
        } catch {
            try? fileManager.removeItem(at: paths.bottleDirectory(name))
            throw error
        }
    }

    /// Prevent Wine maintenance commands from processing Steam's login Run
    /// entry. This only changes the isolated managed clone; launching Steam or
    /// a Steam profile explicitly continues to work normally.
    private func suppressSteamAutoLaunch(in prefix: URL) throws {
        let registry = prefix.appendingPathComponent("user.reg")
        guard fileManager.fileExists(atPath: registry.path) else { return }
        var lines = try String(contentsOf: registry, encoding: .utf8)
            .components(separatedBy: "\n")
        var section = ""
        var changed = false
        lines = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                return line
            }
            if section == #"[software\\microsoft\\windows\\currentversion\\run]"#,
               trimmed.lowercased().hasPrefix(#""steam"="#) {
                changed = true
                return nil
            }
            if section == #"[software\\valve\\steam]"#,
               trimmed.lowercased().hasPrefix(#""suppressautorun"="#),
               trimmed.lowercased() != #""suppressautorun"=dword:00000001"# {
                changed = true
                return #""SuppressAutoRun"=dword:00000001"#
            }
            return line
        }
        if changed {
            try lines.joined(separator: "\n").write(
                to: registry, atomically: true, encoding: .utf8)
        }
    }

    public func installDXMT(in name: String) throws -> ManagedBottle {
        var bottle = try loadBottle(name)
        guard bottle.engineKind == .pinned else {
            throw BottleToolError(
                "Basalt DXMT requires an isolated pinned engine; shared \(bottle.engineKind.rawValue) engines are never patched")
        }
        guard let compatibleEngine = engines().first(where: {
            $0.kind == .pinned && $0.supportsBasaltDXMT
        }) else {
            throw BottleToolError(
                "The pinned Wine/DXMT engine is unavailable; build the Basalt DXMT fork first")
        }
        if bottle.engineID != compatibleEngine.id {
            bottle = try replacePinnedEngine(in: bottle, with: compatibleEngine)
        }
        let fork = repoRoot.appendingPathComponent("runtime/build/dxmt/fork-install")
        let windows = fork.appendingPathComponent("x86_64-windows")
        let unix = fork.appendingPathComponent("x86_64-unix/winemetal.so")
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath)
        let engineWindows = engineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let engineUnix = engineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")
        let system32 = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c/windows/system32")
        try fileManager.createDirectory(at: engineWindows, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            let source = windows.appendingPathComponent(dll)
            guard fileManager.fileExists(atPath: source.path) else {
                throw BottleToolError("Missing Basalt DXMT artifact: \(source.path)")
            }
            try copyFile(source, to: engineWindows.appendingPathComponent(dll))
            try copyFile(source, to: system32.appendingPathComponent(dll))
        }
        guard fileManager.fileExists(atPath: unix.path) else {
            throw BottleToolError("Missing Basalt DXMT artifact: \(unix.path)")
        }
        try copyFile(unix, to: engineUnix)
        bottle.dxmtInstalled = true
        try saveBottle(bottle)
        return bottle
    }

    /// Replaces only the bottle's isolated Wine program files. The prefix,
    /// installed games, Steam data, and profiles remain untouched. This moves
    /// legacy bottles onto the pinned Wine engine used by Basalt's tested
    /// D3DKMT shared-resource path.
    private func replacePinnedEngine(in existing: ManagedBottle,
                                     with provider: BottleEngine) throws -> ManagedBottle {
        var bottle = existing
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath, isDirectory: true)
            .standardizedFileURL
        let bottleDirectory = try paths.bottleDirectory(bottle.name).standardizedFileURL
        let expectedEngine = bottleDirectory.appendingPathComponent(
            "engine", isDirectory: true).standardizedFileURL
        guard engineRoot == expectedEngine else {
            throw BottleToolError("Refusing to replace a pinned engine outside its bottle")
        }

        let token = UUID().uuidString
        let replacement = bottleDirectory.appendingPathComponent(
            "engine-upgrade-\(token)", isDirectory: true)
        let backup = bottleDirectory.appendingPathComponent(
            "engine-backup-\(token)", isDirectory: true)
        let clone = try runner.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-cR", provider.root.path, replacement.path],
            environment: [:], currentDirectory: nil)
        guard clone.status == 0,
              fileManager.isExecutableFile(atPath: replacement.appendingPathComponent("bin/wine").path),
              fileManager.fileExists(atPath: replacement.appendingPathComponent(
                "lib/wine/x86_64-unix/winemac.so").path) else {
            try? fileManager.removeItem(at: replacement)
            throw BottleToolError(
                "Could not clone the DXMT-matched Wine engine: "
                    + clone.trimmedOutput)
        }

        do {
            try fileManager.moveItem(at: engineRoot, to: backup)
            try fileManager.moveItem(at: replacement, to: engineRoot)
            bottle.engineID = provider.id
            bottle.wineBinaryPath = engineRoot.appendingPathComponent("bin/wine").path
            bottle.dxmtInstalled = false
            try saveBottle(bottle)
            try? fileManager.removeItem(at: backup)
            return bottle
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                if fileManager.fileExists(atPath: engineRoot.path) {
                    try? fileManager.moveItem(at: engineRoot, to: replacement)
                }
                try? fileManager.moveItem(at: backup, to: engineRoot)
            }
            try? fileManager.removeItem(at: replacement)
            throw error
        }
    }

    public func installRuntime(in name: String) throws -> ManagedBottle {
        try installRuntime(in: name, alwaysRegister: true)
    }

    /// Brings a stopped bottle's runtime in line with this build before a
    /// launch. Unchanged files are left alone, and Wine runs to register the
    /// runtime only when the bottle's registry hive does not already name it:
    /// starting Wine cold-boots the prefix, which a launch otherwise pays for
    /// on every Play. Call it only while the bottle's wineserver is stopped,
    /// since a running server may not have flushed `system.reg` yet.
    @discardableResult
    public func syncRuntime(in name: String) throws -> ManagedBottle {
        try installRuntime(in: name, alwaysRegister: false)
    }

    /// Set once per managed prefix, including bottles created before this
    /// policy existed. Write the marker only after Wine accepts the setting.
    public func suppressCrashDialogs(in name: String) throws {
        let bottle = try loadBottle(name)
        let marker = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent(".trailbridge-crash-dialog-disabled-v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        let result = try wineCommand(bottle: bottle, arguments: [
            "reg.exe", "add", #"HKCU\Software\Wine\WineDbg"#,
            "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f",
        ], extraEnvironment: [:])
        guard result.status == 0 else {
            throw BottleToolError("Could not disable Wine crash dialogs: \(result.trimmedOutput)")
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
    }

    static let runtimeManifestWindowsPath = #"C:\basalt\runtime\basalt_openxr.json"#

    /// The OpenXR `ActiveRuntime` recorded in a prefix's `system.reg`, read
    /// without starting Wine; nil when the key or value is absent.
    static func activeOpenXRRuntime(inHive hive: Data) -> String? {
        // Hives are ASCII (Wine escapes everything else), relative to HKLM,
        // and double each backslash. Keys are case-insensitive, so search a
        // lowercased copy: a byte search stays fast on multi-megabyte hives.
        let lowercased = Data(hive.map { (65...90).contains($0) ? $0 + 32 : $0 })
        let header = Data("\n[software\\\\khronos\\\\openxr\\\\1]".utf8)
        guard let section = lowercased.range(of: header) else { return nil }
        let end = lowercased.range(
            of: Data("\n[".utf8), in: section.upperBound..<lowercased.endIndex)?
            .lowerBound ?? lowercased.endIndex
        let body = String(decoding: hive[section.upperBound..<end], as: UTF8.self)
        let name = #""activeruntime"=""#
        for line in body.split(separator: "\n")
        where line.count > name.count + 1 && line.hasSuffix("\"")
            && line.prefix(name.count).lowercased() == name {
            var value = ""
            var escaped = false
            for character in line.dropFirst(name.count).dropLast() {
                if escaped || character != "\\" {
                    value.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            return value
        }
        return nil
    }

    private func hiveNamesBasaltRuntime(_ bottle: ManagedBottle) -> Bool {
        let hive = URL(fileURLWithPath: bottle.prefixPath).appendingPathComponent("system.reg")
        guard let data = try? Data(contentsOf: hive),
              let active = Self.activeOpenXRRuntime(inHive: data) else { return false }
        return active.caseInsensitiveCompare(Self.runtimeManifestWindowsPath) == .orderedSame
    }

    private func installRuntime(in name: String, alwaysRegister: Bool) throws -> ManagedBottle {
        var bottle = try loadBottle(name)
        let buildBin = repoRoot.appendingPathComponent("runtime/build/bin")
        let sourceDLL = buildBin.appendingPathComponent("basalt_openxr.dll")
        let sourceManifest = buildBin.appendingPathComponent("basalt_openxr.json")
        guard fileManager.fileExists(atPath: sourceDLL.path),
              fileManager.fileExists(atPath: sourceManifest.path) else {
            throw BottleToolError(
                "The OpenXR runtime is not built; run runtime/scripts/test-dxmt.zsh first")
        }
        try suppressCrashDialogs(in: name)
        let destination = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c/basalt/runtime", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyFile(sourceDLL, to: destination.appendingPathComponent("basalt_openxr.dll"))
        try copyFile(sourceManifest, to: destination.appendingPathComponent("basalt_openxr.json"))

        if alwaysRegister || !bottle.runtimeInstalled || !hiveNamesBasaltRuntime(bottle) {
            let registry = try wineCommand(
                bottle: bottle,
                arguments: [
                    "reg.exe", "add", #"HKLM\Software\Khronos\OpenXR\1"#,
                    "/v", "ActiveRuntime", "/t", "REG_SZ", "/d",
                    Self.runtimeManifestWindowsPath, "/f",
                ],
                extraEnvironment: [:])
            guard registry.status == 0 else {
                throw BottleToolError("OpenXR registration failed: \(registry.trimmedOutput)")
            }
        }
        if !bottle.runtimeInstalled {
            bottle.runtimeInstalled = true
            try saveBottle(bottle)
        }
        return bottle
    }

    public func verify(_ name: String) throws -> String {
        let bottle = try loadBottle(name)
        guard bottle.dxmtInstalled, bottle.runtimeInstalled else {
            throw BottleToolError(
                "Bottle '\(name)' is incomplete (DXMT=\(bottle.dxmtInstalled), runtime=\(bottle.runtimeInstalled))")
        }
        let prefix = URL(fileURLWithPath: bottle.prefixPath)
        let expected = [
            prefix.appendingPathComponent("drive_c/basalt/runtime/basalt_openxr.dll"),
            prefix.appendingPathComponent("drive_c/basalt/runtime/basalt_openxr.json"),
            prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll"),
            URL(fileURLWithPath: bottle.engineRootPath)
                .appendingPathComponent("lib/wine/x86_64-unix/winemetal.so"),
        ]
        for path in expected where !fileManager.fileExists(atPath: path.path) {
            throw BottleToolError("Bottle verification is missing \(path.path)")
        }
        let query = try wineCommand(
            bottle: bottle,
            arguments: [
                "reg.exe", "query", #"HKLM\Software\Khronos\OpenXR\1"#,
                "/v", "ActiveRuntime",
            ], extraEnvironment: [:])
        guard query.status == 0,
              query.output.lowercased().contains(#"c:\basalt\runtime\basalt_openxr.json"#) else {
            throw BottleToolError("Bottle verification could not confirm ActiveRuntime: \(query.trimmedOutput)")
        }
        let loaderSmoke = repoRoot.appendingPathComponent(
            "runtime/build/bin/loader_smoke.exe")
        guard fileManager.fileExists(atPath: loaderSmoke.path) else {
            throw BottleToolError("Bottle verification is missing \(loaderSmoke.path)")
        }
        let smoke = try wineCommand(
            bottle: bottle, arguments: [loaderSmoke.path],
            extraEnvironment: [
                "BASALT_EXPECT_D3D11_EXTENSION": "1",
                "DXMT_BASALT_IOSURFACE": "1",
                "MVK_CONFIG_LOG_LEVEL": "0",
            ],
            currentDirectory: loaderSmoke.deletingLastPathComponent())
        guard smoke.status == 0 else {
            throw BottleToolError(
                "OpenXR loader smoke failed in '\(name)': \(smoke.trimmedOutput)")
        }
        return "PASS: \(name) has an isolated Basalt DXMT engine, registered OpenXR runtime, and working loader"
    }

    public func saveProfile(_ profile: LaunchProfile) throws {
        try prepare()
        _ = try BottleName.validate(profile.name, kind: "profile name")
        _ = try loadBottle(profile.bottleName)
        guard !profile.executable.isEmpty else {
            throw BottleToolError("Profile executable cannot be empty")
        }
        let data = try encoder.encode(profile)
        try data.write(to: paths.profileFile(profile.name), options: .atomic)
    }

    /// Saves a profile for a newly added game, checked like `saveProfile`.
    /// `saveProfile` replaces a file silently, which suits editing; a new game
    /// whose name turned out to be taken must fail instead, so another game's
    /// profile is never replaced. The exclusive create also refuses a name
    /// that differs only in case on a case-insensitive volume.
    public func saveNewProfile(_ profile: LaunchProfile) throws {
        try prepare()
        _ = try BottleName.validate(profile.name, kind: "profile name")
        _ = try loadBottle(profile.bottleName)
        guard !profile.executable.isEmpty else {
            throw BottleToolError("Profile executable cannot be empty")
        }
        let data = try encoder.encode(profile)
        do {
            try data.write(to: paths.profileFile(profile.name), options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw BottleToolError("Launch profile '\(profile.name)' already exists")
        }
    }

    public func loadProfile(_ name: String) throws -> LaunchProfile {
        let file = try paths.profileFile(name)
        let profile: LaunchProfile
        switch contents(LaunchProfile.self, of: file) {
        case .missing:
            throw BottleToolError("Launch profile '\(name)' does not exist")
        case .failure(let reason):
            throw BottleToolError("Launch profile '\(name)' cannot be read: \(reason.detail)")
        case .value(let value):
            profile = value
        }
        guard profile.formatVersion == LaunchProfile.currentFormatVersion else {
            throw BottleToolError("Profile '\(name)' uses unsupported metadata version \(profile.formatVersion)")
        }
        return profile
    }

    /// The profiles `loadProfile` would load: one of another format version
    /// is not among them, it is listed as damaged.
    public func listProfiles() throws -> [LaunchProfile] {
        try scanProfiles().profiles
    }

    /// The profile files that are there but cannot be read or are of
    /// another format version. Their names stay taken.
    public func listDamagedProfiles() throws -> [DamagedItem] {
        try scanProfiles().damaged
    }

    private func scanProfiles() throws -> (profiles: [LaunchProfile], damaged: [DamagedItem]) {
        guard fileManager.fileExists(atPath: paths.profiles.path) else { return ([], []) }
        var profiles = [LaunchProfile](), damaged = [DamagedItem]()
        for file in try fileManager.contentsOfDirectory(
            at: paths.profiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            switch contents(LaunchProfile.self, of: file) {
            case .missing:
                continue
            case .failure(let reason):
                damaged.append(DamagedItem(name: name, file: file, reason: reason))
            case .value(let profile):
                guard isManagedItem(file, named: try? paths.profileFile(profile.name)) else { continue }
                if profile.formatVersion == LaunchProfile.currentFormatVersion {
                    profiles.append(profile)
                } else {
                    damaged.append(DamagedItem(
                        name: name, file: file, reason: .unsupportedVersion(profile.formatVersion)))
                }
            }
        }
        return (profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                damaged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    public func deleteBottle(_ name: String) throws {
        let directory = try paths.bottleDirectory(name)
        let bottle = try loadBottle(name)
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        guard prefix.path.hasPrefix(directory.path + "/"),
              directory.resolvingSymlinksInPath().path.hasPrefix(paths.bottles.resolvingSymlinksInPath().path + "/"),
              (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
            throw BottleToolError("Refusing to delete a bottle outside the managed folder")
        }
        for profile in try listProfiles() where profile.bottleName == name { try deleteProfile(profile.name) }
        try fileManager.removeItem(at: directory)
    }

    public func deleteProfile(_ name: String) throws {
        let file = try paths.profileFile(name)
        guard paths.contains(file) else {
            throw BottleToolError("Refusing to delete a profile outside the managed root")
        }
        guard fileManager.fileExists(atPath: file.path) else {
            throw BottleToolError("Launch profile '\(name)' does not exist")
        }
        try fileManager.removeItem(at: file)
    }

    /// Finds exact DLL filenames only; backups and symlinked directories are excluded.
    public func openVRTargets(profileName: String) throws -> [URL] {
        guard let root = try hostGameRoot(profileName: profileName) else {
            throw BottleToolError("This profile has no game folder. Set and save its Game folder in Edit Launch Profile first.")
        }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var targets = [URL]()
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if properties.isSymbolicLink == true || name.contains("backup")
                || name.hasSuffix(".bak") || name.hasSuffix(".old")
                || name.hasSuffix(".orig") || name.hasSuffix(".original")
                || name.hasSuffix(".basalt-original") {
                enumerator.skipDescendants()
                continue
            }
            guard name == "openvr_api.dll", properties.isRegularFile == true else { continue }
            _ = try validatedOpenVRTarget(profileName: profileName, targetDLL: url)
            targets.append(url.standardizedFileURL)
        }
        return targets.sorted { $0.path < $1.path }
    }

    /// The profile's game folder on this Mac, checked to lie inside its
    /// bottle's prefix; nil when the profile names no game folder.
    private func hostGameRoot(profileName: String) throws -> URL? {
        let profile = try loadProfile(profileName)
        let bottle = try loadBottle(profile.bottleName)
        guard let gameRoot = profile.gameRoot else { return nil }
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        let normalized = gameRoot.replacingOccurrences(of: "\\", with: "/")
        let root: URL
        if normalized.lowercased().hasPrefix("c:/") {
            root = prefix.appendingPathComponent("drive_c")
                .appendingPathComponent(String(normalized.dropFirst(3))).standardizedFileURL
        } else {
            root = URL(fileURLWithPath: Self.currentHostPath(
                normalized, bottleName: bottle.name, prefix: prefix)).standardizedFileURL
        }
        try validateOpenVRLocation(root, prefix: prefix)
        guard fileManager.fileExists(atPath: root.path) else {
            throw BottleToolError("The profile's game folder does not exist.")
        }
        return root
    }

    /// Call immediately before launch, after Steam has finished updating:
    /// applies the fixes the profile's game needs (see GameCompatibilityFix)
    /// and returns those that changed a file.
    public func applyGameCompatibilityFixes(profileName: String) throws -> [GameCompatibilityFix] {
        guard let root = try hostGameRoot(profileName: profileName) else { return [] }
        return try GameCompatibilityFix.apply(inGameRoot: root, fileManager: fileManager)
    }

    private func validateOpenVRLocation(_ location: URL, prefix: URL) throws {
        let resolvedPrefix = prefix.resolvingSymlinksInPath()
        guard location.path.hasPrefix(prefix.path + "/"),
              location.resolvingSymlinksInPath().path.hasPrefix(resolvedPrefix.path + "/") else {
            throw BottleToolError("OpenComposite target must stay inside the managed bottle prefix")
        }
        // Reject even dangling links, including the target, backup and configuration.
        var component = location
        while component != prefix && component.path != "/" {
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw BottleToolError("OpenComposite paths must not contain symbolic links")
            }
            component.deleteLastPathComponent()
        }
    }

    private func validatedOpenVRTarget(profileName: String, targetDLL: URL) throws -> URL {
        let profile = try loadProfile(profileName)
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        let target = targetDLL.standardizedFileURL
        guard target.lastPathComponent.lowercased() == "openvr_api.dll" else {
            throw BottleToolError("OpenComposite target must be named openvr_api.dll")
        }
        for location in [target, target.appendingPathExtension("basalt-original"),
                         target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")] {
            try validateOpenVRLocation(location, prefix: prefix)
            if fileManager.fileExists(atPath: location.path),
               try location.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                throw BottleToolError("OpenComposite target, backup and configuration must be regular files")
            }
        }
        return target
    }

    public func installOpenComposite(profileName: String, artifact: URL,
                                     targetDLL: URL) throws -> URL {
        let target = try validatedOpenVRTarget(profileName: profileName, targetDLL: targetDLL)
        let bytes = try Data(contentsOf: artifact)
        let machine = try OpenCompositeArchitecture.dllArchitecture(in: bytes)
        guard OpenCompositeContent.isOpenComposite(bytes) else {
            throw BottleToolError("The selected DLL is not an OpenComposite OpenXR build")
        }
        // An existing original is required so every installation can be rolled back.
        let original = try Data(contentsOf: target)
        guard try OpenCompositeArchitecture.dllArchitecture(in: original) == machine else {
            throw BottleToolError("OpenComposite DLL architecture does not match the game DLL")
        }
        let backup = target.appendingPathExtension("basalt-original")
        if !OpenCompositeContent.isOpenComposite(original) {
            // Steam may have supplied a newer original since the previous install.
            try original.write(to: backup, options: .atomic)
        }
        try cacheOpenComposite(bytes, replacing: true)
        let ini = target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        let configuration = """
        ; Managed by BasaltVR. OpenComposite is a separate GPL-3.0 project, never bundled.
        ; Use only options supported by the pinned build; audio uses host BlackHole routing.
        initUsingVulkan=false
        """
        // Preserve a configuration supplied by the user.
        let existingINI = fileManager.fileExists(atPath: ini.path)
            ? try String(contentsOf: ini, encoding: .utf8) : nil
        if existingINI == nil || existingINI?.hasPrefix("; Managed by BasaltVR") == true {
            try configuration.write(to: ini, atomically: true, encoding: .utf8)
        }
        try bytes.write(to: target, options: .atomic)
        return target
    }

    public func openCompositeCacheURL(for architecture: OpenCompositeArchitecture) -> URL {
        paths.root.appendingPathComponent("Downloads/OpenComposite/\(architecture.rawValue)/openvr_api.dll")
    }

    private func cacheOpenComposite(_ bytes: Data, replacing: Bool = false) throws {
        guard OpenCompositeContent.isOpenComposite(bytes) else { return }
        let architecture = try OpenCompositeArchitecture.dllArchitecture(in: bytes)
        let cache = openCompositeCacheURL(for: architecture)
        var component = cache
        while component.path.hasPrefix(paths.root.path + "/") {
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw BottleToolError("OpenComposite cache must not contain symbolic links")
            }
            component.deleteLastPathComponent()
        }
        if !replacing, fileManager.fileExists(atPath: cache.path) {
            let existing = try Data(contentsOf: cache)
            guard OpenCompositeContent.isOpenComposite(existing),
                  try OpenCompositeArchitecture.dllArchitecture(in: existing) == architecture else {
                throw BottleToolError("The cached OpenComposite DLL is invalid. Set up OpenVR support again.")
            }
            return
        }
        try ManagedFolder.create(
            cache.deletingLastPathComponent(), inside: paths.root,
            outside: "OpenComposite cache must not contain symbolic links", fileManager: fileManager)
        try bytes.write(to: cache, options: .atomic)
    }

    /// Also seeds older installations that predate the artifact cache.
    public func isOpenComposite(at target: URL) throws -> Bool {
        let bytes = try Data(contentsOf: target)
        guard OpenCompositeContent.isOpenComposite(bytes) else { return false }
        try cacheOpenComposite(bytes)
        return true
    }

    /// Call after Steam has finished updating, immediately before launch.
    /// Preflight all replacements before changing any game DLL.
    public func repairOpenComposite(profileName: String) throws -> Bool {
        var repairs = [(URL, URL)]()
        for target in try openVRTargets(profileName: profileName) {
            if try isOpenComposite(at: target) { continue }
            guard fileManager.fileExists(atPath: target.appendingPathExtension("basalt-original").path) else { continue }
            let architecture = try OpenCompositeArchitecture.dllArchitecture(in: Data(contentsOf: target))
            let cache = openCompositeCacheURL(for: architecture)
            guard let bytes = try? Data(contentsOf: cache), OpenCompositeContent.isOpenComposite(bytes),
                  try OpenCompositeArchitecture.dllArchitecture(in: bytes) == architecture else {
                throw BottleToolError("SET UP OPENVR: Steam replaced the game DLL and no valid OpenComposite artifact is cached. Set up OpenVR support in Library before playing.")
            }
            repairs.append((target, cache))
        }
        for (target, cache) in repairs {
            _ = try installOpenComposite(profileName: profileName, artifact: cache, targetDLL: target)
        }
        return !repairs.isEmpty
    }

    public func uninstallOpenComposite(profileName: String, targetDLL: URL) throws {
        let target = try validatedOpenVRTarget(profileName: profileName, targetDLL: targetDLL)
        let backup = target.appendingPathExtension("basalt-original")
        let original = try Data(contentsOf: backup)
        let ini = target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        let managedINI = fileManager.fileExists(atPath: ini.path)
            && ((try? String(contentsOf: ini, encoding: .utf8))?.hasPrefix("; Managed by BasaltVR") == true)
        try original.write(to: target, options: .atomic)
        try fileManager.removeItem(at: backup)
        if managedINI { try fileManager.removeItem(at: ini) }
    }

    public func runProfile(_ name: String, controlFile: URL,
                           additionalArguments: [String] = []) throws -> CommandOutput {
        let command = try profileLaunchCommand(
            name, controlFile: controlFile,
            additionalArguments: additionalArguments)
        if !command.droppedEnvironment.isEmpty {
            FileHandle.standardError.write(Data(
                "Not passed to the game: \(command.droppedEnvironment.joined(separator: ", "))\n".utf8))
        }
        // Not the caller's stdin: basaltctl may run with /dev/null as stdin, and hello_xr
        // quits at end of file on stdin.
        return try runner.runKeepingInputOpen(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            currentDirectory: command.currentDirectory)
    }

    public func profileLaunchCommand(
        _ name: String, controlFile: URL,
        additionalArguments: [String] = [], frameTrace: FrameTraceSession? = nil
    ) throws -> BottleLaunchCommand {
        let profile = try loadProfile(name)
        let bottle = try loadBottle(profile.bottleName)
        guard bottle.dxmtInstalled, bottle.runtimeInstalled else {
            throw BottleToolError("Bottle '\(bottle.name)' must install DXMT and the runtime before launch")
        }
        guard fileManager.fileExists(atPath: controlFile.path) else {
            throw BottleToolError(
                "Runtime control file does not exist; start basalt-streamer --wired --runtime <path> first")
        }
        let (profileEnvironment, dropped) = Self.withoutLoaderVariables(profile.environment)
        var environment = try workspaceEnvironment(for: bottle, extra: profileEnvironment)
        var windowsExecutable = profile.executable
        var profileArguments = profile.arguments
        var workingDirectory = profile.workingDirectory.map {
            URL(fileURLWithPath: Self.currentHostPath(
                $0, bottleName: bottle.name,
                prefix: URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)),
                isDirectory: true)
        }

        // A `steam.exe -applaunch` invocation is only a message to the already
        // running Steam client. Wine returns as soon as Steam accepts it, and
        // the eventual game inherits Steam's old environment instead of this
        // session's BASALT_CONTROL path, so its headset stays black. Resolve
        // every such profile to the game's own executable (SteamDirectLaunch)
        // so Basalt owns the real game lifetime and supplies the current
        // OpenXR session environment. Arguments before `-applaunch` are the
        // Steam client's; those after the AppID are the game's and follow
        // the arguments of Steam's own launch option.
        var steamLaunch: SteamDirectLaunch?
        if profile.source == .steam,
           let appLaunchIndex = profileArguments.firstIndex(of: "-applaunch"),
           profileArguments.indices.contains(appLaunchIndex + 1) {
            let appID = profileArguments[appLaunchIndex + 1]
            let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            let launch = try SteamDirectLaunch.resolve(
                appID: appID, prefix: prefix, gameRoot: try? hostGameRoot(profileName: name),
                fileManager: fileManager)
            windowsExecutable = Self.winePath(for: launch.executable, prefix: prefix)
            profileArguments = launch.arguments + profileArguments.suffix(from: appLaunchIndex + 2)
            workingDirectory = launch.workingDirectory
            environment["SteamAppId"] = appID
            environment["SteamGameId"] = appID
            steamLaunch = launch
        }
        environment["DXMT_BASALT_IOSURFACE"] = "1"
        environment["BASALT_CONTROL"] = Self.winePath(for: controlFile,
                                                       prefix: URL(fileURLWithPath: bottle.prefixPath))
        let trace: FrameTraceSession?
        if let frameTrace {
            // The caller reserved this launch's files before starting the
            // streamer, which records any video itself. Neither opt-in reaches
            // the game; it gets only the reserved CSV path.
            trace = frameTrace
            environment.removeValue(forKey: "BASALT_FRAME_TRACE")
            environment.removeValue(forKey: "BASALT_RECORD_VIDEO")
            // The session, not the profile, says whether frames are traced:
            // the app's own setting turns the trace on without the variable.
            if frameTrace.tracesFrames {
                environment["BASALT_FRAME_TRACE"] = Self.winePath(
                    for: frameTrace.csv, prefix: URL(fileURLWithPath: bottle.prefixPath))
            }
        } else {
            trace = FrameTraceSession.rewrite(environment: &environment, dataRoot: paths.root,
                prefix: URL(fileURLWithPath: bottle.prefixPath), profile: name)
        }
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        environment["MVK_CONFIG_LOG_LEVEL"] = environment["MVK_CONFIG_LOG_LEVEL"] ?? "0"
        let executable = URL(fileURLWithPath: bottle.wineBinaryPath)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        var command = BottleLaunchCommand(
            executable: executable,
            // Invoke the game directly. Steam's launcher is already running,
            // and start.exe can finish after a Steam game reparents itself,
            // which would make the manager tear down a still-running stream.
            arguments: [windowsExecutable] + profileArguments + additionalArguments,
            environment: environment,
            currentDirectory: workingDirectory)
        command.frameTrace = trace
        command.droppedEnvironment = dropped
        command.steamLaunch = steamLaunch
        return command
    }

    /// A profile's variables without `DYLD_*` and `LD_*`. Those tell the
    /// dynamic loader to load code from a path of the profile's choosing
    /// into Wine, and a profile is a file anyone who can write to the data
    /// folder (a shared network folder) can change. Returns what is passed
    /// on and the names that were dropped, sorted.
    public static func withoutLoaderVariables(
        _ environment: [String: String]
    ) -> (kept: [String: String], dropped: [String]) {
        let kept = environment.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_") }
        return (kept, environment.keys.filter { kept[$0] == nil }.sorted())
    }

    /// Reserves the trace files and the video path this launch records, under
    /// the data root's `Diagnostics` folder. The app's settings (`tracesFrames`,
    /// `recordsVideo`) and the profile's developer opt-ins
    /// (`BASALT_FRAME_TRACE=1`, `BASALT_RECORD_VIDEO=1`) each turn a recording
    /// on; `videoAllowed` withholds the video from either. Nil for neither.
    public func prepareFrameTrace(
        forProfile name: String, tracesFrames: Bool = false, recordsVideo: Bool = false,
        videoAllowed: Bool = true
    ) throws -> FrameTraceSession? {
        let profile = try loadProfile(name)
        guard tracesFrames || recordsVideo
            || profile.environment["BASALT_FRAME_TRACE"] == "1"
            || profile.environment["BASALT_RECORD_VIDEO"] == "1" else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        var environment = profile.environment
        return FrameTraceSession.rewrite(environment: &environment, dataRoot: paths.root,
            prefix: URL(fileURLWithPath: bottle.prefixPath), profile: name,
            tracesFrames: tracesFrames, recordsVideo: recordsVideo, videoAllowed: videoAllowed)
    }

    /// Stops every Wine process owned by the managed bottle for `profileName`.
    ///
    /// A previous manager process can exit without getting a chance to run its
    /// termination handler. Resolving cleanup from persisted profile metadata
    /// lets the next session remove those orphaned Wine processes before it
    /// starts Steam or the game again.
    @discardableResult
    public func terminateBottleProcesses(
        forProfile profileName: String
    ) throws -> CommandOutput {
        try terminateBottleProcesses(launchedWith: prefixCommand(forProfile: profileName))
    }

    /// A command scoped to the managed bottle for `profileName`: it runs
    /// nothing itself, but `terminateBottleProcesses(launchedWith:)` can find
    /// that prefix's wineserver from it.
    public func prefixCommand(forProfile profileName: String) throws -> BottleLaunchCommand {
        let profile = try loadProfile(profileName)
        return try prefixCommand(forBottle: profile.bottleName)
    }

    /// A command scoped to a bottle without needing a launch profile.
    public func prefixCommand(forBottle name: String) throws -> BottleLaunchCommand {
        let bottle = try loadBottle(name)
        return BottleLaunchCommand(
            executable: URL(fileURLWithPath: bottle.wineBinaryPath),
            arguments: [],
            environment: [
                "WINEPREFIX": bottle.prefixPath,
                "WINEARCH": "win64",
                "WINEDEBUG": "-all",
            ],
            currentDirectory: nil)
    }

    /// Stops Wine in every managed bottle, as removing the app does before it
    /// deletes them. A bottle whose Wine cannot be stopped is skipped; its
    /// name and the reason are returned.
    @discardableResult
    public func terminateAllBottleProcesses() -> [(bottle: String, error: String)] {
        guard let bottles = try? listBottles() else { return [] }
        var failures = [(bottle: String, error: String)]()
        for bottle in bottles {
            do {
                _ = try terminateBottleProcesses(launchedWith: prefixCommand(forBottle: bottle.name))
            } catch {
                failures.append((bottle.name, error.localizedDescription))
            }
        }
        return failures
    }

    /// Stops every Wine process owned by the prefix used for `command`.
    ///
    /// Terminating the direct `Process` returned by Foundation is not enough:
    /// Wine reparents long-lived Windows processes (including Steam, games,
    /// helpers, and services) to its per-prefix wineserver. Asking that server
    /// to shut down keeps cleanup scoped to this bottle instead of matching
    /// processes system-wide.
    @discardableResult
    public func terminateBottleProcesses(
        launchedWith command: BottleLaunchCommand
    ) throws -> CommandOutput {
        guard let prefixPath = command.environment["WINEPREFIX"],
              !prefixPath.isEmpty else {
            throw BottleToolError(
                "Cannot clean up Wine processes without a WINEPREFIX")
        }
        let wineserver = command.executable.deletingLastPathComponent()
            .appendingPathComponent("wineserver")
        var result = CommandOutput(status: 0, output: "")
        var failure: Error?
        do {
            guard fileManager.isExecutableFile(atPath: wineserver.path) else {
                throw BottleToolError(
                    "Bottle wineserver is missing: \(wineserver.path)")
            }
            var environment = command.environment
            environment["WINEPREFIX"] = prefixPath
            environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
            result = try runner.run(
                executable: wineserver,
                arguments: ["--kill", "--wait"],
                environment: environment,
                currentDirectory: nil, timeout: Self.wineStopLimit)
            let detail = result.trimmedOutput
            // Wine reports no server for this prefix as status 1 with no diagnostic.
            if result.status != 0 && !(result.status == 1 && detail.isEmpty) {
                throw BottleToolError(
                    "Could not stop Wine processes for \(prefixPath)"
                        + (detail.isEmpty ? "" : ": \(detail)"))
            }
        } catch {
            failure = error
        }
        // Only a private engine adjacent to this prefix can identify a bottle.
        // Shared Whisky/GPTK engines must never be swept by executable path.
        let engine = Self.privateEngine(wine: command.executable, prefixPath: prefixPath)
        if engine == nil, let failure { throw failure }
        let removed = try engine.map { try BottleProcessSweep(access: processAccess).remove(engine: $0) } ?? 0
        return CommandOutput(status: 0, output: result.status == 0 ? result.output : "",
                             removedLeftoverProcesses: removed, leftoverSweepSkipped: engine == nil,
                             // Forced only when the sweep found something to stop.
                             forcedStop: failure != nil && removed > 0)
    }

    /// The engine folder next to `prefixPath` when `wine` is that engine's
    /// own binary, so that its processes can be told by their executable.
    private static func privateEngine(wine: URL, prefixPath: String) -> URL? {
        let bottle = URL(fileURLWithPath: prefixPath).standardizedFileURL.deletingLastPathComponent()
        let engine = bottle.appendingPathComponent("engine", isDirectory: true).standardizedFileURL
        let expectedWine = engine.appendingPathComponent("bin/wine").standardizedFileURL
        let prefix = bottle.appendingPathComponent("prefix").standardizedFileURL
        let privateEngine = wine.standardizedFileURL == expectedWine &&
           URL(fileURLWithPath: prefixPath).standardizedFileURL == prefix &&
           engine.resolvingSymlinksInPath() == bottle.resolvingSymlinksInPath()
                .appendingPathComponent("engine", isDirectory: true)
        return privateEngine ? engine : nil
    }

    /// How many Wine processes of this bottle run now, found the way the
    /// leftover sweep finds them and stopping none. Nil for a bottle on a
    /// shared engine, whose processes cannot be told from another bottle's.
    public func runningProcessCount(inBottle name: String) throws -> Int? {
        let bottle = try loadBottle(name)
        guard let engine = Self.privateEngine(
            wine: URL(fileURLWithPath: bottle.wineBinaryPath), prefixPath: bottle.prefixPath) else { return nil }
        return try BottleProcessSweep(access: processAccess).count(engine: engine)
    }

    /// Cumulative I/O for the same processes counted above; nil for a shared engine.
    public func ioActivity(inBottle name: String) throws -> UInt64? {
        let bottle = try loadBottle(name)
        guard let engine = Self.privateEngine(
            wine: URL(fileURLWithPath: bottle.wineBinaryPath), prefixPath: bottle.prefixPath) else { return nil }
        return try BottleProcessSweep(access: processAccess).ioActivity(engine: engine)
    }

    /// Resolves a normal Wine application without requiring an active VR
    /// stream. The management app uses this for Steam, installers, and bottle
    /// maintenance while still owning the resulting child process.
    public func applicationLaunchCommand(
        bottleName: String, executable windowsExecutable: String,
        arguments: [String] = [], environment extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> BottleLaunchCommand {
        let bottle = try loadBottle(bottleName)
        let executable = URL(fileURLWithPath: bottle.wineBinaryPath)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        var environment = try workspaceEnvironment(for: bottle, extra: extraEnvironment)
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        environment["MVK_CONFIG_LOG_LEVEL"] = environment["MVK_CONFIG_LOG_LEVEL"] ?? "0"
        return BottleLaunchCommand(
            executable: executable,
            arguments: [windowsExecutable] + arguments,
            environment: environment,
            currentDirectory: currentDirectory)
    }

    /// Starts the Steam client before a waited, direct game executable. Steam's
    /// `-applaunch` command returns before the game exits, so Basalt launches
    /// Steam as a prerequisite and retains ownership of the actual game process.
    ///
    /// Steam's CEF helper cannot render its cross-process D3D surface through
    /// DXMT on macOS. Basalt's small launcher keeps GPU work in the main helper
    /// process and selects Chromium's software path, matching the working
    /// configuration used by CrossOver. The original helper remains beside it
    /// and is refreshed whenever Steam installs a newer copy.
    @discardableResult
    public func installSteamWebHelperCompatibility(
        forProfile name: String
    ) throws -> URL? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        return try installSteamWebHelperCompatibility(inBottle: profile.bottleName)
    }

    /// Sign-in needs the same CEF compatibility path before any game profile exists.
    @discardableResult
    public func installSteamWebHelperCompatibility(inBottle name: String) throws -> URL {
        let bottle = try loadBottle(name)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let artifact = repoRoot.appendingPathComponent(
            "runtime/build/bin/steamwebhelper_compat.exe")
        guard fileManager.fileExists(atPath: artifact.path) else {
            throw BottleToolError(
                "Steam UI compatibility is not built; run runtime/scripts/test-dxmt.zsh first")
        }
        let shim = try Data(contentsOf: artifact)
        guard shim.count >= 2, shim[shim.startIndex] == 0x4d,
              shim[shim.index(after: shim.startIndex)] == 0x5a else {
            throw BottleToolError("Steam UI compatibility artifact is not a Windows PE executable")
        }
        guard Self.isSteamWebHelperShim(shim) else {
            throw BottleToolError("Steam UI compatibility artifact is not Basalt's helper launcher")
        }

        let candidates = [
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe"),
            prefix.appendingPathComponent(
                "drive_c/Program Files/Steam/bin/cef/cef.win64/steamwebhelper.exe"),
        ]
        guard let helper = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw BottleToolError(
                "Steam's web helper is missing in '\(bottle.name)'; let Steam finish updating, then try again")
        }
        let resolvedPrefix = prefix.resolvingSymlinksInPath()
        let resolvedHelper = helper.resolvingSymlinksInPath()
        guard resolvedHelper.path.hasPrefix(resolvedPrefix.path + "/") else {
            throw BottleToolError(
                "Steam's web helper resolves outside the managed bottle prefix")
        }
        let backup = helper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")
        if fileManager.fileExists(atPath: backup.path) {
            let resolvedBackup = backup.resolvingSymlinksInPath()
            guard resolvedBackup.path.hasPrefix(resolvedPrefix.path + "/") else {
                throw BottleToolError(
                    "Steam's preserved web helper resolves outside the managed bottle prefix")
            }
        }
        let installed = try Data(contentsOf: helper)

        if !Self.isSteamWebHelperShim(installed) {
            guard installed.count >= 2, installed[installed.startIndex] == 0x4d,
                  installed[installed.index(after: installed.startIndex)] == 0x5a else {
                throw BottleToolError("Steam's web helper is not a Windows PE executable")
            }
            // This is either the initial install or a newer helper written by
            // Steam. Preserve that exact version for the shim to launch. Any
            // build of Basalt's own shim, including an older one, is skipped so
            // it can never replace the original and relaunch itself.
            try copyFile(helper, to: backup)
        } else {
            guard fileManager.fileExists(atPath: backup.path) else {
                throw BottleToolError(
                    "Steam UI compatibility is missing its preserved original helper")
            }
        }

        let original = try Data(contentsOf: backup)
        guard original.count >= 2, original[original.startIndex] == 0x4d,
              original[original.index(after: original.startIndex)] == 0x5a else {
            throw BottleToolError("Steam's preserved web helper is not a Windows PE executable")
        }
        guard !Self.isSteamWebHelperShim(original) else {
            throw BottleToolError(
                "Steam's preserved web helper was overwritten by the compatibility shim; verify Steam's files, then try again")
        }
        try copyFile(artifact, to: helper)
        return helper
    }

    /// Every build of the shim embeds the UTF-16 name of the helper it
    /// launches, which Steam's own helper never contains. Comparing bytes with
    /// the current artifact is not enough: rebuilds change the PE timestamp.
    static func isSteamWebHelperShim(_ executable: Data) -> Bool {
        let marker = Data("steamwebhelper.basalt-original.exe".utf16.flatMap {
            [UInt8($0 & 0xff), UInt8($0 >> 8)]
        })
        return executable.range(of: marker) != nil
    }

    public func steamBootstrapCommand(forProfile name: String) throws -> BottleLaunchCommand? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let candidates = [
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            prefix.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
        ]
        guard let steam = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw BottleToolError("Steam is not installed in '\(bottle.name)'")
        }
        return try applicationLaunchCommand(
            bottleName: bottle.name,
            executable: Self.winePath(for: steam, prefix: prefix),
            // Keep the client visible: a copied or newly-created prefix may
            // need an interactive sign-in before SteamAPI exposes game IPC.
            // The intentional helper substitution must not be checksum-repaired
            // before CEF starts. Inhibiting this launch's bootstrap also prevents
            // a client update from replacing the shim and immediately relaunching
            // a black helper. Steam can still be updated outside a Basalt session;
            // the next compatibility install preserves that newer helper.
            arguments: [
                "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
            ],
            currentDirectory: steam.deletingLastPathComponent())
    }

    public func steamConnectionLogURL(forProfile name: String) throws -> URL? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let candidates = [
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"),
            prefix.appendingPathComponent(
                "drive_c/Program Files/Steam/logs/connection_log.txt"),
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
            ?? candidates[0]
    }

    public static func winePath(for hostURL: URL, prefix: URL) -> String {
        let path = hostURL.standardizedFileURL.path
        let driveC = prefix.standardizedFileURL
            .appendingPathComponent("drive_c", isDirectory: true).path
        if path == driveC {
            return #"C:\"#
        }
        if path.hasPrefix(driveC + "/") {
            return #"C:\"# + path.dropFirst(driveC.count + 1)
                .replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }

    private func wineCommand(bottle: ManagedBottle, arguments: [String],
                             extraEnvironment: [String: String],
                             currentDirectory: URL? = nil) throws -> CommandOutput {
        try bottleCommand(
            bottle: bottle,
            executable: URL(fileURLWithPath: bottle.wineBinaryPath),
            arguments: arguments, extraEnvironment: extraEnvironment,
            currentDirectory: currentDirectory)
    }

    private func bottleCommand(bottle: ManagedBottle, executable: URL,
                               arguments: [String],
                               extraEnvironment: [String: String],
                               currentDirectory: URL? = nil) throws -> CommandOutput {
        var environment = try workspaceEnvironment(for: bottle, extra: extraEnvironment)
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        return try runner.run(
            executable: executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory)
    }

    /// Wine normally maps Documents/Desktop to the Mac home directory. Give
    /// this managed bottle its own host folders before its first wineboot.
    private func workspaceEnvironment(for bottle: ManagedBottle,
                                      extra: [String: String]) throws -> [String: String] {
        let directory = try paths.bottleDirectory(bottle.name)
        let root = paths.root.resolvingSymlinksInPath().path + "/"
        func ensureDirectory(_ url: URL) throws {
            try ManagedFolder.create(
                url, inside: paths.root,
                outside: "Bottle storage resolves outside the managed data folder",
                fileManager: fileManager)
        }
        var environment = extra
        for (key, component) in [
            ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")
        ] {
            let folder = directory.appendingPathComponent("host/\(component)")
            try ensureDirectory(folder)
            environment[key] = folder.path
        }
        var entries = [String]()
        for (key, name) in [
            ("DESKTOP", "Desktop"), ("DOCUMENTS", "Documents"),
            ("DOWNLOAD", "Downloads"), ("PICTURES", "Pictures"),
            ("MUSIC", "Music"), ("VIDEOS", "Videos"), ("TEMPLATES", "Templates")
        ] {
            let folder = directory.appendingPathComponent("host/folders/\(name)")
            try ensureDirectory(folder)
            // Wine's reader drops the backslash before any character; `$` and
            // the backtick are escaped as well so that a shell which sources
            // this file (the format is a shell fragment) expands nothing.
            let escaped = folder.path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            entries.append("XDG_\(key)_DIR=\"\(escaped)\"")
        }
        let config = directory.appendingPathComponent("host/config/user-dirs.dirs")
        // Its folder exists by now, so every link on the way resolves; the
        // file itself may not exist yet, and a path that does not exist
        // resolves no links at all.
        let configFolder = config.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard configFolder.hasPrefix(root),
              !fileManager.fileExists(atPath: config.path)
                || config.resolvingSymlinksInPath().path.hasPrefix(root) else {
            throw BottleToolError("Wine user-folder configuration escapes managed storage")
        }
        try Data((entries.joined(separator: "\n") + "\n").utf8).write(to: config, options: .atomic)
        repointUserFolderLinks(ofBottle: bottle.name, in: directory)
        // Disable native Start Menu/desktop shortcut generation for this process.
        environment["WINEDLLOVERRIDES"] = [extra["WINEDLLOVERRIDES"], "winemenubuilder.exe=d"]
            .compactMap { $0 }.joined(separator: ";")
        return environment
    }

    /// Wine links Desktop, Documents and the like in `drive_c/users/<user>`
    /// to the bottle's host folders by absolute path. After the data folder
    /// was renamed or moved those links dangle, and a game that saves under
    /// Documents fails. A link whose target is
    /// `<another root>/Bottles/<this bottle>/host/folders/<folder>` is
    /// replaced, by a rename over it, with one to the same folder under the
    /// current root. A link that is current is not written, and a link to
    /// anywhere else, a real folder, and a `users` folder reached through a
    /// link are left alone. Best effort: a link that cannot be replaced stays.
    private func repointUserFolderLinks(ofBottle name: String, in directory: URL) {
        let users = directory.appendingPathComponent("prefix/drive_c/users", isDirectory: true)
        guard users.resolvingSymlinksInPath().path
                == directory.resolvingSymlinksInPath().path + "/prefix/drive_c/users",
              let homes = try? fileManager.contentsOfDirectory(atPath: users.path) else { return }
        for home in homes {
            let homeURL = users.appendingPathComponent(home, isDirectory: true)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: homeURL.path)) == nil,
                  let entries = try? fileManager.contentsOfDirectory(atPath: homeURL.path)
            else { continue }
            for entry in entries {
                let link = homeURL.appendingPathComponent(entry)
                guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
                      target.hasPrefix("/") else { continue }
                let components = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
                guard let folder = components.last, components.count > 5,
                      Array(components.suffix(5)) == ["Bottles", name, "host", "folders", folder]
                else { continue }
                let current = directory.appendingPathComponent("host/folders/\(folder)")
                var isDirectory: ObjCBool = false
                guard components != current.standardizedFileURL.pathComponents,
                      fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let replacement = homeURL.appendingPathComponent(
                    ".trailbridge-link-\(UUID().uuidString)")
                guard (try? fileManager.createSymbolicLink(
                    atPath: replacement.path, withDestinationPath: current.path)) != nil
                else { continue }
                if rename(replacement.path, link.path) != 0 {
                    try? fileManager.removeItem(at: replacement)
                }
            }
        }
    }

    private func saveBottle(_ bottle: ManagedBottle) throws {
        let metadata = try paths.bottleMetadata(bottle.name)
        guard paths.contains(metadata) else {
            throw BottleToolError("Refusing to write bottle metadata outside the managed root")
        }
        let data = try encoder.encode(bottle)
        try data.write(to: metadata, options: .atomic)
    }

    /// Copies `source` over `destination` unless the bytes already match.
    private func copyFile(_ source: URL, to destination: URL) throws {
        let bytes = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != bytes {
            try bytes.write(to: destination, options: .atomic)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: source.path),
           let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions],
                                           ofItemAtPath: destination.path)
        }
    }
}
