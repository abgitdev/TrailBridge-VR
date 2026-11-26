import XCTest
@testable import BasaltManagerKit

final class LearningReturnReminderTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session that began at `began`; one that streamed ended an hour later.
    private func session(at began: Date, streamed: Bool = true, ended: Bool = true) -> SessionRecord {
        var record = SessionRecord(profileName: "BRUTALISTICK VR", settings: StreamLaunchSettings(),
                                   startedAt: began)
        if streamed { record.streamingStartedAt = began.addingTimeInterval(60) }
        if ended { record.endedAt = began.addingTimeInterval(streamed ? 3600 : 90) }
        record.outcome = streamed ? .stopped : .failed
        return record
    }

    /// Play is offered and one game ended an hour after `start`.
    private func reminder(_ change: (inout LearningReturnReminder) -> Void = { _ in }) -> LearningReturnReminder {
        var reminder = LearningReturnReminder()
        reminder.sessionHistory = [session(at: start)]
        reminder.playOffered = true
        change(&reminder)
        return reminder
    }

    private var lastPlayed: Date { start.addingTimeInterval(3600) }

    func testABreakIsLongerThanTwentyOneDays() {
        XCTAssertEqual(LearningReturnReminder.breakDays, 21)
        let reminder = reminder()
        XCTAssertFalse(reminder.isDue(now: lastPlayed.addingTimeInterval(day)))
        XCTAssertFalse(reminder.isDue(now: lastPlayed.addingTimeInterval(20 * day)))
        // Exactly 21 days is not "more than".
        XCTAssertFalse(reminder.isDue(now: lastPlayed.addingTimeInterval(21 * day)))
        XCTAssertTrue(reminder.isDue(now: lastPlayed.addingTimeInterval(21 * day + 1)))
        XCTAssertTrue(reminder.isDue(now: lastPlayed.addingTimeInterval(200 * day)))
        // A clock set back shows nothing.
        XCTAssertFalse(reminder.isDue(now: lastPlayed.addingTimeInterval(-30 * day)))
    }

    /// Only a session that reached streaming is "played".
    func testOnlySessionsThatStreamedCount() {
        let old = session(at: start)
        let failedYesterday = session(at: start.addingTimeInterval(29 * day), streamed: false)
        XCTAssertEqual(LearningReturnReminder.lastPlayed(in: [failedYesterday, old]), lastPlayed)
        XCTAssertNil(LearningReturnReminder.lastPlayed(in: [failedYesterday]))
        XCTAssertNil(LearningReturnReminder.lastPlayed(in: []))

        let now = start.addingTimeInterval(30 * day)
        XCTAssertTrue(reminder { $0.sessionHistory = [failedYesterday, old] }.isDue(now: now))
        // Nobody who never played is reminded.
        XCTAssertFalse(reminder { $0.sessionHistory = [failedYesterday] }.isDue(now: now))
        XCTAssertFalse(reminder { $0.sessionHistory = [] }.isDue(now: now))
    }

    func testTheLatestStreamedSessionCountsWhateverTheOrder() {
        let old = session(at: start)
        let recent = session(at: start.addingTimeInterval(25 * day))
        let now = start.addingTimeInterval(30 * day)
        for history in [[old, recent], [recent, old]] {
            XCTAssertEqual(LearningReturnReminder.lastPlayed(in: history),
                           start.addingTimeInterval(25 * day + 3600))
            XCTAssertFalse(reminder { $0.sessionHistory = history }.isDue(now: now))
        }
        // A session whose end was never recorded counts from its streaming start.
        let unfinished = session(at: start, ended: false)
        XCTAssertEqual(LearningReturnReminder.lastPlayed(in: [unfinished]), start.addingTimeInterval(60))
    }

    /// The line belongs where Play is pressed, and never beside a hint.
    func testNothingIsShownWithoutPlayOrBesideAHintOrWithDamagedProgress() {
        let now = start.addingTimeInterval(30 * day)
        XCTAssertTrue(reminder().isDue(now: now))
        XCTAssertFalse(reminder { $0.playOffered = false }.isDue(now: now))
        XCTAssertFalse(reminder { $0.stripTaken = true }.isDue(now: now))
        // An answer could not be remembered: it would come back every launch.
        XCTAssertFalse(reminder { $0.progressDamaged = true }.isDue(now: now))
    }

    func testAnAnsweredReminderStaysAwayUntilTheNextBreak() {
        let answered = start.addingTimeInterval(30 * day)
        var reminder = reminder { $0.answeredAt = answered }
        // Answered, and still not played: it does not come back.
        XCTAssertFalse(reminder.isDue(now: answered.addingTimeInterval(60)))
        XCTAssertFalse(reminder.isDue(now: answered.addingTimeInterval(300 * day)))
        // A launch that failed is not a game either.
        reminder.sessionHistory.insert(session(at: answered.addingTimeInterval(day), streamed: false), at: 0)
        XCTAssertFalse(reminder.isDue(now: answered.addingTimeInterval(300 * day)))

        // A game reaches the headset again...
        let played = answered.addingTimeInterval(2 * day)
        reminder.sessionHistory.insert(session(at: played), at: 0)
        XCTAssertFalse(reminder.isDue(now: played.addingTimeInterval(3 * day)))
        XCTAssertFalse(reminder.isDue(now: played.addingTimeInterval(21 * day)))
        // ...and the next such break gets its own line.
        XCTAssertTrue(reminder.isDue(now: played.addingTimeInterval(22 * day)))
    }

    /// An answer older than the last game belongs to an earlier break.
    func testAnAnswerFromAnEarlierBreakDoesNotHideTheLine() {
        let reminder = reminder { $0.answeredAt = start.addingTimeInterval(-40 * day) }
        XCTAssertTrue(reminder.isDue(now: start.addingTimeInterval(30 * day)))
    }

    func testTheLineReadsAsAgreed() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(LearningReturnReminder.text, "Been a while? I'll show you how to start VR")
        XCTAssertEqual(LearningReturnReminder.showTitle, "Show")
        XCTAssertEqual(LearningReturnReminder.closeTitle, "Close")
        for language in AppLanguage.allCases {
            L10n.language = language
            XCTAssertFalse(LearningReturnReminder.text.isEmpty, "\(language)")
            XCTAssertFalse(LearningReturnReminder.text.contains("%"), "\(language)")
        }
    }
}
