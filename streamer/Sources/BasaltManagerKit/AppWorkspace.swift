import Foundation
import BasaltBottleKit

/// Where the app may write, given where its own files are.
///
/// Started from a source checkout, the app keeps its settings and its
/// standard data folder in `<checkout>/.local`. Started from a packaged app,
/// its own files are inside the app bundle, which is never written to: the
/// settings and the standard data folder are in the support folder instead.
public struct AppWorkspace: Equatable, Sendable {
    /// Names another support folder than the one in Application Support.
    public static let supportFolderVariable = "TRAILBRIDGE_SUPPORT_DIR"
    /// The support folder's name in `~/Library/Application Support`.
    public static let supportFolderName = "TrailBridge VR"

    /// The checkout, or the support files inside the app bundle.
    public let repoRoot: URL
    /// `repoRoot` is the support files of a packaged app, not a checkout.
    public let isPackaged: Bool
    /// The packaged app's folder for settings and the standard data folder.
    /// A checkout does not use it.
    public let supportFolder: URL

    public init(repoRoot: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.repoRoot = repoRoot
        // The marker alone decides, as it does for the packaged start: a
        // bundle that lacks some of its support files is still a bundle,
        // and nothing may be written inside it. A checkout that was also
        // packaged into stays a checkout.
        isPackaged = fileManager.fileExists(
            atPath: repoRoot.appendingPathComponent(RepositoryLocator.packagedMarker).path)
            && !RepositoryLocator.hasSourceLayout(repoRoot, fileManager: fileManager)
        if let override = environment[Self.supportFolderVariable], !override.isEmpty {
            supportFolder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            supportFolder = home.appendingPathComponent(
                "Library/Application Support/\(Self.supportFolderName)", isDirectory: true)
        }
    }

    /// The folder of `manager-preferences.json` and `learning.json`.
    public var configFolder: URL {
        isPackaged
            ? supportFolder.appendingPathComponent("config", isDirectory: true)
            : repoRoot.appendingPathComponent(".local/config", isDirectory: true)
    }

    /// The data folder the app uses until the person chooses another.
    public var standardDataFolder: URL {
        isPackaged
            ? supportFolder.appendingPathComponent("Data", isDirectory: true)
            : repoRoot.appendingPathComponent(".local/data", isDirectory: true)
    }
}

/// How a packaged app starts: with no checkout and no development script,
/// from the support files inside its own bundle.
public struct PackagedStart: Equatable, Sendable {
    /// The search path a process started by Finder would have.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The support files: the process's `BASALT_REPO_ROOT` and its current
    /// directory.
    public let supportRoot: URL
    /// The `PATH` to set; nil leaves the one the process has.
    public let path: String?

    /// The start to make, or nil when the app is not a packaged one or was
    /// already given its files: then it starts as from a checkout.
    public static func plan(environment: [String: String], resourceURL: URL?,
                            fileManager: FileManager = .default) -> PackagedStart? {
        guard environment["BASALT_REPO_ROOT"] == nil, let resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent("BasaltVR", isDirectory: true)
        guard fileManager.fileExists(
            atPath: root.appendingPathComponent(RepositoryLocator.packagedMarker).path) else {
            return nil
        }
        return PackagedStart(supportRoot: root,
                             path: (environment["PATH"] ?? "").isEmpty ? systemPath : nil)
    }

    /// The variables the start sets in the process.
    public var environment: [String: String] {
        var values = ["BASALT_REPO_ROOT": supportRoot.path]
        values["PATH"] = path
        return values
    }
}
