// SPDX-License-Identifier: MIT
import XCTest
@testable import BasaltManagerKit

@MainActor
final class ConsoleTranscriptTests: XCTestCase {
    func testSessionCloseWaitsForOutputEOFAndRetainsItsPartialLine() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repo.appendingPathComponent(".local/tmp/console-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: path) }
        let console = SessionConsole(), process = NSObject()
        let source = ObjectIdentifier(process)
        console.restart(with: "start\n", transcriptURL: path)
        console.registerOutputSource(source)
        _ = console.append("last par", from: source, prefix: "game: ")
        let closed = expectation(description: "closed after EOF")
        console.closeTranscript { closed.fulfill() }
        _ = console.append("tial", from: source, prefix: "game: ")
        _ = console.finish(source, prefix: "game: ")
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(try String(contentsOf: path), "start\ngame: last partial\n")
    }

    func testTranscriptRetainsEveryLineBeforeSuppressionAndTailTrim() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repo.appendingPathComponent(".local/tmp/console-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: path) }
        let console = SessionConsole()
        console.restart(with: "first\n", transcriptURL: path)
        let error = "err:   Device error at frame 42: fault\n"
        _ = console.append(error + error + error, prefix: "game: ")
        for _ in 0..<1000 { _ = console.append(String(repeating: "x", count: 100) + "\n") }
        _ = console.append("last partial")
        _ = console.finish(nil)
        let closed = expectation(description: "writer closed")
        console.closeTranscript { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 5)
        let text = try String(contentsOf: path)
        XCTAssertTrue(text.hasPrefix("first\ngame: " + error + "game: " + error + "game: " + error))
        XCTAssertTrue(text.contains("\nlast partial\n"))
        XCTAssertGreaterThan(text.utf8.count, SessionConsole.maximumLogBytes)
        XCTAssertFalse(console.log.contains("first\n"))
    }

    /// A recording's transcript can be attached to a report, so it gets the
    /// same redaction as a copied log, within the batch delay and before the
    /// session ends; the log on screen keeps the original text.
    func testTranscriptIsRedactedLikeACopiedLogWhileTheScreenKeepsTheOriginal() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repo.appendingPathComponent(".local/tmp/console-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: path) }
        let redactor = DiagnosticRedactor(
            homeDirectory: "/Users/ada", userName: "ada", dataFolder: "/Volumes/Ada Disk/TrailBridge",
            appFolder: nil, hostNames: ["Adas-Mac"], volumeNames: ["Ada Disk"])
        let console = SessionConsole()
        console.restart(with: "start\n", transcriptURL: path, transcriptRedactor: redactor)
        let raw = "game: /Volumes/Ada Disk/TrailBridge/Bottles/blood-trail/prefix\n"
            + "USB Quest TESTQUEST00001 is authorized\n"
            + "ALVR control accepted by 'Ada Quest': StreamConfig sent\n"
            + "cache ~ /Users/ada/Library/Caches\n"
        _ = console.append(raw)
        let deadline = Date().addingTimeInterval(5)
        var early = ""
        while Date() < deadline, !early.contains("Caches") {
            try await Task.sleep(nanoseconds: 100_000_000)
            early = try String(contentsOf: path)
        }
        XCTAssertTrue(early.contains("game: [data folder]/Bottles/blood-trail/prefix\n"), early)
        let closed = expectation(description: "writer closed")
        console.closeTranscript { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 5)
        let text = try String(contentsOf: path)
        XCTAssertEqual(text, "start\n"
            + "game: [data folder]/Bottles/blood-trail/prefix\n"
            + "USB Quest [serial] is authorized\n"
            + "ALVR control accepted by '[headset]': StreamConfig sent\n"
            + "cache ~ ~/Library/Caches\n")
        XCTAssertTrue(console.log.contains("USB Quest TESTQUEST00001 is authorized"))
    }
}
