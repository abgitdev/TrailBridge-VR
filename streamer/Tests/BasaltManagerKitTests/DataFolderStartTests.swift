import XCTest
@testable import BasaltManagerKit

final class DataFolderStartTests: XCTestCase {
    private let repo = URL(fileURLWithPath: "/project/trailbridge", isDirectory: true)
    private let scriptDefault = "/project/trailbridge/.local/data"

    func testNothingSetUsesTheStandardFolder() {
        let start = DataFolderStart.choose(environment: nil, saved: nil, repoRoot: repo)
        XCTAssertEqual(start.source, .standard)
        XCTAssertEqual(start.folder.path, scriptDefault)
        XCTAssertEqual(DataFolderStart.standardFolder(repoRoot: repo).path, scriptDefault)
    }

    func testScriptDefaultIsNotExplicitSoTheSavedFolderWins() {
        let start = DataFolderStart.choose(
            environment: scriptDefault, saved: "/Volumes/Games/TrailBridge", repoRoot: repo)
        XCTAssertEqual(start.source, .saved)
        XCTAssertEqual(start.folder.path, "/Volumes/Games/TrailBridge")
    }

    func testScriptDefaultAloneStaysTheStandardFolderAsGiven() {
        let start = DataFolderStart.choose(environment: scriptDefault, saved: nil, repoRoot: repo)
        XCTAssertEqual(start.source, .standard)
        XCTAssertEqual(start.folder, URL(fileURLWithPath: scriptDefault, isDirectory: true))
    }

    /// The development setup: the development script exports its default and
    /// nothing is saved. The folder is that very string, as before.
    func testDevelopmentSetupKeepsItsPathExactly() {
        let repo = URL(fileURLWithPath: "/Volumes/Game Disk/Apps/trailbridge-vr", isDirectory: true)
        let exported = "/Volumes/Game Disk/Apps/trailbridge-vr/.local/data"
        let start = DataFolderStart.choose(environment: exported, saved: nil, repoRoot: repo)
        XCTAssertEqual(start.source, .standard)
        XCTAssertEqual(start.folder.path, exported)
        XCTAssertEqual(start.folder, URL(fileURLWithPath: exported, isDirectory: true))
    }

    func testOtherSpellingsOfTheScriptDefaultAreNotExplicit() {
        for spelling in [
            scriptDefault + "/",
            "/project/trailbridge/./.local/data",
            "/project/trailbridge/scripts/../.local/data",
        ] {
            let start = DataFolderStart.choose(environment: spelling, saved: "/Users/me/Games", repoRoot: repo)
            XCTAssertEqual(start.source, .saved, spelling)
            XCTAssertEqual(start.folder.path, "/Users/me/Games", spelling)
        }
    }

    func testScriptDefaultReachedThroughASymbolicLinkIsNotExplicit() throws {
        let directory = try temporaryDirectory()
        let realRepo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realRepo.appendingPathComponent(".local/data"), withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRepo)

        let start = DataFolderStart.choose(
            environment: alias.appendingPathComponent(".local/data").path,
            saved: "/Users/me/Games", repoRoot: realRepo)
        XCTAssertEqual(start.source, .saved)

        let reverse = DataFolderStart.choose(
            environment: realRepo.appendingPathComponent(".local/data").path,
            saved: nil, repoRoot: alias)
        XCTAssertEqual(reverse.source, .standard)
    }

    func testExplicitEnvironmentFolderWinsOverTheSavedOne() {
        let start = DataFolderStart.choose(
            environment: "/Volumes/Fast/Data", saved: "/Users/me/Games", repoRoot: repo)
        XCTAssertEqual(start.source, .environment)
        XCTAssertEqual(start.folder.path, "/Volumes/Fast/Data")
    }

    func testAFolderElsewhereInsideTheProjectIsExplicit() {
        let start = DataFolderStart.choose(
            environment: "/project/trailbridge/.local/other", saved: "/Users/me/Games", repoRoot: repo)
        XCTAssertEqual(start.source, .environment)
        XCTAssertEqual(start.folder.path, "/project/trailbridge/.local/other")
    }

    func testSavedFolderMayBeOnAnyDisk() {
        for saved in ["/Users/me/Games", "/Volumes/External/TrailBridge", "/Volumes/nas-share/vr"] {
            let start = DataFolderStart.choose(environment: nil, saved: saved, repoRoot: repo)
            XCTAssertEqual(start.source, .saved, saved)
            XCTAssertEqual(start.folder.path, saved)
        }
    }

    func testEmptyValuesCountAsAbsent() {
        XCTAssertEqual(DataFolderStart.choose(environment: "", saved: "", repoRoot: repo),
                       DataFolderStart(folder: DataFolderStart.standardFolder(repoRoot: repo), source: .standard))
        XCTAssertEqual(DataFolderStart.choose(environment: "", saved: "/Users/me/Games", repoRoot: repo).source,
                       .saved)
    }
}
