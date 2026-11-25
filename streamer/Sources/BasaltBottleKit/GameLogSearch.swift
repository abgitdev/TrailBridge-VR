// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// A log that a Windows game wrote itself.
public struct GameLogFile: Equatable, Sendable {
    public enum Engine: String, Equatable, Sendable {
        case unity, unreal
    }

    public let engine: Engine
    /// On this Mac, for reading the log only: the path names the disk, the
    /// Mac's user and the Wine user.
    public let url: URL
    public let modified: Date
    /// The folder the log must stay inside once links are resolved: the
    /// prefix, or the game's own folder.
    public let root: URL
    /// The same root after resolving links at discovery.
    public let resolvedRoot: String
    let device: dev_t
    let inode: ino_t
    let earliest: Date

    /// Opens the log for reading, checked again as when it was found, since
    /// it may have been replaced since.
    public func open() -> (handle: FileHandle, size: Int64)? {
        guard let opened = Self.openRegularFile(url, inside: resolvedRoot) else { return nil }
        let handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
        guard opened.info.st_dev == device, opened.info.st_ino == inode,
              Self.modificationDate(opened.info) >= earliest else { return nil }
        return (handle, Int64(opened.info.st_size))
    }

    static func modificationDate(_ info: stat) -> Date {
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }

    /// Opens `url` without following a link at its end or waiting for a
    /// writer on a pipe, and keeps it open only when it is a regular file
    /// whose real path lies inside `root`, itself a real path. A link
    /// further up, or a file swapped for a link, could otherwise hand any
    /// file of the Mac to a report.
    static func openRegularFile(_ url: URL, inside root: String) -> (fd: Int32, info: stat)? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let path = realPath(of: fd), path.hasPrefix(root == "/" ? root : root + "/") else {
            close(fd)
            return nil
        }
        return (fd, info)
    }

    /// Where an open file or folder is, every link resolved.
    static func realPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    /// The real path of a folder, found the same way as that of a file in
    /// it, so the two compare alike.
    static func realPath(ofFolder url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return realPath(of: fd)
    }
}

/// Where a game writes its own log. The session log has what Wine, the
/// runtime and the streamer print; why a game that runs and submits frames
/// still shows a black headset (a video it cannot decode, a file it cannot
/// load) is often only in the game's own log inside the prefix. Unity
/// players and Unreal games are known; other engines keep their logs
/// wherever they like.
public struct GameLogSearch: Equatable, Sendable {
    /// A log time up to this much earlier than the game's start still
    /// counts: HFS+ and many network disks keep file times to the second.
    public static let timeSlack: TimeInterval = 2
    /// A larger `app.info` is not one.
    static let maximumAppInfoBytes = 4096

    /// The Wine prefix the game runs in.
    public let prefix: URL
    /// The game's `.exe` on this Mac.
    public let executable: URL

    public init(prefix: URL, executable: URL) {
        self.prefix = prefix.standardizedFileURL
        self.executable = URL(fileURLWithPath: executable.path, isDirectory: false).standardizedFileURL
    }

    /// The logs written since the game started, oldest first. Logs of
    /// earlier runs are older: a Unity player moves the last run's
    /// `Player.log` to `Player-prev.log`, an Unreal game renames its log
    /// with a `-backup-` time, and a moved file keeps its time.
    ///
    /// - A Unity player (`Game.exe` beside `Game_Data`) names its company
    ///   and product in `Game_Data/app.info` and writes `Player.log` in
    ///   `AppData/LocalLow/<company>/<product>` of the Windows user; Unity
    ///   2017.2 to 2018 wrote `output_log.txt` there, older versions
    ///   `output_log.txt` in `Game_Data`.
    /// - An Unreal game (`<Project>/Binaries/Win64/*.exe`, or a launcher
    ///   beside `<Project>`) writes `<Project>/Saved/Logs/*.log` in the
    ///   user's `AppData/Local`, or else in its own folder.
    public func files(since start: Date, fileManager: FileManager = .default) -> [GameLogFile] {
        readLogs(since: start, limit: .max, fileManager: fileManager) { $0 }
    }

    /// The newest readable logs, returned oldest first. An Unreal game's
    /// install folder is used only if none of its AppData logs can be read.
    public func readLogs<Log>(since start: Date, limit: Int, fileManager: FileManager = .default,
                              reading read: (GameLogFile) -> Log?) -> [Log] {
        guard limit > 0 else { return [] }
        let earliest = start.addingTimeInterval(-Self.timeSlack)
        var roots = [URL: String?]()
        func logs(at locations: [Location]) -> [GameLogFile] {
            Self.logs(at: locations, since: earliest, fileManager: fileManager, roots: &roots)
        }
        let users = Self.userFolders(in: prefix, fileManager: fileManager)
        let unity = logs(at: unityLocations(users: users, fileManager: fileManager))
        let projects = unrealProjects(fileManager: fileManager)
        let inAppData = projects.flatMap { project in
            users.compactMap { user in
                SteamDirectLaunch.existingItem(
                    "AppData/Local/\(project.name)/Saved/Logs", in: user, directory: true, fileManager: fileManager)
                .map { Location(engine: .unreal, folder: $0, names: nil, root: prefix) }
            }
        }
        var unreal = Self.sortedLogs(logs(at: inAppData))
        // Keep the successful read that decides whether the fallback is needed.
        var newestAppData: (file: GameLogFile, log: Log)?
        while let file = unreal.popLast() {
            if let log = read(file) {
                newestAppData = (file, log)
                unreal.append(file)
                break
            }
        }
        if newestAppData == nil {
            unreal = logs(at: projects.compactMap { project in
                SteamDirectLaunch.existingItem(
                    "\(project.name)/Saved/Logs", in: project.gameFolder, directory: true, fileManager: fileManager)
                .map { Location(engine: .unreal, folder: $0, names: nil, root: project.gameFolder) }
            })
        }
        var selected = [Log]()
        for file in Self.sortedLogs(unity + unreal).reversed() {
            let log = file == newestAppData?.file ? newestAppData?.log : read(file)
            if let log { selected.append(log) }
            if selected.count == limit { break }
        }
        return Array(selected.reversed())
    }

    private static func sortedLogs(_ files: [GameLogFile]) -> [GameLogFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.url.path).inserted }
            .sorted { ($0.modified, $0.url.path) < ($1.modified, $1.url.path) }
    }

    /// A folder that may hold the game's logs.
    private struct Location {
        let engine: GameLogFile.Engine
        let folder: URL
        /// The logs' names; nil for every `.log` file.
        let names: [String]?
        /// Where the logs must stay once links are resolved.
        let root: URL
    }

    /// The Windows users' folders in `drive_c/users`. `Public` belongs to
    /// no one, and Wine names the user's own folder after the Mac account.
    static func userFolders(in prefix: URL, fileManager: FileManager) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        return folders(in: users, fileManager: fileManager)
            .filter { $0.lastPathComponent.caseInsensitiveCompare("Public") != .orderedSame }
    }

    /// The folders in `folder`, not links to one, by name. They keep the
    /// path they were found under, as the files in them do.
    private static func folders(in folder: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Unity

    /// The logs of a Unity player in the Windows users' `AppData/LocalLow`,
    /// where `app.info` says, and the oldest versions' in its data folder.
    private func unityLocations(users: [URL], fileManager: FileManager) -> [Location] {
        let gameFolder = executable.deletingLastPathComponent()
        let stem = executable.deletingPathExtension().lastPathComponent
        let own = stem.isEmpty ? nil : SteamDirectLaunch.existingItem(
            "\(stem)_Data", in: gameFolder, directory: true, fileManager: fileManager)
        // A launcher's own name has no data folder; the player beside it does.
        let info = own.flatMap {
            SteamDirectLaunch.existingItem("app.info", in: $0, directory: false, fileManager: fileManager)
        } ?? Self.onlyOther(in: gameFolder, besides: own, fileManager: fileManager)
        var locations = Set([own, info?.deletingLastPathComponent()].compactMap { $0?.standardizedFileURL })
            .sorted { $0.path < $1.path }
            .map { Location(engine: .unity, folder: $0, names: ["output_log.txt"], root: gameFolder) }
        if let info, let names = Self.companyAndProduct(in: info, inside: gameFolder) {
            locations += users.compactMap { user in
                SteamDirectLaunch.existingItem(
                    "AppData/LocalLow/\(names.company)/\(names.product)", in: user,
                    directory: true, fileManager: fileManager)
                .map { Location(engine: .unity, folder: $0,
                                names: ["Player.log", "Player-prev.log", "output_log.txt"], root: prefix) }
            }
        }
        return locations
    }

    /// The `app.info` of the only other `*_Data` folder beside the
    /// executable that has one; nil when there are none or several.
    private static func onlyOther(in gameFolder: URL, besides own: URL?,
                                  fileManager: FileManager) -> URL? {
        let others = folders(in: gameFolder, fileManager: fileManager).filter {
            $0.lastPathComponent.lowercased().hasSuffix("_data")
                && $0.standardizedFileURL.path != own?.standardizedFileURL.path
        }
        let infos = others.compactMap {
            SteamDirectLaunch.existingItem("app.info", in: $0, directory: false, fileManager: fileManager)
        }
        return infos.count == 1 ? infos[0] : nil
    }

    /// The first two lines of a Unity player's `app.info`.
    static func companyAndProduct(in info: URL, inside gameFolder: URL) -> (company: String, product: String)? {
        guard let root = GameLogFile.realPath(ofFolder: gameFolder),
              let opened = GameLogFile.openRegularFile(info, inside: root) else { return nil }
        let handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
        guard opened.info.st_size <= maximumAppInfoBytes,
              let data = try? handle.read(upToCount: maximumAppInfoBytes) else { return nil }
        let lines = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"])) }
        guard lines.count >= 2, SteamDirectLaunch.isPlainName(lines[0]),
              SteamDirectLaunch.isPlainName(lines[1]) else { return nil }
        return (lines[0], lines[1])
    }

    // MARK: Unreal

    /// The Unreal project: the folder above the executable's
    /// `Binaries/Win64`, or, for a launcher, the folder beside it that holds
    /// `Binaries/Win64`; of several, the one named like the launcher when
    /// there is one. The engine's own `Engine` folder is no game.
    private func unrealProjects(fileManager: FileManager) -> [(name: String, gameFolder: URL)] {
        let folder = executable.deletingLastPathComponent()
        let binaries = folder.deletingLastPathComponent()
        var projects = [(name: String, gameFolder: URL)]()
        if folder.lastPathComponent.caseInsensitiveCompare("Win64") == .orderedSame,
           binaries.lastPathComponent.caseInsensitiveCompare("Binaries") == .orderedSame {
            let project = binaries.deletingLastPathComponent()
            projects.append((project.lastPathComponent, project.deletingLastPathComponent()))
        } else {
            for entry in Self.folders(in: folder, fileManager: fileManager)
            where SteamDirectLaunch.existingItem(
                "Binaries/Win64", in: entry, directory: true, fileManager: fileManager) != nil {
                projects.append((entry.lastPathComponent, folder))
            }
        }
        projects = projects.filter {
            SteamDirectLaunch.isPlainName($0.name) && $0.name.caseInsensitiveCompare("Engine") != .orderedSame
        }
        let launcher = SteamDirectLaunch.comparableName(executable.deletingPathExtension().lastPathComponent)
        let named = projects.filter { SteamDirectLaunch.comparableName($0.name) == launcher }
        return named.count == 1 ? named : projects
    }

    // MARK: Opening the logs

    /// The logs in `locations` written at or after `earliest`, each opened
    /// and checked as `GameLogFile.openRegularFile` does; the time is the
    /// opened file's.
    private static func logs(at locations: [Location], since earliest: Date,
                             fileManager: FileManager, roots: inout [URL: String?]) -> [GameLogFile] {
        locations.flatMap { location -> [GameLogFile] in
            let resolved = roots[location.root] ?? GameLogFile.realPath(ofFolder: location.root)
            roots[location.root] = .some(resolved)
            guard let root = resolved else { return [] }
            let entries = (try? fileManager.contentsOfDirectory(atPath: location.folder.path)) ?? []
            return entries.sorted().compactMap { name in
                let wanted = location.names.map { logs in
                    logs.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                } ?? (!name.hasPrefix(".") && (name as NSString).pathExtension.caseInsensitiveCompare("log") == .orderedSame)
                let url = location.folder.appendingPathComponent(name, isDirectory: false)
                guard wanted, let opened = GameLogFile.openRegularFile(url, inside: root) else { return nil }
                close(opened.fd)
                let modified = GameLogFile.modificationDate(opened.info)
                guard modified >= earliest else { return nil }
                return GameLogFile(engine: location.engine, url: url, modified: modified, root: location.root,
                                   resolvedRoot: root, device: opened.info.st_dev, inode: opened.info.st_ino,
                                   earliest: earliest)
            }
        }
    }
}
