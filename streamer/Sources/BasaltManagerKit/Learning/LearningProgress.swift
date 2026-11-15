import Foundation

/// What the Learning section remembers about the quick path: that it was
/// completed, and when it last was.
public struct LearningProgress: Codable, Equatable, Sendable {
    public var quickPathCompleted = false
    public var quickPathLastCompletedAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quickPathCompleted = try container.decodeIfPresent(Bool.self, forKey: .quickPathCompleted) ?? false
        quickPathLastCompletedAt = try container.decodeIfPresent(Date.self, forKey: .quickPathLastCompletedAt)
    }
}

/// What is remembered about one chapter.
public struct LearningChapterRecord: Codable, Equatable, Sendable {
    /// When the chapter was walked to its end.
    public var completedAt: Date?
    /// The step the chapter stopped at, by its name; nil when it is not
    /// under way. A name this version does not know starts the chapter over.
    public var pausedStep: String?

    public init(completedAt: Date? = nil, pausedStep: String? = nil) {
        self.completedAt = completedAt
        self.pausedStep = pausedStep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        pausedStep = try container.decodeIfPresent(String.self, forKey: .pausedStep)
    }
}

/// The chapters' records, by chapter name. Names this version does not know
/// are kept as they are and written back.
public struct LearningChapterRecords: Codable, Equatable, Sendable {
    private var records = [String: LearningChapterRecord]()

    public init() {}

    public init(from decoder: Decoder) throws {
        records = try decoder.singleValueContainer().decode([String: LearningChapterRecord].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(records)
    }

    public subscript(chapter: LearningChapter) -> LearningChapterRecord {
        get { records[chapter.rawValue] ?? LearningChapterRecord() }
        set { records[chapter.rawValue] = newValue == LearningChapterRecord() ? nil : newValue }
    }
}

/// The answer to the first-launch invitation.
public struct LearningFirstRunRecord: Codable, Equatable, Sendable {
    public enum Answer: String, Codable, Sendable { case start, later }

    public var answer: Answer
    public var answeredAt: Date

    public init(answer: Answer, answeredAt: Date) {
        self.answer = answer
        self.answeredAt = answeredAt
    }
}

/// What is remembered about the line the Stream page shows after a long
/// break.
public struct LearningReturnReminderRecord: Codable, Equatable, Sendable {
    /// When the line was last answered: used or closed.
    public var answeredAt: Date

    public init(answeredAt: Date) {
        self.answeredAt = answeredAt
    }
}

/// Learning progress in its own file, `.local/config/learning.json`, through
/// its own `WorkspacePreferences`, so the manager's preferences file is never
/// rewritten for it. A damaged file reads as "nothing completed".
///
/// The app keeps one store, on the main thread, for every write: each write
/// saves all the keys this store read or set, so a second store on the same
/// file would bring back what the first one has since changed.
///
/// The quick path's record stays under its first key, "progress". The
/// chapters, the invitation and the reminder after a break have their own
/// keys beside it, so a version of the app that does not know a key carries
/// it over untouched.
public final class LearningProgressStore {
    public static let fileName = "learning.json"
    private static let key = "progress"
    private static let chaptersKey = "chapters.v1"
    private static let firstRunKey = "firstRun"
    private static let returnReminderKey = "returnReminder"

    private let preferences: WorkspacePreferences
    public private(set) var progress: LearningProgress
    public private(set) var chapters: LearningChapterRecords
    /// Nil until the invitation was answered.
    public private(set) var firstRun: LearningFirstRunRecord?
    /// Nil until the reminder after a break was answered for the first time.
    public private(set) var returnReminder: LearningReturnReminderRecord?

    public init(fileURL: URL) {
        preferences = WorkspacePreferences(fileURL: fileURL)
        progress = preferences.value(forKey: Self.key) ?? LearningProgress()
        chapters = preferences.value(forKey: Self.chaptersKey) ?? LearningChapterRecords()
        firstRun = preferences.value(forKey: Self.firstRunKey)
        returnReminder = preferences.value(forKey: Self.returnReminderKey)
    }

    /// The file beside the manager's preferences, in the same folder.
    public convenience init(configDirectory: URL) {
        self.init(fileURL: configDirectory.appendingPathComponent(Self.fileName))
    }

    public var fileURL: URL { preferences.fileURL }

    /// True when the file exists but could not be read. It is then left as it
    /// is: progress lives in memory until the app quits.
    public var isDamaged: Bool { preferences.loadError != nil }

    // Every write below changes the value in memory even when the file
    // cannot be written, and throws the error for a caller that wants to log
    // it. Each returns only after the file is on disk, so a write made while
    // the app quits is not lost.

    /// Call it when the quick path completes.
    public func recordQuickPathCompleted(at date: Date = Date()) throws {
        progress.quickPathCompleted = true
        progress.quickPathLastCompletedAt = date
        try preferences.set(progress, forKey: Self.key)
    }

    /// The chapter stopped at this step; "Continue" returns to it.
    public func recordChapterPaused(_ chapter: LearningChapter, atStep step: String) throws {
        guard chapters[chapter].pausedStep != step else { return }
        chapters[chapter].pausedStep = step
        try preferences.set(chapters, forKey: Self.chaptersKey)
    }

    /// The chapter was walked to its end: it is no longer under way.
    public func recordChapterCompleted(_ chapter: LearningChapter, at date: Date = Date()) throws {
        chapters[chapter] = LearningChapterRecord(completedAt: date)
        try preferences.set(chapters, forKey: Self.chaptersKey)
    }

    /// The invitation was answered; it is not shown again.
    public func recordFirstRunAnswer(_ answer: LearningFirstRunRecord.Answer, at date: Date = Date()) throws {
        firstRun = LearningFirstRunRecord(answer: answer, answeredAt: date)
        try preferences.set(firstRun, forKey: Self.firstRunKey)
    }

    /// The reminder after a break was used or closed. It stays away until
    /// a game has reached the headset again and another break has passed.
    public func recordReturnReminderAnswered(at date: Date = Date()) throws {
        returnReminder = LearningReturnReminderRecord(answeredAt: date)
        try preferences.set(returnReminder, forKey: Self.returnReminderKey)
    }
}
