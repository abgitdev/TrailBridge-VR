import XCTest
@testable import BasaltManagerKit

/// The download that writes a large archive straight to its file. The
/// network is replaced by a `URLProtocol` that answers from memory.
final class StreamedDownloadTests: XCTestCase {
    private let url = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/wine-devel-11.10-osx64.tar.xz")!

    override func tearDown() {
        StubProtocol.answer = nil
        super.tearDown()
    }

    func testWritesTheBodyToTheFileAndReportsHowMuchArrived() async throws {
        let chunks = (0..<8).map { Data(repeating: UInt8($0), count: 64 * 1024) }
        let body = chunks.reduce(Data(), +)
        StubProtocol.answer = .init(status: 200, chunks: chunks)
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        let reports = Reports()

        let final = try await StreamedDownload.fetch(
            url, to: file, progress: { reports.add($0, $1) }, protocolClasses: [StubProtocol.self])

        XCTAssertEqual(final, url)
        XCTAssertEqual(try Data(contentsOf: file), body)
        let last = try XCTUnwrap(reports.values.last)
        XCTAssertEqual(last.received, Int64(body.count))
        XCTAssertEqual(last.total, Int64(body.count))
        XCTAssertEqual(reports.values.map(\.received), reports.values.map(\.received).sorted(),
                       "the count only grows")
    }

    func testOlderFileAtTheSamePlaceIsReplaced() async throws {
        StubProtocol.answer = .init(status: 200, chunks: [Data("new".utf8)])
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        try Data("an older, longer file".utf8).write(to: file)
        _ = try await StreamedDownload.fetch(
            url, to: file, progress: { _, _ in }, protocolClasses: [StubProtocol.self])
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }

    func testFileIsNeverWrittenThroughALink() async throws {
        StubProtocol.answer = .init(status: 200, chunks: [Data("new".utf8)])
        let folder = try temporaryDirectory()
        let elsewhere = folder.appendingPathComponent("elsewhere.txt")
        try Data("kept".utf8).write(to: elsewhere)
        let file = folder.appendingPathComponent("wine.tar.xz")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        _ = try await StreamedDownload.fetch(
            url, to: file, progress: { _, _ in }, protocolClasses: [StubProtocol.self])
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("kept".utf8))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }

    func testAnAnswerOtherThanSuccessWritesNoFile() async throws {
        for status in [404, 403, 500, 206] {
            StubProtocol.answer = .init(status: status, chunks: [Data("<html>".utf8)])
            let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
            do {
                _ = try await StreamedDownload.fetch(
                    url, to: file, progress: { _, _ in }, protocolClasses: [StubProtocol.self])
                XCTFail("HTTP \(status) is not a download")
            } catch {
                XCTAssertEqual(error as? WineInstallError, .downloadFailed, "\(status): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(status)")
        }
    }

    func testConnectionLostIsANetworkError() async throws {
        StubProtocol.answer = .init(status: 200, chunks: [Data("part".utf8)],
                                    failure: URLError(.networkConnectionLost))
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        do {
            _ = try await StreamedDownload.fetch(
                url, to: file, progress: { _, _ in }, protocolClasses: [StubProtocol.self])
            XCTFail("a lost connection is not a download")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")
        }
    }

    /// The installer turns a network error into its own plain sentence and
    /// removes the part that arrived.
    func testInstallerReportsALostConnectionAndRemovesThePart() async throws {
        StubProtocol.answer = .init(status: 200, chunks: [Data("part".utf8)],
                                    failure: URLError(.networkConnectionLost))
        let data = try temporaryDirectory()
        let installer = WineInstaller(dataRoot: data, requiredBytes: 0, freeBytes: { _ in nil })
        do {
            _ = try await installer.install(fetch: { url, file, progress in
                try await StreamedDownload.fetch(url, to: file, progress: progress,
                                                 protocolClasses: [StubProtocol.self])
            })
            XCTFail("a lost connection is not an install")
        } catch {
            XCTAssertEqual(error as? WineInstallError, .downloadFailed, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: data.appendingPathComponent("Downloads").path), [])
        XCTAssertFalse(installer.isInstalled)
    }

    func testCancelledDownloadStops() async throws {
        // Large enough for the session to hand it on before the body ends.
        StubProtocol.answer = .init(status: 200, chunks: [Data(repeating: 1, count: 1 << 20)],
                                    stalls: true)
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        let url = url
        let started = expectation(description: "the first bytes arrived")
        started.assertForOverFulfill = false
        let download = Task {
            try await StreamedDownload.fetch(
                url, to: file, progress: { _, _ in started.fulfill() },
                protocolClasses: [StubProtocol.self])
        }
        await fulfillment(of: [started], timeout: 10)
        download.cancel()
        switch await download.result {
        case .success: XCTFail("a cancelled download must not finish")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Cancelled between the task's start and the load's: the session ends
    /// the load before anyone waits for it, and the wait must still end.
    func testLoadThatEndedBeforeItWasAwaitedStillAnswers() async throws {
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        let download = StreamedDownload(file: file, progress: { _, _ in })
        download.finish(error: URLError(.cancelled))
        let started = Started()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                download.begin(continuation) { started.note() }
            }
            XCTFail("a cancelled load is not a download")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(started.value, "a load that has ended is not started again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLoadAwaitedBeforeItEndsIsStartedAndAnswersOnce() async throws {
        let file = try temporaryDirectory().appendingPathComponent("wine.tar.xz")
        let download = StreamedDownload(file: file, progress: { _, _ in })
        let started = Started()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                download.begin(continuation) { started.note() }
                download.finish(error: URLError(.timedOut))
                // A second end has no one left to answer.
                download.finish(error: nil)
            }
            XCTFail("a load that timed out is not a download")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "\(error)")
        }
        XCTAssertTrue(started.value)
    }

    /// The same through the session: cancelled at every moment around the
    /// start, the download always ends.
    func testDownloadCancelledAroundItsStartAlwaysEnds() async throws {
        StubProtocol.answer = .init(status: 200, chunks: [Data("part".utf8)], stalls: true)
        let folder = try temporaryDirectory()
        let url = url
        for round in 0..<200 {
            let file = folder.appendingPathComponent("wine-\(round).tar.xz")
            let download = Task {
                try await StreamedDownload.fetch(
                    url, to: file, progress: { _, _ in }, protocolClasses: [StubProtocol.self])
            }
            for _ in 0..<(round % 20) { await Task.yield() }
            download.cancel()
            let ended = expectation(description: "round \(round) ended")
            Task {
                _ = await download.result
                ended.fulfill()
            }
            await fulfillment(of: [ended], timeout: 10)
        }
    }
}

private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var noted = false
    var value: Bool { lock.withLock { noted } }
    func note() { lock.withLock { noted = true } }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [(received: Int64, total: Int64?)]()
    var values: [(received: Int64, total: Int64?)] { lock.withLock { recorded } }
    func add(_ received: Int64, _ total: Int64?) { lock.withLock { recorded.append((received, total)) } }
}

/// Answers every request of a session from memory.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status: Int
        var chunks: [Data]
        /// Ends the load with this error after the chunks.
        var failure: URLError?
        /// Never ends the load: the body stays unfinished.
        var stalls = false
    }

    private static let lock = NSLock()
    private static var stored: Answer?
    static var answer: Answer? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let answer = Self.answer, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let length = answer.chunks.reduce(0) { $0 + $1.count }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(length)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in answer.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else if !answer.stalls {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
