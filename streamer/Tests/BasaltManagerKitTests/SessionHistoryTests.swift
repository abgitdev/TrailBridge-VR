import XCTest
@testable import BasaltManagerKit

final class SessionHistoryTests: XCTestCase {
    func testSummaryAggregatesEverySeriesAndCountsLowFrameRates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            StreamMetricSample(date: start, fps: 72),
            StreamMetricSample(date: start, megabits: 30),
            StreamMetricSample(date: start, fps: 60, latencyMilliseconds: 50),
            StreamMetricSample(date: start, fps: 66, latencyMilliseconds: 70),
            StreamMetricSample(date: start, fps: .nan),
        ]

        let summary = StreamMetricSummary(samples: samples, targetFPS: 72)

        XCTAssertEqual(summary.fps.count, 3)
        XCTAssertEqual(summary.fps.average, 66)
        XCTAssertEqual(summary.fps.minimum, 60)
        XCTAssertEqual(summary.fps.maximum, 72)
        // 60 is below 0.9 × 72 = 64.8; 66 is not.
        XCTAssertEqual(summary.lowFrameRateSamples, 1)
        XCTAssertEqual(try XCTUnwrap(summary.lowFrameRateShare), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(summary.megabits.average, 30)
        XCTAssertEqual(summary.latencyMilliseconds.average, 60)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(StreamMetricSummary().isEmpty)
        XCTAssertNil(StreamMetricSummary().fps.average)
    }

    func testStreamingDurationExcludesStartup() {
        var record = SessionRecord(
            profileName: "beat-saber", settings: StreamLaunchSettings(),
            startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(record.streamingDuration)
        record.streamingStartedAt = Date(timeIntervalSince1970: 130)
        record.endedAt = Date(timeIntervalSince1970: 730)
        XCTAssertEqual(record.streamingDuration, 600)
    }

    func testStorePrependsCapsAndRoundTrips() throws {
        let store = SessionHistoryStore(
            file: try temporaryDirectory().appendingPathComponent("nested/history.json"),
            limit: 3)
        XCTAssertEqual(store.load(), [])

        var records = [SessionRecord]()
        for index in 0..<5 {
            var record = SessionRecord(
                profileName: "game-\(index)", settings: StreamLaunchSettings(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)))
            record.outcome = .stopped
            record.metrics.add(StreamMetricSample(fps: 72), targetFPS: 72)
            records.append(record)
            try store.append(record)
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.profileName), ["game-4", "game-3", "game-2"])
        XCTAssertEqual(loaded.first, records[4])

        var updated = records[4]
        updated.outcome = .ended
        XCTAssertEqual(try store.append(updated).map(\.profileName), ["game-4", "game-3", "game-2"])
        XCTAssertEqual(store.load().first?.outcome, .ended)

        try store.clear()
        XCTAssertEqual(store.load(), [])
        try store.clear()
    }

    func testUpdateChangesOneRecordWhereItStands() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.json")
        let store = SessionHistoryStore(file: file)
        // Nothing to change in a history that is not there, and none is made.
        XCTAssertEqual(try store.update(UUID()) { $0.outcome = .ended }, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let older = SessionRecord(profileName: "older", settings: StreamLaunchSettings(),
                                  startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = SessionRecord(profileName: "newer", settings: StreamLaunchSettings(),
                                  startedAt: Date(timeIntervalSince1970: 1_800_000_100))
        try store.append(older)
        try store.append(newer)

        // The game log of the older session is saved after the newer one started.
        let updated = try store.update(older.id) { $0.gameLog = "20270115T080000.000000Z-older.game.log" }
        XCTAssertEqual(updated.map(\.profileName), ["newer", "older"])
        XCTAssertEqual(store.load().last?.gameLog, "20270115T080000.000000Z-older.game.log")
        XCTAssertNil(store.load().first?.gameLog)
        // A session the history no longer has stays out of it.
        XCTAssertEqual(try store.update(UUID()) { $0.gameLog = "x" }.map(\.profileName), ["newer", "older"])
        XCTAssertEqual(store.load(), updated)

        // Written by a newer app: left alone.
        try Data(#"{"formatVersion": 99, "sessions": []}"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.update(older.id) { $0.outcome = .ended }) {
            XCTAssertEqual($0 as? SessionHistoryStore.Failure, .newerFormat(99))
        }
    }

    func testStoreSkipsUnreadableRecordsAndToleratesCorruptFiles() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.json")
        let store = SessionHistoryStore(file: file)
        // History stores whole-second ISO 8601 dates.
        var record = SessionRecord(
            profileName: "kept", settings: StreamLaunchSettings(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        record.outcome = .failed
        record.failureReason = "Steam is open but not signed in."
        try store.append(record)

        // A record from a future format must not discard the readable ones.
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(
            of: #""sessions" : ["#,
            with: #""sessions" : [ { "id" : "not-a-uuid", "outcome" : "teleported" },"#)
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [record])

        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(try store.append(record), [record])
    }

    // MARK: - A history file that cannot be read is never replaced

    private func record(_ name: String) -> SessionRecord {
        var record = SessionRecord(
            profileName: name, settings: StreamLaunchSettings(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        record.outcome = .ended
        return record
    }

    private func setAsideCopies(of store: SessionHistoryStore) throws -> [URL] {
        let folder = store.file.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { DamagedFile.isSetAside($0, of: store.file.lastPathComponent) }
            .map { folder.appendingPathComponent($0) }
    }

    func testAMissingFileIsAnEmptyHistory() throws {
        let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(try store.append(record("first")).map(\.profileName), ["first"])
        XCTAssertEqual(try setAsideCopies(of: store), [])
    }

    /// Three sessions on disk, and the file cannot be read at the moment a
    /// fourth ends: the fourth is not saved, the three are not lost.
    func testAHistoryThatCannotBeReadRightNowIsLeftAloneAndTheRecordIsNotSaved() throws {
        let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
        try store.save([record("a"), record("b"), record("c")])
        let bytes = try Data(contentsOf: store.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path) }

        XCTAssertEqual(store.load(), [], "reading is advisory")
        XCTAssertThrowsError(try store.append(record("d"), setAside: { _ in XCTFail("nothing is moved") })) { error in
            guard case SessionHistoryStore.Failure.unreadable = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains(SessionHistoryStore.fileName), error.localizedDescription)
        }
        XCTAssertThrowsError(try store.save([record("d")]))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
        XCTAssertEqual(try Data(contentsOf: store.file), bytes)
        XCTAssertEqual(store.load().map(\.profileName), ["a", "b", "c"])
        XCTAssertEqual(try setAsideCopies(of: store), [])
    }

    func testAFolderAtTheHistorysPathIsLeftAlone() throws {
        let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.append(record("a"))) { error in
            guard case SessionHistoryStore.Failure.unreadable = error else { return XCTFail("\(error)") }
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// Bytes that were read and are not a history: kept under another name,
    /// and a new history is started.
    func testAHistoryThatIsNotOneIsSetAsideBeforeANewOneIsStarted() throws {
        let valid = SessionHistoryStore(dataRoot: try temporaryDirectory())
        try valid.save([record("a"), record("b"), record("c")])
        let withoutVersion = try String(contentsOf: valid.file, encoding: .utf8)
            .replacingOccurrences(of: #""formatVersion" : 1,"#, with: "")
        XCTAssertFalse(withoutVersion.contains("formatVersion"))

        for damaged in ["not json", "", #"{"formatVersion":"one","sessions":"none"}"#, withoutVersion] {
            let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
            try Data(damaged.utf8).write(to: store.file)
            var moved = [URL]()
            let new = record("new")
            XCTAssertEqual(try store.append(new) { moved.append($0) }, [new])
            XCTAssertEqual(store.load(), [new])
            let copies = try setAsideCopies(of: store)
            XCTAssertEqual(copies.map(\.lastPathComponent), moved.map(\.lastPathComponent))
            XCTAssertEqual(copies.count, 1)
            XCTAssertEqual(try Data(contentsOf: copies[0]), Data(damaged.utf8), "the old bytes, untouched")
            XCTAssertTrue(copies[0].lastPathComponent.hasPrefix("SessionHistory.damaged-"))
            XCTAssertTrue(copies[0].lastPathComponent.hasSuffix(".json"))

            // The next session is appended to the new history; nothing more is moved.
            XCTAssertEqual(try store.append(record("next")) { _ in XCTFail() }.count, 2)
            XCTAssertEqual(try setAsideCopies(of: store).count, 1)
        }
    }

    /// A file written by a newer version of the app is shown as far as it
    /// reads, and never written over by this one.
    func testAHistoryOfANewerFormatIsNeverWrittenOver() throws {
        let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
        try store.save([record("a"), record("b")])
        let newer = try String(contentsOf: store.file, encoding: .utf8)
            .replacingOccurrences(of: #""formatVersion" : 1,"#, with: #""formatVersion" : 2, "futureTopLevel" : {"a" : 1},"#)
        XCTAssertTrue(newer.contains("futureTopLevel"))
        try Data(newer.utf8).write(to: store.file)

        XCTAssertEqual(store.load().map(\.profileName), ["a", "b"])
        for write in [{ _ = try store.append(self.record("c")) }, { _ = try store.save([self.record("c")]) }] {
            XCTAssertThrowsError(try write()) { error in
                XCTAssertEqual(error as? SessionHistoryStore.Failure, .newerFormat(2))
                XCTAssertTrue(error.localizedDescription.contains(SessionHistoryStore.fileName))
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.file), Data(newer.utf8))
        XCTAssertEqual(try setAsideCopies(of: store), [])
    }

    /// The history in a data folder never creates that folder: one made in
    /// place of a disk that is not connected would hide the real one.
    func testTheHistoryInADataFolderNeverCreatesThatFolder() throws {
        let root = try temporaryDirectory().appendingPathComponent("disk left/TrailBridge Data")
        let store = SessionHistoryStore(dataRoot: root)
        XCTAssertEqual(store.load(), [])
        XCTAssertThrowsError(try store.append(record("a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
    }

    func testFailuresHaveTheirOwnTextInEveryLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            let texts = [SessionHistoryStore.Failure.unreadable("EACCES"), .newerFormat(2)].map(\.localizedDescription)
            XCTAssertEqual(Set(texts).count, 2, "\(language)")
            XCTAssertTrue(texts[0].contains("EACCES"), "\(language)")
            for text in texts { XCTAssertTrue(text.contains("SessionHistory.json"), "\(language)") }
        }
    }

    func testMetricsCSV() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let csv = StreamMetricCSV.render([
            StreamMetricSample(date: date, fps: 72.5),
            StreamMetricSample(date: date, megabits: 28, latencyMilliseconds: .infinity),
        ])
        XCTAssertEqual(csv, """
            timestamp,quest_fps,wire_mbps,input_to_display_ms
            2027-01-15T08:00:00.250Z,72.5,,
            2027-01-15T08:00:00.250Z,,28.0,

            """)
        XCTAssertEqual(StreamMetricCSV.render([]), StreamMetricCSV.header + "\n")
    }
}
