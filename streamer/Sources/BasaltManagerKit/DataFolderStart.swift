import Foundation

/// Which data folder the app opens at start.
public struct DataFolderStart: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// `BASALT_DATA_DIR` set by the person, to something other than the
        /// development script's default.
        case environment
        /// The folder chosen in Settings.
        case saved
        /// The workspace's standard folder: `<repo>/.local/data` in a
        /// checkout, `Data` in the support folder of a packaged app.
        case standard
    }

    public let folder: URL
    public let source: Source

    public init(folder: URL, source: Source) {
        self.folder = folder
        self.source = source
    }

    /// `<repo>/.local/data` in a checkout, which scripts/trailbridge-dev.zsh
    /// always exports as `BASALT_DATA_DIR`; in a packaged app, `Data` in
    /// its support folder.
    public static func standardFolder(repoRoot: URL) -> URL {
        AppWorkspace(repoRoot: repoRoot).standardDataFolder
    }

    public static func choose(environment: String?, saved: String?, repoRoot: URL) -> DataFolderStart {
        choose(environment: environment, saved: saved, workspace: AppWorkspace(repoRoot: repoRoot))
    }

    /// An explicit `BASALT_DATA_DIR` wins; the development script's default
    /// is not explicit, so the folder saved in Settings comes before it.
    /// Empty values count as absent.
    public static func choose(environment: String?, saved: String?,
                              workspace: AppWorkspace) -> DataFolderStart {
        let standard = workspace.standardDataFolder
        let requested = environment.flatMap(folder)
        if let requested, !same(requested, standard) {
            return DataFolderStart(folder: requested, source: .environment)
        }
        if let saved = saved.flatMap(folder) {
            return DataFolderStart(folder: saved, source: .saved)
        }
        // Keep the script's own spelling of the default path when it gave one.
        return DataFolderStart(folder: requested ?? standard, source: .standard)
    }

    /// The folder as the app uses it once it is open: with every symbolic
    /// link on the way resolved (`realpath`), so that each later comparison
    /// of paths inside it is between resolved paths. The result is spelled
    /// the way Foundation spells resolved paths (`/tmp` and `/var`, not
    /// `/private/tmp` and `/private/var`), which is what those comparisons
    /// produce. A folder that is not there cannot be resolved and comes
    /// back as it is.
    public static func resolved(_ folder: URL) -> URL {
        guard let path = realpath(folder.standardizedFileURL.path, nil) else {
            return folder.standardizedFileURL
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true).standardizedFileURL
    }

    private static func folder(_ path: String) -> URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func same(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
