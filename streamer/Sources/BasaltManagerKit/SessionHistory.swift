import Foundation

/// Running count, mean, and range of one metric series. It keeps no samples,
/// so a session of any length summarizes in constant space.
public struct MetricStatistics: Codable, Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var sum = 0.0
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?

    public init() {}

    public init<Values: Sequence>(_ values: Values) where Values.Element == Double {
        values.forEach { add($0) }
    }

    public var average: Double? { count > 0 ? sum / Double(count) : nil }

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        sum += value
        minimum = Swift.min(minimum ?? value, value)
        maximum = Swift.max(maximum ?? value, value)
    }
}

/// Whole-session aggregates of the dashboard series. The dashboard itself
/// keeps only a recent window, so history and diagnostics use this instead.
public struct StreamMetricSummary: Codable, Equatable, Sendable {
    /// A Quest FPS report below this fraction of the target counts as low.
    public static let lowFrameRateFraction = 0.9

    public var fps = MetricStatistics()
    public var megabits = MetricStatistics()
    public var latencyMilliseconds = MetricStatistics()
    /// Quest FPS reports below `lowFrameRateFraction` of the target rate.
    public var lowFrameRateSamples = 0

    public init() {}

    public init(samples: [StreamMetricSample], targetFPS: Int) {
        for sample in samples { add(sample, targetFPS: targetFPS) }
    }

    public var isEmpty: Bool {
        fps.count == 0 && megabits.count == 0 && latencyMilliseconds.count == 0
    }

    /// Share of Quest FPS reports that fell below the target, if any arrived.
    public var lowFrameRateShare: Double? {
        fps.count > 0 ? Double(lowFrameRateSamples) / Double(fps.count) : nil
    }

    public mutating func add(_ sample: StreamMetricSample, targetFPS: Int) {
        if let value = sample.fps, value.isFinite {
            fps.add(value)
            if targetFPS > 0, value < Double(targetFPS) * Self.lowFrameRateFraction {
                lowFrameRateSamples += 1
            }
        }
        if let value = sample.megabits { megabits.add(value) }
        if let value = sample.latencyMilliseconds { latencyMilliseconds.add(value) }
    }
}

/// One VR session the manager launched, kept for the Stream page's history
/// and for diagnostic reports.
public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The game exited on its own.
        case ended
        /// The user stopped the session.
        case stopped
        /// Startup or the streamer failed; `failureReason` says why.
        case failed
    }

    public let id: UUID
    public var profileName: String
    public var settings: StreamLaunchSettings
    public var startedAt: Date
    /// When the game was launched against a ready streamer; nil if startup
    /// never got that far.
    public var streamingStartedAt: Date?
    public var endedAt: Date?
    public var outcome: Outcome?
    public var failureReason: String?
    public var metrics: StreamMetricSummary
    /// The excerpt of the game's own log saved for this session: a file name
    /// in the data folder's `Diagnostics` folder, set once the game has
    /// ended; nil when none was saved.
    public var gameLog: String?
    /// The hints for known errors in the session's logs (`KnownErrorHint`),
    /// as the session log gives them, set once the game's log has been
    /// read; nil when there were none.
    public var hints: [String]?

    public init(id: UUID = UUID(), profileName: String,
                settings: StreamLaunchSettings, startedAt: Date = Date()) {
        self.id = id
        self.profileName = profileName
        self.settings = settings
        self.startedAt = startedAt
        metrics = StreamMetricSummary()
    }

    /// Time spent streaming, excluding Steam and streamer startup.
    public var streamingDuration: TimeInterval? {
        guard let streamingStartedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(streamingStartedAt))
    }
}

/// Persists recent `SessionRecord`s as JSON in the Basalt data root, newest
/// first. History is advisory for reading: a file that cannot be read shows
/// as empty, and records from an incompatible future format are skipped
/// individually rather than discarding the rest. Writing never destroys what
/// is there: a file that could not be read at that moment is left alone (the
/// new record is not saved), a file that is not a history is set aside as
/// `SessionHistory.damaged-<time>.json` before a new one is started, and a
/// file written by a newer version of the app is not written over.
public struct SessionHistoryStore: Sendable {
    public static let defaultLimit = 50
    public static let fileName = "SessionHistory.json"

    /// Why nothing was saved. The file is as it was.
    public enum Failure: LocalizedError, Equatable {
        /// The file is there and could not be read: no permission, a folder
        /// at its path, a read error on a share.
        case unreadable(String)
        /// The file has a newer `formatVersion` than this app writes.
        case newerFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): L10n.string(.historyUnreadable, SessionHistoryStore.fileName, why)
            case .newerFormat: L10n.string(.historyNewerFormat, SessionHistoryStore.fileName)
            }
        }
    }

    public let file: URL
    public let limit: Int
    /// False for the history in a data folder: that folder is never created
    /// here, since one made in place of a disk that is not connected would
    /// hide the real folder when the disk comes back.
    private let createsFolder: Bool

    /// A history in a file of the caller's own; its folder is created on saving.
    public init(file: URL, limit: Int = defaultLimit) {
        self.file = file
        self.limit = max(1, limit)
        createsFolder = true
    }

    /// The app's history, `SessionHistory.json` in its data folder. Saving
    /// fails when the data folder is not there.
    public init(dataRoot: URL, limit: Int = defaultLimit) {
        file = dataRoot.appendingPathComponent(Self.fileName)
        self.limit = max(1, limit)
        createsFolder = false
    }

    public func load() -> [SessionRecord] {
        guard case .document(let document)? = try? contents() else { return [] }
        return Array(document.sessions.compactMap(\.value).prefix(limit))
    }

    /// Prepends `record` (replacing an older copy with the same ID) and
    /// returns the saved history. Throws `Failure` without touching the file
    /// when it cannot be read or is of a newer format. `setAside` is told
    /// where a damaged file went.
    @discardableResult
    public func append(_ record: SessionRecord,
                       setAside: (URL) -> Void = { _ in }) throws -> [SessionRecord] {
        let earlier = try recordsToKeep(setAside: setAside)
        return try write([record] + earlier.filter { $0.id != record.id })
    }

    /// Replaces the history with `records`, under the same rules as `append`.
    @discardableResult
    public func save(_ records: [SessionRecord],
                     setAside: (URL) -> Void = { _ in }) throws -> [SessionRecord] {
        _ = try recordsToKeep(setAside: setAside)
        return try write(records)
    }

    /// Changes the saved record with `id` where it stands and returns the
    /// saved history. A history without that record, a missing or damaged
    /// file included, is left as it is; one of a newer format throws, as in
    /// `append`.
    @discardableResult
    public func update(_ id: UUID, _ change: (inout SessionRecord) -> Void) throws -> [SessionRecord] {
        guard case .document(let document) = try contents() else { return [] }
        guard document.formatVersion <= Document.currentFormatVersion else {
            throw Failure.newerFormat(document.formatVersion)
        }
        var records = document.sessions.compactMap(\.value)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return Array(records.prefix(limit))
        }
        change(&records[index])
        return try write(records)
    }

    private enum Contents {
        /// No file: no session was recorded yet.
        case missing
        case document(Document)
        /// Bytes that were read and are not a history.
        case damaged
    }

    private func contents() throws -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
            throw Failure.unreadable(error.localizedDescription)
        }
        guard let document = try? Self.decoder.decode(Document.self, from: data) else { return .damaged }
        return .document(document)
    }

    /// What the file holds now, once it is certain that writing loses nothing.
    private func recordsToKeep(setAside: (URL) -> Void) throws -> [SessionRecord] {
        switch try contents() {
        case .missing:
            return []
        case .document(let document):
            guard document.formatVersion <= Document.currentFormatVersion else {
                throw Failure.newerFormat(document.formatVersion)
            }
            return document.sessions.compactMap(\.value)
        case .damaged:
            setAside(try DamagedFile.setAside(file))
            return []
        }
    }

    private func write(_ records: [SessionRecord]) throws -> [SessionRecord] {
        let kept = Array(records.prefix(limit))
        if createsFolder {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let document = Document(
            formatVersion: Document.currentFormatVersion,
            sessions: kept.map { Lossy(value: $0) })
        try Self.encoder.encode(document).write(to: file, options: .atomic)
        return kept
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private struct Document: Codable {
        static let currentFormatVersion = 1
        var formatVersion: Int
        var sessions: [Lossy<SessionRecord>]
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A record says what a past session used; it is never migrated.
        decoder.userInfo[StreamLaunchSettings.recordedSessionKey] = true
        return decoder
    }
}

/// Decodes to nil instead of failing the enclosing array.
private struct Lossy<Value: Codable>: Codable {
    let value: Value?

    init(value: Value) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// The dashboard series as CSV, for comparing runs in a spreadsheet.
public enum StreamMetricCSV {
    public static let header = "timestamp,quest_fps,wire_mbps,input_to_display_ms"

    public static func render(_ samples: [StreamMetricSample]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [header]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples {
            lines.append([
                formatter.string(from: sample.date),
                cell(sample.fps),
                cell(sample.megabits),
                cell(sample.latencyMilliseconds),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }
}
