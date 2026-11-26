import XCTest
@testable import BasaltCore

final class HeadsetTrustTests: XCTestCase {
    func testDefaultCLIIsUnrestrictedAndTrustFileIsOptIn() throws {
        XCTAssertNil(try StreamerOptions.parse(["--wireless"])?.trustFile)
        XCTAssertEqual(try StreamerOptions.parse(["--wireless", "--trust-file", "trusted.json"])?.trustFile, "trusted.json")
        XCTAssertThrowsError(try StreamerOptions.parse(["--trust-file"]))
        XCTAssertTrue(HeadsetBeaconGate(file: nil).accept(hostname: "Quest", ip: "192.0.2.1") { _ in XCTFail("No request without a trust file") })
    }

    func testPrivateStoreAndForgetPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeadsetTrust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HeadsetTrustStore(file: root.appendingPathComponent("trusted.json"))
        XCTAssertEqual(try store.load(), [])
        try store.setTrusted("Quest", trusted: true)
        try store.setTrusted("Quest", trusted: true)
        XCTAssertEqual(try store.load(), ["Quest"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try store.setTrusted("Quest", trusted: false)
        XCTAssertEqual(try store.load(), [])
        XCTAssertThrowsError(try store.setTrusted("bad\nname", trusted: true))
        try Data("broken".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.setTrusted("Other", trusted: true))
    }

    func testParseableRequestPreservesHostnameIdentity() {
        let request = HeadsetRequest.parse("Headset request: Quest at home at 192.0.2.1")
        XCTAssertEqual(request?.hostname, "Quest at home")
        XCTAssertEqual(request?.ip, "192.0.2.1")
        XCTAssertNil(HeadsetRequest.parse("game: Headset request: Quest at 192.0.2.1"))
        XCTAssertNil(HeadsetRequest.parse("Headset request:  at 192.0.2.1"))
        XCTAssertNil(HeadsetRequest.parse("Headset request: Quest\nforged at 192.0.2.1"))
    }

    func testDeveloperPathHasPriorityOverManagedTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ADBLocator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let developer = root.appendingPathComponent("scripts/tools/adb")
        let managed = root.appendingPathComponent("Tools/platform-tools/adb")
        for file in [developer, managed] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        }
        XCTAssertEqual(AlvrADBExecutableLocator.find(environment: ["PATH": developer.deletingLastPathComponent().path], fallbackDirectories: [], dataRoot: root), developer)
        XCTAssertEqual(AlvrADBExecutableLocator.find(environment: ["PATH": "/fixture/empty"], fallbackDirectories: [], dataRoot: root), managed)
    }
}

/// A list of trusted headsets that is damaged, in part or as a whole.
final class DamagedHeadsetTrustTests: XCTestCase {
    private func store() throws -> HeadsetTrustStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeadsetTrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return HeadsetTrustStore(dataRoot: root)
    }

    /// One name that is too long (or is no name at all) used to lock out
    /// every headset: the whole list was rejected.
    func testInvalidEntriesAreLeftOutInsteadOfRejectingTheList() throws {
        let store = try store()
        XCTAssertEqual(store.file.lastPathComponent, "TrustedHeadsets.json")
        try Data(#"["Quest-3", "a-hostname-that-is-longer-than-thirty-two-bytes", 5, "bad\nname", "", "Pico-4", "Quest-3"]"#.utf8)
            .write(to: store.file)
        XCTAssertEqual(try store.load(), ["Pico-4", "Quest-3"])
        let gate = HeadsetBeaconGate(file: store.file)
        XCTAssertTrue(gate.accept(hostname: "Quest-3", ip: "192.0.2.1") { _ in XCTFail("approved already") })
        XCTAssertFalse(gate.accept(hostname: "a-hostname-that-is-longer-than-thirty-two-bytes", ip: "192.0.2.1") { _ in })

        // Wi-Fi Play prepares the list, and approving a headset still works.
        try store.prepare()
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: store.file)), ["Pico-4", "Quest-3"])
        try store.setTrusted("New-HMD", trusted: true)
        XCTAssertEqual(try store.load(), ["New-HMD", "Pico-4", "Quest-3"])
    }

    /// A file that is no list at all: the error names the file instead of
    /// Foundation's "The data couldn't be read because it isn't in the
    /// correct format", nothing is written over it, and it can be reset.
    func testAFileThatIsNoListSaysSoNamingTheFileAndCanBeReset() throws {
        for damaged in ["broken", "", #"{"Quest-3": true}"#] {
            let store = try store()
            try Data(damaged.utf8).write(to: store.file)
            for operation in [{ _ = try store.load() }, { try store.prepare() },
                              { try store.setTrusted("Quest-3", trusted: true) }] {
                XCTAssertThrowsError(try operation(), damaged) { error in
                    XCTAssertEqual((error as? HeadsetTrustStore.Unreadable)?.file, store.file)
                    XCTAssertTrue(error.localizedDescription.contains("TrustedHeadsets.json"), error.localizedDescription)
                }
            }
            XCTAssertEqual(try Data(contentsOf: store.file), Data(damaged.utf8), "kept as it is")
            // Fails closed meanwhile.
            XCTAssertFalse(HeadsetBeaconGate(file: store.file).accept(hostname: "Quest-3", ip: "192.0.2.1") { _ in })

            try store.reset()
            XCTAssertEqual(try store.load(), [])
            let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            try store.setTrusted("Quest-3", trusted: true)
            XCTAssertEqual(try store.load(), ["Quest-3"])
        }
    }

    func testAListThatCannotBeOpenedIsUnreadableToo() throws {
        let store = try store()
        try store.setTrusted("Quest-3", trusted: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.file.path)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is HeadsetTrustStore.Unreadable) }
        XCTAssertThrowsError(try store.prepare()) { XCTAssertTrue($0 is HeadsetTrustStore.Unreadable) }
        try store.reset()
        XCTAssertEqual(try store.load(), [])
    }

    /// U+2028 and U+2029 are separators, not control characters, and still
    /// break the one-line "Headset request: … at …" report.
    func testANameWithAnyKindOfLineBreakIsRefused() {
        for name in ["Quest\u{2028}forged", "Quest\u{2029}forged", "Quest\u{85}forged", "Quest\rforged",
                     "Quest\nforged", "Quest\u{0B}x", "Quest\u{0C}x", "\u{2028}"] {
            XCTAssertFalse(HeadsetTrustStore.validHostname(name), name.debugDescription)
            XCTAssertNil(HeadsetRequest.parse("Headset request: \(name) at 192.0.2.1"), name.debugDescription)
            XCTAssertFalse(HeadsetBeaconGate(file: URL(fileURLWithPath: "/fixture/trust.json"),
                                             now: { 0 }, signature: { _ in nil }, read: { _ in [name] })
                .accept(hostname: name, ip: "192.0.2.1") { _ in XCTFail("an invalid name is never reported") })
        }
        for name in ["Quest 3", "Quest-3", "헤드셋", "クエスト", "Quest at home"] {
            XCTAssertTrue(HeadsetTrustStore.validHostname(name), name)
        }
    }

    /// The list in a data folder never creates that folder: one made in
    /// place of a disk that is not connected would hide the real one.
    func testTheListInADataFolderNeverCreatesThatFolder() throws {
        let existing = try store().file.deletingLastPathComponent()
        let root = existing.appendingPathComponent("disk left/TrailBridge Data")
        let store = HeadsetTrustStore(dataRoot: root)
        XCTAssertEqual(try store.load(), [])
        XCTAssertThrowsError(try store.prepare())
        XCTAssertThrowsError(try store.setTrusted("Quest-3", trusted: true))
        XCTAssertThrowsError(try store.reset())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), [])
    }
}
