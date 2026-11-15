import XCTest
@testable import BasaltCore

final class EncoderDiagnosticsTests: XCTestCase {
    func testParsesHighProfileLevelFromSPSFixture() throws {
        // NAL header, profile_idc=High, constraint flags, level_idc=4.2.
        let sps = Data([0x67, 0x64, 0x00, 0x2a, 0xac, 0xd9, 0x40, 0x78,
                        0x02, 0x27, 0xe5, 0xc0, 0x44, 0x00, 0x00, 0x03,
                        0x00, 0x04, 0x00, 0x00, 0x03, 0x01, 0xe0, 0x3c,
                        0x60, 0xc6, 0x58])
        let profile = try XCTUnwrap(H264SPSProfile(nalu: sps))
        XCTAssertEqual(profile.profileIDC, 100)
        XCTAssertEqual(profile.levelIDC, 42)
        let padded = Data([0xff, 0xff]) + sps
        XCTAssertEqual(H264SPSProfile(nalu: padded[2...]), profile)
    }

    func testRejectsTruncatedAndNonSPSNALUnits() {
        for bytes: [UInt8] in [[], [0x67], [0x67, 0x64, 0x00],
                               [0x68, 0x64, 0x00, 0x2a], [0xe7, 0x64, 0x00, 0x2a],
                               [0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x2a]] {
            XCTAssertNil(H264SPSProfile(nalu: Data(bytes)))
        }
    }

    func testLatencyWindowUsesNearestRankPercentilesAndMaximum() throws {
        var window = EncodeLatencyWindow()
        XCTAssertNil(window.statistics)
        for milliseconds in (1...100).reversed() {
            window.record(UInt64(milliseconds) * 1_000_000)
        }
        let stats = try XCTUnwrap(window.statistics)
        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertEqual(stats.p50Milliseconds, 50)
        XCTAssertEqual(stats.p95Milliseconds, 95)
        XCTAssertEqual(stats.maximumMilliseconds, 100)
        var single = EncodeLatencyWindow()
        single.record(250_000)
        XCTAssertEqual(single.statistics?.p50Milliseconds, 0.25)
        XCTAssertEqual(single.statistics?.p95Milliseconds, 0.25)
    }

    func testLatencyStorageIsBoundedWithoutAConnectedTransport() throws {
        var window = EncodeLatencyWindow()
        window.record(1_000_000_000)
        for _ in 0..<EncodeLatencyWindow.capacity { window.record(2_000_000) }
        let stats = try XCTUnwrap(window.statistics)
        XCTAssertEqual(stats.sampleCount, EncodeLatencyWindow.capacity + 1)
        XCTAssertEqual(stats.p50Milliseconds, 2)
        XCTAssertEqual(stats.p95Milliseconds, 2)
        XCTAssertEqual(stats.maximumMilliseconds, 1000)
    }
}
