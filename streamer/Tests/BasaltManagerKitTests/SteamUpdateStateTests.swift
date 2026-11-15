import XCTest
import BasaltBottleKit
import BasaltManagerKit

final class SteamUpdateStateTests: XCTestCase {
    func testFullyInstalledProceedsAndEachUpdateBitBlocks() throws {
        XCTAssertTrue(try SteamUpdateState.parse("\"AppState\"\n{\n \"StateFlags\" \"4\"\n}").isReady)
        for bit: UInt64 in [2, 256, 512, 1024, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608] {
            XCTAssertTrue(SteamUpdateState(flags: bit | 4).isUpdating, "bit \(bit)")
            XCTAssertFalse(SteamUpdateState(flags: bit | 4).isReady)
        }
        XCTAssertFalse(SteamUpdateState(flags: 0).isReady)
        XCTAssertFalse(SteamUpdateState(flags: 1).isReady)
    }

    func testMalformedManifestIsNotAssumedReady() {
        for manifest in ["", "\"StateFlags\" \"oops\"", "\"StateFlags\" \"-1\"", "\"Other\" \"4\""] {
            XCTAssertThrowsError(try SteamUpdateState.parse(manifest))
        }
    }

    @MainActor func testWaitPollsUntilUpdateFinishes() async throws {
        var states: [UInt64] = [1026, 1048580, 4194308, 4]
        var waits = 0, pauses = 0
        try await SteamUpdateWaiter.wait(read: { .init(flags: states.removeFirst()) }, startAnyway: { false },
            onWaiting: { _ in waits += 1 }, pause: { pauses += 1 })
        XCTAssertEqual(waits, 3); XCTAssertEqual(pauses, 3); XCTAssertTrue(states.isEmpty)
    }

    @MainActor func testReadyNeverWaits() async throws {
        try await SteamUpdateWaiter.wait(read: { .init(flags: 4) }, startAnyway: { false },
            onWaiting: { _ in XCTFail("Ready waited") }, pause: { XCTFail("Ready slept") })
    }

    @MainActor func testStartAnywayReleasesWaitAndCancellationStopsIt() async throws {
        var override = false, reads = 0
        try await SteamUpdateWaiter.wait(read: { reads += 1; return .init(flags: 2) }, startAnyway: { override },
            onWaiting: { _ in }, pause: { override = true })
        XCTAssertEqual(reads, 1)
        do {
            try await SteamUpdateWaiter.wait(read: { .init(flags: 2) }, startAnyway: { false },
                onWaiting: { _ in }, pause: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Wrong error") }
    }

    @MainActor func testTransientManifestReadFailureKeepsWaiting() async throws {
        var reads = 0, unknown = 0
        try await SteamUpdateWaiter.wait(read: {
            reads += 1
            if reads == 1 { throw BottleToolError("manifest is being replaced") }
            return .init(flags: 4)
        }, startAnyway: { false }, onWaiting: { if $0 == nil { unknown += 1 } }, pause: {})
        XCTAssertEqual(reads, 2); XCTAssertEqual(unknown, 1)
    }

    func testManifestDiscoveryUsesSteamAppIDAndStaysInPrefix() throws {
        let root = try temporaryDirectory()
        let manifest = root.appendingPathComponent("drive_c/Steam/steamapps/appmanifest_123.acf")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: manifest)
        var profile = LaunchProfile(name: "game", bottleName: "test", source: .steam, executable: "Game.exe", environment: ["SteamAppId": "123"])
        XCTAssertEqual(try SteamUpdateState.manifestURL(profile: profile, prefix: root)?.resolvingSymlinksInPath(), manifest.resolvingSymlinksInPath())
        profile.environment = [:]; profile.arguments = ["-applaunch", "123"]
        XCTAssertEqual(try SteamUpdateState.manifestURL(profile: profile, prefix: root)?.resolvingSymlinksInPath(), manifest.resolvingSymlinksInPath())
        // A profile made from a detected game has no app ID: nothing to
        // wait for, and the game must still be allowed to start.
        profile.arguments = []
        XCTAssertNil(try SteamUpdateState.manifestURL(profile: profile, prefix: root))
        profile.source = .direct
        XCTAssertNil(try SteamUpdateState.manifestURL(profile: profile, prefix: root))
    }
}
