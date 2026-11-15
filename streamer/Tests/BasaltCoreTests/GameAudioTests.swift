import XCTest
@testable import BasaltCore

final class GameAudioTests: XCTestCase {
    private let outputs = [
        AudioOutputCandidate(id: 1, name: "BlackHole 2ch", isBuiltIn: false),
        AudioOutputCandidate(id: 2, name: "USB speakers", isBuiltIn: false),
        AudioOutputCandidate(id: 3, name: "Built-in speakers", isBuiltIn: true),
        AudioOutputCandidate(id: 4, name: "blackhole 16ch", isBuiltIn: false),
    ]

    func testRestoreKeepsPreviousRealDevice() {
        XCTAssertEqual(audioOutputToRestore(previousID: 2, routedID: 1,
                                            systemOutputID: 3, candidates: outputs), 2)
    }

    func testRestoreUsesSystemOutputWhenPreviousIsLoopback() {
        XCTAssertEqual(audioOutputToRestore(previousID: 1, routedID: 1,
                                            systemOutputID: 2, candidates: outputs), 2)
    }

    func testRestorePrefersBuiltInWhenSystemOutputIsLoopback() {
        XCTAssertEqual(audioOutputToRestore(previousID: 1, routedID: 1,
                                            systemOutputID: 1, candidates: outputs), 3)
    }

    func testRestoreUsesFirstRealOutputWhenNoBuiltInExists() {
        XCTAssertEqual(audioOutputToRestore(previousID: 1, routedID: 1,
                                            systemOutputID: nil,
                                            candidates: Array(outputs.prefix(2))), 2)
    }

    func testRestoreFindsNoRealOutput() {
        XCTAssertNil(audioOutputToRestore(previousID: 1, routedID: 1,
                                          systemOutputID: 1,
                                          candidates: [outputs[0], outputs[3]]))
    }

    func testFloatStereoConvertsToLittleEndianPCM16WithClipping() throws {
        let pcm = try StereoPCM16Encoder.encode(
            left: [-2, -1, -0.5, 0, 0.5, 1, 2, .nan],
            right: [1, 0.25, 0, -0.25, -1, 0, 0.75, .infinity])
        XCTAssertEqual(pcm, Data([
            0x00, 0x80, 0xff, 0x7f,
            0x00, 0x80, 0x00, 0x20,
            0x00, 0xc0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0xe0,
            0x00, 0x40, 0x00, 0x80,
            0xff, 0x7f, 0x00, 0x00,
            0xff, 0x7f, 0x00, 0x60,
            0x00, 0x00, 0x00, 0x00,
        ]))
    }

    func testStereoConversionRejectsMismatchedChannels() {
        XCTAssertThrowsError(try StereoPCM16Encoder.encode(
            left: [0, 1], right: [0]))
    }
}
