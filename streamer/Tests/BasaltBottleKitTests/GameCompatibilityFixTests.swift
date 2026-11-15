import XCTest
@testable import BasaltBottleKit

final class GameCompatibilityFixTests: XCTestCase {
    private let shipped = Data((
        "StereoRenderingMode: 1\r\n"
        + "InitializationType: 1\r\n"
        + "EditorAppKey: application.generated.unity.vtolvr.exe\r\n"
        + "ActionManifestFileRelativeFilePath: StreamingAssets\\SteamVR\\actions.json\r\n"
        + "MirrorView: 2\r\n").utf8)

    func testVTOLGetsSeparateEyePassesAndKeepsTheOriginal() throws {
        let root = try vtolFolder(settings: shipped)
        let settings = settingsURL(in: root)

        XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: root), [.vtolVRSeparateEyePasses])
        let expected = String(decoding: shipped, as: UTF8.self)
            .replacingOccurrences(of: "StereoRenderingMode: 1", with: "StereoRenderingMode: 0")
        XCTAssertEqual(try Data(contentsOf: settings), Data(expected.utf8),
                       "only the number changes; CRLF line endings and other lines stay")
        XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("basalt-original")), shipped)

        XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: root), [],
                       "an applied fix is not applied again")
        XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("basalt-original")), shipped)
    }

    func testAGameUpdateThatRestoresTheFileIsFixedAgain() throws {
        let root = try vtolFolder(settings: shipped)
        _ = try GameCompatibilityFix.apply(inGameRoot: root)
        let updated = Data("StereoRenderingMode: 1\nMirrorView: 1\n".utf8)
        try updated.write(to: settingsURL(in: root))

        XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: root), [.vtolVRSeparateEyePasses])
        XCTAssertEqual(try String(contentsOf: settingsURL(in: root), encoding: .utf8),
                       "StereoRenderingMode: 0\nMirrorView: 1\n")
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: root).appendingPathExtension("basalt-original")),
                       updated, "the backup holds the file as the update left it")
    }

    func testOtherGamesAndUnexpectedSettingsAreLeftAlone() throws {
        let other = try temporaryDirectory()
        let settings = settingsURL(in: other)
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try shipped.write(to: settings)
        XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: other), [],
                       "without VTOLVR.exe this is some other game")
        XCTAssertEqual(try Data(contentsOf: settings), shipped)

        for contents in ["StereoRenderingMode: 0\r\n", "MirrorView: 2\r\n",
                         "StereoRenderingMode: 1\nStereoRenderingMode: 1\n"] {
            let root = try vtolFolder(settings: Data(contents.utf8))
            XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: root), [], contents)
            XCTAssertEqual(try String(contentsOf: settingsURL(in: root), encoding: .utf8), contents)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: settingsURL(in: root).appendingPathExtension("basalt-original").path))
        }

        let noSettings = try temporaryDirectory()
        try Data().write(to: noSettings.appendingPathComponent("VTOLVR.exe"))
        XCTAssertEqual(try GameCompatibilityFix.apply(inGameRoot: noSettings), [])
    }

    func testALinkedSettingsFileIsRefused() throws {
        let root = try vtolFolder(settings: shipped)
        let settings = settingsURL(in: root)
        let elsewhere = try temporaryDirectory().appendingPathComponent("OpenVRSettings.asset")
        try FileManager.default.moveItem(at: settings, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try GameCompatibilityFix.apply(inGameRoot: root))
        XCTAssertEqual(try Data(contentsOf: elsewhere), shipped)
    }

    func testBottleManagerAppliesFixesForTheProfilesGameFolder() throws {
        let temporary = try temporaryDirectory()
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix, engineRoot: engineRoot,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        let game = prefix.appendingPathComponent("drive_c/Games/VTOL VR", isDirectory: true)
        try writeVTOL(into: game, settings: shipped)

        let manager = BottleManager(root: root, repoRoot: temporary.appendingPathComponent("repo"))
        try manager.saveProfile(LaunchProfile(
            name: "vtol", bottleName: "Test", source: .direct,
            executable: #"C:\Games\VTOL VR\VTOLVR.exe"#, gameRoot: #"C:\Games\VTOL VR"#))
        try manager.saveProfile(LaunchProfile(
            name: "no-folder", bottleName: "Test", source: .direct,
            executable: #"C:\Games\VTOL VR\VTOLVR.exe"#))

        XCTAssertEqual(try manager.applyGameCompatibilityFixes(profileName: "vtol"),
                       [.vtolVRSeparateEyePasses])
        XCTAssertTrue(try String(contentsOf: settingsURL(in: game), encoding: .utf8)
            .hasPrefix("StereoRenderingMode: 0\r\n"))
        XCTAssertEqual(try manager.applyGameCompatibilityFixes(profileName: "no-folder"), [],
                       "a profile without a game folder has nothing to fix")
        XCTAssertEqual(try manager.openVRTargets(profileName: "vtol"), [],
                       "the shared folder lookup still serves OpenVR support")
        XCTAssertThrowsError(try manager.openVRTargets(profileName: "no-folder"))
    }

    // MARK: - Fixtures

    private func settingsURL(in root: URL) -> URL {
        root.appendingPathComponent("VTOLVR_Data/StreamingAssets/SteamVR/OpenVRSettings.asset")
    }

    private func vtolFolder(settings: Data) throws -> URL {
        let root = try temporaryDirectory()
        try writeVTOL(into: root, settings: settings)
        return root
    }

    private func writeVTOL(into root: URL, settings: Data) throws {
        let file = settingsURL(in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: root.appendingPathComponent("VTOLVR.exe"))
        try settings.write(to: file)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GameCompatibilityFixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
