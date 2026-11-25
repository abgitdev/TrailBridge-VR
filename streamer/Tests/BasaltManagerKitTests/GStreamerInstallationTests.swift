import XCTest
@testable import BasaltManagerKit

final class GStreamerInstallationTests: XCTestCase {
    func testMissingFrameworkRequiresADirectory() throws {
        let framework = try temporaryDirectory().appendingPathComponent("GStreamer.framework")
        let fileManager = FileManager()
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework, fileManager: fileManager),
                       .missing)
        try Data().write(to: framework)
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework, fileManager: fileManager),
                       .missing)
    }

    func testFrameworkWithoutReadableMetadataIsInstalledWithoutAVersion() throws {
        let framework = try temporaryDirectory().appendingPathComponent("GStreamer.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework), .installed(version: nil))
        try Data("invalid plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework), .installed(version: nil))
    }

    func testReadsTheVersionFromFrameworkMetadata() throws {
        let fileManager = FileManager.default
        let framework = try temporaryDirectory().appendingPathComponent("GStreamer.framework")
        let resources = framework.appendingPathComponent("Versions/1.0/Resources")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "1.0")
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework), .installed(version: nil))

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.28.1"], format: .xml, options: 0)
        try plist.write(to: resources.appendingPathComponent("Info.plist"))
        XCTAssertEqual(GStreamerInstallation.detect(frameworkURL: framework), .installed(version: "1.28.1"))
    }
}
