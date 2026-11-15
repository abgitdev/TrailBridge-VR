import XCTest
@testable import BasaltCore

/// The management app recognises these failures by their text. `setup()`
/// needs a real adb and headset, so the wording is pinned in two halves: the
/// constants still hold the exact text `setup()` threw as literals, and
/// `setup()` still throws them through the constants.
final class AlvrWiredFailureTests: XCTestCase {
    private static let expected: [(name: String, constant: String, text: String)] = [
        ("adbMissing", AlvrWiredFailure.adbMissing,
         "Could not find adb; open Headset in TrailBridge and choose Get Android Platform Tools."),
        ("debuggingUnauthorized", AlvrWiredFailure.debuggingUnauthorized,
         "Quest USB debugging is unauthorized; accept the USB debugging prompt in the headset"),
        ("noAuthorizedQuest", AlvrWiredFailure.noAuthorizedQuest,
         "No authorized USB Quest found by adb; connect a data-capable cable and enable Developer Mode"),
        ("clientMissing", AlvrWiredFailure.clientMissing,
         "No ALVR client package is installed on the USB headset"),
        ("pausedBehindLockScreen", AlvrWiredFailure.pausedBehindLockScreen,
         "ALVR is paused behind the Quest lock screen. Put on and unlock the headset, keep the ALVR client open, then try Play VR again."),
    ]

    func testConstantsKeepTheOriginalTextByteForByte() {
        for (name, constant, text) in Self.expected {
            XCTAssertEqual(Array(constant.utf8), Array(text.utf8), name)
            XCTAssertEqual(BasaltError(constant).localizedDescription, text, name)
        }
        XCTAssertEqual(Set(Self.expected.map(\.text)).count, 5)
    }

    /// A source check, not a run of `setup()`: each constant is thrown exactly
    /// once, and its text is written only where the constant is declared.
    func testSetupThrowsEachConstantAndHoldsNoSecondCopyOfItsText() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BasaltCore/AlvrWiredConnection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for (name, _, text) in Self.expected {
            XCTAssertEqual(
                source.components(separatedBy: "throw BasaltError(AlvrWiredFailure.\(name))").count, 2, name)
            XCTAssertEqual(source.components(separatedBy: "\"\(text)\"").count, 2, name)
        }
    }
}
