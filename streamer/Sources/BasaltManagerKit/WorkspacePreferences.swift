import Foundation
import BasaltBottleKit

/// App preferences live beside the workspace, including when launched from Finder.
/// No credentials or Steam session data belong in this store.
///
/// The file is one JSON object; each value is the JSON of one setting, as
/// base64 text. Entries are read one by one: an entry that is not such text
/// does not hide the others, and is kept and written back as it is. A file
/// that cannot be read at all, or is not a JSON object, sets `loadError`;
/// it is then never written over, until `setAside()` moves it out of the way.
public final class WorkspacePreferences {
    /// The file is there and cannot be used as it is.
    public struct Unreadable: LocalizedError {
        public let file: URL
        /// The system's own words, for "Details".
        public let reason: String

        public var errorDescription: String? {
            L10n.string(.settingsFileUnreadable, file.lastPathComponent)
        }
    }

    /// The folder of the file is not on the disk it was on when the app
    /// started: that disk is not connected. Nothing is created in its place.
    public struct DiskNotConnected: LocalizedError {
        public let file: URL

        public var errorDescription: String? {
            L10n.string(.settingsDiskNotConnected, file.lastPathComponent)
        }
    }

    public let fileURL: URL
    public private(set) var loadError: Error?
    private var values = [String: Data]()
    /// Entries that are not what this store writes, by key, as JSON objects.
    private var foreign = [String: Any]()
    /// The disk of the file's folder, or, until the folder exists, of the
    /// nearest folder above it: where the first save creates the folder.
    private var volume: VolumeIdentity?
    /// The folder itself has been seen, so `volume` is its own disk.
    private var folderSeen: Bool

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let folder = fileURL.deletingLastPathComponent()
        if let identity = VolumeIdentity.of(folder) {
            volume = identity
            folderSeen = true
        } else {
            volume = VolumeIdentity.ofNearestExisting(folder)
            folderSeen = false
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for (key, value) in object {
                    if let text = value as? String, let data = Data(base64Encoded: text) {
                        values[key] = data
                    } else {
                        foreign[key] = value
                    }
                }
            } catch {
                loadError = Unreadable(file: fileURL, reason: error.localizedDescription)
            }
        }
    }

    public func value<T: Decodable>(forKey key: String) -> T? {
        guard let data = values[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func data(forKey key: String) -> Data? { value(forKey: key) }
    public func string(forKey key: String) -> String? { value(forKey: key) }

    /// True when the file has an entry for `key` that does not read as `T`:
    /// the setting was made and is lost, which is not the same as never made.
    public func isUnreadable<T: Decodable>(_ type: T.Type, forKey key: String) -> Bool {
        if foreign[key] != nil { return true }
        guard let data = values[key] else { return false }
        return (try? JSONDecoder().decode(type, from: data)) == nil
    }

    public func set<T: Encodable>(_ value: T?, forKey key: String) throws {
        // Preserve a damaged file for recovery instead of replacing it with defaults.
        if let loadError { throw loadError }
        var updated = values
        updated[key] = try value.map { try JSONEncoder().encode($0) }
        var kept = foreign
        kept[key] = nil
        let data: Data
        if kept.isEmpty {
            data = try JSONEncoder().encode(updated)
        } else {
            var object = kept
            for (key, value) in updated { object[key] = value.base64EncodedString() }
            data = try JSONSerialization.data(withJSONObject: object)
        }
        try prepareFolder()
        try data.write(to: fileURL, options: .atomic)
        values = updated
        foreign = kept
    }

    /// Renames the file to `<name>.damaged-<time>.json` beside itself and
    /// starts over with no settings, so that settings can be saved again.
    /// What was read from the file stays out of memory too: the next start
    /// would not see it either. Returns where the file went.
    @discardableResult
    public func setAside(now: Date = Date()) throws -> URL {
        let moved = try DamagedFile.setAside(fileURL, now: now)
        loadError = nil
        values = [:]
        foreign = [:]
        return moved
    }

    /// Makes sure the file's folder is there, on the disk that held it.
    /// A folder on another disk than before, or a missing one whose place
    /// is now on another disk, means that its disk has left: nothing is
    /// created then. A folder that was only removed is made again.
    private func prepareFolder() throws {
        let folder = fileURL.deletingLastPathComponent()
        if let now = VolumeIdentity.of(folder) {
            if folderSeen, let volume, !now.isSameVolume(as: volume) {
                throw DiskNotConnected(file: fileURL)
            }
            volume = now
            folderSeen = true
            return
        }
        if let volume {
            guard let now = VolumeIdentity.ofNearestExisting(folder), now.isSameVolume(as: volume) else {
                throw DiskNotConnected(file: fileURL)
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        volume = VolumeIdentity.of(folder) ?? volume
        folderSeen = true
    }
}
