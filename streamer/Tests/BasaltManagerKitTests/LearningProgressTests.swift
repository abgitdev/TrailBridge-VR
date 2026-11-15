import XCTest
@testable import BasaltManagerKit

final class LearningProgressTests: XCTestCase {
    private func attributes(_ url: URL) throws -> (Data, Date?) {
        (try Data(contentsOf: url),
         try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func testNothingIsCompletedAndNothingIsWrittenBeforeTheFirstCompletion() throws {
        let directory = try temporaryDirectory().appendingPathComponent("config")
        let store = LearningProgressStore(configDirectory: directory)
        XCTAssertEqual(store.fileURL.lastPathComponent, "learning.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(store.progress, LearningProgress())
        XCTAssertFalse(store.progress.quickPathCompleted)
        XCTAssertNil(store.progress.quickPathLastCompletedAt)
        XCTAssertFalse(store.isDamaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCompletionRoundTripsAndKeepsTheLastDate() throws {
        let file = try temporaryDirectory().appendingPathComponent("config/learning.json")
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = Date(timeIntervalSince1970: 1_800_086_400.5)

        let store = LearningProgressStore(fileURL: file)
        try store.recordQuickPathCompleted(at: first)
        XCTAssertTrue(store.progress.quickPathCompleted)
        XCTAssertEqual(store.progress.quickPathLastCompletedAt, first)

        let reopened = LearningProgressStore(fileURL: file)
        XCTAssertFalse(reopened.isDamaged)
        XCTAssertTrue(reopened.progress.quickPathCompleted)
        XCTAssertEqual(reopened.progress.quickPathLastCompletedAt, first)

        try reopened.recordQuickPathCompleted(at: second)
        let again = LearningProgressStore(fileURL: file).progress
        XCTAssertTrue(again.quickPathCompleted)
        XCTAssertEqual(again.quickPathLastCompletedAt, second)
    }

    func testTheManagerPreferencesFileIsNeverTouched() throws {
        let directory = try temporaryDirectory().appendingPathComponent("config")
        let managerFile = directory.appendingPathComponent("manager-preferences.json")
        try WorkspacePreferences(fileURL: managerFile).set("brutalistick-vr", forKey: "profile")
        let before = try attributes(managerFile)

        let store = LearningProgressStore(configDirectory: directory)
        try store.recordQuickPathCompleted(at: Date(timeIntervalSince1970: 1_800_000_000))

        let after = try attributes(managerFile)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(WorkspacePreferences(fileURL: managerFile).string(forKey: "profile"), "brutalistick-vr")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["manager-preferences.json", "learning.json"])
    }

    func testADamagedFileReadsAsNothingCompletedAndIsLeftAlone() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        for damaged in ["{ not json", "", "[1, 2, 3]"] {
            try Data(damaged.utf8).write(to: file)
            let store = LearningProgressStore(fileURL: file)
            XCTAssertTrue(store.isDamaged, damaged)
            XCTAssertEqual(store.progress, LearningProgress(), damaged)

            // Completion still counts until the app quits; the file is kept
            // for recovery and the error is reported to the caller only.
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertThrowsError(try store.recordQuickPathCompleted(at: date), damaged)
            XCTAssertTrue(store.progress.quickPathCompleted)
            XCTAssertEqual(store.progress.quickPathLastCompletedAt, date)
            XCTAssertEqual(try Data(contentsOf: file), Data(damaged.utf8), damaged)
            XCTAssertEqual(LearningProgressStore(fileURL: file).progress, LearningProgress(), damaged)
        }
    }

    func testAReadableFileWithForeignOrBrokenValuesReadsAsNothingCompleted() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")

        // Another key only.
        try WorkspacePreferences(fileURL: file).set("x", forKey: "other")
        XCTAssertEqual(LearningProgressStore(fileURL: file).progress, LearningProgress())
        XCTAssertFalse(LearningProgressStore(fileURL: file).isDamaged)

        // The right key with the wrong shape.
        try WorkspacePreferences(fileURL: file).set(["quickPathCompleted": "yes"], forKey: "progress")
        XCTAssertEqual(LearningProgressStore(fileURL: file).progress, LearningProgress())

        // The right key with a value that is not what the app writes at
        // all: only that entry is lost, the file is not "damaged".
        let other = Data(#""x""#.utf8).base64EncodedString()
        try Data(#"{"progress": 5, "other": "\#(other)"}"#.utf8).write(to: file)
        XCTAssertEqual(LearningProgressStore(fileURL: file).progress, LearningProgress())
        XCTAssertFalse(LearningProgressStore(fileURL: file).isDamaged)
        XCTAssertEqual(WorkspacePreferences(fileURL: file).string(forKey: "other"), "x")

        // A date without the flag is not a completion claim on its own.
        try WorkspacePreferences(fileURL: file).set(["quickPathLastCompletedAt": 0.0], forKey: "progress")
        let store = LearningProgressStore(fileURL: file)
        XCTAssertFalse(store.progress.quickPathCompleted)

        // Such a file is still writable, and the other key survives.
        try store.recordQuickPathCompleted(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(LearningProgressStore(fileURL: file).progress.quickPathCompleted)
        XCTAssertEqual(WorkspacePreferences(fileURL: file).string(forKey: "other"), "x")
    }

    // MARK: - Chapters and the invitation

    func testNoChapterOrInvitationRecordIsThereBeforeItsFirstWrite() throws {
        let store = LearningProgressStore(fileURL: try temporaryDirectory().appendingPathComponent("learning.json"))
        XCTAssertEqual(store.chapters, LearningChapterRecords())
        XCTAssertNil(store.firstRun)
        for chapter in LearningChapter.allCases {
            XCTAssertEqual(store.chapters[chapter], LearningChapterRecord())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The file an older version of the app left: one key, two fields.
    func testAnOldProgressFileReadsAsBeforeAndTakesTheNewKeys() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try JSONSerialization.data(withJSONObject: [
            "quickPathCompleted": true, "quickPathLastCompletedAt": date.timeIntervalSinceReferenceDate,
        ])
        try JSONEncoder().encode(["progress": old]).write(to: file)

        let store = LearningProgressStore(fileURL: file)
        XCTAssertFalse(store.isDamaged)
        XCTAssertTrue(store.progress.quickPathCompleted)
        XCTAssertEqual(store.progress.quickPathLastCompletedAt, date)
        XCTAssertEqual(store.chapters, LearningChapterRecords())
        XCTAssertNil(store.firstRun)

        try store.recordChapterPaused(.game, atStep: "gameWait")
        try store.recordFirstRunAnswer(.start, at: date)
        let reopened = LearningProgressStore(fileURL: file)
        XCTAssertTrue(reopened.progress.quickPathCompleted)
        XCTAssertEqual(reopened.progress.quickPathLastCompletedAt, date)
        XCTAssertEqual(reopened.chapters[.game].pausedStep, "gameWait")
        XCTAssertEqual(reopened.firstRun, LearningFirstRunRecord(answer: .start, answeredAt: date))
    }

    func testChapterRecordsRoundTrip() throws {
        let file = try temporaryDirectory().appendingPathComponent("config/learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let store = LearningProgressStore(fileURL: file)
        try store.recordChapterPaused(.launchOptions, atStep: "optionsConnection")
        try store.recordChapterPaused(.game, atStep: "gameSteam")
        XCTAssertEqual(store.chapters[.launchOptions], LearningChapterRecord(pausedStep: "optionsConnection"))

        // Completing a chapter ends its pause; the other chapter keeps its own.
        try store.recordChapterCompleted(.launchOptions, at: date)
        let reopened = LearningProgressStore(fileURL: file)
        XCTAssertEqual(reopened.chapters[.launchOptions], LearningChapterRecord(completedAt: date))
        XCTAssertEqual(reopened.chapters[.game], LearningChapterRecord(pausedStep: "gameSteam"))
        XCTAssertEqual(reopened.chapters[.mac], LearningChapterRecord())
        XCTAssertNil(reopened.firstRun)
        XCTAssertEqual(reopened.progress, LearningProgress())
    }

    func testTheInvitationAnswerRoundTrips() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try LearningProgressStore(fileURL: file).recordFirstRunAnswer(.later, at: date)
        XCTAssertEqual(LearningProgressStore(fileURL: file).firstRun,
                       LearningFirstRunRecord(answer: .later, answeredAt: date))
    }

    /// One store for every write: the quick path's record, the chapters and
    /// the invitation never wipe one another, in any order.
    func testWritesFromDifferentPlacesLoseNothing() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LearningProgressStore(fileURL: file)
        try store.recordFirstRunAnswer(.start, at: date)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        try store.recordQuickPathCompleted(at: date)
        try store.recordChapterCompleted(.launchOptions, at: date)
        try store.recordChapterPaused(.mac, atStep: "macWhoBuilds")

        for check in [store, LearningProgressStore(fileURL: file)] {
            XCTAssertTrue(check.progress.quickPathCompleted)
            XCTAssertEqual(check.progress.quickPathLastCompletedAt, date)
            XCTAssertEqual(check.firstRun?.answer, .start)
            XCTAssertEqual(check.chapters[.game].pausedStep, "gameWait")
            XCTAssertEqual(check.chapters[.mac].pausedStep, "macWhoBuilds")
            XCTAssertEqual(check.chapters[.launchOptions].completedAt, date)
        }
    }

    /// An older version of the app knows only the "progress" key and writes
    /// through a store of its own, made for that one write. The new keys must
    /// still be there afterwards.
    func testAnOlderVersionsWriteDoesNotWipeTheNewKeys() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LearningProgressStore(fileURL: file)
        try store.recordFirstRunAnswer(.later, at: date)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        try store.recordChapterCompleted(.launchOptions, at: date)

        // What that version does at the end of its quick path, to the letter:
        // its own preferences object, and only its own two fields.
        struct OlderProgress: Codable {
            var quickPathCompleted = true
            var quickPathLastCompletedAt: Date?
        }
        let later = date.addingTimeInterval(3600)
        try WorkspacePreferences(fileURL: file).set(
            OlderProgress(quickPathLastCompletedAt: later), forKey: "progress")

        let reopened = LearningProgressStore(fileURL: file)
        XCTAssertTrue(reopened.progress.quickPathCompleted)
        XCTAssertEqual(reopened.progress.quickPathLastCompletedAt, later)
        XCTAssertEqual(reopened.firstRun, LearningFirstRunRecord(answer: .later, answeredAt: date))
        XCTAssertEqual(reopened.chapters[.game].pausedStep, "gameWait")
        XCTAssertEqual(reopened.chapters[.launchOptions].completedAt, date)

        // The same through this version's own store, made fresh for the write.
        try LearningProgressStore(fileURL: file).recordQuickPathCompleted(at: date)
        let again = LearningProgressStore(fileURL: file)
        XCTAssertEqual(again.progress.quickPathLastCompletedAt, date)
        XCTAssertEqual(again.firstRun?.answer, .later)
        XCTAssertEqual(again.chapters[.game].pausedStep, "gameWait")
    }

    func testTheNewKeysLieBesideTheOldOne() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let store = LearningProgressStore(fileURL: file)
        try store.recordQuickPathCompleted(at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.recordChapterPaused(.game, atStep: "gameWait")
        try store.recordFirstRunAnswer(.start, at: Date(timeIntervalSince1970: 1_800_000_000))
        let keys = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file)).keys
        XCTAssertEqual(Set(keys), ["progress", "chapters.v1", "firstRun"])
    }

    /// A chapter of a later version is carried over, not dropped.
    func testAChapterThisVersionDoesNotKnowIsKept() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        try WorkspacePreferences(fileURL: file).set(
            ["audio": LearningChapterRecord(pausedStep: "audioRestart")], forKey: "chapters.v1")
        let store = LearningProgressStore(fileURL: file)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        let saved: [String: LearningChapterRecord] = try XCTUnwrap(
            WorkspacePreferences(fileURL: file).value(forKey: "chapters.v1"))
        XCTAssertEqual(saved, [
            "audio": LearningChapterRecord(pausedStep: "audioRestart"),
            "game": LearningChapterRecord(pausedStep: "gameWait"),
        ])
    }

    func testBrokenNewKeysReadAsNothingAndTheOldKeyStillReads() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let preferences = WorkspacePreferences(fileURL: file)
        try preferences.set(LearningProgress(), forKey: "progress")
        try preferences.set("not a dictionary", forKey: "chapters.v1")
        try preferences.set(["answer": "maybe"], forKey: "firstRun")
        let store = LearningProgressStore(fileURL: file)
        XCTAssertFalse(store.isDamaged)
        XCTAssertEqual(store.chapters, LearningChapterRecords())
        XCTAssertNil(store.firstRun)
        // Such a file is still writable.
        try store.recordChapterPaused(.mac, atStep: "macSummary")
        XCTAssertEqual(LearningProgressStore(fileURL: file).chapters[.mac].pausedStep, "macSummary")
    }

    func testADamagedFileKeepsTheNewRecordsInMemoryOnly() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        try Data("{ not json".utf8).write(to: file)
        let store = LearningProgressStore(fileURL: file)
        XCTAssertTrue(store.isDamaged)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try store.recordChapterPaused(.game, atStep: "gameWait"))
        XCTAssertThrowsError(try store.recordChapterCompleted(.launchOptions, at: date))
        XCTAssertThrowsError(try store.recordFirstRunAnswer(.later, at: date))
        XCTAssertEqual(store.chapters[.game].pausedStep, "gameWait")
        XCTAssertEqual(store.chapters[.launchOptions].completedAt, date)
        XCTAssertEqual(store.firstRun?.answer, .later)
        XCTAssertEqual(try Data(contentsOf: file), Data("{ not json".utf8))
    }

    /// The write is on disk when the call returns: nothing is left for a
    /// background task that a quitting app would not wait for.
    func testEveryWriteIsOnDiskWhenItReturns() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let store = LearningProgressStore(fileURL: file)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        let saved: [String: LearningChapterRecord] = try XCTUnwrap(
            WorkspacePreferences(fileURL: file).value(forKey: "chapters.v1"))
        XCTAssertEqual(saved["game"]?.pausedStep, "gameWait")
        // The same step again writes nothing.
        let before = try attributes(file)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        let after = try attributes(file)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    // MARK: - The reminder after a break

    func testNoReminderAnswerIsThereBeforeItsFirstWrite() throws {
        let store = LearningProgressStore(fileURL: try temporaryDirectory().appendingPathComponent("learning.json"))
        XCTAssertNil(store.returnReminder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The answer lives in `learning.json` under its own key: no new file.
    func testTheReminderAnswerRoundTripsInTheSameFile() throws {
        let directory = try temporaryDirectory().appendingPathComponent("config")
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = Date(timeIntervalSince1970: 1_803_000_000.5)
        let store = LearningProgressStore(configDirectory: directory)
        try store.recordReturnReminderAnswered(at: first)
        XCTAssertEqual(store.returnReminder, LearningReturnReminderRecord(answeredAt: first))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["learning.json"])
        let keys = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: store.fileURL)).keys
        XCTAssertEqual(Set(keys), ["returnReminder"])

        let reopened = LearningProgressStore(configDirectory: directory)
        XCTAssertEqual(reopened.returnReminder?.answeredAt, first)
        // The next break's answer replaces it.
        try reopened.recordReturnReminderAnswered(at: second)
        XCTAssertEqual(LearningProgressStore(configDirectory: directory).returnReminder?.answeredAt, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["learning.json"])
    }

    /// The reminder's answer and the older records (quick path, chapters,
    /// invitation) never wipe one another, whichever is written first and by
    /// whichever store.
    func testTheReminderAnswerAndTheOlderRecordsKeepOneAnother() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LearningProgressStore(fileURL: file)
        try store.recordQuickPathCompleted(at: date)
        try store.recordChapterPaused(.game, atStep: "gameWait")
        try store.recordFirstRunAnswer(.start, at: date)
        try store.recordReturnReminderAnswered(at: date)
        try store.recordChapterCompleted(.launchOptions, at: date)

        for check in [store, LearningProgressStore(fileURL: file)] {
            XCTAssertEqual(check.returnReminder?.answeredAt, date)
            XCTAssertTrue(check.progress.quickPathCompleted)
            XCTAssertEqual(check.firstRun?.answer, .start)
            XCTAssertEqual(check.chapters[.game].pausedStep, "gameWait")
            XCTAssertEqual(check.chapters[.launchOptions].completedAt, date)
        }
        let keys = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file)).keys
        XCTAssertEqual(Set(keys), ["progress", "chapters.v1", "firstRun", "returnReminder"])

        // A version that does not know the key writes through its own
        // preferences object: the answer is still there afterwards.
        try WorkspacePreferences(fileURL: file).set(LearningProgress(), forKey: "progress")
        XCTAssertEqual(LearningProgressStore(fileURL: file).returnReminder?.answeredAt, date)
    }

    func testABrokenReminderAnswerReadsAsNoneAndADamagedFileKeepsItInMemory() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        try WorkspacePreferences(fileURL: file).set(["answeredAt": "yesterday"], forKey: "returnReminder")
        let store = LearningProgressStore(fileURL: file)
        XCTAssertFalse(store.isDamaged)
        XCTAssertNil(store.returnReminder)

        let damagedFile = try temporaryDirectory().appendingPathComponent("learning.json")
        try Data("{ not json".utf8).write(to: damagedFile)
        let damaged = LearningProgressStore(fileURL: damagedFile)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try damaged.recordReturnReminderAnswered(at: date))
        XCTAssertEqual(damaged.returnReminder?.answeredAt, date)
        XCTAssertEqual(try Data(contentsOf: damagedFile), Data("{ not json".utf8))
    }
}
