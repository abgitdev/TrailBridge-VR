import XCTest
@testable import BasaltCore

final class EncodedVideoRecorderTests: XCTestCase {
    private func temporaryPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("session.hevc").path
    }

    private func indexRows(_ path: String) throws -> [[String]] {
        try String(contentsOfFile: path + ".index.csv", encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("frame,") }
            .map { $0.split(separator: ",").map(String.init) }
    }

    func testFramesAreWrittenInOrderWithAnIndexAndWaitForTheFirstKeyframe() throws {
        let path = try temporaryPath()
        let recorder = try EncodedVideoRecorder(path: path, minimumFreeBytes: 0)
        recorder.append(annexB: Data([9, 9]), isKeyframe: false, questTimestampNanoseconds: 1)
        recorder.append(annexB: Data([1, 2, 3]), isKeyframe: true, questTimestampNanoseconds: 7)
        recorder.append(annexB: Data([4]), isKeyframe: false, questTimestampNanoseconds: nil)
        recorder.finish()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([1, 2, 3, 4]))
        let rows = try indexRows(path)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Array(rows[0][2...]), ["7", "0", "3", "1", "1"])
        XCTAssertEqual(Array(rows[1][2...]), ["0", "3", "1", "0", "1"])
        XCTAssertEqual(rows.map { $0[0] }, ["0", "1"])
    }

    func testAFullBacklogSkipsToTheNextKeyframeSoNoBrokenFramesAreRecorded() throws {
        let path = try temporaryPath()
        let recorder = try EncodedVideoRecorder(path: path, maximumBacklogBytes: 4, minimumFreeBytes: 0)
        recorder.queue.suspend()
        recorder.append(annexB: Data([1, 1, 1]), isKeyframe: true, questTimestampNanoseconds: 1)
        recorder.append(annexB: Data([2, 2]), isKeyframe: false, questTimestampNanoseconds: 2) // backlog full
        recorder.append(annexB: Data([3]), isKeyframe: false, questTimestampNanoseconds: 3) // would fit, but depends on 2
        recorder.queue.resume()
        recorder.queue.sync {}
        recorder.append(annexB: Data([4]), isKeyframe: false, questTimestampNanoseconds: 4) // still waiting
        recorder.append(annexB: Data([5, 5]), isKeyframe: true, questTimestampNanoseconds: 5)
        recorder.finish()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([1, 1, 1, 5, 5]))
        let rows = try indexRows(path)
        XCTAssertEqual(rows.map { $0[2] }, ["1", "5"])
        XCTAssertEqual(rows.map { $0[6] }, ["0", "3"])
    }

    func testRecordingStopsAtTheSizeLimitAndNeverOverwritesAnExistingFile() throws {
        let path = try temporaryPath()
        let recorder = try EncodedVideoRecorder(path: path, maximumFileBytes: 3, minimumFreeBytes: 0)
        recorder.append(annexB: Data([1, 2]), isKeyframe: true, questTimestampNanoseconds: 1)
        recorder.append(annexB: Data([3, 4]), isKeyframe: true, questTimestampNanoseconds: 2)
        recorder.append(annexB: Data([5]), isKeyframe: true, questTimestampNanoseconds: 3)
        recorder.finish()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([1, 2]))
        XCTAssertThrowsError(try EncodedVideoRecorder(path: path, minimumFreeBytes: 0))
    }

    func testRefusesToStartWithoutEnoughFreeSpace() throws {
        let path = try temporaryPath()
        XCTAssertThrowsError(try EncodedVideoRecorder(path: path, minimumFreeBytes: .max))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOptionParsesTheRecordingPath() throws {
        XCTAssertNil(try StreamerOptions.parse(["--wireless"])?.recordVideoFile)
        XCTAssertEqual(try StreamerOptions.parse(["--wireless", "--record-video", "/x/a.hevc"])?.recordVideoFile,
                       "/x/a.hevc")
        XCTAssertThrowsError(try StreamerOptions.parse(["--record-video"]))
    }
}
