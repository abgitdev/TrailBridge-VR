import XCTest
import CryptoKit
@testable import BasaltBottleKit
@testable import BasaltManagerKit

/// The installer against a small archive made here with `/usr/bin/tar`:
/// no network, and the real unpacking.
final class WineInstallerTests: XCTestCase {
    private let wineRoot = "Wine Devel.app/Contents/Resources/wine"
    private let source = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/wine-devel-11.10-osx64.tar.xz")!

    func testPinIsTheOneTheDevelopmentScriptUses() {
        XCTAssertEqual(PinnedWine.download.version, "11.10")
        XCTAssertEqual(PinnedWine.download.url, source)
        XCTAssertEqual(PinnedWine.download.checksum,
                       "6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b")
        XCTAssertEqual(PinnedWine.archiveBytes, 188_035_604)
        XCTAssertTrue(PinnedWine.download.isTrustedSource(source))
        XCTAssertTrue(PinnedWine.download.isTrustedSource(
            URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")!))
        XCTAssertFalse(PinnedWine.download.isTrustedSource(URL(string: "http://github.com/x")!))
        XCTAssertFalse(PinnedWine.download.isTrustedSource(URL(string: "https://example.com/x")!))
    }

    func testSizesAreShownRoundedInTheAppsLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(PinnedWine.archiveSizeText, "190 MB")
        XCTAssertEqual(PinnedWine.unpackedSizeText, "720 MB")
    }

    func testGStreamerPackageMatchesThePinnedWineRequirements() {
        XCTAssertEqual(PinnedWine.gStreamerVersion, "1.28.1")
        XCTAssertEqual(PinnedWine.gStreamerPackageURL.absoluteString,
                       "https://gstreamer.freedesktop.org/data/pkg/osx/1.28.1/gstreamer-1.0-1.28.1-universal.pkg")
    }

    func testInstallsWineWhereTheEngineIsLookedForAndCleansUp() async throws {
        let fixture = try makeFixture()
        let stages = Recorder<WineInstaller.Stage>()
        let outcome = try await fixture.installer.install(fetch: fixture.fetch) { stages.add($0) }

        XCTAssertEqual(outcome, .installed)
        let root = fixture.data.appendingPathComponent("Tools/wine-11.10/" + wineRoot)
        for file in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), file)
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/wine").path))
        XCTAssertTrue(fixture.installer.isInstalled)
        XCTAssertEqual(try names(in: fixture.data.appendingPathComponent("Downloads")), [],
                       "the archive is gone")
        XCTAssertEqual(try names(in: fixture.data.appendingPathComponent("Tools")), ["wine-11.10"],
                       "no partly unpacked folder is left")
        XCTAssertEqual(try names(in: fixture.data), ["Downloads", "Tools"],
                       "nothing else is written, and both are entries the app removes with itself")
        XCTAssertTrue(AppFootprint.dataFolderEntries.isSuperset(of: ["Downloads", "Tools"]))
        XCTAssertEqual(stages.values.first, .downloading(received: 0, total: nil))
        XCTAssertEqual(Array(stages.values.suffix(2)), [.verifying, .unpacking])

        // What the app then finds: the pinned engine, under its usual id.
        let engines = BottleEngineDiscovery.discover(
            repoRoot: fixture.repo, dataRoot: fixture.data, home: fixture.home)
        XCTAssertEqual(engines.map(\.id), [BottleEngineDiscovery.pinnedDXMTEngineID])
        XCTAssertEqual(engines.first?.root.path, root.path)
    }

    func testInstalledWineIsNotDownloadedAgain() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.installer.install(fetch: fixture.fetch)
        let calls = Recorder<URL>()
        let outcome = try await fixture.installer.install(fetch: { url, _, _ in
            calls.add(url)
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertEqual(outcome, .alreadyInstalled)
        XCTAssertEqual(calls.values, [])
    }

    func testFileWithAnotherChecksumIsRefusedAndRemoved() async throws {
        let fixture = try makeFixture()
        let other = try makeArchive(files: ["bin/wine", "bin/wineserver",
                                            "lib/wine/x86_64-unix/winemac.so", "extra"])
        let fetch: WineInstaller.Fetch = { url, file, _ in
            try FileManager.default.copyItem(at: other, to: file)
            return url
        }
        await assertInstall(fixture, fetch: fetch, throws: .checksumMismatch)
        try assertNothingLeft(fixture)
    }

    func testArchiveWithoutWinesFilesIsRefusedAndRemoved() async throws {
        for missing in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"] {
            let files = ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"]
                .filter { $0 != missing }
            let fixture = try makeFixture(files: files)
            await assertInstall(fixture, fetch: fixture.fetch, throws: .incompleteArchive)
            try assertNothingLeft(fixture)
        }
    }

    func testFileThatIsNotAnArchiveFailsToUnpackAndIsRemoved() async throws {
        let folder = try temporaryDirectory()
        let junk = folder.appendingPathComponent("junk.tar.xz")
        try Data("not an archive".utf8).write(to: junk)
        let fixture = try makeFixture(archive: junk)
        do {
            _ = try await fixture.installer.install(fetch: fixture.fetch)
            XCTFail("a file that is not an archive must not install")
        } catch let error as WineInstallError {
            guard case .unpackFailed = error else { return XCTFail("\(error)") }
        }
        try assertNothingLeft(fixture)
    }

    func testDownloadThatFailsLeavesNothing() async throws {
        let fixture = try makeFixture()
        let fetch: WineInstaller.Fetch = { _, file, _ in
            // Part of the file arrived before the connection was lost.
            try Data("partial".utf8).write(to: file)
            throw URLError(.networkConnectionLost)
        }
        await assertInstall(fixture, fetch: fetch, throws: .downloadFailed)
        try assertNothingLeft(fixture)
    }

    func testDownloadRedirectedElsewhereIsRefused() async throws {
        let fixture = try makeFixture()
        let archive = fixture.archive
        let fetch: WineInstaller.Fetch = { _, file, _ in
            try FileManager.default.copyItem(at: archive, to: file)
            return URL(string: "https://example.com/wine-devel-11.10-osx64.tar.xz")!
        }
        await assertInstall(fixture, fetch: fetch, throws: .unexpectedSource)
        try assertNothingLeft(fixture)
    }

    func testCancelledInstallLeavesNothing() async throws {
        let fixture = try makeFixture()
        let archive = fixture.archive
        let fetch: WineInstaller.Fetch = { url, file, _ in
            try FileManager.default.copyItem(at: archive, to: file)
            withUnsafeCurrentTask { $0?.cancel() }
            return url
        }
        let installer = fixture.installer
        let install = Task { try await installer.install(fetch: fetch) }
        switch await install.result {
        case .success: XCTFail("a cancelled install must not finish")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try assertNothingLeft(fixture)
    }

    func testTooLittleFreeSpaceStopsBeforeAnyDownload() async throws {
        let fixture = try makeFixture(requiredBytes: 900, freeBytes: 100)
        let calls = Recorder<URL>()
        do {
            _ = try await fixture.installer.install(fetch: { url, _, _ in
                calls.add(url)
                return url
            })
            XCTFail("an install that cannot fit must not start")
        } catch let error as WineInstallError {
            XCTAssertEqual(error, .notEnoughSpace(needed: 900, free: 100))
        }
        XCTAssertEqual(calls.values, [])
        try assertNothingLeft(fixture)
    }

    func testLeftoversOfAnInstallThatWasKilledAreRemovedByTheNext() async throws {
        let fixture = try makeFixture()
        let files = FileManager.default
        try files.createDirectory(at: fixture.installer.partialFolder.appendingPathComponent("old"),
                                  withIntermediateDirectories: true)
        try files.createDirectory(at: fixture.installer.archiveFile.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try Data("old".utf8).write(to: fixture.installer.archiveFile)
        // A folder under the final name that is no usable Wine is replaced.
        try files.createDirectory(at: fixture.installer.installFolder.appendingPathComponent("broken"),
                                  withIntermediateDirectories: true)

        _ = try await fixture.installer.install(fetch: fixture.fetch)

        XCTAssertTrue(fixture.installer.isInstalled)
        XCTAssertEqual(try names(in: fixture.data.appendingPathComponent("Tools")), ["wine-11.10"])
        XCTAssertEqual(try names(in: fixture.installer.installFolder), ["Wine Devel.app"])
        XCTAssertEqual(try names(in: fixture.data.appendingPathComponent("Downloads")), [])
    }

    func testDataFolderWhoseDiskIsAwayIsNotCreated() async throws {
        let data = try temporaryDirectory().appendingPathComponent("Volumes/Gone/TrailBridge")
        let installer = WineInstaller(dataRoot: data)
        do {
            _ = try await installer.install(fetch: { url, _, _ in url })
            XCTFail("nothing may be installed where the data folder is not")
        } catch {
            XCTAssertTrue(error is DataFolderUnavailable, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }

    func testErrorsAreSaidInTheAppsLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let errors: [WineInstallError] = [
            .downloadFailed, .unexpectedSource, .checksumMismatch, .incompleteArchive,
            .unpackFailed("tar: Error"), .notEnoughSpace(needed: 908_000_000, free: 1_000_000),
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            let texts = errors.map(\.localizedDescription)
            XCTAssertEqual(Set(texts).count, errors.count, "\(language)")
            for text in texts { XCTAssertFalse(text.contains("%"), "\(language): \(text)") }
            XCTAssertTrue(texts[4].contains("tar: Error"), "\(language)")
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let data: URL
        let repo: URL
        let home: URL
        let archive: URL
        let installer: WineInstaller
        /// Stands in for the network: the archive arrives as it is.
        var fetch: WineInstaller.Fetch {
            let archive = archive
            return { url, file, progress in
                try FileManager.default.copyItem(at: archive, to: file)
                progress(1, 1)
                return url
            }
        }
    }

    private func makeFixture(
        files: [String] = ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/winemac.so"],
        archive: URL? = nil, requiredBytes: Int64 = 0, freeBytes: Int64? = nil
    ) throws -> Fixture {
        let folder = try temporaryDirectory()
        let data = folder.appendingPathComponent("disk/TrailBridge", isDirectory: true)
        let repo = folder.appendingPathComponent("support", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        for url in [data, repo, home] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let archive = try archive ?? makeArchive(files: files)
        let digest = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }.joined()
        let pin = PinnedHeadsetDownload(version: "11.10", url: source, checksum: digest, digest: .sha256)
        return Fixture(data: data, repo: repo, home: home, archive: archive,
                       installer: WineInstaller(dataRoot: data, pin: pin, requiredBytes: requiredBytes,
                                                freeBytes: { _ in freeBytes }))
    }

    /// A `.tar.xz` shaped like the published one, with empty files.
    private func makeArchive(files: [String]) throws -> URL {
        let folder = try temporaryDirectory()
        let root = folder.appendingPathComponent("content/" + wineRoot, isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("wine-devel-11.10-osx64.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", folder.appendingPathComponent("content").path,
                         "Wine Devel.app"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return archive
    }

    private func assertInstall(_ fixture: Fixture, fetch: @escaping WineInstaller.Fetch,
                               throws expected: WineInstallError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.installer.install(fetch: fetch)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WineInstallError, expected, "\(error)", file: file, line: line)
        }
    }

    /// No archive, no partly unpacked folder, no Wine.
    private func assertNothingLeft(_ fixture: Fixture,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(fixture.installer.isInstalled, file: file, line: line)
        for folder in ["Downloads", "Tools"] {
            let url = fixture.data.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            XCTAssertEqual(try names(in: url), [], folder, file: file, line: line)
        }
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

/// Collects what a `@Sendable` callback reports.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [Value]()
    var values: [Value] { lock.withLock { recorded } }
    func add(_ value: Value) { lock.withLock { recorded.append(value) } }
}
