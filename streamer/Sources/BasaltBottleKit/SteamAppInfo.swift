import Foundation

/// One launch option Steam lists for an app: what the client starts when the
/// player presses Play (`config/launch/<n>` in the app's information).
public struct SteamLaunchOption: Equatable, Sendable {
    /// Relative to the game's install folder, as Steam stores it (`\` or `/`).
    public var executable: String
    /// One command line, as Steam passes it to the game.
    public var arguments: String
    /// Relative to the install folder; empty means the executable's folder.
    public var workingDirectory: String
    /// `default`, `option1`, `vr`, `server`, …; empty when Steam gives none.
    public var type: String
    /// Comma-separated `windows`, `macos`, `linux`; empty means every system.
    public var operatingSystems: String
    /// `64` or `32`; empty when Steam gives none.
    public var architecture: String
    /// The beta branch the option belongs to; empty for the default branch.
    public var betaKey: String
    /// `SteamGlobal` or `SteamChina`; empty for both.
    public var realm: String

    public init(executable: String, arguments: String = "", workingDirectory: String = "",
                type: String = "", operatingSystems: String = "", architecture: String = "",
                betaKey: String = "", realm: String = "") {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.type = type
        self.operatingSystems = operatingSystems
        self.architecture = architecture
        self.betaKey = betaKey
        self.realm = realm
    }
}

/// Reads one app's launch options from Steam's `appcache/appinfo.vdf`.
///
/// The file is the client's binary cache of app information. Versions 39 to
/// 41 (magic `0x07564427`…`0x07564429`) hold a header, one entry per app (its
/// AppID, the entry's size in bytes, fixed fields, then the app's information
/// as binary KeyValues) and AppID 0 at the end; version 41 keeps every key
/// once in a table at the end of the file and refers to keys by index, the
/// older ones spell them inline. Version 42 (`0x0756442A`) is a shard: a
/// header, an index of apps, the key table, then the apps' data. Only the
/// requested app is decoded. Another version, a truncated file or an
/// inconsistent entry reads as nil, and callers then look at the game's
/// folder instead.
public enum SteamAppInfo {
    static let format27: UInt32 = 0x0756_4427
    static let format28: UInt32 = 0x0756_4428
    static let format29: UInt32 = 0x0756_4429
    static let format2A: UInt32 = 0x0756_442A
    /// Deeper nesting than Steam ever writes means a damaged file.
    static let maximumDepth = 64

    /// The app's launch options in Steam's order: nil when the file cannot be
    /// read or does not list the app, empty when the app lists none.
    public static func launchOptions(appID: UInt32, inFileAt url: URL) -> [SteamLaunchOption]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return launchOptions(appID: appID, in: data)
    }

    public static func launchOptions(appID: UInt32, in data: Data) -> [SteamLaunchOption]? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [SteamLaunchOption]? in
            guard let information = appInformation(appID: appID, in: bytes) else { return nil }
            return launchOptions(fromAppInformation: information)
        }
    }

    // MARK: - Binary KeyValues

    /// A binary KeyValues value. Numbers are kept as their decimal text,
    /// since Steam writes a few launch fields either way; values a launch
    /// does not need are `.other`.
    enum Node {
        case object([(key: String, value: Node)])
        case string(String)
        case other

        var entries: [(key: String, value: Node)]? {
            if case .object(let entries) = self { return entries }
            return nil
        }
    }

    static func appInformation(appID: UInt32,
                               in bytes: UnsafeRawBufferPointer) -> [(key: String, value: Node)]? {
        var cursor = ByteCursor(bytes: bytes)
        guard let magic = cursor.uint32(), [format27, format28, format29, format2A].contains(magic),
              cursor.uint32() != nil else { return nil }  // the universe
        if magic == format2A { return shardAppInformation(appID: appID, in: bytes, after: cursor) }
        var keyTableOffset: Int?
        if magic == format29 {
            guard let offset = cursor.uint64(), offset < UInt64(bytes.count) else { return nil }
            keyTableOffset = Int(offset)
        }
        // After `size`: info state, last update, PICS token, SHA-1 of the
        // text form, change number and, from format 28, SHA-1 of the binary
        // form. The app's KeyValues fill the rest of the entry.
        let fixedFields = 4 + 4 + 8 + 20 + 4 + (magic == format27 ? 0 : 20)
        while let id = cursor.uint32(), id != 0 {
            guard let size = cursor.uint32(), Int(size) <= cursor.remaining else { return nil }
            let start = cursor.offset
            let end = start + Int(size)
            guard id == appID else {
                cursor.offset = end
                continue
            }
            guard Int(size) > fixedFields else { return nil }
            var keys: [String]?
            if let keyTableOffset {
                guard let table = keyTable(at: keyTableOffset, in: bytes) else { return nil }
                keys = table
            }
            var information = ByteCursor(bytes: bytes, offset: start + fixedFields, end: end)
            return object(&information, keys: keys, depth: 0)
        }
        return nil
    }

    /// Version 42: after the universe, the shard's index and count, the
    /// number of apps, the index's size, the number of keys, the key table's
    /// size, the data's size and two CRC-32s. Each index entry holds the
    /// AppID, the offset and size of its data from the start of the data
    /// section, and the size of a summary that follows; an app's data is the
    /// SHA-1 of its binary form, then its KeyValues.
    static func shardAppInformation(appID: UInt32, in bytes: UnsafeRawBufferPointer,
                                    after header: ByteCursor) -> [(key: String, value: Node)]? {
        var cursor = header
        var fields = [Int]()
        for _ in 0..<9 {
            guard let field = cursor.uint32() else { return nil }
            fields.append(Int(field))
        }
        let (appCount, indexSize, keyCount, keyTableSize) = (fields[2], fields[3], fields[4], fields[5])
        let indexStart = cursor.offset
        let keyTableStart = indexStart + indexSize
        let dataStart = keyTableStart + keyTableSize
        guard dataStart <= bytes.count else { return nil }
        var index = ByteCursor(bytes: bytes, offset: indexStart, end: keyTableStart)
        for _ in 0..<appCount {
            guard let id = index.uint32(), let offset = index.uint32(), let size = index.uint32(),
                  let summary = index.uint32(), index.skip(Int(summary)) else { return nil }
            guard id == appID else { continue }
            let start = dataStart + Int(offset)
            let end = start + Int(size)
            guard Int(size) > 20, end <= bytes.count,
                  let keys = strings(keyCount, at: keyTableStart, end: dataStart, in: bytes) else {
                return nil
            }
            var information = ByteCursor(bytes: bytes, offset: start + 20, end: end)
            return object(&information, keys: keys, depth: 0)
        }
        return nil
    }

    /// Version 41's key table: a count, then the keys.
    static func keyTable(at offset: Int, in bytes: UnsafeRawBufferPointer) -> [String]? {
        var cursor = ByteCursor(bytes: bytes, offset: offset)
        guard let count = cursor.uint32() else { return nil }
        return strings(Int(count), at: cursor.offset, end: bytes.count, in: bytes)
    }

    /// `count` NUL-terminated UTF-8 strings from `offset`, all before `end`.
    static func strings(_ count: Int, at offset: Int, end: Int,
                        in bytes: UnsafeRawBufferPointer) -> [String]? {
        var cursor = ByteCursor(bytes: bytes, offset: offset, end: end)
        // Every string takes at least its terminating NUL.
        guard count >= 0, count <= cursor.remaining else { return nil }
        var result = [String]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard let string = cursor.cString() else { return nil }
            result.append(string)
        }
        return result
    }

    /// The entries up to the object's end marker.
    static func object(_ cursor: inout ByteCursor, keys: [String]?,
                       depth: Int) -> [(key: String, value: Node)]? {
        guard depth < maximumDepth else { return nil }
        var entries = [(key: String, value: Node)]()
        while let type = cursor.byte() {
            if type == 0x08 || type == 0x0B { return entries }
            let key: String
            if let keys {
                guard let index = cursor.uint32(), Int(index) < keys.count else { return nil }
                key = keys[Int(index)]
            } else {
                guard let name = cursor.cString() else { return nil }
                key = name
            }
            switch type {
            case 0x00:
                guard let children = object(&cursor, keys: keys, depth: depth + 1) else { return nil }
                entries.append((key: key, value: .object(children)))
            case 0x01:
                guard let text = cursor.cString() else { return nil }
                entries.append((key: key, value: .string(text)))
            case 0x02:
                guard let value = cursor.uint32() else { return nil }
                entries.append((key: key, value: .string(String(Int32(bitPattern: value)))))
            case 0x07:
                guard let value = cursor.uint64() else { return nil }
                entries.append((key: key, value: .string(String(value))))
            case 0x0A:
                guard let value = cursor.uint64() else { return nil }
                entries.append((key: key, value: .string(String(Int64(bitPattern: value)))))
            case 0x03, 0x04, 0x06:  // float, pointer, colour
                guard cursor.skip(4) else { return nil }
                entries.append((key: key, value: .other))
            case 0x05:  // UTF-16 text
                guard cursor.skipWideString() else { return nil }
                entries.append((key: key, value: .other))
            default:
                return nil
            }
        }
        return nil  // the bytes ended inside the object
    }

    static func launchOptions(
        fromAppInformation root: [(key: String, value: Node)]
    ) -> [SteamLaunchOption] {
        // An entry holds one object, "appinfo"; its contents are accepted at
        // the top as well.
        let information = child(root, "appinfo")?.entries ?? root
        guard let config = child(information, "config")?.entries,
              let launch = child(config, "launch")?.entries else { return [] }
        return launch.compactMap { option -> SteamLaunchOption? in
            guard let fields = option.value.entries else { return nil }
            let requirements = child(fields, "config")?.entries ?? []
            return SteamLaunchOption(
                executable: text(fields, "executable"),
                arguments: text(fields, "arguments"),
                workingDirectory: text(fields, "workingdir"),
                type: text(fields, "type"),
                operatingSystems: text(requirements, "oslist"),
                architecture: text(requirements, "osarch"),
                betaKey: text(requirements, "betakey"),
                realm: text(requirements, "realm"))
        }
    }

    private static func child(_ entries: [(key: String, value: Node)], _ key: String) -> Node? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private static func text(_ entries: [(key: String, value: Node)], _ key: String) -> String {
        if case .string(let value)? = child(entries, key) { return value }
        return ""
    }
}

/// Little-endian reads that never pass `end`; each returns nil, or false,
/// instead of reading out of bounds.
struct ByteCursor {
    let bytes: UnsafeRawBufferPointer
    var offset: Int
    let end: Int

    init(bytes: UnsafeRawBufferPointer, offset: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.offset = offset
        self.end = min(end ?? bytes.count, bytes.count)
    }

    var remaining: Int { max(0, end - offset) }

    mutating func byte() -> UInt8? {
        guard offset >= 0, offset < end else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() -> UInt32? {
        guard offset >= 0, remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (8 * index)
        }
        offset += 4
        return value
    }

    mutating func uint64() -> UInt64? {
        guard offset >= 0, remaining >= 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        offset += 8
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, offset >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    /// NUL-terminated UTF-8 text.
    mutating func cString() -> String? {
        guard offset >= 0, offset < end else { return nil }
        var terminator = offset
        while terminator < end, bytes[terminator] != 0 {
            terminator += 1
        }
        guard terminator < end else { return nil }
        let text = String(decoding: bytes[offset..<terminator], as: UTF8.self)
        offset = terminator + 1
        return text
    }

    /// Skips NUL-terminated UTF-16 text.
    mutating func skipWideString() -> Bool {
        while remaining >= 2 {
            let low = bytes[offset]
            let high = bytes[offset + 1]
            offset += 2
            if low == 0 && high == 0 { return true }
        }
        return false
    }
}
