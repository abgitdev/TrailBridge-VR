import Foundation

/// The one line the Stream page shows to someone who has not played for a
/// long time: "Been a while? I'll show how to start VR". It opens the quick
/// path. Used or closed, it stays away until a game has reached the headset
/// again and another such break has passed.
///
/// A value: the app fills it from its model and from `learning.json`, and
/// asks `isDue` when the Stream page is drawn. Nothing here reads a clock
/// or a file.
public struct LearningReturnReminder: Equatable, Sendable {
    /// A break is longer than this many days.
    public static let breakDays = 21

    /// Finished sessions.
    public var sessionHistory = [SessionRecord]()
    /// When the line was last used or closed; nil when it never was.
    public var answeredAt: Date?
    /// `learning.json` exists but could not be read: an answer could not be
    /// remembered, so the line would come back at every launch.
    public var progressDamaged = false
    /// Play is on the Stream page now: a game is ready and nothing runs.
    public var playOffered = false
    /// The hint strip is taken: the quick path, a chapter, a topic or
    /// advice is being shown.
    public var stripTaken = false

    public init() {}

    /// When a game last reached the headset: the end of the latest session
    /// that got as far as streaming, or its streaming start when no end was
    /// recorded. Nil when no session ever streamed.
    public static func lastPlayed(in history: [SessionRecord]) -> Date? {
        history.compactMap { record -> Date? in
            guard let streamed = record.streamingStartedAt else { return nil }
            return max(streamed, record.endedAt ?? streamed)
        }.max()
    }

    /// Whether to show the line now.
    public func isDue(now: Date) -> Bool {
        guard playOffered, !stripTaken, !progressDamaged,
              let lastPlayed = Self.lastPlayed(in: sessionHistory) else { return false }
        guard now.timeIntervalSince(lastPlayed) > TimeInterval(Self.breakDays) * 86_400 else { return false }
        // Answered after the last game: this break has had its line.
        if let answeredAt, answeredAt >= lastPlayed { return false }
        return true
    }

    public static var text: String { L10n.string(.learningReturnReminder) }
    /// The button that opens the quick path.
    public static var showTitle: String { L10n.string(.learningProgramShow) }
    /// The name of the line's close control.
    public static var closeTitle: String { L10n.string(.commonClose) }
}
