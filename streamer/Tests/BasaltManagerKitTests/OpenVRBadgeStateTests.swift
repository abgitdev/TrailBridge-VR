import XCTest
import BasaltBottleKit
import BasaltManagerKit

final class OpenVRBadgeStateTests: XCTestCase {
    func testInstalledStatusChip() {
        let chip = OpenVRStatusChip.presentation(for: .installed)
        XCTAssertEqual(chip.text, "READY · OPENVR")
        XCTAssertEqual(chip.tint, .green)
        XCTAssertTrue(chip.showsCheckmark)
        XCTAssertEqual(chip.help, "OpenVR support is on (OpenComposite installed in the game folder)")
    }

    func testNeedsSetupStatusChip() {
        let chip = OpenVRStatusChip.presentation(for: .needsSetup)
        XCTAssertEqual(chip.text, "SET UP OPENVR")
        XCTAssertEqual(chip.tint, .orange)
        XCTAssertFalse(chip.showsCheckmark)
        XCTAssertEqual(chip.help, "This game uses OpenVR. Click to install OpenVR support.")
    }

    func testNoOpenVRAndUnknownStatusChip() {
        let chip = OpenVRStatusChip.presentation(for: OpenVRBadgeState.none)
        XCTAssertEqual(chip.text, "READY")
        XCTAssertEqual(chip.tint, .green)
        XCTAssertTrue(chip.showsCheckmark)
        XCTAssertNil(chip.help)
        XCTAssertEqual(OpenVRStatusChip.presentation(for: nil), chip)
    }

    func testNoOpenVRDLLShowsNoBadge() throws {
        let (manager, dll) = try fixture()
        // A leftover backup alone is not a game DLL.
        try Data().write(to: dll.appendingPathExtension("basalt-original"))
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .none)
    }

    func testProfileWithoutGameFolderShowsNoBadge() throws {
        let (manager, dll) = try fixture()
        try Data().write(to: dll)
        var profile = try manager.loadProfile("game")
        profile.gameRoot = nil
        try manager.saveProfile(profile)
        // There is no folder to inspect, so no false "set up OpenVR" prompt.
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .none)
    }

    func testGameDLLNeedsSetup() throws {
        let (manager, dll) = try fixture()
        try Data().write(to: dll)
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .needsSetup)
    }

    func testBackupDoesNotMeanInstalledAndContentDetectsRestoration() throws {
        let (manager, dll) = try fixture()
        try Data().write(to: dll)
        let backup = dll.appendingPathExtension("basalt-original")
        try Data().write(to: backup)
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .needsSetup)
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[0x3c] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 2; bytes[87] = 0x20; bytes[88] = 0x0b; bytes[89] = 0x02
        try (Data(bytes) + Data("OCOVR OpenComposite".utf8)).write(to: dll)
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .installed)
        try Data().write(to: dll)
        try FileManager.default.removeItem(at: backup)
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .needsSetup)
        try FileManager.default.removeItem(at: dll)
        XCTAssertEqual(try OpenVRBadgeState.inspect(profileName: "game", manager: manager), .none)
    }

    private func fixture() throws -> (BottleManager, URL) {
        let repo = try temporaryDirectory()
        let root = repo.appendingPathComponent("data")
        let directory = root.appendingPathComponent("Bottles/Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engineRoot = directory.appendingPathComponent("engine")
        let wine = engineRoot.appendingPathComponent("bin/wine")
        let engine = BottleEngine(id: "fixture", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(name: "Test", engine: engine, prefix: prefix,
                                   engineRoot: engineRoot, wineBinary: wine)
        let dll = prefix.appendingPathComponent("drive_c/Games/Test/Plugins/openvr_api.dll")
        try FileManager.default.createDirectory(at: dll.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(root: root, repoRoot: repo)
        try manager.saveProfile(LaunchProfile(name: "game", bottleName: "Test", source: .direct,
            executable: #"C:\Games\Test\Game.exe"#, gameRoot: #"C:\Games\Test"#))
        return (manager, dll)
    }
}
