import Foundation
import BasaltBottleKit

/// Where the disk of a data folder is.
public enum DataFolderKind: Equatable, Sendable {
    case thisMac, external, network

    public var name: String {
        switch self {
        case .thisMac: L10n.string(.dataFolderKindThisMac)
        case .external: L10n.string(.dataFolderKindExternal)
        case .network: L10n.string(.dataFolderKindNetwork)
        }
    }
}

/// The disk of a data folder as Settings shows it.
public struct DataFolderVolume: Equatable, Sendable {
    public let kind: DataFolderKind
    /// Nil when macOS does not say.
    public let freeBytes: Int64?

    public init(kind: DataFolderKind, freeBytes: Int64?) {
        self.kind = kind
        self.freeBytes = freeBytes
    }

    /// From the `URLResourceValues` of the folder. A disk that is not known
    /// to be built in counts as external. Free space is what macOS can make
    /// available for important use; disks that do not report it (0 or
    /// nothing) fall back to the plain number.
    init(isLocal: Bool?, isInternal: Bool?, importantUsageBytes: Int64?, availableBytes: Int?) {
        if isLocal == false {
            kind = .network
        } else {
            kind = isInternal == true ? .thisMac : .external
        }
        if let importantUsageBytes, importantUsageBytes > 0 {
            freeBytes = importantUsageBytes
        } else {
            freeBytes = availableBytes.map(Int64.init)
        }
    }

    /// The line under the path, e.g. "External disk · 812 GB free".
    public var summary: String {
        guard let freeBytes else { return kind.name }
        let free = freeBytes.formatted(.byteCount(style: .file).locale(L10n.language.locale))
        return L10n.string(.dataFolderKindAndFree, kind.name, free)
    }
}

/// Why a folder cannot hold the data.
public enum DataFolderProblem: Error, Equatable, Sendable {
    /// A file is at this path.
    case notAFolder
    /// Nothing is at this path: the disk is not connected or the share is
    /// not mounted. Nothing is created in its place.
    case missing
    case cannotCreate
    case notWritable
    /// macOS privacy protection refused access.
    case accessDenied
    /// The disk has no symbolic links (some network shares); Wine
    /// environments need them.
    case noSymbolicLinks
    /// A FAT32 disk: no file over 4 GB, and games have such files.
    case fat32
    /// The path has a backslash, a line break or another control character.
    /// Wine writes paths with backslashes, so a backslash in a folder name
    /// names another place to a game, and a line break splits the file that
    /// keeps Wine away from the Mac's own Desktop and Documents.
    case unsupportedPath

    /// The reason in the app's current language.
    public var message: String {
        switch self {
        case .notAFolder: L10n.string(.dataFolderIsFile)
        case .missing: L10n.string(.dataFolderMissing)
        case .cannotCreate: L10n.string(.dataFolderCannotCreate)
        case .notWritable: L10n.string(.dataFolderNotWritable)
        case .accessDenied: L10n.string(.dataFolderAccessDenied)
        case .noSymbolicLinks: L10n.string(.dataFolderNoLinks)
        case .fat32: L10n.string(.dataFolderFAT32)
        case .unsupportedPath: L10n.string(.dataFolderUnsupportedPath)
        }
    }
}

/// A chosen folder that passed the check.
public struct DataFolderVerdict: Equatable, Sendable {
    /// The folder the person chose.
    public let chosen: URL
    /// The folder to use: `chosen`, or the "TrailBridge" folder inside it
    /// when `chosen` already holds other files.
    public let folder: URL
    public let volume: DataFolderVolume

    public var usesSubfolder: Bool { folder != chosen }

    /// Says that the data goes into a subfolder, when it does.
    public var subfolderNote: String? {
        usesSubfolder ? L10n.string(.dataFolderSubfolderNote) : nil
    }
}

/// Judges a folder for the app's data: bottles, profiles, downloads, tools.
public struct DataFolderCheck: Sendable {
    /// The subfolder used inside a folder that holds other files.
    public static let subfolderName = "TrailBridge"
    /// What marks a folder as already holding TrailBridge data.
    static let dataMarkers: Set<String> = ["Bottles", "Profiles", SessionHistoryStore.fileName]
    /// What `statfs` calls FAT32 (and older FAT) disks.
    static let fat32Name = "msdos"

    private let fileSystem: any DataFolderFileSystem

    public init() { self.init(fileSystem: SystemDataFolderFileSystem()) }

    init(fileSystem: any DataFolderFileSystem) { self.fileSystem = fileSystem }

    /// Checks a folder the person chose. Creates it when it does not exist
    /// and tries a file and a symbolic link in it; both are removed again,
    /// and so are the folders it created when the answer is no. The app's
    /// own default folder is used as it is: pass `usingSubfolder: false`.
    /// A FAT32 disk is refused here only: `checkExisting` lets a folder
    /// already in use stay usable.
    ///
    /// `opened` is the data folder the app has open, with the disk it was
    /// on. When that same folder is checked and its place is now on another
    /// disk, its disk has left: the answer is `.missing` and nothing is
    /// created, wherever it was mounted.
    public func check(_ chosen: URL, usingSubfolder: Bool = true,
                      opened: OpenedDataFolder? = nil) -> Result<DataFolderVerdict, DataFolderProblem> {
        let chosen = chosen.standardizedFileURL
        if let problem = Self.pathProblem(chosen) { return .failure(problem) }
        if let opened, opened.folder.path == chosen.path, !opened.diskIsConnected {
            return .failure(.missing)
        }
        var created = [URL]()
        do {
            try ensureFolder(chosen, created: &created)
            // The app works with the resolved path once the folder is open.
            if let problem = Self.pathProblem(DataFolderStart.resolved(chosen)) { throw problem }
            if fileSystem.fileSystemName(at: chosen) == Self.fat32Name { throw DataFolderProblem.fat32 }
            var folder = chosen
            if usingSubfolder, try holdsOtherFiles(chosen) {
                folder = chosen.appendingPathComponent(Self.subfolderName, isDirectory: true)
                try ensureFolder(folder, created: &created)
            }
            try probe(folder)
            return .success(DataFolderVerdict(chosen: chosen, folder: folder, volume: volume(at: folder)))
        } catch {
            for folder in created.reversed() { fileSystem.removeEmptyFolder(at: folder) }
            return .failure(error as? DataFolderProblem ?? .notWritable)
        }
    }

    /// Looks at the folder already in use, at start and for Settings. Creates
    /// and writes nothing, so a disconnected disk gets no folder in its place.
    /// With `opened`, a folder at the same path on another disk than the
    /// one the data folder was opened on is `.missing` too: it stands where
    /// the disk was mounted.
    public func checkExisting(_ folder: URL,
                              opened: OpenedDataFolder? = nil) -> Result<DataFolderVolume, DataFolderProblem> {
        let folder = folder.standardizedFileURL
        if let problem = Self.pathProblem(folder) { return .failure(problem) }
        do {
            guard let isFolder = try fileSystem.isFolder(at: folder) else { return .failure(.missing) }
            guard isFolder else { return .failure(.notAFolder) }
            if let opened, opened.folder.path == folder.path, !opened.isStillThere {
                return .failure(.missing)
            }
            if let problem = Self.pathProblem(DataFolderStart.resolved(folder)) { return .failure(problem) }
            // Listing is what macOS privacy protection refuses.
            _ = try fileSystem.names(in: folder)
            return .success(volume(at: folder))
        } catch {
            return .failure(Self.problem(for: error, otherwise: .missing))
        }
    }

    // MARK: - Steps (each throws a DataFolderProblem)

    private func ensureFolder(_ folder: URL, created: inout [URL]) throws {
        switch try isFolder(folder) {
        case true?: return
        case false?: throw DataFolderProblem.notAFolder
        case nil: break
        }
        // Never stand in for a disk that is not connected.
        if let mountPoint = Self.mountPoint(of: folder), try isFolder(mountPoint) == nil {
            throw DataFolderProblem.missing
        }
        var missing = [folder]
        var parent = folder.deletingLastPathComponent()
        while parent.path != "/", try isFolder(parent) == nil {
            missing.append(parent)
            parent = parent.deletingLastPathComponent()
        }
        for folder in missing.reversed() {
            do {
                try fileSystem.createFolder(at: folder)
            } catch {
                throw Self.problem(for: error, otherwise: .cannotCreate)
            }
            created.append(folder)
        }
    }

    private func isFolder(_ url: URL) throws -> Bool? {
        do {
            return try fileSystem.isFolder(at: url)
        } catch {
            throw Self.problem(for: error, otherwise: .cannotCreate)
        }
    }

    /// Whether the folder has files and is not a TrailBridge data folder.
    /// Hidden entries (.DS_Store, a disk's own service folders) do not count.
    private func holdsOtherFiles(_ folder: URL) throws -> Bool {
        let names: [String]
        do {
            names = try fileSystem.names(in: folder).filter { !$0.hasPrefix(".") }
        } catch {
            throw Self.problem(for: error, otherwise: .notWritable)
        }
        return !names.isEmpty && Self.dataMarkers.isDisjoint(with: names)
    }

    private func probe(_ folder: URL) throws {
        let name = ".trailbridge-check-\(UUID().uuidString)"
        let file = folder.appendingPathComponent(name)
        do {
            try fileSystem.createFile(at: file)
        } catch {
            throw Self.problem(for: error, otherwise: .notWritable)
        }
        defer { fileSystem.remove(at: file) }
        // The file could be written, so a link that fails or reads back
        // wrong means the disk has no symbolic links.
        let link = folder.appendingPathComponent(name + "-link")
        defer { fileSystem.remove(at: link) }
        guard (try? fileSystem.createLink(at: link, to: name)) != nil,
              (try? fileSystem.linkTarget(at: link)) == name else {
            throw DataFolderProblem.noSymbolicLinks
        }
    }

    private func volume(at folder: URL) -> DataFolderVolume {
        fileSystem.volume(at: folder) ?? DataFolderVolume(kind: .thisMac, freeBytes: nil)
    }

    // MARK: - Rules

    /// `.unsupportedPath` for a path with a backslash, a line break or
    /// another control character; nil for every other path. Format
    /// characters (the joiner inside an emoji) are fine.
    public static func pathProblem(_ folder: URL) -> DataFolderProblem? {
        let unsupported = folder.path.unicodeScalars.contains {
            $0 == "\\" || $0.properties.generalCategory == .control
                || CharacterSet.newlines.contains($0)
        }
        return unsupported ? .unsupportedPath : nil
    }

    /// `/Volumes/<name>` for a path on a disk or share mounted there.
    static func mountPoint(of folder: URL) -> URL? {
        let parts = folder.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
    }

    /// EPERM is macOS privacy protection (Files and Folders); EACCES is an
    /// ordinary permission, so the folder is just not writable.
    static func problem(for error: any Error, otherwise: DataFolderProblem) -> DataFolderProblem {
        switch (error as? POSIXError)?.code {
        case .EPERM: .accessDenied
        case .EACCES, .EROFS: .notWritable
        default: otherwise
        }
    }
}

// MARK: - File system

/// The file-system calls the check makes; tests replace them. Errors are
/// `POSIXError`.
protocol DataFolderFileSystem: Sendable {
    /// Nil when nothing is at `url`. Follows symbolic links.
    func isFolder(at url: URL) throws -> Bool?
    /// Creates one folder; its parent must exist.
    func createFolder(at url: URL) throws
    /// Removes the folder only when it is empty.
    func removeEmptyFolder(at url: URL)
    func names(in folder: URL) throws -> [String]
    func createFile(at url: URL) throws
    func createLink(at url: URL, to target: String) throws
    func linkTarget(at url: URL) throws -> String
    /// Removes a file or a link.
    func remove(at url: URL)
    func volume(at url: URL) -> DataFolderVolume?
    /// The file system's name as `statfs` gives it: "apfs", "exfat", "msdos".
    func fileSystemName(at url: URL) -> String?
}

struct SystemDataFolderFileSystem: DataFolderFileSystem {
    func isFolder(at url: URL) throws -> Bool? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw Self.lastError()
        }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    func createFolder(at url: URL) throws {
        guard mkdir(url.path, 0o777) == 0 else { throw Self.lastError() }
    }

    func removeEmptyFolder(at url: URL) {
        _ = rmdir(url.path)
    }

    func names(in folder: URL) throws -> [String] {
        guard let directory = opendir(folder.path) else { throw Self.lastError() }
        defer { closedir(directory) }
        var names = [String]()
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    func createFile(at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.lastError() }
        defer { close(descriptor) }
        var byte: UInt8 = 0
        guard write(descriptor, &byte, 1) == 1 else { throw Self.lastError() }
    }

    func createLink(at url: URL, to target: String) throws {
        guard symlink(target, url.path) == 0 else { throw Self.lastError() }
    }

    func linkTarget(at url: URL) throws -> String {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(url.path, &buffer, buffer.count)
        guard length >= 0 else { throw Self.lastError() }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    func remove(at url: URL) {
        _ = unlink(url.path)
    }

    func volume(at url: URL) -> DataFolderVolume? {
        // A new URL each time: URL keeps the values it has read.
        guard let values = try? URL(fileURLWithPath: url.path, isDirectory: true).resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsInternalKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        return DataFolderVolume(
            isLocal: values.volumeIsLocal, isInternal: values.volumeIsInternal,
            importantUsageBytes: values.volumeAvailableCapacityForImportantUsage,
            availableBytes: values.volumeAvailableCapacity)
    }

    func fileSystemName(at url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
