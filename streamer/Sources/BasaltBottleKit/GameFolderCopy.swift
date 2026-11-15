// SPDX-License-Identifier: MIT
import Darwin
import Foundation

// MARK: - Folder name

/// The name of a game's own folder in `C:\Games`. The game reaches the folder
/// through Wine, so Windows must be able to hold the name as well as macOS.
public enum GameFolderName {
    /// A long name leaves less of Windows' 260-character path limit to the
    /// game's own files.
    public static let maximumLength = 64

    public enum Problem: Equatable, Sendable {
        case empty
        case tooLong
        case forbiddenCharacter(String)
        case startsWithDot
        case endsWithDotOrSpace
        case reservedName

        var reason: String {
            switch self {
            case .empty: return "the name is empty"
            case .tooLong: return "the name is longer than \(GameFolderName.maximumLength) characters"
            case .forbiddenCharacter(let character): return "Windows does not allow '\(character)' in names"
            case .startsWithDot: return "a name starting with a dot is hidden"
            case .endsWithDotOrSpace: return "Windows drops a dot or space at the end of a name"
            case .reservedName: return "Windows reserves this name for a device"
            }
        }
    }

    /// `value` itself when both Windows and macOS accept it: "Beat Saber"
    /// passes; "CON", "nul.txt", "Game.", "a/b" and ".hidden" do not.
    @discardableResult
    public static func validate(_ value: String) throws -> String {
        if let problem = problem(with: value) {
            throw GameFolderCopyError.invalidFolderName(value, problem)
        }
        return value
    }

    public static func isValid(_ value: String) -> Bool { problem(with: value) == nil }

    /// Windows file naming rules: none of `\ / : * ? " < > |` or control
    /// characters, no dot or space at the end, and no device name such as
    /// CON or COM1, also not before an extension ("nul.txt" is NUL). A leading
    /// dot is refused too: macOS hides such a folder, and the copy's own work
    /// folder starts with one.
    public static func problem(with value: String) -> Problem? {
        guard !value.isEmpty else { return .empty }
        guard value.count <= maximumLength, value.utf8.count <= 255 else { return .tooLong }
        if let scalar = value.unicodeScalars.first(where: {
            forbiddenCharacters.contains($0) || $0.properties.generalCategory == .control
        }) {
            return .forbiddenCharacter(String(scalar))
        }
        if value.hasPrefix(".") { return .startsWithDot }
        if value.hasSuffix(".") || value.hasSuffix(" ") { return .endsWithDotOrSpace }
        var device = String(value.prefix { $0 != "." })
        while device.hasSuffix(" ") { device.removeLast() }
        return reservedNames.contains(device.uppercased()) ? .reservedName : nil
    }

    private static let forbiddenCharacters = Set(#"\/:*?"<>|"#.unicodeScalars)

    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        for port in ["COM", "LPT"] {
            for number in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"] {
                names.insert(port + number)
            }
        }
        return names
    }()
}

// MARK: - Errors

/// Why scanning or copying a game folder stopped. Only `cancelled` is the
/// user's own choice. Whatever the reason, the environment keeps nothing of
/// the copy, and the chosen folder is never changed.
public enum GameFolderCopyError: LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidFolderName(String, GameFolderName.Problem)
    case sourceNotFolder(String)
    /// The folder is inside the app's data folder or contains it, and so
    /// would include environments, among them the destination.
    case sourceOverlapsDataFolder(String)
    case tooManyEntries(limit: Int)
    /// Symbolic links, special files, unreadable items: the first few, and
    /// how many there are in all.
    case unsupportedEntries(examples: [GameFolderInventory.RejectedEntry], count: Int)
    /// Entries whose names differ only in case, which Windows and the Mac's
    /// usual volumes cannot hold side by side.
    case caseConflicts(examples: [String], count: Int)
    case destinationExists(String)
    /// A symbolic link, or something that is not a folder, on the way from
    /// the environment's prefix to `C:\Games`.
    case unsafeDestination(String)
    case notEnoughSpace(required: Int64, available: Int64?)
    /// A file vanished or changed after the scan.
    case sourceChanged(String)
    case failed(String)

    public var isCancellation: Bool { self == .cancelled }

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Copying was cancelled; nothing was added"
        case .invalidFolderName(let name, let problem):
            return "'\(name)' cannot name the game's folder: \(problem.reason)"
        case .sourceNotFolder(let path):
            return "\(path) is not a folder"
        case .sourceOverlapsDataFolder(let path):
            return "\(path) is inside the app's data folder or contains it; choose the game's own folder"
        case .tooManyEntries(let limit):
            return "The folder holds more than \(limit) files and folders"
        case .unsupportedEntries(let examples, let count):
            let list = examples.map { "\($0.path) (\($0.reason.description))" }
            return "The folder contains \(count) item(s) that cannot be copied safely: "
                + Self.listing(list, total: count)
        case .caseConflicts(let examples, let count):
            return "The folder contains names that differ only in case: "
                + Self.listing(examples, total: count)
        case .destinationExists(let name):
            return #"C:\Games\"# + name + " already exists in this environment; choose another folder name"
        case .unsafeDestination(let path):
            return "\(path) is a symbolic link or not a folder; nothing was copied"
        case .notEnoughSpace(let required, let available):
            let free = available.map { Self.bytes($0) + " free" } ?? "free space unknown"
            return "Not enough disk space: the copy needs \(Self.bytes(required)) free (\(free))"
        case .sourceChanged(let path):
            return "The folder changed after it was scanned (\(path)); choose it again"
        case .failed(let message):
            return message
        }
    }

    private static func listing(_ items: [String], total: Int) -> String {
        let more = total - items.count
        return items.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }

    private static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }
}

// MARK: - Inventory

/// A read-only scan of a game folder chosen anywhere on the Mac: what a copy
/// creates, and what makes it refuse. Links are recorded, never followed.
public struct GameFolderInventory: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// Relative to the scanned folder, with "/" between components.
        public let path: String
        public let size: Int64

        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public enum Rejection: String, Equatable, Sendable, CustomStringConvertible {
        case symbolicLink, namedPipe, socket, device, unreadable, otherVolume, unsupportedName, other

        public var description: String {
            switch self {
            case .symbolicLink: return "symbolic link"
            case .namedPipe: return "named pipe"
            case .socket: return "socket"
            case .device: return "device"
            case .unreadable: return "unreadable"
            case .otherVolume: return "on another volume"
            case .unsupportedName: return "name is not UTF-8"
            case .other: return "special file"
            }
        }
    }

    public struct RejectedEntry: Equatable, Sendable {
        public let path: String
        public let reason: Rejection

        public init(path: String, reason: Rejection) {
            self.path = path
            self.reason = reason
        }
    }

    /// Far above a VR game (Beat Saber has about 1,200 entries), low enough
    /// that a scan of a wrong folder, such as a whole disk, stops soon.
    public static let defaultEntryLimit = 100_000
    /// How many rejected entries and case conflicts are kept by name.
    public static let exampleLimit = 5

    /// The scanned folder, with every symbolic link in its path resolved.
    public let source: URL
    /// `st_dev` of the scanned folder: files clone only within one volume.
    public let volume: Int32
    /// With `volume`, identifies the folder, so a copy notices a replacement.
    let sourceInode: UInt64
    /// Regular files in walk order; `.DS_Store` and AppleDouble `._*` files
    /// are left out.
    public let files: [File]
    /// Every folder below `source`, each after the folder holding it.
    public let directories: [String]
    public let rejected: [RejectedEntry]
    public let rejectedCount: Int
    public let caseConflicts: [String]
    public let caseConflictCount: Int
    /// Entries seen, the skipped Finder files included.
    public let entryCount: Int
    public let totalBytes: Int64

    /// Nothing in the folder makes a copy refuse.
    public var isCopyable: Bool { rejectedCount == 0 && caseConflictCount == 0 }

    init(source: URL, volume: Int32, sourceInode: UInt64, files: [File],
         directories: [String], rejected: [RejectedEntry] = [], rejectedCount: Int = 0,
         caseConflicts: [String] = [], caseConflictCount: Int = 0, entryCount: Int = 0) {
        self.source = source
        self.volume = volume
        self.sourceInode = sourceInode
        self.files = files
        self.directories = directories
        self.rejected = rejected
        self.rejectedCount = rejectedCount
        self.caseConflicts = caseConflicts
        self.caseConflictCount = caseConflictCount
        self.entryCount = entryCount
        totalBytes = files.reduce(0) { Self.addingBytes($0, $1.size) }
    }

    /// Byte counts stop at `Int64.max` instead of trapping: sparse files can
    /// claim more than an Int64 holds in total, and a trap in the middle of a
    /// copy would leave its work folder behind.
    static func addingBytes(_ total: Int64, _ bytes: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(max(0, bytes))
        return overflow ? .max : sum
    }
}

// MARK: - Progress and space

public struct GameFolderCopyProgress: Equatable, Sendable {
    public let copiedBytes: Int64
    public let totalBytes: Int64
    public let copiedFiles: Int
    public let totalFiles: Int

    public init(copiedBytes: Int64, totalBytes: Int64, copiedFiles: Int, totalFiles: Int) {
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
        self.copiedFiles = copiedFiles
        self.totalFiles = totalFiles
    }

    /// 0...1 by bytes; by files when there are no bytes to copy.
    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(copiedBytes) / Double(totalBytes)) }
        if totalFiles > 0 { return min(1, Double(copiedFiles) / Double(totalFiles)) }
        return 1
    }
}

/// The volume a copy writes to.
public struct GameFolderVolume: Equatable, Sendable {
    public let device: Int32
    public let freeBytes: Int64
    /// APFS: a file on the same volume is cloned, sharing its blocks.
    public let supportsClones: Bool

    public init(device: Int32, freeBytes: Int64, supportsClones: Bool) {
        self.device = device
        self.freeBytes = freeBytes
        self.supportsClones = supportsClones
    }

    /// Whether the files of `inventory` are cloned rather than copied here.
    public func clones(_ inventory: GameFolderInventory) -> Bool {
        supportsClones && device == inventory.volume
    }
}

public enum GameFolderSpace {
    /// The 20 GiB the streamer keeps free while it records video
    /// (`EncodedVideoRecorder.defaultMinimumFreeBytes`), so a copy never fills
    /// the disk the system and the games run from.
    public static let defaultReserveBytes: Int64 = 20 << 30

    /// Free bytes the destination needs before a copy starts: the reserve
    /// alone when the files are cloned on one APFS volume, else their size
    /// plus the reserve.
    public static func requiredFreeBytes(totalBytes: Int64, clones: Bool,
                                         reserveBytes: Int64) -> Int64 {
        let reserve = max(0, reserveBytes)
        guard !clones else { return reserve }
        let (sum, overflow) = max(0, totalBytes).addingReportingOverflow(reserve)
        return overflow ? .max : sum
    }

    /// The bytes available to the user on the volume holding `url`, as
    /// `statfs` reports them; purgeable space does not count. The copy checks
    /// this number, so a screen that shows free space should show it too.
    public static func freeBytes(at url: URL) -> Int64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return available(info)
    }

    public static func volume(at url: URL) -> GameFolderVolume? {
        var info = statfs()
        var identity = stat()
        guard statfs(url.path, &info) == 0, stat(url.path, &identity) == 0 else { return nil }
        return volume(info, device: identity.st_dev)
    }

    static func volume(of descriptor: Int32) -> GameFolderVolume? {
        var info = statfs()
        var identity = stat()
        guard fstatfs(descriptor, &info) == 0, fstat(descriptor, &identity) == 0 else { return nil }
        return volume(info, device: identity.st_dev)
    }

    private static func volume(_ info: statfs, device: dev_t) -> GameFolderVolume {
        let type = withUnsafeBytes(of: info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return GameFolderVolume(device: device, freeBytes: available(info),
                                supportsClones: type == "apfs")
    }

    private static func available(_ info: statfs) -> Int64 {
        let (bytes, overflow) = Int64(clamping: info.f_bavail)
            .multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? .max : bytes
    }
}

// MARK: - Scan and copy

extension BottleManager {
    /// Scans a game folder chosen anywhere on the Mac, without changing it.
    /// The chosen URL is resolved once; inside it no link is ever followed.
    /// Refuses a folder that overlaps the data folder, which holds every
    /// environment, and stops after `entryLimit` entries.
    public func inventoryGameFolder(
        _ source: URL, entryLimit: Int = GameFolderInventory.defaultEntryLimit
    ) throws -> GameFolderInventory {
        guard let path = GameFolderLocation.canonical(source.path) else {
            throw GameFolderCopyError.sourceNotFolder(source.path)
        }
        try requireOutsideDataFolder(path)
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            let code = errno
            if code == ENOTDIR || code == ELOOP { throw GameFolderCopyError.sourceNotFolder(path) }
            throw GameFolderCopyError.failed("Could not open \(path): \(posixMessage(code))")
        }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0 else {
            throw GameFolderCopyError.failed("Could not read \(path): \(posixMessage(errno))")
        }
        let walk = try GameFolderWalk.walk(root, device: info.st_dev, entryLimit: entryLimit)
        return GameFolderInventory(
            source: URL(fileURLWithPath: path, isDirectory: true), volume: info.st_dev,
            sourceInode: info.st_ino, files: walk.files, directories: walk.directories,
            rejected: walk.rejected, rejectedCount: walk.rejectedCount,
            caseConflicts: walk.caseConflicts, caseConflictCount: walk.caseConflictCount,
            entryCount: walk.entryCount)
    }

    /// Copies a scanned folder into `C:\Games\<folderName>` of a managed
    /// bottle and returns the new folder. Never runs Wine.
    ///
    /// Everything is refused before the first write: entries the scan
    /// rejected, a name Windows cannot hold, a link anywhere from the prefix
    /// to `Games`, an existing folder of that name in any case, and too little
    /// space. The free space must cover `reserveBytes`, plus the files' size
    /// unless they are cloned on the same APFS volume. Files are copied one by
    /// one into a hidden work folder in `Games`, cloned where the volume
    /// allows; the finished tree is checked again for links and special files
    /// and then renamed into place, never over an existing folder. On any
    /// failure or cancellation only the work folder is removed, together with
    /// a `Games` folder this call created and left empty.
    ///
    /// `isCancelled` is polled before each file and while a large file copies;
    /// `progress` is called at the start, at most ten times a second while
    /// copying, and once all files are copied.
    @discardableResult
    public func copyGameFolder(
        _ inventory: GameFolderInventory, intoBottle bottleName: String,
        folderName: String, reserveBytes: Int64 = GameFolderSpace.defaultReserveBytes,
        progress: (GameFolderCopyProgress) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> URL {
        try withoutActuallyEscaping(progress) { progress in
            try withoutActuallyEscaping(isCancelled) { isCancelled in
                try copyGameFolder(
                    inventory, intoBottle: bottleName, folderName: folderName,
                    reserveBytes: reserveBytes, progress: progress, isCancelled: isCancelled,
                    freeBytes: GameFolderSpace.freeBytes(at:), clones: true)
            }
        }
    }

    /// `freeBytes` stands in for the volume's free space, and `clones: false`
    /// copies every file's data even where cloning works, so tests reach the
    /// progress, cancellation and space checks inside one file.
    func copyGameFolder(
        _ inventory: GameFolderInventory, intoBottle bottleName: String, folderName: String,
        reserveBytes: Int64, progress: @escaping (GameFolderCopyProgress) -> Void,
        isCancelled: @escaping () -> Bool, freeBytes: @escaping (URL) -> Int64?, clones: Bool
    ) throws -> URL {
        let bottle = try loadBottle(bottleName)
        let name = try GameFolderName.validate(folderName)
        try Self.requireCopyable(inventory)
        let source = try openScannedFolder(inventory)
        defer { close(source.descriptor) }
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let destination = try GameFolderDestination.open(prefix: prefix)
        try destination.requireAbsent(name)
        if let driveCPath = GameFolderLocation.canonical(driveC.path),
           GameFolderLocation.lineage(of: driveCPath).contains(
               GameFolderLocation.Identity(device: inventory.volume, inode: inventory.sourceInode)) {
            throw GameFolderCopyError.sourceOverlapsDataFolder(inventory.source.path)
        }
        let required = GameFolderSpace.requiredFreeBytes(
            totalBytes: inventory.totalBytes,
            clones: destination.volume.clones(inventory), reserveBytes: reserveBytes)
        let available = freeBytes(driveC)
        guard let available, available >= required else {
            throw GameFolderCopyError.notEnoughSpace(required: required, available: available)
        }
        guard !isCancelled() else { throw GameFolderCopyError.cancelled }

        let work = try destination.makeWorkFolder()
        defer { close(work.descriptor) }
        do {
            let copier = try GameFolderCopier(
                inventory: inventory, source: source, work: work.descriptor,
                flags: clones ? GameFolderCopier.cloneFlags : GameFolderCopier.dataFlags,
                stopBelowFreeBytes: max(0, reserveBytes) / 2,
                freeBytes: { freeBytes(driveC) }, progress: progress, isCancelled: isCancelled)
            try copier.run()
            try copier.verify(device: destination.volume.device)
            try destination.publish(work.name, as: name)
        } catch {
            destination.discard(work.name)
            throw error
        }
        return driveC.appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The source must be neither inside the data folder nor around it,
    /// compared both by path and by file identity, so a second path to the
    /// same folder (another case, `/System/Volumes/Data`) is caught too.
    private func requireOutsideDataFolder(_ source: String) throws {
        let root = GameFolderLocation.canonicalAllowingMissing(paths.root.path)
        var overlaps = GameFolderLocation.overlap(source, root)
        if !overlaps, let rootIdentity = GameFolderLocation.identity(of: root),
           let sourceIdentity = GameFolderLocation.identity(of: source) {
            overlaps = GameFolderLocation.lineage(of: source).contains(rootIdentity)
                || GameFolderLocation.lineage(of: root).contains(sourceIdentity)
        }
        if overlaps { throw GameFolderCopyError.sourceOverlapsDataFolder(source) }
    }

    /// Opens the scanned folder again and makes sure it is still the folder
    /// that was scanned.
    private func openScannedFolder(
        _ inventory: GameFolderInventory
    ) throws -> (descriptor: Int32, path: String) {
        let path = inventory.source.path
        guard GameFolderLocation.canonical(path) == path else {
            throw GameFolderCopyError.sourceChanged(path)
        }
        try requireOutsideDataFolder(path)
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GameFolderCopyError.sourceChanged(path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == inventory.volume,
              info.st_ino == inventory.sourceInode else {
            close(descriptor)
            throw GameFolderCopyError.sourceChanged(path)
        }
        return (descriptor, GameFolderLocation.path(of: descriptor) ?? path)
    }

    /// Checks the inventory itself as well as what its scan found, so even a
    /// hand-made one cannot reach outside the work folder or make two names
    /// collide on a case-insensitive volume.
    private static func requireCopyable(_ inventory: GameFolderInventory) throws {
        guard inventory.rejectedCount == 0 else {
            throw GameFolderCopyError.unsupportedEntries(
                examples: inventory.rejected, count: inventory.rejectedCount)
        }
        guard inventory.caseConflictCount == 0 else {
            throw GameFolderCopyError.caseConflicts(
                examples: inventory.caseConflicts, count: inventory.caseConflictCount)
        }
        var seen = [String: String]()
        for path in inventory.directories + inventory.files.map(\.path) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw GameFolderCopyError.failed("The scan lists an unsafe path: \(path)")
            }
            let key = GameFolderWalk.folded(path)
            if let earlier = seen[key] {
                throw GameFolderCopyError.caseConflicts(examples: [earlier, path], count: 1)
            }
            seen[key] = path
        }
    }
}

// MARK: - Walking a folder

/// One pass over a folder tree from an open folder, with lstat semantics:
/// every folder below it is opened with O_NOFOLLOW_ANY, so neither a link in
/// the tree nor one swapped in during the walk is ever followed. Used for the
/// scan and again to check the finished copy.
struct GameFolderWalk {
    var files = [GameFolderInventory.File]()
    var directories = [String]()
    var rejected = [GameFolderInventory.RejectedEntry]()
    var rejectedCount = 0
    var caseConflicts = [String]()
    var caseConflictCount = 0
    var entryCount = 0

    private struct Entry {
        let name: String
        let info: stat?
        let readable: Bool
        let validName: Bool
    }

    static func walk(_ root: Int32, device: dev_t, entryLimit: Int) throws -> GameFolderWalk {
        var walk = GameFolderWalk()
        var pending = [""]
        while let folder = pending.popLast() {
            guard let entries = listing(of: folder, in: root) else {
                if folder.isEmpty {
                    throw GameFolderCopyError.failed("Could not read the folder: \(posixMessage(errno))")
                }
                walk.reject(folder, .unreadable)
                continue
            }
            if !folder.isEmpty { walk.directories.append(folder) }
            var kept = [String]()
            var subfolders = [String]()
            for entry in entries {
                walk.entryCount += 1
                guard walk.entryCount <= entryLimit else {
                    throw GameFolderCopyError.tooManyEntries(limit: entryLimit)
                }
                let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                guard entry.validName else { walk.reject(path, .unsupportedName); continue }
                guard let info = entry.info else { walk.reject(path, .unreadable); continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    if entry.name == ".DS_Store" || entry.name.hasPrefix("._") { continue }
                    if info.st_dev != device {
                        walk.reject(path, .otherVolume)
                    } else if !entry.readable {
                        walk.reject(path, .unreadable)
                    } else {
                        walk.files.append(.init(path: path, size: Int64(info.st_size)))
                        kept.append(path)
                    }
                case S_IFDIR:
                    if info.st_dev != device {
                        walk.reject(path, .otherVolume)
                    } else {
                        subfolders.append(path)
                        kept.append(path)
                    }
                case S_IFLNK: walk.reject(path, .symbolicLink)
                case S_IFIFO: walk.reject(path, .namedPipe)
                case S_IFSOCK: walk.reject(path, .socket)
                case S_IFCHR, S_IFBLK: walk.reject(path, .device)
                default: walk.reject(path, .other)
                }
            }
            walk.noteCaseConflicts(among: kept)
            pending.append(contentsOf: subfolders.reversed())
        }
        return walk
    }

    /// Names as Windows and the Mac's usual volumes compare them: case and
    /// Unicode normalization do not count.
    static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    private mutating func reject(_ path: String, _ reason: GameFolderInventory.Rejection) {
        rejectedCount += 1
        if rejected.count < GameFolderInventory.exampleLimit {
            rejected.append(.init(path: path, reason: reason))
        }
    }

    /// `paths` share one folder; the copy would create all of them there.
    private mutating func noteCaseConflicts(among paths: [String]) {
        var seen = [String: String]()
        for path in paths {
            let key = Self.folded(path)
            guard let earlier = seen[key] else {
                seen[key] = path
                continue
            }
            caseConflictCount += 1
            for name in [earlier, path] where caseConflicts.count < GameFolderInventory.exampleLimit
                && !caseConflicts.contains(name) {
                caseConflicts.append(name)
            }
        }
    }

    /// The entries of `folder` (relative to `root`), sorted by name, or nil
    /// when the folder cannot be opened or read to the end.
    private static func listing(of folder: String, in root: Int32) -> [Entry]? {
        let descriptor = folder.isEmpty
            ? openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            : openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            return nil
        }
        defer { closedir(stream) }
        var entries = [Entry]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { return nil }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            let name = String(decoding: bytes, as: UTF8.self)
            if name == "." || name == ".." { continue }
            guard name.utf8.elementsEqual(bytes) else {
                entries.append(Entry(name: name, info: nil, readable: false, validName: false))
                continue
            }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                entries.append(Entry(name: name, info: nil, readable: false, validName: true))
                continue
            }
            let readable = info.st_mode & S_IFMT == S_IFREG && faccessat(descriptor, name, R_OK, 0) == 0
            entries.append(Entry(name: name, info: info, readable: readable, validName: true))
        }
        return entries.sorted { $0.name < $1.name }
    }
}

// MARK: - Destination

/// `drive_c` and `Games` of the target prefix, held open so every write
/// happens inside them by descriptor: no link from the prefix on is ever
/// followed, even one created during the copy.
private final class GameFolderDestination {
    private let driveC: Int32
    private var games: Int32
    private var createdGames = false
    let volume: GameFolderVolume

    private init(driveC: Int32, games: Int32, volume: GameFolderVolume) {
        self.driveC = driveC
        self.games = games
        self.volume = volume
    }

    deinit {
        if games >= 0 { close(games) }
        close(driveC)
    }

    static func open(prefix: URL) throws -> GameFolderDestination {
        let prefixDescriptor = Darwin.open(
            prefix.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard prefixDescriptor >= 0 else { throw refusal(errno, at: prefix.path) }
        defer { close(prefixDescriptor) }
        let driveC = openat(prefixDescriptor, "drive_c",
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard driveC >= 0 else {
            throw refusal(errno, at: prefix.appendingPathComponent("drive_c").path)
        }
        guard let volume = GameFolderSpace.volume(of: driveC) else {
            let code = errno
            close(driveC)
            throw GameFolderCopyError.failed("Could not read the environment's disk: \(posixMessage(code))")
        }
        let games = openat(driveC, "Games", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if games < 0 && errno != ENOENT {
            let code = errno
            close(driveC)
            throw refusal(code, at: prefix.appendingPathComponent("drive_c/Games").path)
        }
        return GameFolderDestination(driveC: driveC, games: games, volume: volume)
    }

    /// Nothing named `name` in `Games`, in any case; a dangling link counts.
    /// Reports the name as it is on disk.
    func requireAbsent(_ name: String) throws {
        guard games >= 0 else { return }
        guard let existing = GameFolderLocation.names(in: games) else {
            throw GameFolderCopyError.failed(#"Could not read C:\Games: "# + posixMessage(errno))
        }
        let wanted = GameFolderWalk.folded(name)
        if let match = existing.first(where: { GameFolderWalk.folded($0) == wanted }) {
            throw GameFolderCopyError.destinationExists(match)
        }
        var info = stat()
        if fstatat(games, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw GameFolderCopyError.destinationExists(name)
        }
        guard errno == ENOENT else {
            throw GameFolderCopyError.failed(#"Could not check C:\Games: "# + posixMessage(errno))
        }
    }

    /// A hidden folder in `Games`, which the Library's own search skips.
    func makeWorkFolder() throws -> (name: String, descriptor: Int32) {
        if games < 0 {
            if mkdirat(driveC, "Games", 0o755) == 0 {
                createdGames = true
            } else if errno != EEXIST {
                throw GameFolderCopyError.failed(#"Could not create C:\Games: "# + posixMessage(errno))
            }
            games = openat(driveC, "Games", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard games >= 0 else {
                discard(nil)
                throw GameFolderCopyError.unsafeDestination(#"C:\Games"#)
            }
        }
        let name = ".trailbridge-import-\(UUID().uuidString)"
        guard mkdirat(games, name, 0o755) == 0 else {
            let code = errno
            discard(nil)
            throw GameFolderCopyError.failed(#"Could not create a work folder in C:\Games: "#
                + posixMessage(code))
        }
        let descriptor = openat(games, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            discard(name)
            throw GameFolderCopyError.failed("Could not open the work folder: \(posixMessage(code))")
        }
        return (name, descriptor)
    }

    /// Renames the work folder to `name`; the volume refuses if that exists.
    func publish(_ work: String, as name: String) throws {
        guard renameatx_np(games, work, games, name, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        if code == EEXIST { throw GameFolderCopyError.destinationExists(name) }
        throw GameFolderCopyError.failed(#"Could not move the copy into C:\Games: "#
            + posixMessage(code))
    }

    /// Removes the work folder, then `Games` if this copy created it and it
    /// is empty again. Nothing else.
    func discard(_ work: String?) {
        if let work, games >= 0 { GameFolderLocation.removeEntry(work, in: games) }
        if createdGames { _ = unlinkat(driveC, "Games", AT_REMOVEDIR) }
    }

    private static func refusal(_ code: Int32, at path: String) -> GameFolderCopyError {
        switch code {
        case ELOOP, ENOTDIR: return .unsafeDestination(path)
        case ENOENT: return .failed("The environment has no \(path)")
        default: return .failed("Could not open \(path): \(posixMessage(code))")
        }
    }
}

// MARK: - Copying

/// Copies the scanned files into the work folder one at a time with
/// copyfile, then checks the result.
private final class GameFolderCopier {
    /// Clone where the volume allows, else copy data, metadata and extended
    /// attributes; implies COPYFILE_EXCL and COPYFILE_NOFOLLOW_SRC.
    static let cloneFlags = copyfile_flags_t(COPYFILE_CLONE)
    /// What COPYFILE_CLONE falls back to, without trying a clone first.
    static let dataFlags = copyfile_flags_t(
        COPYFILE_EXCL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_NOFOLLOW_SRC)
    /// Large files report progress and are checked for cancellation and
    /// space at least this often.
    private static let blockSize: UInt32 = 1 << 20
    private static let spaceCheckInterval: Int64 = 64 << 20
    private static let reportInterval: UInt64 = 100_000_000

    private let inventory: GameFolderInventory
    private let source: Int32
    private let sourcePath: String
    private let work: Int32
    private let workPath: String
    private let flags: copyfile_flags_t
    private let stopBelowFreeBytes: Int64
    private let freeBytes: () -> Int64?
    private let progress: (GameFolderCopyProgress) -> Void
    private let isCancelled: () -> Bool
    private var copiedBytes: Int64 = 0
    private var copiedFiles = 0
    private var lastReport: UInt64 = 0
    private var lastSpaceCheck: Int64 = 0

    init(inventory: GameFolderInventory, source: (descriptor: Int32, path: String), work: Int32,
         flags: copyfile_flags_t, stopBelowFreeBytes: Int64, freeBytes: @escaping () -> Int64?,
         progress: @escaping (GameFolderCopyProgress) -> Void,
         isCancelled: @escaping () -> Bool) throws {
        guard let workPath = GameFolderLocation.path(of: work) else {
            throw GameFolderCopyError.failed("Could not locate the work folder: \(posixMessage(errno))")
        }
        self.inventory = inventory
        self.source = source.descriptor
        sourcePath = source.path
        self.work = work
        self.workPath = workPath
        self.flags = flags
        self.stopBelowFreeBytes = stopBelowFreeBytes
        self.freeBytes = freeBytes
        self.progress = progress
        self.isCancelled = isCancelled
    }

    func run() throws {
        report(copiedBytes, force: true)
        for folder in inventory.directories {
            guard mkdirat(work, folder, 0o755) == 0 else {
                throw GameFolderCopyError.failed("Could not create \(folder): \(posixMessage(errno))")
            }
        }
        for file in inventory.files {
            if isCancelled() { throw GameFolderCopyError.cancelled }
            if let shortage = spaceShortage(at: copiedBytes, force: true) { throw shortage }
            try copy(file)
            copiedBytes = GameFolderInventory.addingBytes(copiedBytes, file.size)
            copiedFiles += 1
            report(copiedBytes, force: false)
        }
        report(copiedBytes, force: true)
    }

    /// The finished tree holds exactly the scanned folders and files, and no
    /// link or special file a copy might have produced.
    func verify(device: dev_t) throws {
        let walk = try GameFolderWalk.walk(work, device: device, entryLimit: .max)
        if let entry = walk.rejected.first {
            throw GameFolderCopyError.failed(
                "The copy contains \(entry.path) (\(entry.reason.description))")
        }
        let expected = Dictionary(inventory.files.map { ($0.path, $0.size) }) { first, _ in first }
        let copied = Dictionary(walk.files.map { ($0.path, $0.size) }) { first, _ in first }
        guard walk.caseConflictCount == 0, copied == expected,
              Set(walk.directories) == Set(inventory.directories) else {
            throw GameFolderCopyError.failed("The copy does not match the scanned folder")
        }
    }

    private func copy(_ file: GameFolderInventory.File) throws {
        try requireUnchangedSource(file)
        let monitor = DataCopyMonitor { [unowned self] copied in
            let bytes = GameFolderInventory.addingBytes(self.copiedBytes, copied)
            self.report(bytes, force: false)
            if self.isCancelled() { return .cancelled }
            return self.spaceShortage(at: bytes, force: false)
        }
        guard let state = copyfile_state_alloc() else {
            throw GameFolderCopyError.failed("Could not copy \(file.path): \(posixMessage(ENOMEM))")
        }
        defer { copyfile_state_free(state) }
        var blockSize = Self.blockSize
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_BSIZE), &blockSize)
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                               unsafeBitCast(dataCopyCallback, to: UnsafeRawPointer.self))
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX),
                               Unmanaged.passUnretained(monitor).toOpaque())
        let (result, code) = withExtendedLifetime(monitor) {
            let result = copyfile(sourcePath + "/" + file.path, workPath + "/" + file.path,
                                  state, flags)
            return (result, errno)
        }
        if result != 0 {
            if let reason = monitor.stopReason { throw reason }
            let failure = monitor.failure ?? code
            if failure == ENOENT { throw GameFolderCopyError.sourceChanged(file.path) }
            throw GameFolderCopyError.failed("Could not copy \(file.path): \(posixMessage(failure))")
        }
        try unlockCopy(of: file)
    }

    /// Still a regular file of the scanned size, reached without any link.
    private func requireUnchangedSource(_ file: GameFolderInventory.File) throws {
        var info = stat()
        guard fstatat(source, file.path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
            let code = errno
            if code == ENOENT || code == ELOOP || code == ENOTDIR {
                throw GameFolderCopyError.sourceChanged(file.path)
            }
            throw GameFolderCopyError.failed("Could not read \(file.path): \(posixMessage(code))")
        }
        guard info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == file.size else {
            throw GameFolderCopyError.sourceChanged(file.path)
        }
    }

    /// The copy keeps the source's mode and file flags. A locked file
    /// (immutable or append-only) could never be removed again, not even
    /// with its environment, and a read-only one keeps the game from updating
    /// it: unlock it and let its owner read and write it.
    private func unlockCopy(of file: GameFolderInventory.File) throws {
        var info = stat()
        guard fstatat(work, file.path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0,
              info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == file.size else {
            throw GameFolderCopyError.sourceChanged(file.path)
        }
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & locks != 0,
           lchflags(workPath + "/" + file.path, info.st_flags & ~locks) != 0 {
            throw GameFolderCopyError.failed("Could not unlock \(file.path): \(posixMessage(errno))")
        }
        let mode = (info.st_mode & 0o777) | S_IRUSR | S_IWUSR
        if info.st_mode & 0o7777 != mode,
           fchmodat(work, file.path, mode, AT_SYMLINK_NOFOLLOW) != 0 {
            throw GameFolderCopyError.failed(
                "Could not set permissions on \(file.path): \(posixMessage(errno))")
        }
    }

    private func report(_ bytes: Int64, force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now &- lastReport >= Self.reportInterval else { return }
        lastReport = now
        progress(GameFolderCopyProgress(
            copiedBytes: bytes, totalBytes: inventory.totalBytes,
            copiedFiles: copiedFiles, totalFiles: inventory.files.count))
    }

    /// Stops the copy once the volume falls below half the reserve: another
    /// program may be filling it, or a clone fell back to a full copy.
    private func spaceShortage(at bytes: Int64, force: Bool) -> GameFolderCopyError? {
        guard force || bytes - lastSpaceCheck >= Self.spaceCheckInterval else { return nil }
        lastSpaceCheck = bytes
        guard let free = freeBytes(), free < stopBelowFreeBytes else { return nil }
        return .notEnoughSpace(required: stopBelowFreeBytes, available: free)
    }
}

/// What copyfile's C callback can reach while one file's data copies.
private final class DataCopyMonitor {
    /// Bytes of the file copied so far; returns a reason to stop, or nil.
    let advance: (Int64) -> GameFolderCopyError?
    var stopReason: GameFolderCopyError?
    var failure: Int32?

    init(advance: @escaping (Int64) -> GameFolderCopyError?) { self.advance = advance }
}

/// Called for every block copyfile writes and for every error. An error
/// stops the copy, as without a callback: going on would make copyfile try
/// the same write again.
private let dataCopyCallback: copyfile_callback_t = { what, stage, state, _, _, context in
    guard let context else { return COPYFILE_CONTINUE }
    let monitor = Unmanaged<DataCopyMonitor>.fromOpaque(context).takeUnretainedValue()
    if stage == COPYFILE_ERR {
        monitor.failure = errno
        return COPYFILE_QUIT
    }
    guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else { return COPYFILE_CONTINUE }
    var copied: off_t = 0
    _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
    guard let reason = monitor.advance(Int64(copied)) else { return COPYFILE_CONTINUE }
    monitor.stopReason = reason
    return COPYFILE_QUIT
}

// MARK: - Paths and file identity

enum GameFolderLocation {
    struct Identity: Equatable {
        let device: dev_t
        let inode: UInt64
    }

    /// `path` with every link resolved, or nil when it does not exist.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Like `canonical`, for a folder that may not exist yet: the nearest
    /// existing folder above it is resolved instead.
    static func canonicalAllowingMissing(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing = [String]()
        while canonical(existing.path) == nil && existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = canonical(existing.path) ?? existing.path
        return missing.reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
    }

    /// Equal, or one inside the other, ignoring case.
    static func overlap(_ first: String, _ second: String) -> Bool {
        let first = GameFolderWalk.folded(first)
        let second = GameFolderWalk.folded(second)
        return first == second || contains(first, second) || contains(second, first)
    }

    private static func contains(_ folder: String, _ path: String) -> Bool {
        folder == "/" || path.hasPrefix(folder + "/")
    }

    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// The identities of `path` and of every folder above it.
    static func lineage(of path: String) -> [Identity] {
        var identities = [Identity]()
        var current = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if let identity = identity(of: current.path) { identities.append(identity) }
            guard current.path != "/" else { return identities }
            current.deleteLastPathComponent()
        }
    }

    /// The path the system has for an open file or folder.
    static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// The names in an open folder, read through a description of their own
    /// so the folder's descriptor stays untouched.
    static func names(in folder: Int32) -> [String]? {
        let descriptor = openat(folder, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            return nil
        }
        defer { closedir(stream) }
        var names = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? names : nil }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Removes the entry `name` of an open folder: a folder with everything
    /// in it, anything else by itself. A link is removed, never followed, so
    /// nothing outside the entry is touched. Best effort.
    static func removeEntry(_ name: String, in parent: Int32) {
        let folder = openat(parent, name,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard folder >= 0 else {
            if unlinkat(parent, name, 0) != 0 && errno == EPERM {
                unlock(name, in: parent)
                _ = unlinkat(parent, name, 0)
            }
            return
        }
        for child in names(in: folder) ?? [] { removeEntry(child, in: folder) }
        close(folder)
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    /// Clears the immutable and append-only flags that make unlink fail.
    private static func unlock(_ name: String, in parent: Int32) {
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        _ = fchflags(file, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
    }
}

private func posixMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}
