import Foundation

/// The game a Steam profile starts, found on disk instead of through the
/// Steam client.
///
/// `steam.exe -applaunch APP_ID` only hands the AppID to the Steam client
/// that is already running: Wine returns at once, and Steam starts the game
/// with its own environment, without this session's `BASALT_CONTROL` and
/// `DXMT_BASALT_IOSURFACE`. The OpenXR runtime then cannot reach the
/// streamer, the game is told not to render and the headset stays black,
/// while the manager takes the returned launcher for the game's exit and
/// shuts the environment down. So TrailBridge starts the game's own
/// executable itself, the way Steam would: the verified executable for the
/// few games in `verifiedExecutables`, else the launch option Steam keeps
/// for the app in `appcache/appinfo.vdf`, else the game's folder (a Unity
/// player, an Unreal game, or its only `.exe`).
public struct SteamDirectLaunch: Equatable, Sendable {
    public enum Origin: String, Equatable, Sendable {
        /// `SteamDirectLaunch.verifiedExecutables`.
        case verified
        /// A launch option from Steam's `appinfo.vdf`.
        case steamLaunchOptions
        /// The game's folder.
        case gameFolder
    }

    /// The game's `.exe` on this Mac.
    public var executable: URL
    /// The arguments of Steam's launch option, if any; a profile's own
    /// arguments come after them.
    public var arguments: [String]
    public var workingDirectory: URL
    public var origin: Origin

    public init(executable: URL, arguments: [String] = [], workingDirectory: URL,
                origin: Origin) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.origin = origin
    }
}

extension SteamDirectLaunch {
    /// Executables verified in a headset, relative to the game's install
    /// folder with "/" between components. They win over Steam's own launch
    /// options: Blood Trail, for one, starts its Unreal game binary rather
    /// than the launcher Steam names.
    public static let verifiedExecutables: [String: String] = [
        "620980": "Beat Saber.exe",
        "2669380": "BrutalistickVR.exe",
        "1032430": "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe",
    ]

    /// Install folders of verified games, for environments whose Steam
    /// library has lost the game's manifest.
    static let verifiedInstallFolders: [String: String] = ["620980": "Beat Saber"]

    /// The game `appID` names, inside `prefix`. `gameRoot` is the profile's
    /// game folder, used when Steam's manifest does not name one.
    public static func resolve(appID: String, prefix: URL, gameRoot: URL? = nil,
                               fileManager: FileManager = .default) throws -> SteamDirectLaunch {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
              let numericID = UInt32(appID) else {
            throw BottleToolError("Steam AppID must contain ASCII digits only.")
        }
        let roots = steamRoots(in: prefix, fileManager: fileManager)
        guard let install = installDirectory(
            appID: appID, prefix: prefix, steamRoots: roots, gameRoot: gameRoot,
            fileManager: fileManager) else {
            throw BottleToolError(
                "Steam app \(appID) is not installed in this environment. Open Steam, install the game or let its update finish, then try again.")
        }
        if let relative = verifiedExecutables[appID] {
            guard let executable = existingItem(
                relative, in: install, directory: false, fileManager: fileManager) else {
                throw BottleToolError(
                    "Steam reports app \(appID), but \(relative) is missing from “\(install.lastPathComponent)”. Open Steam, finish any pending update or verify the game's files, then try again.")
            }
            return SteamDirectLaunch(
                executable: executable, workingDirectory: executable.deletingLastPathComponent(),
                origin: .verified)
        }
        if let launch = fromLaunchOptions(
            appID: numericID, install: install, steamRoots: roots, fileManager: fileManager) {
            return launch
        }
        if let found = gameExecutable(in: install, fileManager: fileManager) {
            let executable = unrealGameBinary(launching: found, in: install, fileManager: fileManager)
                ?? found
            return SteamDirectLaunch(
                executable: executable, workingDirectory: executable.deletingLastPathComponent(),
                origin: .gameFolder)
        }
        throw BottleToolError(
            "TrailBridge could not tell which .exe in “\(install.lastPathComponent)” is the game. In the Library, open the game's ⋯ menu → Edit Launch Profile… and choose the game's own .exe instead of steam.exe.")
    }

    // MARK: - Steam's records

    static func steamRoots(in prefix: URL, fileManager: FileManager) -> [URL] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        return ["Program Files (x86)/Steam", "Program Files/Steam"]
            .map { driveC.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0, fileManager: fileManager) }
    }

    /// `steamapps/common/<installdir>` from the app's manifest in any of the
    /// bottle's Steam libraries, else the profile's game folder, else the
    /// usual folder of a verified game.
    static func installDirectory(appID: String, prefix: URL, steamRoots: [URL], gameRoot: URL?,
                                 fileManager: FileManager) -> URL? {
        for library in libraries(prefix: prefix, steamRoots: steamRoots, fileManager: fileManager) {
            let manifest = library.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                  let folder = vdfValues("installdir", in: text).first,
                  isPlainName(folder) else { continue }
            let install = library.appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
            if isDirectory(install, fileManager: fileManager) { return install }
        }
        if let gameRoot, isDirectory(gameRoot, fileManager: fileManager) { return gameRoot }
        if let folder = verifiedInstallFolders[appID] {
            for root in steamRoots {
                let install = root.appendingPathComponent("steamapps", isDirectory: true)
                    .appendingPathComponent("common", isDirectory: true)
                    .appendingPathComponent(folder, isDirectory: true)
                if isDirectory(install, fileManager: fileManager) { return install }
            }
        }
        return nil
    }

    /// Each Steam root's `steamapps` folder, then the libraries its
    /// `libraryfolders.vdf` lists.
    static func libraries(prefix: URL, steamRoots: [URL], fileManager: FileManager) -> [URL] {
        var folders = [URL]()
        for root in steamRoots {
            let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
            folders.append(steamApps)
            let list = steamApps.appendingPathComponent("libraryfolders.vdf")
            guard let text = try? String(contentsOf: list, encoding: .utf8) else { continue }
            for path in vdfValues("path", in: text) {
                if let library = hostURL(forWindowsPath: path, prefix: prefix, fileManager: fileManager) {
                    folders.append(library.appendingPathComponent("steamapps", isDirectory: true))
                }
            }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The best launch option for TrailBridge whose executable exists:
    /// SteamVR's own option first, then the default one, the numbered ones,
    /// and the option for other VR systems last. Options for other systems,
    /// beta branches, servers and editors are never used.
    static func fromLaunchOptions(appID: UInt32, install: URL, steamRoots: [URL],
                                  fileManager: FileManager) -> SteamDirectLaunch? {
        for root in steamRoots {
            let cache = root.appendingPathComponent("appcache", isDirectory: true)
                .appendingPathComponent("appinfo.vdf")
            guard let options = SteamAppInfo.launchOptions(appID: appID, inFileAt: cache) else {
                continue
            }
            let ranked = options.enumerated()
                .compactMap { item -> (rank: Int, index: Int, option: SteamLaunchOption)? in
                    guard let rank = launchRank(item.element) else { return nil }
                    return (rank: rank, index: item.offset, option: item.element)
                }
                .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            for candidate in ranked {
                let option = candidate.option
                guard option.executable.lowercased().hasSuffix(".exe"),
                      let found = existingItem(
                          option.executable, in: install, directory: false, fileManager: fileManager)
                else { continue }
                if let game = unrealGameBinary(launching: found, in: install, fileManager: fileManager) {
                    return SteamDirectLaunch(
                        executable: game, arguments: commandLineArguments(option.arguments),
                        workingDirectory: game.deletingLastPathComponent(),
                        origin: .steamLaunchOptions)
                }
                let folder = option.workingDirectory.isEmpty ? nil : existingItem(
                    option.workingDirectory, in: install, directory: true, fileManager: fileManager)
                return SteamDirectLaunch(
                    executable: found, arguments: commandLineArguments(option.arguments),
                    workingDirectory: folder ?? found.deletingLastPathComponent(),
                    origin: .steamLaunchOptions)
            }
        }
        return nil
    }

    /// Lower is better; nil means TrailBridge never starts the option.
    static func launchRank(_ option: SteamLaunchOption) -> Int? {
        let systems = option.operatingSystems.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard systems.isEmpty || systems.contains("windows"),
              option.betaKey.isEmpty,
              option.realm.lowercased() != "steamchina" else { return nil }
        let rank: Int
        switch option.type.lowercased() {
        case "vr": rank = 0
        case "", "default": rank = 1
        case "server", "editor", "manual", "openvroverlay", "osvr": return nil
        case "othervr": rank = 3
        default: rank = 2  // option1…option3 and none
        }
        return option.architecture == "32" ? rank + 10 : rank
    }

    /// Splits one command line at spaces and tabs outside double quotes, the
    /// way the game's C runtime will see it.
    static func commandLineArguments(_ line: String) -> [String] {
        var arguments = [String]()
        var current = ""
        var quoted = false
        var started = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted, character == " " || character == "\t" {
                if started {
                    arguments.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        if started { arguments.append(current) }
        return arguments
    }

    // MARK: - The game's folder

    /// A Unity player (`Game.exe` beside `Game_Data`), else the `.exe` named
    /// like the folder, else an Unreal `*-Win64-Shipping.exe`, else the only
    /// probable game. Nil when several files remain equally likely: starting
    /// the wrong one would only look like another broken launch.
    static func gameExecutable(in install: URL, fileManager: FileManager) -> URL? {
        let scan = scanExecutables(in: install, fileManager: fileManager)
        let games = scan.executables.filter { isProbableGame($0.relative) }
        let unity = games.filter { candidate in
            let stem = (candidate.name as NSString).deletingPathExtension
            let data = candidate.folder.isEmpty ? stem + "_Data" : candidate.folder + "/" + stem + "_Data"
            return scan.folders.contains(data.lowercased())
        }
        if unity.count == 1 { return unity[0].url }
        let pool = unity.isEmpty ? games : unity
        let folderName = comparableName(install.lastPathComponent)
        let named = pool.filter {
            !folderName.isEmpty
                && comparableName(($0.name as NSString).deletingPathExtension) == folderName
        }
        if named.count == 1 { return named[0].url }
        if unity.isEmpty {
            let shipping = games.filter { $0.name.lowercased().hasSuffix("-win64-shipping.exe") }
            if shipping.count == 1 { return shipping[0].url }
        }
        return pool.count == 1 ? pool[0].url : nil
    }

    /// Unreal's packaged game, `<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe`,
    /// when `executable` is the small launcher at the top of the install
    /// folder that starts it. The session lasts as long as the started
    /// process, so the game itself wins over its launcher.
    static func unrealGameBinary(launching executable: URL, in install: URL,
                                 fileManager: FileManager) -> URL? {
        guard executable.deletingLastPathComponent().standardizedFileURL.path
                == install.standardizedFileURL.path,
              let names = try? fileManager.contentsOfDirectory(atPath: install.path) else { return nil }
        let binaries = names
            .filter { !$0.hasPrefix(".") && $0.lowercased() != "engine" }
            .compactMap {
                existingItem("\($0)/Binaries/Win64/\($0)-Win64-Shipping.exe", in: install,
                             directory: false, fileManager: fileManager)
            }
        return binaries.count == 1 ? binaries[0] : nil
    }

    struct ExecutableCandidate {
        let url: URL
        /// Relative to the install folder, "/"-separated.
        let relative: String
        /// The folder part of `relative`; empty at the top.
        let folder: String
        let name: String
    }

    struct ExecutableScan {
        var executables = [ExecutableCandidate]()
        /// Every folder seen, relative and lowercased.
        var folders = Set<String>()
    }

    /// `.exe` files at most `maximumDepth` levels down, outside hidden
    /// folders. A game folder with more entries than `maximumEntries` is
    /// scanned only that far.
    static func scanExecutables(in install: URL, fileManager: FileManager, maximumDepth: Int = 4,
                                maximumEntries: Int = 20_000) -> ExecutableScan {
        var scan = ExecutableScan()
        guard let enumerator = fileManager.enumerator(atPath: install.path) else { return scan }
        var visited = 0
        while let relative = enumerator.nextObject() as? String {
            visited += 1
            if visited > maximumEntries { break }
            let name = (relative as NSString).lastPathComponent
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if name.hasPrefix(".") {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if type == .typeDirectory {
                scan.folders.insert(relative.lowercased())
                if enumerator.level >= maximumDepth { enumerator.skipDescendants() }
                continue
            }
            guard type == .typeRegular, (name as NSString).pathExtension.lowercased() == "exe" else {
                continue
            }
            scan.executables.append(ExecutableCandidate(
                url: install.appendingPathComponent(relative, isDirectory: false),
                relative: relative, folder: (relative as NSString).deletingLastPathComponent,
                name: name))
        }
        return scan
    }

    /// Not a crash reporter, runtime installer, uninstaller or setup program,
    /// judged as Add Game from Folder judges them.
    static func isProbableGame(_ relative: String) -> Bool {
        let components = relative.split(separator: "/").map { $0.lowercased() }
        guard let file = components.last else { return false }
        if components.dropLast().contains(where: { helperFolders.contains($0) }) { return false }
        let stem = (file as NSString).deletingPathExtension
        if helperNames.contains(stem) || helperPrefixes.contains(where: { stem.hasPrefix($0) }) {
            return false
        }
        return !installerWords.contains { stem.contains($0) }
    }

    static let helperNames: Set<String> = ["crashpad_handler", "dxsetup"]
    static let helperPrefixes = [
        "unitycrashhandler", "crashreportclient", "crashreporter", "crashhandler",
        "steamerrorreporter", "vc_redist", "vcredist", "dotnetfx", "ue4prereqsetup",
        "ueprereqsetup", "unins",
    ]
    static let helperFolders: Set<String> = ["_commonredist", "redist", "__installer"]
    static let installerWords = ["setup", "install"]

    /// "Beat Saber.exe" in "Beat Saber", also "SomeGame.exe" in "Some Game":
    /// case, accents, spaces and punctuation do not count.
    static func comparableName(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(
            folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    // MARK: - Paths

    /// `relative` (Steam's `\` or `/` separators) inside `base`, matching
    /// each name regardless of case as Windows does and spelled as on disk;
    /// nil when it climbs out with `..`, names a drive, or is not there as a
    /// file (or folder).
    static func existingItem(_ relative: String, in base: URL, directory: Bool,
                             fileManager: FileManager) -> URL? {
        let components = relative.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty, !components.contains(".."),
              !components.contains(where: { $0.contains(":") }) else { return nil }
        var url = base
        for (index, component) in components.enumerated() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return nil }
            let match = names.contains(component)
                ? Optional(component)
                : names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            guard let name = match else { return nil }
            url = url.appendingPathComponent(name, isDirectory: directory || index < components.count - 1)
        }
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue == directory else { return nil }
        return url
    }

    static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isFolder: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }

    /// `C:\…` inside the prefix's `drive_c`; another drive through the
    /// prefix's `dosdevices` link.
    static func hostURL(forWindowsPath path: String, prefix: URL, fileManager: FileManager) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 3, let drive = normalized.first?.lowercased(),
              normalized.dropFirst().hasPrefix(":/") else { return nil }
        let rest = String(normalized.dropFirst(3))
        if drive == "c" {
            return prefix.appendingPathComponent("drive_c", isDirectory: true)
                .appendingPathComponent(rest, isDirectory: true)
        }
        let link = prefix.appendingPathComponent("dosdevices/\(drive):")
        guard fileManager.fileExists(atPath: link.path) else { return nil }
        return link.resolvingSymlinksInPath().appendingPathComponent(rest, isDirectory: true)
    }

    /// The values of `key` in Valve's text KeyValues (`.acf`, `.vdf`), with
    /// `\\` and `\"` unescaped.
    static func vdfValues(_ key: String, in text: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: #"\""# + escaped + #"\"\s*\"((?:\\.|[^\"])*)\""#,
            options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
                    .replacingOccurrences(of: #"\""#, with: #"""#)
            }
    }
}
