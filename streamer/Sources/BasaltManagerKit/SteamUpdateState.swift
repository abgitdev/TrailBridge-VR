import Foundation
import BasaltBottleKit

public struct SteamUpdateState: Equatable, Sendable {
    public let flags: UInt64
    public init(flags: UInt64) { self.flags = flags }

    // Steam EAppState reference (public Open Steamworks AppsCommon.h):
    // https://github.com/SteamRE/open-steamworks/blob/master/Open%20Steamworks/AppsCommon.h
    // 2 UpdateRequired; 256 UpdateRunning; 512 UpdatePaused; 1024 UpdateStarted
    // (include both running and started bits); 65536 Reconfiguring;
    // 131072 Validating; 262144 AddingFiles; 524288 Preallocating;
    // 1048576 Downloading; 2097152 Staging; 4194304 Committing; 8388608 UpdateStopping.
    // Treat the whole lifecycle, including queued/paused updates, as unsafe to launch.
    public static let updateMask: UInt64 = 2 | 256 | 512 | 1024 | 65536 | 131072
        | 262144 | 524288 | 1048576 | 2097152 | 4194304 | 8388608
    public var isUpdating: Bool { flags & Self.updateMask != 0 }
    public var isReady: Bool { flags & 4 != 0 && !isUpdating }
    /// A download or update that Steam has started and not paused: only
    /// such a one can stand still.
    public var isDownloadRunning: Bool { flags & 1024 != 0 && flags & 512 == 0 }

    public static func parse(_ manifest: String) throws -> Self {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*"StateFlags"\s*"([0-9]+)"\s*$"#)
        guard let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
              let range = Range(match.range(at: 1), in: manifest), let flags = UInt64(manifest[range]) else {
            throw BottleToolError("Steam's game status is unavailable. Keep Steam open while it finishes updating.")
        }
        return .init(flags: flags)
    }

    public static func manifestURL(profile: LaunchProfile, prefix: URL, fileManager: FileManager = .default) throws -> URL? {
        guard profile.source == .steam else { return nil }
        var appID = profile.environment["SteamAppId"] ?? profile.environment["SteamGameId"]
        if appID == nil, let index = profile.arguments.firstIndex(of: "-applaunch"), profile.arguments.indices.contains(index + 1) {
            appID = profile.arguments[index + 1]
        }
        // A profile made from a detected game has no app ID. Its update state
        // cannot be read, which must not stop the game from starting.
        guard let appID, !appID.isEmpty, appID.allSatisfy(\.isNumber) else { return nil }
        // Search only this managed prefix, including secondary libraries in it.
        guard let enumerator = fileManager.enumerator(at: prefix.appendingPathComponent("drive_c"),
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw BottleToolError("Steam's game manifest was not found.")
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants(); continue
            }
            if file.lastPathComponent == "appmanifest_\(appID).acf", file.deletingLastPathComponent().lastPathComponent == "steamapps" {
                return file
            }
        }
        throw BottleToolError("Steam's game manifest was not found. Finish installing the game in Steam first.")
    }
}

public enum SteamUpdateWaiter {
    /// Injectable reads and clock let tests exercise the actual wait/override loop.
    @MainActor
    public static func wait(read: () async throws -> SteamUpdateState,
                            startAnyway: () -> Bool,
                            onWaiting: (SteamUpdateState?) -> Void,
                            pause: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) async throws {
        while true {
            try Task.checkCancellation()
            if startAnyway() { return }
            // Steam atomically rewrites manifests; a transient missing/partial
            // file must not release the launch during a download or commit.
            let state: SteamUpdateState?
            do { state = try await read() }
            catch is CancellationError { throw CancellationError() }
            catch { state = nil }
            if state?.isReady == true { return }
            onWaiting(state)
            try await pause()
        }
    }
}
