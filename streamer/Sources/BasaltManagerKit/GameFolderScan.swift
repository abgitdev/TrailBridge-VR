import Foundation
import BasaltBottleKit

// MARK: - Executables

/// One `.exe` file in a game folder chosen for Add Game from Folder.
public struct GameFolderExecutable: Identifiable, Equatable, Sendable {
    /// What the file most likely is. Only `.game` files are offered as the
    /// game; the others are listed under "Other .exe files", so the user can
    /// still choose one when the guess is wrong.
    public enum Kind: Int, Comparable, Sendable {
        /// The game, or a launcher of it.
        case game
        /// A setup program: such a folder may hold an installer, not a game.
        case installer
        /// A crash reporter, a runtime installer or an uninstaller that games
        /// ship next to their own executable.
        case helper

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Relative to the game folder, with "/" between components, as in
    /// `GameFolderInventory.files`.
    public let path: String
    public let size: Int64
    public let kind: Kind

    public init(path: String, size: Int64, kind: Kind) {
        self.path = path
        self.size = size
        self.kind = kind
    }

    public var id: String { path }

    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Folders between the game folder and the file: 0 for a file at the top.
    public var depth: Int { max(0, path.split(separator: "/").count - 1) }
}

// MARK: - Hints and refusals

/// Something the sheet tells the user about a folder before it is added.
public enum GameFolderHint: Equatable, Sendable {
    /// No probable game, only setup programs or `.msi` packages: the game has
    /// to be installed into an environment, not copied.
    case installerOnly
    /// `steam_api64.dll` or `steam_api.dll`: the game may refuse to run
    /// without the Steam client, which a game added from a folder never
    /// starts. Only the name is checked.
    case steamAPI
    /// `openvr_api.dll`: the game talks OpenVR and needs OpenVR support
    /// (OpenComposite), which the user sets up after adding it.
    case openVR

    /// The hint in the app's current language.
    public var message: String {
        switch self {
        case .installerOnly: return L10n.string(.folderImportInstallerHint)
        case .steamAPI: return L10n.string(.folderImportSteamHint)
        case .openVR: return L10n.string(.folderImportOpenVRHint)
        }
    }
}

/// Why a folder cannot be added as it is. Shown before anything is created
/// or copied.
public enum GameFolderRefusal: Equatable, Sendable {
    /// Symbolic links, special files and other entries the copy refuses: the
    /// first few paths, and how many there are in all.
    case unsupportedEntries(examples: [String], count: Int)
    /// Names that differ only in case, which Windows cannot hold side by side.
    case caseConflicts(examples: [String], count: Int)
    /// Not a single `.exe` file outside hidden folders.
    case noExecutable
    /// The scan stopped at `limit` entries: most likely a folder far above
    /// the game, such as a whole disk.
    case tooManyEntries(limit: Int)
    /// The folder is inside the app's data folder or contains it, and so
    /// would include environments, the new one among them.
    case insideDataFolder

    /// The refusal behind an error that `BottleManager.inventoryGameFolder`
    /// threw, or nil when the error is not about the folder's contents or
    /// place; the sheet then shows it as a failure with its reason.
    public init?(error: Error) {
        switch error as? GameFolderCopyError {
        case .unsupportedEntries(let examples, let count)?:
            self = .unsupportedEntries(examples: examples.map(\.path), count: count)
        case .caseConflicts(let examples, let count)?:
            self = .caseConflicts(examples: examples, count: count)
        case .tooManyEntries(let limit)?:
            self = .tooManyEntries(limit: limit)
        case .sourceOverlapsDataFolder?:
            self = .insideDataFolder
        default:
            return nil
        }
    }

    /// The refusal in the app's current language.
    public var message: String {
        switch self {
        case .unsupportedEntries(let examples, let count):
            return L10n.string(.folderImportUnsupportedEntries, Int64(count),
                               examples.joined(separator: ", "))
        case .caseConflicts(let examples, _):
            return L10n.string(.folderImportCaseConflicts, examples.joined(separator: ", "))
        case .noExecutable:
            return L10n.string(.folderImportNoExecutable)
        case .tooManyEntries(let limit):
            return L10n.string(.folderImportTooManyEntries,
                               limit.formatted(.number.locale(L10n.language.locale)))
        case .insideDataFolder:
            return L10n.string(.folderImportInsideData)
        }
    }
}

/// What is wrong with a name typed for the game's new environment.
public enum GameFolderEnvironmentNameProblem: Equatable, Sendable {
    /// Not a name `BottleName.validate` accepts.
    case invalid
    /// An environment folder or a reserved name already has it, ignoring case.
    case taken

    /// The problem in the app's current language.
    public func message(for name: String) -> String {
        switch self {
        case .invalid: return L10n.string(.folderImportEnvironmentInvalid)
        case .taken: return L10n.string(.folderImportEnvironmentTaken, name)
        }
    }
}

// MARK: - Space

/// Whether the disk that receives the copy has room for it, with the numbers
/// the sheet shows. The rule is the copy's own (`GameFolderSpace`), and
/// `BottleManager.copyGameFolder` checks it again before it writes.
public struct GameFolderSpaceVerdict: Equatable, Sendable {
    /// The files are cloned on one APFS volume and take almost no space.
    public let clones: Bool
    /// The size of the game's files.
    public let gameBytes: Int64
    /// What stays free on the disk in any case.
    public let reserveBytes: Int64
    /// Free space the copy needs before it starts: the reserve, plus the
    /// game's size unless the files are cloned.
    public let requiredBytes: Int64
    /// Free space on the disk as the copy counts it (purgeable space is not
    /// included); nil when it could not be read.
    public let availableBytes: Int64?

    public init(clones: Bool, gameBytes: Int64, reserveBytes: Int64, availableBytes: Int64?) {
        self.clones = clones
        self.gameBytes = max(0, gameBytes)
        self.reserveBytes = max(0, reserveBytes)
        self.availableBytes = availableBytes
        requiredBytes = GameFolderSpace.requiredFreeBytes(
            totalBytes: self.gameBytes, clones: clones, reserveBytes: self.reserveBytes)
    }

    /// Unknown free space counts as too little, as it does for the copy.
    public var isEnough: Bool { availableBytes.map { $0 >= requiredBytes } ?? false }

    /// The sheet's space line in the app's current language. The reserve is
    /// named in whole binary gigabytes, like the video recorder's limit.
    public var message: String {
        guard let availableBytes else { return L10n.string(.folderImportSpaceUnknown) }
        guard isEnough else {
            return L10n.string(.folderImportSpaceShort, Self.text(availableBytes),
                               Self.text(requiredBytes), reserveBytes >> 30)
        }
        if clones { return L10n.string(.folderImportSpaceClone) }
        return L10n.string(.folderImportSpaceCopy, Self.text(gameBytes), Self.text(availableBytes))
    }

    /// A byte count as the app shows sizes elsewhere.
    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.language.locale))
    }
}

// MARK: - Scan

/// A game folder as the Add Game from Folder sheet presents it. Everything
/// is worked out from the read-only scan alone; nothing here touches the
/// disk except `environmentFolderNames(in:)`.
public struct GameFolderScan: Equatable, Sendable {
    /// The scan the copy needs later.
    public let inventory: GameFolderInventory
    /// Probable games first, the best guess on top; then installers, then
    /// helpers. Hidden files and folders are left out.
    public let executables: [GameFolderExecutable]
    public let hints: [GameFolderHint]
    /// Why the folder cannot be added, or nil when it can.
    public let refusal: GameFolderRefusal?
    /// The folder's name, offered as the game's title; empty when the name
    /// is blank.
    public let suggestedTitle: String
    /// The name of the copy in `C:\Games`: the folder's own name whenever
    /// Windows can hold it.
    public let destinationFolderName: String

    public init(inventory: GameFolderInventory) {
        let folderName = inventory.source.lastPathComponent
        let executables = Self.executables(in: inventory)
        self.inventory = inventory
        self.executables = executables
        hints = Self.hints(in: inventory, executables: executables)
        refusal = Self.refusal(for: inventory, executables: executables)
        suggestedTitle = Self.suggestedTitle(forFolderNamed: folderName)
        destinationFolderName = Self.destinationFolderName(forFolderNamed: folderName)
    }

    /// Offered as the game, best guess first.
    public var gameExecutables: [GameFolderExecutable] {
        executables.filter { $0.kind == .game }
    }

    /// Listed under "Other .exe files".
    public var otherExecutables: [GameFolderExecutable] {
        executables.filter { $0.kind != .game }
    }

    /// Preselected in the sheet. Nil when no file looks like the game, so
    /// the user picks one from the other files on purpose.
    public var suggestedExecutable: GameFolderExecutable? { gameExecutables.first }
}

extension GameFolderScan {
    // MARK: Executables

    /// Every `.exe` outside hidden folders, ordered for the sheet: probable
    /// games first, then installers, then helpers. Within each group a file
    /// named like the folder comes first, then an Unreal `*-Win64-Shipping.exe`,
    /// then files nearer the top, then by name. The session lasts as long as
    /// the started process, so the game itself should win over a launcher.
    public static func executables(in inventory: GameFolderInventory) -> [GameFolderExecutable] {
        let folder = comparableName(inventory.source.lastPathComponent)
        return visibleFiles(of: inventory)
            .filter { fileExtension(of: $0.path) == "exe" }
            .map { file in
                GameFolderExecutable(path: file.path, size: file.size,
                                     kind: kind(ofExecutableAt: file.path))
            }
            .sorted { ordered($0, before: $1, folder: folder) }
    }

    /// The kind of the `.exe` at `path` (relative, "/"-separated), judged by
    /// its name and the folders above it, ignoring case.
    public static func kind(ofExecutableAt path: String) -> GameFolderExecutable.Kind {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let file = components.last else { return .helper }
        if components.dropLast().contains(where: { helperFolders.contains($0) }) { return .helper }
        let stem = (file as NSString).deletingPathExtension
        if helperNames.contains(stem) || helperPrefixes.contains(where: { stem.hasPrefix($0) }) {
            return .helper
        }
        if installerWords.contains(where: { stem.contains($0) }) { return .installer }
        return .game
    }

    // MARK: Hints and refusals

    /// What the sheet tells the user about `inventory`, in the order it
    /// shows the hints.
    public static func hints(in inventory: GameFolderInventory) -> [GameFolderHint] {
        hints(in: inventory, executables: executables(in: inventory))
    }

    /// Why `inventory` cannot be added, the most telling reason first: an
    /// entry the copy refuses also hides files from the scan, so a folder
    /// whose only `.exe` is a link reports the link, not a missing `.exe`.
    public static func refusal(for inventory: GameFolderInventory) -> GameFolderRefusal? {
        refusal(for: inventory, executables: executables(in: inventory))
    }

    /// The installer hint first, since it means the folder is not a game
    /// yet. An `.msi` counts as an installer unless it is a runtime package,
    /// judged like an `.exe`, as in `_CommonRedist`.
    private static func hints(in inventory: GameFolderInventory,
                              executables: [GameFolderExecutable]) -> [GameFolderHint] {
        let files = visibleFiles(of: inventory)
        let names = Set(files.map { fileName(of: $0.path).lowercased() })
        let hasPackage = files.contains {
            fileExtension(of: $0.path) == "msi" && kind(ofExecutableAt: $0.path) != .helper
        }
        var hints = [GameFolderHint]()
        if !executables.contains(where: { $0.kind == .game }),
           hasPackage || executables.contains(where: { $0.kind == .installer }) {
            hints.append(.installerOnly)
        }
        if !names.isDisjoint(with: ["steam_api64.dll", "steam_api.dll"]) { hints.append(.steamAPI) }
        if names.contains("openvr_api.dll") { hints.append(.openVR) }
        return hints
    }

    private static func refusal(for inventory: GameFolderInventory,
                                executables: [GameFolderExecutable]) -> GameFolderRefusal? {
        if inventory.rejectedCount > 0 {
            return .unsupportedEntries(examples: inventory.rejected.map(\.path),
                                       count: inventory.rejectedCount)
        }
        if inventory.caseConflictCount > 0 {
            return .caseConflicts(examples: inventory.caseConflicts,
                                  count: inventory.caseConflictCount)
        }
        return executables.isEmpty ? .noExecutable : nil
    }

    // MARK: Names

    /// The folder's name without surrounding spaces. Empty for a name of
    /// spaces only or a disk's root, so the sheet asks for a title instead
    /// of inventing one.
    public static func suggestedTitle(forFolderNamed name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "/" ? "" : trimmed
    }

    /// The folder's own name when Windows can hold it (`GameFolderName`),
    /// otherwise its profile slug. The slug is cut at 56 characters, which
    /// can leave a dot at the end, and may be a device name such as "con" or
    /// "nul.txt" that Windows reserves; "game-" in front of it is valid.
    public static func destinationFolderName(forFolderNamed name: String) -> String {
        if GameFolderName.isValid(name) { return name }
        var slug = ProfileNaming.slug(name)
        while let last = slug.last, "-._".contains(last) { slug.removeLast() }
        if slug.isEmpty { slug = "game" }
        if GameFolderName.isValid(slug) { return slug }
        let prefixed = "game-" + slug
        return GameFolderName.isValid(prefixed) ? prefixed : "game"
    }

    /// The environments of the games verified in a headset. They count
    /// as taken even before they exist, so the Steam wizard can still create
    /// them under the names it expects.
    public static let reservedEnvironmentNames: [String] =
        SteamCatalogGame.verified.compactMap(\.environmentName)

    /// The name of every entry in the data folder's `Bottles`, whether or not
    /// it holds a readable `bottle.json`: creating an environment fails on
    /// any existing entry. Empty when the folder does not exist or cannot be
    /// read; `BottleManager.createBottle` still refuses an existing name.
    public static func environmentFolderNames(in bottles: URL,
                                              fileManager: FileManager = .default) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: bottles.path)) ?? []
    }

    /// A new environment's name for a game titled `title`: its profile slug
    /// ("Beat Saber" → "beat-saber"), with "-2", "-3", … added until neither
    /// `taken` nor `reservedEnvironmentNames` has it, ignoring case. The data
    /// volume ignores case, while `loadBottle` compares names exactly, so
    /// "beat-saber" next to the Steam wizard's "Beat-Saber" would break both.
    /// `taken` holds `environmentFolderNames(in:)` and the names the app
    /// keeps for later, such as the Steam wizard's remembered environment.
    public static func environmentName(for title: String, taken: [String]) -> String {
        let used = Set((taken + reservedEnvironmentNames).map(nameKey))
        let base = ProfileNaming.slug(title)
        var name = base
        var suffix = 2
        while used.contains(nameKey(name)) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    /// Nil when `name` can be the game's new environment.
    public static func environmentNameProblem(
        _ name: String, taken: [String]
    ) -> GameFolderEnvironmentNameProblem? {
        guard (try? BottleName.validate(name)) != nil else { return .invalid }
        let key = nameKey(name)
        return (taken + reservedEnvironmentNames).contains { nameKey($0) == key } ? .taken : nil
    }

    // MARK: Space

    /// The space verdict for copying `inventory` to `volume`, the disk of
    /// the data folder. Files on the same APFS volume are cloned and need
    /// only the reserve; from any other disk they need their size plus the
    /// reserve. Without a volume nothing is known, so nothing is enough.
    public static func space(
        for inventory: GameFolderInventory, on volume: GameFolderVolume?,
        reserveBytes: Int64 = GameFolderSpace.defaultReserveBytes
    ) -> GameFolderSpaceVerdict {
        GameFolderSpaceVerdict(
            clones: volume?.clones(inventory) ?? false, gameBytes: inventory.totalBytes,
            reserveBytes: reserveBytes, availableBytes: volume?.freeBytes)
    }

    // MARK: Profile

    /// The launch profile of a game copied into `C:\Games\<folderName>` of
    /// `bottle`. It starts `executable` (relative to the game folder,
    /// "/"-separated) directly, without Steam, in the executable's own
    /// folder on the Mac, like Add Game. The game folder is the root of the
    /// copy, where Prepare VR looks for the game's OpenVR DLLs. A blank title
    /// is left out, so the Library names the game after its executable.
    public static func profile(
        named name: String, title: String, executable: String, arguments: [String] = [],
        folderName: String, in bottle: ManagedBottle
    ) throws -> LaunchProfile {
        let folder = try GameFolderName.validate(folderName)
        let components = executable.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy(isWindowsPathComponent) else {
            throw BottleToolError("'\(executable)' cannot be started from C:\\Games\\\(folder)")
        }
        let gameRoot = #"C:\Games\"# + folder
        var directory = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return LaunchProfile(
            name: name, bottleName: bottle.name, source: .direct,
            executable: ([gameRoot] + components).joined(separator: #"\"#),
            arguments: arguments, workingDirectory: directory.path,
            gameRoot: gameRoot, title: title.isEmpty ? nil : title)
    }

    // MARK: Helpers

    /// Crash reporters, runtime installers and uninstallers, by file name
    /// without extension.
    private static let helperNames: Set<String> = ["crashpad_handler", "dxsetup"]
    private static let helperPrefixes = [
        "unitycrashhandler", "crashreportclient", "vc_redist", "vcredist", "dotnetfx",
        "ue4prereqsetup", "ueprereqsetup", "unins",
    ]
    /// Folders that only hold runtime installers: Steam's `_CommonRedist`,
    /// Unreal's `Engine/Extras/Redist`, and the installer data of some games.
    private static let helperFolders: Set<String> = ["_commonredist", "redist", "__installer"]
    private static let installerWords = ["setup", "install"]

    /// Characters Windows does not allow in a name; one of them would make
    /// the executable's `C:\` path mean something else.
    private static let windowsForbidden = Set(#"\/:*?"<>|"#.unicodeScalars)

    private static func isWindowsPathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.unicodeScalars.contains {
                windowsForbidden.contains($0) || $0.properties.generalCategory == .control
            }
    }

    private static func ordered(_ first: GameFolderExecutable, before second: GameFolderExecutable,
                                folder: String) -> Bool {
        if first.kind != second.kind { return first.kind < second.kind }
        let firstNamed = isNamed(first, like: folder)
        if firstNamed != isNamed(second, like: folder) { return firstNamed }
        let firstShipping = isShipping(first)
        if firstShipping != isShipping(second) { return firstShipping }
        if first.depth != second.depth { return first.depth < second.depth }
        let byName = first.fileName.localizedStandardCompare(second.fileName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return first.path < second.path
    }

    /// "Beat Saber.exe" in "Beat Saber", also "SomeGame.exe" in "Some Game":
    /// case, accents, spaces and punctuation do not count.
    private static func isNamed(_ executable: GameFolderExecutable, like folder: String) -> Bool {
        !folder.isEmpty
            && comparableName((executable.fileName as NSString).deletingPathExtension) == folder
    }

    /// Unreal's packaged game binary, which its small launcher at the top of
    /// the folder starts.
    private static func isShipping(_ executable: GameFolderExecutable) -> Bool {
        executable.fileName.lowercased().hasSuffix("-win64-shipping.exe")
    }

    private static func comparableName(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(
            folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// How the data volume compares names: case and Unicode normalization do
    /// not count.
    private static func nameKey(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Files outside hidden folders, without hidden files. The scan already
    /// leaves out `.DS_Store` and AppleDouble `._*` files but keeps other dot
    /// files, which are never the game.
    private static func visibleFiles(of inventory: GameFolderInventory) -> [GameFolderInventory.File] {
        inventory.files.filter { file in
            !file.path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    private static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func fileExtension(of path: String) -> String {
        (fileName(of: path) as NSString).pathExtension.lowercased()
    }
}
