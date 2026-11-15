import XCTest
import CryptoKit
import BasaltCore
@testable import BasaltManagerKit

private final class FakeHeadsetRunner: HeadsetCommandRunning, @unchecked Sendable {
    var calls = [[String]]()
    var environments = [[String: String]]()
    var results = [HeadsetCommandResult]()
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> HeadsetCommandResult {
        calls.append(arguments); environments.append(environment)
        guard !results.isEmpty else { XCTFail("Unexpected process invocation"); return .init(status: 1, output: "unexpected") }
        return results.removeFirst()
    }
}

private final class HeadsetFixtureFileManager: FileManager, @unchecked Sendable {
    let adbPath: String
    init(adbPath: String) { self.adbPath = adbPath; super.init() }
    override func isExecutableFile(atPath path: String) -> Bool { path == adbPath }
}

final class HeadsetSetupTests: XCTestCase {
    private let devices = "List of devices attached\nTEST device usb:1 model:Quest_3 transport_id:1\n"

    func testNoHeadsetAndUnauthorizedStatus() {
        XCTAssertEqual(HeadsetStatus.parse(devices: "List of devices attached\n").connection, .none)
        XCTAssertEqual(HeadsetStatus.parse(devices: "List of devices attached\nTEST unauthorized usb:1\n").connection, .unauthorized)
        XCTAssertEqual(HeadsetStatus.parse(devices: "List of devices attached\n192.0.2.1:5555 device model:Quest_3\n").connection, .none)
    }

    func testConnectedModelAndPackageVersion() {
        let status = HeadsetStatus.parse(devices: devices,
            package: "  Package [alvr.client.stable] (abc):\n    versionName=20.14.1\n")
        XCTAssertEqual(status.connection, .connected)
        XCTAssertEqual(status.model, "Quest 3")
        XCTAssertEqual(status.serial, "TEST")
        XCTAssertTrue(status.clientInstalled)
        XCTAssertEqual(status.clientVersion, "20.14.1")
    }

    func testMissingPackageAndUnknownVersionRemainDistinct() {
        let missing = HeadsetStatus.parse(devices: devices, package: "Unable to find package: alvr.client.stable")
        XCTAssertFalse(missing.clientInstalled)
        XCTAssertNil(missing.clientVersion)
        let unknown = HeadsetStatus.parse(devices: devices, package: "Package [alvr.client.stable]")
        XCTAssertTrue(unknown.clientInstalled)
        XCTAssertNil(unknown.clientVersion)
        XCTAssertEqual(HeadsetStatus.parse(devices: devices, package: "versionName=21.0.0\n").clientVersion, "21.0.0")
    }

    func testAnADBServerStartedByThisAppIsStoppedOnce() throws {
        let root = try temporaryDirectory()
        let runner = FakeHeadsetRunner()
        runner.results = [.init(status: 0, output: "* daemon not running; starting now at tcp:5039\n"
            + "* daemon started successfully\nList of devices attached\n")]
        let setup = HeadsetSetup(dataRoot: root, runner: runner,
                                 locate: { URL(fileURLWithPath: "/fixture/adb") },
                                 serverOwnership: AlvrADBServerOwnership())
        XCTAssertEqual(try setup.inspect().connection, HeadsetStatus.Connection.none)
        var stopped = [(adb: URL, environment: [String: String])]()
        XCTAssertTrue(setup.stopServerIfStartedHere { stopped.append(($0, $1)) })
        XCTAssertEqual(stopped.map(\.adb.path), ["/fixture/adb"])
        XCTAssertEqual(stopped.first?.environment["ADB_SERVER_SOCKET"], "tcp:localhost:5039",
                       "the app's own server, not the one other tools use")
        XCTAssertFalse(setup.stopServerIfStartedHere { _, _ in XCTFail("already stopped") })
        XCTAssertEqual(runner.calls, [["devices", "-l"]], "the test started no adb")
    }

    func testAnADBServerThatWasAlreadyRunningIsLeftAlone() throws {
        let root = try temporaryDirectory()
        let runner = FakeHeadsetRunner()
        runner.results = [.init(status: 0, output: "List of devices attached\n")]
        let setup = HeadsetSetup(dataRoot: root, runner: runner,
                                 locate: { URL(fileURLWithPath: "/fixture/adb") },
                                 serverOwnership: AlvrADBServerOwnership())
        _ = try setup.inspect()
        XCTAssertFalse(setup.stopServerIfStartedHere { _, _ in
            XCTFail("someone else's adb server must not be stopped")
        })
    }

    func testAnADBServerLeftByAnEarlierRunIsStoppedOnTheAppsOwnPort() throws {
        let root = try temporaryDirectory()
        // This app run has started no server: the marker of the run that
        // crashed is the caller's reason to ask.
        let setup = HeadsetSetup(dataRoot: root, runner: FakeHeadsetRunner(),
                                 locate: { URL(fileURLWithPath: "/fixture/adb") },
                                 serverOwnership: AlvrADBServerOwnership())
        var stopped = [(adb: URL, environment: [String: String])]()
        XCTAssertTrue(setup.stopServerLeftByEarlierRun { stopped.append(($0, $1)) })
        XCTAssertEqual(stopped.map(\.adb.path), ["/fixture/adb"])
        XCTAssertEqual(stopped.first?.environment["ADB_SERVER_SOCKET"], "tcp:localhost:5039",
                       "the app's own server, not the one other tools use")
        let noTools = HeadsetSetup(dataRoot: root, runner: FakeHeadsetRunner(), locate: { nil },
                                   serverOwnership: AlvrADBServerOwnership())
        XCTAssertFalse(noTools.stopServerLeftByEarlierRun { _, _ in XCTFail("no adb to ask") })
    }

    func testInspectorUsesInjectedRunnerAndExactStablePackage() throws {
        let root = try temporaryDirectory()
        let runner = FakeHeadsetRunner()
        runner.results = [.init(status: 0, output: devices), .init(status: 0, output: "Package [alvr.client.stable]\n versionName=20.14.1")]
        let setup = HeadsetSetup(dataRoot: root, runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertEqual(try setup.inspect().clientVersion, "20.14.1")
        XCTAssertEqual(runner.calls, [["devices", "-l"], ["-s", "TEST", "shell", "dumpsys", "package", "alvr.client.stable"]])
        XCTAssertEqual(runner.environments.first?["ANDROID_USER_HOME"], root.appendingPathComponent("Tools/Android").path)
    }

    func testMissingToolsNeverInvokesProcess() throws {
        let runner = FakeHeadsetRunner()
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { nil })
        XCTAssertEqual(try setup.inspect().connection, .noTools)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testManagedToolsCanBeLocatedThroughInjectedFileSystem() throws {
        let root = try temporaryDirectory()
        let fileManager = HeadsetFixtureFileManager(adbPath: root.appendingPathComponent("Tools/platform-tools/adb").path)
        let setup = HeadsetSetup(dataRoot: root, runner: FakeHeadsetRunner(), fileManager: fileManager)
        XCTAssertTrue(setup.adbAvailable)
        // The fixture declares the managed executable without creating or running it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileManager.adbPath))
    }

    func testADBFailureIsAnErrorNotNoHeadset() throws {
        let runner = FakeHeadsetRunner(); runner.results = [.init(status: 1, output: "server failed")]
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertThrowsError(try setup.inspect()) { XCTAssertTrue($0.localizedDescription.contains("server failed")) }
    }

    func testPinnedOfficialURLsAndVersions() {
        XCTAssertEqual(PinnedHeadsetDownload.platformTools.version, "37.0.1")
        XCTAssertEqual(PinnedHeadsetDownload.platformTools.url.absoluteString, "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")
        XCTAssertEqual(PinnedHeadsetDownload.platformTools.checksum, "6ae73f4de6452dc57e62ec02b68eed92a4c21661")
        XCTAssertEqual(PinnedHeadsetDownload.testedALVR.version, "20.14.1")
        XCTAssertEqual(PinnedHeadsetDownload.testedALVR.url.absoluteString, "https://github.com/alvr-org/ALVR/releases/download/v20.14.1/alvr_client_android.apk")
        XCTAssertEqual(PinnedHeadsetDownload.testedALVR.checksum, "be68feeb02665e3d69f1cdbcabf38ea4d15c42868a7ec6b5e698dbefee4e4e36")
        XCTAssertFalse(PinnedHeadsetDownload.platformTools.url.absoluteString.contains("latest"))
    }

    func testPinnedURLAndChecksumRejection() {
        for pin in [PinnedHeadsetDownload.platformTools, .testedALVR] {
            XCTAssertThrowsError(try pin.verify(Data("tampered".utf8), requestedURL: pin.url))
            XCTAssertThrowsError(try pin.verify(Data(), requestedURL: URL(string: "https://example.com/fake")!))
        }
    }

    func testBothChecksumAlgorithmsAcceptMatchingBytes() throws {
        let data = Data("fixture".utf8)
        for (algorithm, checksum) in [
            (PinnedHeadsetDownload.Digest.sha1, Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()),
            (.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        ] {
            let pin = PinnedHeadsetDownload(version: "fixture", url: URL(string: "https://github.com/fixture")!, checksum: checksum, digest: algorithm)
            XCTAssertNoThrow(try pin.verify(data, requestedURL: pin.url))
        }
    }

    func testInjectedDownloadRejectsChecksumBeforeWriting() async throws {
        let directory = try temporaryDirectory()
        do {
            _ = try await HeadsetSetup.download(.testedALVR, into: directory) { url in (Data("fake APK".utf8), url) }
            XCTFail("Expected checksum rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("checksum")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUnexpectedRedirectIsRejected() async throws {
        let directory = try temporaryDirectory()
        do {
            _ = try await HeadsetSetup.download(.platformTools, into: directory) { _ in (Data(), URL(string: "https://example.com/tools.zip")!) }
            XCTFail("Expected source rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unexpected source")) }
    }

    func testInvalidCachedAPKCannotInvokeADBOrUninstall() throws {
        let directory = try temporaryDirectory(), runner = FakeHeadsetRunner()
        let apk = directory.appendingPathComponent("client.apk"); try Data().write(to: apk)
        let setup = HeadsetSetup(dataRoot: directory, runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertThrowsError(try setup.installClient(apk: apk, serial: "TEST", replacingOldClient: true))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSignatureMismatchNeverUninstallsWithoutExplicitChoice() throws {
        let runner = FakeHeadsetRunner()
        runner.results = [.init(status: 1, output: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]")]
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertThrowsError(try setup.installVerifiedClient(apk: URL(fileURLWithPath: "/fixture/client.apk"), serial: "TEST", replacingOldClient: false)) {
            guard case HeadsetInstallError.signatureMismatch = $0 else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.prefix(4), ["-s", "TEST", "install", "-r"])
    }

    func testExplicitReplacementUninstallsThenInstallsAndStopsOnError() throws {
        let runner = FakeHeadsetRunner()
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        runner.results = [.init(status: 0, output: "Success"), .init(status: 0, output: "Success")]
        try setup.installVerifiedClient(apk: URL(fileURLWithPath: "/fixture/client.apk"), serial: "TEST", replacingOldClient: true)
        XCTAssertEqual(runner.calls.first, ["-s", "TEST", "uninstall", "alvr.client.stable"])
        XCTAssertEqual(runner.calls.count, 2)
        runner.calls = []; runner.results = [.init(status: 1, output: "uninstall failed")]
        XCTAssertThrowsError(try setup.installVerifiedClient(apk: URL(fileURLWithPath: "/fixture/client.apk"), serial: "TEST", replacingOldClient: true))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testInstallFailureWithoutSignatureIsOrdinaryError() throws {
        let runner = FakeHeadsetRunner(); runner.results = [.init(status: 1, output: "INSTALL_FAILED_INSUFFICIENT_STORAGE")]
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertThrowsError(try setup.installVerifiedClient(apk: URL(fileURLWithPath: "/fixture/client.apk"), serial: "TEST", replacingOldClient: false)) {
            XCTAssertTrue($0.localizedDescription.contains("INSUFFICIENT_STORAGE"))
        }
    }

    func testDowngradeRequiresExplicitReplacementToo() throws {
        let runner = FakeHeadsetRunner(); runner.results = [.init(status: 1, output: "INSTALL_FAILED_VERSION_DOWNGRADE")]
        let setup = HeadsetSetup(dataRoot: try temporaryDirectory(), runner: runner, locate: { URL(fileURLWithPath: "/fixture/adb") })
        XCTAssertThrowsError(try setup.installVerifiedClient(apk: URL(fileURLWithPath: "/fixture/client.apk"), serial: "TEST", replacingOldClient: false)) {
            guard case HeadsetInstallError.newerVersionInstalled = $0 else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(runner.calls.count, 1)
    }
}
