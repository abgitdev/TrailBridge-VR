import Foundation
import BasaltCore

/// Everything TrailBridge VR leaves on a Mac, found so it can be shown with
/// its size and removed without a trace: people care about free space, and
/// the app must not leave caches, logs or orphaned folders behind.
///
/// Where the app writes:
/// - its data folder: environments with their games, launch profiles,
///   downloads, Android tools (with adb's keys), diagnostics, session
///   history (and a damaged one set aside as
///   `SessionHistory.damaged-<time>.json`), trusted headsets, the marker of
///   a running session. Wine's own
///   config, cache and temporary files stay inside each environment.
/// - Application Support/BasaltVR, only when basaltctl is run with no data
///   folder given. The original BasaltVR app keeps its data there too, so
///   it is listed apart (`basaltVRFolder`) and removed only on request.
/// - two preference files beside the support files, and beside them a
///   preference file that could not be read and was set aside on request
///   (`manager-preferences.damaged-<time>.json`).
/// - a packaged app, whose support files are inside its bundle, keeps those
///   preference files in `config` in its support folder
///   (Application Support/TrailBridge VR) and its standard data folder in
///   `Data` beside it. The support folder goes too once nothing is left in
///   it.
/// - the Wine the app downloads is in the data folder (`Tools`), and so is
///   its archive while it is downloaded (`Downloads`).
/// - what macOS makes for any app: its defaults domain, saved window state
///   and Metal shader caches, plus the shared Metal cache of Wine processes.
/// - two kinds of temporary files, normally removed at once, left only by a
///   session that ended abnormally.
/// - reports macOS writes in ~/Library/Logs/DiagnosticReports when the app
///   or its streamer crashes.
/// The app's privacy permissions are reset apart (`AppPermissions`).
public enum AppFootprint {
    public enum Group: String, CaseIterable, Sendable {
        /// The data folder: environments, games, downloads, tools, logs.
        case games
        /// Preferences and learning progress.
        case settings
        /// Caches and state macOS keeps for the app and for Wine.
        case systemCaches
        /// Reports macOS wrote when the app or its streamer crashed.
        case crashReports
        /// Temporary files left by a session that ended abnormally.
        case temporaryFiles
    }

    public struct Item: Equatable, Sendable {
        public let group: Group
        public let url: URL
        public let bytes: Int64

        public init(group: Group, url: URL, bytes: Int64) {
            self.group = group
            self.url = url
            self.bytes = bytes
        }
    }

    public struct Locations: Sendable {
        public var dataRoot: URL
        /// The folder holding `manager-preferences.json` and `learning.json`.
        public var preferencesFolder: URL
        /// The support folder of a packaged app, which holds the
        /// preferences folder and the standard data folder; nil for an app
        /// started from a checkout.
        public var supportFolder: URL?
        public var bundleIdentifier: String?
        public var home: URL
        /// `confstr(_CS_DARWIN_USER_CACHE_DIR)`, where Metal keeps its caches.
        public var userCacheDirectory: URL?
        public var temporaryDirectory: URL
        /// Whether `items` also lists `basaltVRFolder`: the person's choice
        /// when removing the app, off unless they make it.
        public var includesBasaltVRFolder: Bool

        public init(dataRoot: URL, preferencesFolder: URL, supportFolder: URL? = nil,
                    bundleIdentifier: String?,
                    home: URL, userCacheDirectory: URL?, temporaryDirectory: URL,
                    includesBasaltVRFolder: Bool = false) {
            self.dataRoot = dataRoot
            self.preferencesFolder = preferencesFolder
            self.supportFolder = supportFolder
            self.bundleIdentifier = bundleIdentifier
            self.home = home
            self.userCacheDirectory = userCacheDirectory
            self.temporaryDirectory = temporaryDirectory
            self.includesBasaltVRFolder = includesBasaltVRFolder
        }

        /// A packaged app's standard data folder, when the data folder in
        /// use is another one: what the app stored before the person chose
        /// that other folder is still there.
        var standardDataFolderApart: URL? {
            guard let supportFolder else { return nil }
            let standard = supportFolder.appendingPathComponent("Data", isDirectory: true)
            // Paths, not URLs: the same folder may be written with or
            // without a trailing slash.
            return standard.standardizedFileURL.path == dataRoot.standardizedFileURL.path
                ? nil : standard
        }

        /// Where macOS keeps this user's crash, hang and resource reports.
        public var diagnosticReportsFolder: URL {
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        }

        /// This Mac's locations for an app with `bundleIdentifier`.
        public static func current(dataRoot: URL, preferencesFolder: URL,
                                   supportFolder: URL? = nil,
                                   bundleIdentifier: String?,
                                   includesBasaltVRFolder: Bool = false) -> Locations {
            Locations(
                dataRoot: dataRoot, preferencesFolder: preferencesFolder,
                supportFolder: supportFolder,
                bundleIdentifier: bundleIdentifier,
                home: FileManager.default.homeDirectoryForCurrentUser,
                userCacheDirectory: AppFootprint.userCacheDirectory(),
                temporaryDirectory: FileManager.default.temporaryDirectory,
                includesBasaltVRFolder: includesBasaltVRFolder)
        }
    }

    /// `~/Library/Application Support/BasaltVR`: where `basaltctl` keeps its
    /// data when it is given no folder, and where the original BasaltVR app
    /// keeps its own. It may hold another app's games, so it is never
    /// removed unless the person asks for it.
    public struct BasaltVRFolder: Equatable, Sendable {
        public let url: URL
        /// What removing it deletes: the folder itself, or only the entries
        /// named in `dataFolderEntries` when it holds other files too.
        public let items: [Item]

        public var bytes: Int64 { AppFootprint.totalBytes(items) }
    }

    /// Entries the app creates at the top of its data folder.
    public static let dataFolderEntries: Set<String> = [
        "Bottles", "Profiles", "Downloads", "Tools", "Diagnostics",
        "SessionHistory.json", HeadsetTrustStore.fileName, "app-home",
        SessionMarker.fileName,
    ]
    /// Also the app's own: a session history that could not be read as one
    /// and was set aside (`DamagedFile`) when a new one was started.
    static func isDataFolderEntry(_ name: String) -> Bool {
        dataFolderEntries.contains(name)
            || DamagedFile.isSetAside(name, of: SessionHistoryStore.fileName)
    }
    /// Finder's own file, harmless to remove with the folder.
    static let ignorableEntries: Set<String> = [".DS_Store"]
    public static let preferenceFiles = ["manager-preferences.json", "learning.json"]
    /// The preference file that is set aside, on request, when it cannot be
    /// read (`WorkspacePreferences.setAside`); its copies are listed too.
    static let preferenceFileSetAside = "manager-preferences.json"
    /// The Metal cache macOS keeps for Wine processes, which have no bundle
    /// of their own here. Games' caches stay inside their environments.
    public static let wineCacheFolders = ["org.winehq.wine"]
    /// The app's and the streamer's executable names: macOS names a report
    /// `<name>-<time>.ips`, or `<name>_<time>_<host>.<kind>` for a hang or a
    /// resource report. Wine's reports are not listed: other Wine apps on
    /// the Mac write the same names.
    public static let crashReportProcessNames = ["TrailBridgeVR", "basalt-streamer"]

    /// Everything that exists now, with its size on disk: what removing the
    /// app deletes. `basaltVRFolder` is in it only when `locations` says so.
    public static func items(at locations: Locations,
                             fileManager: FileManager = .default) -> [Item] {
        var items = [Item]()
        func add(_ group: Group, _ url: URL) {
            if let item = item(group, url, fileManager) { items.append(item) }
        }

        for url in dataFolderItems(locations.dataRoot, fileManager: fileManager) {
            add(.games, url)
        }
        if let standard = locations.standardDataFolderApart {
            for url in dataFolderItems(standard, fileManager: fileManager) {
                add(.games, url)
            }
        }
        if locations.includesBasaltVRFolder,
           let folder = basaltVRFolder(at: locations, fileManager: fileManager) {
            items += folder.items
        }
        for name in preferenceFiles {
            add(.settings, locations.preferencesFolder.appendingPathComponent(name))
        }
        let setAside = ((try? fileManager.contentsOfDirectory(
            atPath: locations.preferencesFolder.path)) ?? [])
            .filter { DamagedFile.isSetAside($0, of: preferenceFileSetAside) }
        for name in setAside.sorted() {
            add(.settings, locations.preferencesFolder.appendingPathComponent(name))
        }
        if let id = locations.bundleIdentifier, !id.isEmpty, !id.contains("/") {
            let library = locations.home.appendingPathComponent("Library", isDirectory: true)
            add(.settings, library.appendingPathComponent("Preferences/\(id).plist"))
            add(.systemCaches, library.appendingPathComponent("Saved Application State/\(id).savedState"))
            for folder in ["Caches", "HTTPStorages", "WebKit"] {
                add(.systemCaches, library.appendingPathComponent("\(folder)/\(id)"))
            }
            if let cache = locations.userCacheDirectory {
                add(.systemCaches, cache.appendingPathComponent(id))
            }
        }
        if let cache = locations.userCacheDirectory {
            for name in wineCacheFolders {
                add(.systemCaches, cache.appendingPathComponent(name))
            }
        }
        for url in crashReports(in: locations.diagnosticReportsFolder, fileManager: fileManager) {
            add(.crashReports, url)
        }
        for url in temporaryFiles(in: locations.temporaryDirectory, olderThan: nil,
                                  fileManager: fileManager) {
            add(.temporaryFiles, url)
        }
        return items
    }

    /// The app's and the streamer's reports in `folder`, files only.
    static func crashReports(in folder: URL, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().filter { name in
            crashReportProcessNames.contains { process in
                name.hasPrefix(process + "-") || name.hasPrefix(process + "_")
            }
        }.map { folder.appendingPathComponent($0) }.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && !isSymbolicLink(url, fileManager)
        }
    }

    /// The BasaltVR folder in Application Support with what removing it
    /// would delete; nil when there is nothing of that kind in it, or when
    /// it is the app's own data folder, which `items` lists already.
    public static func basaltVRFolder(at locations: Locations,
                                      fileManager: FileManager = .default) -> BasaltVRFolder? {
        let folder = locations.home.appendingPathComponent(
            "Library/Application Support/BasaltVR", isDirectory: true).standardizedFileURL
        // Paths, not URLs: the same folder may be written with or without
        // a trailing slash.
        guard folder.path != locations.dataRoot.standardizedFileURL.path else { return nil }
        let items = dataFolderItems(folder, fileManager: fileManager)
            .compactMap { item(.games, $0, fileManager) }
        return items.isEmpty ? nil : BasaltVRFolder(url: folder, items: items)
    }

    /// The whole data folder when it holds only what the app made, so it
    /// goes too; otherwise only the app's entries, leaving the user's files
    /// and the folder they chose. Never a home folder or a volume root.
    static func dataFolderItems(_ dataRoot: URL, fileManager: FileManager) -> [URL] {
        let root = dataRoot.standardizedFileURL
        guard let children = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        let ours = children.filter(isDataFolderEntry)
        let others = children.filter {
            !isDataFolderEntry($0) && !ignorableEntries.contains($0)
        }
        let protected = root.pathComponents.count <= 3
            || root.path == fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
            || isSymbolicLink(root, fileManager)
        if others.isEmpty, !protected {
            return [root]
        }
        return ours.sorted().map { root.appendingPathComponent($0) }
    }

    /// `basalt-manager-….control` (a streaming session's link to the game)
    /// and `BasaltVR-command-….log` (a Wine command's output) in the
    /// temporary folder; with `olderThan`, only those last changed before it.
    public static func temporaryFiles(in directory: URL, olderThan cutoff: Date?,
                                      fileManager: FileManager = .default) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter {
            ($0.hasPrefix("basalt-manager-") && $0.hasSuffix(".control"))
                || ($0.hasPrefix("BasaltVR-command-") && $0.hasSuffix(".log"))
        }
        .sorted()
        .map { directory.appendingPathComponent($0) }
        .filter { url in
            guard let cutoff else { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return modified.map { $0 < cutoff } ?? false
        }
    }

    /// Removes the items. A link is removed, never followed. Returns those
    /// that could not be removed, with why.
    @discardableResult
    public static func remove(_ items: [Item],
                              fileManager: FileManager = .default) -> [(Item, String)] {
        var failures = [(Item, String)]()
        for item in items where exists(item.url, fileManager) {
            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                failures.append((item, error.localizedDescription))
            }
        }
        return failures
    }

    /// Removes `folder` and then its parents while each is empty, stopping
    /// at the first that is not: what the preference files leave behind.
    public static func removeEmptyFolders(from folder: URL, levels: Int,
                                          fileManager: FileManager = .default) {
        var current = folder.standardizedFileURL
        for _ in 0..<max(0, levels) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
                  contents.allSatisfy(ignorableEntries.contains) else { return }
            guard (try? fileManager.removeItem(at: current)) != nil else { return }
            current.deleteLastPathComponent()
        }
    }

    /// Removes the folders the preference files leave behind, while each
    /// is empty: `.local/config` and `.local` beside a checkout; for a
    /// packaged app `config` and then the support folder itself, which by
    /// now holds nothing unless the person keeps files of their own in it.
    public static func removeEmptyFolders(at locations: Locations,
                                          fileManager: FileManager = .default) {
        guard let support = locations.supportFolder else {
            removeEmptyFolders(from: locations.preferencesFolder, levels: 2, fileManager: fileManager)
            return
        }
        removeEmptyFolders(from: locations.preferencesFolder, levels: 1, fileManager: fileManager)
        removeEmptyFolders(from: support, levels: 1, fileManager: fileManager)
    }

    public static func totalBytes(_ items: [Item], in group: Group? = nil) -> Int64 {
        items.filter { group == nil || $0.group == group }.reduce(0) { $0 + $1.bytes }
    }

    public static func userCacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private static func item(_ group: Group, _ url: URL, _ fileManager: FileManager) -> Item? {
        guard exists(url, fileManager) else { return nil }
        return Item(group: group, url: url.standardizedFileURL,
                    bytes: allocatedSize(of: url, fileManager: fileManager))
    }

    private static func exists(_ url: URL, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url, fileManager)
    }

    private static func isSymbolicLink(_ url: URL, _ fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Bytes on disk, counting a folder's contents without following links.
    static func allocatedSize(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .isSymbolicLinkKey, .isDirectoryKey]
        func size(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true else {
            return size(url)
        }
        var total: Int64 = 0
        let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            total += size(child)
        }
        return total
    }
}
