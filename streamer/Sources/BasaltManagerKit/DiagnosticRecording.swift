// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import BasaltBottleKit
import BasaltCore

/// What the user asked to record for one game. Both are off by default and
/// live in the app's own preferences, keyed by profile name; nothing is
/// written into the profile or the game's files.
public struct DiagnosticRecordingSettings: Codable, Equatable, Sendable {
    /// The runtime's frame CSV and the app's console transcript.
    public var recordsFrames = false
    /// The streamer's encoded video.
    public var recordsVideo = false

    public init(recordsFrames: Bool = false, recordsVideo: Bool = false) {
        self.recordsFrames = recordsFrames
        self.recordsVideo = recordsVideo
    }

    private enum CodingKeys: String, CodingKey { case recordsFrames, recordsVideo }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordsFrames = try values.decodeIfPresent(Bool.self, forKey: .recordsFrames) ?? false
        recordsVideo = try values.decodeIfPresent(Bool.self, forKey: .recordsVideo) ?? false
    }

    /// The developer override in a profile file: only the literal `1` counts.
    public init(profileEnvironment: [String: String]) {
        recordsFrames = profileEnvironment["BASALT_FRAME_TRACE"] == "1"
        recordsVideo = profileEnvironment["BASALT_RECORD_VIDEO"] == "1"
    }

    public var isEnabled: Bool { recordsFrames || recordsVideo }

    /// Either source turns a recording on.
    public func union(_ other: Self) -> Self {
        Self(recordsFrames: recordsFrames || other.recordsFrames,
             recordsVideo: recordsVideo || other.recordsVideo)
    }

    /// Disk use of the recorded video at a stream bitrate, in megabytes (10^6
    /// bytes) per minute: 375 at 50 Mbit/s.
    public static func videoMegabytesPerMinute(megabits: Int) -> Int {
        Int((Double(max(0, megabits)) * 60 / 8).rounded())
    }
}

/// What one launch records, after the free-space guard.
public struct DiagnosticRecordingPlan: Equatable, Sendable {
    /// Below this much free space on the data root's volume a launch records no
    /// video. The streamer's recorder refuses below the same amount, so the app
    /// never promises a video the streamer would not write.
    public static let minimumFreeBytesForVideo: Int64 = EncodedVideoRecorder.defaultMinimumFreeBytes

    public let recordsFrames: Bool
    public let recordsVideo: Bool
    /// Video was asked for and withheld; the session log says so once.
    public let videoSkippedForLowSpace: Bool

    /// `freeBytes` is nil when the volume could not be asked; the streamer's
    /// own check still applies then.
    public init(settings: DiagnosticRecordingSettings, profileEnvironment: [String: String],
                freeBytes: Int64?, minimumFreeBytes: Int64 = minimumFreeBytesForVideo) {
        let wanted = settings.union(DiagnosticRecordingSettings(profileEnvironment: profileEnvironment))
        let lowSpace = freeBytes.map { $0 < minimumFreeBytes } ?? false
        recordsFrames = wanted.recordsFrames
        videoSkippedForLowSpace = wanted.recordsVideo && lowSpace
        recordsVideo = wanted.recordsVideo && !lowSpace
    }
}

/// One recorded launch: the files in the `Diagnostics` folder that share a
/// `<UTC time>-<profile>` name. A launch that recorded nothing has only the
/// excerpt of the game's own log, which the app saves after every session.
public struct DiagnosticRecording: Identifiable, Equatable, Sendable {
    public enum FileKind: String, CaseIterable, Sendable {
        case frames, sessionLog, gameLog, video, videoIndex
    }

    public struct File: Identifiable, Equatable, Sendable {
        public let kind: FileKind
        public let url: URL
        public let bytes: Int64
        public let modified: Date
        public var id: String { url.lastPathComponent }
    }

    /// The shared file name without its extensions.
    public let id: String
    public let profileName: String
    public let startedAt: Date
    public let files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var lastModified: Date { files.map(\.modified).max() ?? startedAt }
    /// From the launch that reserved the name to the last write.
    public var duration: TimeInterval { max(0, lastModified.timeIntervalSince(startedAt)) }
    public var frames: File? { files.first { $0.kind == .frames } }
}

/// Lists and deletes recordings. Every access opens the folder without
/// following symlinks and touches only regular files named like a recording.
public struct DiagnosticRecordingStore: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }

    public var directory: URL { DiagnosticsStorage.directory(dataRoot: dataRoot) }

    /// Newest first. A missing or unreadable folder lists as empty.
    public func list() -> [DiagnosticRecording] {
        let fd = DiagnosticsStorage.open(dataRoot: dataRoot, create: false)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var grouped = [String: [DiagnosticRecording.File]]()
        for entry in Self.recordingFiles(in: fd) {
            grouped[entry.stem, default: []].append(DiagnosticRecording.File(
                kind: entry.kind, url: directory.appendingPathComponent(entry.name),
                bytes: entry.bytes, modified: entry.modified))
        }
        let order = DiagnosticRecording.FileKind.allCases
        return grouped.compactMap { stem, files -> DiagnosticRecording? in
            guard let name = Self.parse(stem: stem) else { return nil }
            return DiagnosticRecording(
                id: stem, profileName: name.profile, startedAt: name.startedAt,
                files: files.sorted {
                    (order.firstIndex(of: $0.kind)!, $0.id) < (order.firstIndex(of: $1.kind)!, $1.id)
                })
        }
        .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }

    /// Removes every file of one recording, including any written since it was listed.
    public func delete(_ recording: DiagnosticRecording) throws {
        _ = try remove { stem, _ in stem == recording.id }
    }

    /// Removes every recording except `keeping` (a session still being
    /// written) and returns how many files went. Other files stay.
    @discardableResult
    public func deleteAll(keeping: Set<String> = []) throws -> Int {
        try remove { stem, _ in !keeping.contains(stem) }
    }

    /// The largest saved game log `gameLogText(named:)` reads: many times
    /// the size of an excerpt.
    static let maximumGameLogBytes = 1 << 20

    /// Where a saved excerpt of a game's own log is, by file name; nil when
    /// the name is not that of one in this folder.
    public func gameLogFile(named name: String) -> URL? {
        guard !name.contains("/"), let parsed = Self.parse(fileName: name), parsed.kind == .gameLog,
              Self.parse(stem: parsed.stem) != nil else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// A saved excerpt of a game's own log, by file name; nil when it is
    /// gone or the name is not that of one in this folder.
    public func gameLogText(named name: String) -> String? {
        guard gameLogFile(named: name) != nil else { return nil }
        let folder = DiagnosticsStorage.open(dataRoot: dataRoot, create: false)
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.maximumGameLogBytes,
              let data = try? handle.read(upToCount: Self.maximumGameLogBytes + 1) ?? Data(),
              data.count <= Self.maximumGameLogBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes the oldest excerpts of a game's own log that are all a
    /// launch left, keeping the newest `limit`, and returns how many went.
    /// The app saves one after every session; recordings the person turned
    /// on keep theirs until they are deleted.
    @discardableResult
    public func removeGameLogs(keeping limit: Int) throws -> Int {
        let old = Set(list().filter { $0.files.allSatisfy { $0.kind == .gameLog } }
            .dropFirst(max(0, limit)).map(\.id))
        guard !old.isEmpty else { return 0 }
        return try remove { stem, kind in kind == .gameLog && old.contains(stem) }
    }

    private func remove(where matches: (_ stem: String, _ kind: DiagnosticRecording.FileKind) -> Bool) throws -> Int {
        let fd = DiagnosticsStorage.open(dataRoot: dataRoot, create: false)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var removed = 0
        for entry in Self.recordingFiles(in: fd) where matches(entry.stem, entry.kind) {
            if unlinkat(fd, entry.name, 0) == 0 {
                removed += 1
            } else if errno != ENOENT {
                throw BottleToolError(
                    "Could not delete \(entry.name): \(String(cString: strerror(errno)))")
            }
        }
        return removed
    }

    private struct Entry {
        let name: String
        let stem: String
        let kind: DiagnosticRecording.FileKind
        let bytes: Int64
        let modified: Date
    }

    /// Regular files in the open folder whose names belong to a recording.
    /// Symlinks, folders and unrelated files are left out.
    private static func recordingFiles(in directory: Int32) -> [Entry] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(stream) }
        var entries = [Entry]()
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard let parsed = parse(fileName: name), parse(stem: parsed.stem) != nil else { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970:
                Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            entries.append(Entry(name: name, stem: parsed.stem, kind: parsed.kind,
                                 bytes: Int64(info.st_size), modified: modified))
        }
        return entries
    }

    /// Splits a file name into the recording's name and the kind of file.
    /// Longer endings first: `.hevc.index.csv` is a video index, not a frame CSV.
    static func parse(fileName: String) -> (stem: String, kind: DiagnosticRecording.FileKind)? {
        let codecs = VideoCodec.allCases.map(\.rawValue)
        let endings: [(String, DiagnosticRecording.FileKind)] =
            codecs.map { (".\($0).index.csv", .videoIndex) }
            + [(".console.log", .sessionLog), (".game.log", .gameLog), (".csv", .frames)]
            + codecs.map { (".\($0)", .video) }
        for (ending, kind) in endings where fileName.hasSuffix(ending) {
            let stem = String(fileName.dropLast(ending.count))
            return stem.isEmpty ? nil : (stem, kind)
        }
        return nil
    }

    /// `20250101T000000.000000Z-<profile>`, as `FrameTraceSession` names a launch.
    static func parse(stem: String) -> (startedAt: Date, profile: String)? {
        let stampLength = 23
        let characters = Array(stem.utf8)
        guard characters.count > stampLength + 1, characters[stampLength] == UInt8(ascii: "-"),
              characters[8] == UInt8(ascii: "T"), characters[15] == UInt8(ascii: "."),
              characters[22] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in characters[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
              let micros = number(16..<22) else { return nil }
        let profile = String(decoding: characters[(stampLength + 1)...], as: UTF8.self)
        guard (try? BottleName.validate(profile, kind: "profile name")) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
            return nil
        }
        return (date.addingTimeInterval(Double(micros) / 1_000_000), profile)
    }
}
