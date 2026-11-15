import Foundation

public struct HeadsetRequest: Equatable, Sendable, Identifiable {
    public var id: String { hostname }
    public let hostname: String
    public let ip: String

    public static func parse(_ line: String) -> Self? {
        let prefix = "Headset request: "
        guard line.hasPrefix(prefix), let separator = line.range(of: " at ", options: .backwards) else { return nil }
        let name = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<separator.lowerBound])
        let ip = String(line[separator.upperBound...])
        guard HeadsetTrustStore.validHostname(name), !ip.isEmpty,
              ip.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return nil }
        return Self(hostname: name, ip: ip)
    }
}

public struct HeadsetTrustStore: Sendable {
    public static let fileName = "TrustedHeadsets.json"

    /// The list as a whole cannot be read: the file is damaged, or macOS
    /// does not let the app read it. The file is left as it is.
    public struct Unreadable: LocalizedError, Equatable {
        public let file: URL
        public let reason: String

        public var errorDescription: String? {
            "The list of trusted headsets (\(file.lastPathComponent)) cannot be read: \(reason)"
        }
    }

    public let file: URL
    /// False for the list in a data folder: that folder is never created
    /// here, since one made in place of a disk that is not connected would
    /// hide the real folder when the disk comes back.
    private let createsFolder: Bool

    /// A list in a file of the caller's own; its folder is created on saving.
    public init(file: URL) {
        self.file = file
        createsFolder = true
    }

    /// The app's list, `TrustedHeadsets.json` in its data folder. Saving
    /// fails when the data folder is not there.
    public init(dataRoot: URL) {
        file = dataRoot.appendingPathComponent(Self.fileName)
        createsFolder = false
    }

    /// A name that fits the log line it is reported in: no control or format
    /// characters and no line break of any kind (U+2028 and U+2029 are
    /// separators, not control characters).
    public static func validHostname(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }
    }

    /// The approved names. An entry that is not a valid name is left out, so
    /// one bad entry does not lock out every headset; a file that is no list
    /// at all throws `Unreadable`.
    public func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } catch is DecodingError {
            throw Unreadable(file: file, reason: "it is not a list of names")
        } catch {
            throw Unreadable(file: file, reason: error.localizedDescription)
        }
        return Set(entries.compactMap(\.name).filter(Self.validHostname)).sorted()
    }

    public func setTrusted(_ hostname: String, trusted: Bool) throws {
        guard Self.validHostname(hostname) else { throw BasaltError("Invalid ALVR hostname") }
        var names = Set(try load())
        if trusted { names.insert(hostname) } else { names.remove(hostname) }
        try save(names.sorted())
    }

    public func prepare() throws {
        // Also enforce private permissions for an existing, valid list.
        try save(load())
    }

    /// Replaces the list, readable or not, with an empty one: the way out
    /// when `load` throws `Unreadable`.
    public func reset() throws {
        try save([])
    }

    /// One element of the list; nil when it is not text.
    private struct Entry: Decodable {
        let name: String?

        init(from decoder: any Decoder) throws {
            name = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private func save(_ names: [String]) throws {
        if createsFolder {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // Atomic replacement with permissions set before publishing the new file.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path,
            contents: try JSONEncoder().encode(names), attributes: [.posixPermissions: 0o600]) else {
            throw BasaltError("Could not save trusted headsets")
        }
        guard rename(temporary.path, file.path) == 0 else { throw BasaltError("Could not replace headset trust file") }
    }
}
