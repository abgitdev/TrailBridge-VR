import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

final class SteamGameWizardTests: XCTestCase {
    private let finalSection = """
    [time] Startup - updater built Oct 21 2026
    [time] Startup - Steam Client launched with: "C:\\Steam\\steam.exe"
    [time] Verifying installation...
    [time] Verifying file sizes only
    [time] Verification complete
    """

    func testThreeBootstrapGenerationsAtEveryLinePrefix() {
        let lines: [(String, SteamBootstrapState)] = [
            ("Startup - updater built May 20 2024", .updating),
            (#"Startup - Steam Client launched with: "C:\Steam\steam.exe""#, .updating),
            ("Verifying installation...", .updating),
            ("Unable to read and verify install manifest steam_client_win32.installed", .updating),
            ("Verification complete", .updating),
            ("Downloading update...", .updating),
            ("Download complete.", .updating),
            ("Update complete, launching Steam...", .updating),
            ("Shutdown", .updating),
            ("Startup - updater built Jan 29 2026", .updating),
            (#"Startup - Steam Client launched with: "C:\Steam\steam.exe""#, .updating),
            ("Verifying installation...", .updating),
            ("Unable to read and verify install manifest steam_client_win64.installed", .updating),
            ("Verification complete", .updating),
            ("Downloading update...", .updating),
            ("Download complete.", .updating),
            ("Update complete, launching Steam...", .updating),
            ("Shutdown", .updating),
            ("Startup - updater built Oct 21 2026", .updating),
            (#"Startup - Steam Client launched with: "C:\Steam\steam.exe""#, .updating),
            ("Verifying installation...", .updating),
            ("Verifying file sizes only", .updating),
            ("Verification complete", .finished),
        ]
        var text = ""
        for (line, expected) in lines {
            text += "[time] " + line + "\n"
            XCTAssertEqual(SteamBootstrapState.parse(text), expected, line)
            XCTAssertEqual(SteamBootstrapState.parse(text.replacingOccurrences(of: "\n", with: "\r\n")), expected, "CRLF: " + line)
        }
    }

    func testMissingEmptyAndUnrelatedLogAreNotStarted() {
        for text in [nil, "", "Verification complete", "Steam is running"] as [String?] {
            XCTAssertEqual(SteamBootstrapState.parse(text), .notStarted)
        }
    }

    func testOnlyLatestOrdinaryStartupCounts() {
        XCTAssertEqual(SteamBootstrapState.parse(finalSection), .finished)
        XCTAssertEqual(SteamBootstrapState.parse(finalSection + "\nStartup - updater built newer"), .updating)
        XCTAssertEqual(SteamBootstrapState.parse(finalSection + "\nDownloading update (10 of 100 KB)..."), .updating)
        XCTAssertEqual(SteamBootstrapState.parse(finalSection + "\nUpdate complete, launching Steam..."), .updating)
        XCTAssertEqual(SteamBootstrapState.parse(finalSection + "\nDownloading update...\nVerification complete"), .finished)
    }

    func testSuppressedStartupCannotProveAnUpdateFinished() {
        let suppressed = """
        \nStartup - updater built newest
        Startup - Steam Client launched with: "steam.exe" -inhibitbootstrap -noverifyfiles -no-cef-sandbox
        Verification complete
        """
        XCTAssertEqual(SteamBootstrapState.parse(suppressed), .notStarted)
        XCTAssertEqual(SteamBootstrapState.parse("Startup - updater built old\nDownloading update..." + suppressed), .updating)
        XCTAssertEqual(SteamBootstrapState.parse(finalSection + suppressed), .finished)
    }

    func testReadinessRequiresBothFilesAndStableLog() {
        var readiness = SteamBootstrapReadiness()
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 0))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 4.999))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: false, manifestExists: true, now: 5))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: false, now: 5))
        XCTAssertTrue(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 5))
    }

    func testEveryLogChangeResetsStabilityAndEarlyVerificationIsUnsafe() {
        var readiness = SteamBootstrapReadiness()
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 0))
        let downloading = finalSection + "\nDownloading update..."
        XCTAssertFalse(readiness.observe(log: downloading, helperExists: true, manifestExists: true, now: 1))
        XCTAssertFalse(readiness.observe(log: downloading, helperExists: true, manifestExists: true, now: 30))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 31))
        XCTAssertTrue(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 36))
        XCTAssertFalse(readiness.observe(log: nil, helperExists: true, manifestExists: true, now: 37))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: true, now: 38))
    }

    func testFilesystemReadinessUsesInjectedClockAndMissingFiles() throws {
        let fixture = try workspace()
        let steam = try XCTUnwrap(SteamInstallation.executable(in: fixture.bottle.prefix))
        let root = steam.deletingLastPathComponent()
        var readiness = SteamBootstrapReadiness()
        XCTAssertFalse(readiness.observe(steam: steam, now: 0))
        try write(finalSection, to: root.appendingPathComponent("logs/bootstrap_log.txt"))
        XCTAssertFalse(readiness.observe(steam: steam, now: 1))
        XCTAssertFalse(readiness.observe(steam: steam, now: 6))
        try write("helper", to: root.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe"))
        XCTAssertFalse(readiness.observe(steam: steam, now: 7))
        try write("manifest", to: root.appendingPathComponent("package/steam_client_win64.installed"))
        XCTAssertTrue(readiness.observe(steam: steam, now: 8))
    }

    func testAllEightNextSteps() {
        var facts = SteamWizardFacts()
        XCTAssertEqual(facts.nextStep, .choose)
        facts.chosen = true
        XCTAssertEqual(facts.nextStep, .create)
        facts.bottleExists = true
        XCTAssertEqual(facts.nextStep, .prepare)
        facts.prepared = true
        XCTAssertEqual(facts.nextStep, .steam)
        facts.steamExists = true
        XCTAssertEqual(facts.nextStep, .steam)
        facts.bootstrapReady = true
        XCTAssertEqual(facts.nextStep, .signIn)
        facts.loggedOn = true
        XCTAssertEqual(facts.nextStep, .game)
        facts.gameInstalled = true
        XCTAssertEqual(facts.nextStep, .profile)
        facts.profileExists = true
        XCTAssertEqual(facts.nextStep, .done)
    }

    func testResumeReusesBottleAndInstalledGameDoesNotRequireAnotherLogin() {
        var facts = SteamWizardFacts()
        facts.chosen = true
        facts.bottleExists = true
        XCTAssertEqual(facts.nextStep, .prepare)
        facts.prepared = true
        facts.steamExists = true
        XCTAssertEqual(facts.nextStep, .steam)
        facts.bootstrapReady = true
        facts.gameInstalled = true
        XCTAssertEqual(facts.nextStep, .profile)
        facts.profileExists = true
        XCTAssertEqual(facts.nextStep, .done)
        facts.installingSteam = true
        XCTAssertEqual(facts.nextStep, .steam)
    }

    func testConfirmedSignInMovesPastAnUnconfirmedUpdate() {
        var facts = SteamWizardFacts()
        facts.chosen = true
        facts.bottleExists = true
        facts.prepared = true
        facts.steamExists = true
        // Stopped or timed out: the update evidence never appeared.
        XCTAssertEqual(facts.nextStep, .steam)
        facts.loggedOn = true
        XCTAssertEqual(facts.nextStep, .game)
        facts.gameInstalled = true
        XCTAssertEqual(facts.nextStep, .profile)
        facts.profileExists = true
        XCTAssertEqual(facts.nextStep, .done)
        // A running setup and a missing client still hold the wizard on Steam.
        facts.installingSteam = true
        XCTAssertEqual(facts.nextStep, .steam)
        facts.installingSteam = false
        facts.steamExists = false
        XCTAssertEqual(facts.nextStep, .steam)
    }

    func testRetryAfterTimeoutRestartsOnlyAMissingClient() {
        XCTAssertEqual(SteamSetupRetryDecision.decide(ownedClientRunning: false, ready: false),
                       .startPlainSteamIfLogStaysSilent)
        XCTAssertEqual(SteamSetupRetryDecision.decide(ownedClientRunning: true, ready: false), .watch)
        XCTAssertEqual(SteamSetupRetryDecision.decide(ownedClientRunning: false, ready: true), .watch)
        XCTAssertEqual(SteamSetupRetryDecision.decide(ownedClientRunning: true, ready: true), .watch)
        // The restart itself still waits for a silent log, as at installer exit.
        XCTAssertFalse(SteamBootstrapStartDecision.shouldStartPlainSteam(
            logAtExit: finalSection + "\nDownloading update...",
            logNow: finalSection + "\nDownloading update...\nDownload complete."))
        XCTAssertTrue(SteamBootstrapStartDecision.shouldStartPlainSteam(
            logAtExit: finalSection + "\nDownloading update...", logNow: finalSection + "\nDownloading update..."))
    }

    func testInstallerExitCancelledUncheckedRunSteamAndUpdated() {
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: false, bootstrapState: .notStarted, ready: false), .cancelled)
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: false, bootstrapState: .finished, ready: true), .cancelled)
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: true, bootstrapState: .notStarted, ready: false), .startBootstrap)
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: true, bootstrapState: .updating, ready: false), .startBootstrap)
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: true, bootstrapState: .finished, ready: false), .waitForStability)
        XCTAssertEqual(SteamInstallerExitDecision.decide(steamExists: true, bootstrapState: .finished, ready: true), .openSignIn)
    }

    func testInstalledSteamNeedsNoStabilityWaitButStillNeedsFinishedLogAndFiles() {
        var readiness = SteamBootstrapReadiness()
        XCTAssertTrue(readiness.observe(log: finalSection, helperExists: true, manifestExists: true,
                                        now: 0, requireStability: false))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: false, manifestExists: true,
                                         now: 1, requireStability: false))
        XCTAssertFalse(readiness.observe(log: finalSection, helperExists: true, manifestExists: false,
                                         now: 2, requireStability: false))
        XCTAssertFalse(readiness.observe(log: finalSection + "\nDownloading update...", helperExists: true,
                                         manifestExists: true, now: 3, requireStability: false))
        XCTAssertFalse(readiness.observe(log: nil, helperExists: true, manifestExists: true,
                                         now: 4, requireStability: false))
    }

    func testPlainSteamStartsOnlyWhenNothingWritesTheUpdateLog() {
        XCTAssertEqual(SteamBootstrapStartDecision.grace, 20)
        XCTAssertTrue(SteamBootstrapStartDecision.shouldStartPlainSteam(logAtExit: nil, logNow: nil))
        XCTAssertTrue(SteamBootstrapStartDecision.shouldStartPlainSteam(logAtExit: "old", logNow: "old"))
        XCTAssertFalse(SteamBootstrapStartDecision.shouldStartPlainSteam(logAtExit: nil, logNow: "started"))
        XCTAssertFalse(SteamBootstrapStartDecision.shouldStartPlainSteam(logAtExit: "old", logNow: "old\nmore"))
    }

    func testTimeoutBoundaryAndReadyAtDeadline() {
        XCTAssertEqual(SteamBootstrapWaitDecision.decide(ready: false, elapsed: 899.99), .wait)
        XCTAssertEqual(SteamBootstrapWaitDecision.decide(ready: false, elapsed: 900), .timedOut)
        XCTAssertEqual(SteamBootstrapWaitDecision.decide(ready: false, elapsed: 901), .timedOut)
        XCTAssertEqual(SteamBootstrapWaitDecision.decide(ready: true, elapsed: 900), .openSignIn)
    }

    @MainActor func testWaiterPollsAndTimesOutWithInjectedClock() async throws {
        var time: TimeInterval = 0
        var reads = 0
        let result = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: {
            reads += 1; return false
        }, now: { time }, pause: { time += 300 })
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(reads, 4)
    }

    /// The update log of a client that died mid-update: the second updater
    /// generation started, asked for its manifest, hit a Wine page fault a
    /// second later, and every Wine process of the environment was gone
    /// within 15 seconds. Nothing was written after it.
    private let logOfAClientThatDiedMidUpdate = """
    [2026-03-01 12:00:00] Startup - updater built May 20 2024 14:26:54
    [2026-03-01 12:00:00] Startup - Steam Client launched with: "C:\\Program Files (x86)\\Steam\\steam.exe"
    [2026-03-01 12:00:00] Verifying installation...
    [2026-03-01 12:00:00] Unable to read and verify install manifest C:\\Program Files (x86)\\Steam\\package\\steam_client_win32.installed
    [2026-03-01 12:00:00] Verification complete
    [2026-03-01 12:00:00] Downloading update...
    [2026-03-01 12:00:13] Download complete.
    [2026-03-01 12:00:14] Extracting package...
    [2026-03-01 12:00:19] Installing update...
    [2026-03-01 12:00:21] Update complete, launching Steam...
    [2026-03-01 12:00:21] Shutdown

    [2026-03-01 12:00:21] Startup - updater built Jan 29 2026 14:35:32
    [2026-03-01 12:00:21] Startup - Steam Client launched with: "C:\\Program Files (x86)\\Steam\\Steam.exe"
    [2026-03-01 12:00:21] Verifying installation...
    [2026-03-01 12:00:21] Verifying file sizes only
    [2026-03-01 12:00:21] Unable to read and verify install manifest C:\\Program Files (x86)\\Steam\\package\\steam_client_win64.installed
    [2026-03-01 12:00:21] Verification complete
    [2026-03-01 12:00:21] Downloading update...
    [2026-03-01 12:00:21] Checking for available updates...
    [2026-03-01 12:00:21] Downloading manifest: https://client-update.steamstatic.com/steam_client_win64
    [2026-03-01 12:00:21] Manifest download: send request
    [2026-03-01 12:00:21] Manifest download: waiting for download to finish
    """

    /// That log never becomes ready by itself; the waiter starts the client
    /// again once, ten seconds after the last Wine process went, and the
    /// wait then ends when the restarted client finishes the update.
    @MainActor func testWaiterRestartsOnceAClientThatDiedMidUpdate() async throws {
        var time: TimeInterval = 0
        var log = logOfAClientThatDiedMidUpdate
        var readiness = SteamBootstrapReadiness()
        var running = true
        var restarts = [TimeInterval]()
        XCTAssertEqual(SteamBootstrapState.parse(log), .updating)
        let result = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: {
            readiness.observe(log: log, helperExists: true, manifestExists: true, now: time)
        }, clientRunning: { running }, restartClient: {
            restarts.append(time)
            running = true
        }, now: { time }, pause: {
            time += 1
            if time == 16 { running = false }                    // the last process went
            if time == 60 { log += "\n" + self.finalSection }    // the restarted client finished
            if time == 70 { running = false }                    // and went as well: no second restart
        })
        XCTAssertEqual(restarts, [26])
        XCTAssertEqual(result, .openSignIn)
        XCTAssertEqual(time, 65, "ready after the usual five quiet seconds")
    }

    @MainActor func testWaiterWithoutAClientStartsItTwiceThenSaysItIsStuck() async throws {
        var time: TimeInterval = 0
        var restarts = [TimeInterval]()
        var stuck = [TimeInterval]()
        let result = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: { false },
            clientRunning: { false }, restartClient: { restarts.append(time) },
            reportStuck: { if $0 { stuck.append(time) } },
            now: { time }, pause: { time += 1 })
        XCTAssertEqual(restarts, [10, 20], "each restarted client gets its own ten seconds")
        XCTAssertEqual(stuck.first, 30, "then the user is told, and the wait goes on")
        XCTAssertEqual(stuck.count, 870)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(time, 900)
    }

    func testOnlyTenSecondsWithoutAnyProcessCountAsALostClient() {
        XCTAssertEqual(SteamClientLoss.confirmation, 10)
        XCTAssertEqual(SteamClientLoss.restarts, 2)
        var loss = SteamClientLoss()
        // Running, or not known (a shared engine, or the app is about to start Steam itself).
        XCTAssertEqual(loss.observe(running: true, now: 0), .wait)
        XCTAssertEqual(loss.observe(running: nil, now: 100), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 200), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 209.9), .wait)
        // Anything in between starts the count again.
        XCTAssertEqual(loss.observe(running: nil, now: 210), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 211), .wait)
        XCTAssertEqual(loss.observe(running: true, now: 220), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 221), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 230.9), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 231), .restart)
        // The restarted client needs a moment; it gets ten seconds of its own.
        XCTAssertEqual(loss.observe(running: false, now: 232), .wait)
        XCTAssertEqual(loss.observe(running: true, now: 240), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 241), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 251), .restart)
        // Two restarts are used up: from now on a lost client is the user's to decide.
        XCTAssertEqual(loss.observe(running: false, now: 255), .wait)
        XCTAssertEqual(loss.observe(running: false, now: 261), .stuck)
        XCTAssertEqual(loss.observe(running: false, now: 300), .stuck)
        XCTAssertEqual(loss.observe(running: true, now: 301), .wait, "a client that is back is not stuck")
    }

    @MainActor func testWaiterReleasesOnlyWhenReady() async throws {
        var time: TimeInterval = 0
        let result = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: { time >= 5 },
            now: { time }, pause: { time += 1 })
        XCTAssertEqual(result, .openSignIn)
        XCTAssertEqual(time, 5)
    }

    @MainActor func testStopOrDifferentSessionCancelsBeforeAnotherRead() async {
        for replacement in [Optional<UUID>.none, UUID()] {
            let original = UUID()
            var current: UUID? = original
            var reads = 0
            do {
                _ = try await SteamBootstrapWaiter.wait(isCurrent: { current == original }, readReady: {
                    reads += 1; return false
                }, now: { 0 }, pause: { current = replacement })
                XCTFail("Invalid session must not proceed")
            } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(reads, 1)
        }
    }

    @MainActor func testWaiterPropagatesCancellation() async {
        do {
            _ = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: { false },
                pause: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Wrong error") }
    }

    func testGameInstallCommandHasExactArgumentsAndBottleEnvironment() throws {
        let fixture = try workspace()
        let command = try SteamInstallation.installGameCommand(appID: "2669380", bottle: fixture.bottle, manager: fixture.manager)
        XCTAssertEqual(command.arguments, [#"C:\Program Files (x86)\Steam\steam.exe"#,
            "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox", "+app_install", "2669380"])
        XCTAssertEqual(command.environment["WINEPREFIX"], fixture.bottle.prefix.path)
        XCTAssertEqual(command.environment["WINEARCH"], "win64")
        for key in ["TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"] {
            XCTAssertTrue(try XCTUnwrap(command.environment[key]).hasPrefix(fixture.manager.paths.root.path + "/"))
        }
        XCTAssertEqual(command.currentDirectory, SteamInstallation.executable(in: fixture.bottle.prefix)?.deletingLastPathComponent())
    }

    func testInstallCommandRejectsNonASCIIDigitsAndExternalBottles() throws {
        let fixture = try workspace()
        for id in ["", "123 abc", "-1", "123\n", "1;exit", "١٢٣", "１２３", "+123"] {
            XCTAssertThrowsError(try SteamInstallation.installGameCommand(appID: id, bottle: fixture.bottle, manager: fixture.manager), id)
        }
        let external = DiscoveredBottle(name: "external", origin: .whisky, prefix: fixture.bottle.prefix)
        XCTAssertThrowsError(try SteamInstallation.installGameCommand(appID: "123", bottle: external, manager: fixture.manager))
    }

    func testFirstRunHasNoCompatibilityArgumentsOrHelperRequirement() throws {
        let fixture = try workspace()
        let command = try SteamInstallation.firstRunCommand(bottle: fixture.bottle, manager: fixture.manager)
        XCTAssertEqual(command.arguments, [#"C:\Program Files (x86)\Steam\steam.exe"#])
    }

    func testCatalogContainsExactlyTwoVerifiedGamesAndUnverifiedOther() {
        XCTAssertEqual(SteamCatalogGame.verified.map(\.appID),
                       ["2669380", "1032430", "667970", "1592190", "629730"])
        XCTAssertEqual(SteamCatalogGame.all.filter(\.isVerified).count, 5)
        XCTAssertTrue(SteamCatalogGame.verified.allSatisfy { $0.status == "Проверена в шлеме" })
        // BONELAB starts its own OpenXR loader; the others need OpenComposite.
        XCTAssertEqual(SteamCatalogGame.verified.filter { !$0.needsOpenVR }.map(\.name), ["BONELAB"])
        XCTAssertEqual(Set(SteamCatalogGame.verified.compactMap(\.environmentName)).count, 5)
        XCTAssertTrue(SteamCatalogGame.verified.allSatisfy {
            $0.verifiedIn == VerifiedMonth(year: 2026, month: 11)
        })
        XCTAssertNil(SteamCatalogGame.other.verifiedIn)
        XCTAssertEqual(VerifiedMonth(year: 2026, month: 11).text(locale: Locale(identifier: "en")),
                       "November 2026")
        let russian = VerifiedMonth(year: 2026, month: 11).text(locale: Locale(identifier: "ru"))
        XCTAssertTrue(russian.hasPrefix("ноябрь 2026"), russian)
        XCTAssertEqual(SteamCatalogGame.other.name, "Другая игра")
        XCTAssertEqual(SteamCatalogGame.other.status, "Не проверена")
        XCTAssertFalse(SteamCatalogGame.other.isVerified)
        XCTAssertNil(SteamCatalogGame.other.appID)
        XCTAssertEqual(SteamWizardCopy.endToEndCaveat, "Сам мастер пока не проверен от начала до конца на чистом окружении.")
    }

    func testOnlyTheVerifiedSteamGamesCountAsVerified() {
        func profile(_ source: LaunchSource, _ environment: [String: String],
                     arguments: [String] = []) -> LaunchProfile {
            LaunchProfile(name: "game", bottleName: "game", source: source,
                          executable: #"C:\Game\Game.exe"#, arguments: arguments,
                          environment: environment)
        }
        // The two working games, as their profiles are saved.
        XCTAssertTrue(SteamCatalogGame.isVerified(
            profile: profile(.steam, ["SteamAppId": "2669380", "SteamGameId": "2669380"])))
        XCTAssertTrue(SteamCatalogGame.isVerified(profile: profile(.steam, [
            "BASALT_TOUCH_GRIP_PITCH_DEGREES": "15", "SteamAppId": "1032430", "SteamGameId": "1032430",
        ])))
        // Either variable is enough.
        XCTAssertTrue(SteamCatalogGame.isVerified(profile: profile(.steam, ["SteamAppId": "2669380"])))
        XCTAssertTrue(SteamCatalogGame.isVerified(profile: profile(.steam, ["SteamGameId": "1032430"])))

        // Other Steam games, the wizard's -applaunch profiles, and every
        // other source are not verified, whatever their environment says.
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.steam, ["SteamAppId": "620980"])))
        XCTAssertFalse(SteamCatalogGame.isVerified(
            profile: profile(.steam, [:], arguments: ["-applaunch", "2669380"])))
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.steam, ["SteamAppId": " 2669380"])))
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.direct, [:])))
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.direct, ["SteamAppId": "2669380"])))
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.bsmanager, [
            "SteamAppId": "620980", "SteamGameId": "620980", "SteamOverlayGameId": "620980",
        ])))
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile(.itch, ["SteamGameId": "1032430"])))
    }

    func testEnvironmentNameDerivationAndExactBottleManagerValidation() throws {
        XCTAssertEqual(try SteamCatalogGame.verified[0].bottleName(custom: "ignored"), "brutalistick-vr")
        XCTAssertEqual(try SteamCatalogGame.verified[1].bottleName(), "blood-trail")
        XCTAssertEqual(try SteamCatalogGame.other.bottleName(), "steam-games")
        for name in ["a", "Game_1.2-test", String(repeating: "a", count: 64)] {
            XCTAssertEqual(try SteamCatalogGame.other.bottleName(custom: name), try BottleName.validate(name))
        }
        for name in ["", "../game", ".game", "-game", "игра", " game", "game ", "game/name", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try SteamCatalogGame.other.bottleName(custom: name), name)
            XCTAssertThrowsError(try BottleName.validate(name), name)
        }
    }

    func testBottleLevelConnectionLogAndFreshSignInEvidence() throws {
        let fixture = try workspace()
        let log = SteamInstallation.connectionLogURL(in: fixture.bottle.prefix)
        XCTAssertEqual(log.lastPathComponent, "connection_log.txt")
        XCTAssertTrue(log.path.hasSuffix("Steam/logs/connection_log.txt"))
        let old = Data("[Logged On, old]\n".utf8)
        XCTAssertEqual(SteamConnectionLog.state(in: old, after: old.count), .waiting)
        XCTAssertEqual(SteamConnectionLog.state(in: old + Data("[Logged Off, new]\n".utf8), after: old.count), .loggedOff)
        XCTAssertEqual(SteamConnectionLog.state(in: old + Data("[Logged On, new]\n".utf8), after: old.count), .loggedOn)
    }

    func testDiskDiscoveryReusesHalfDoneBottleAndRequiresInstalledManifest() throws {
        let fixture = try workspace()
        let first = try SteamWizardDiskState.read(name: fixture.bottle.name, manager: fixture.manager)
        XCTAssertEqual(first.bottle?.id, fixture.bottle.id)
        XCTAssertFalse(try XCTUnwrap(first.bottle).isReadyForVR)
        let steam = try XCTUnwrap(SteamInstallation.executable(in: fixture.bottle.prefix)).deletingLastPathComponent()
        let gameRoot = steam.appendingPathComponent("steamapps/common/Test")
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let manifest = steam.appendingPathComponent("steamapps/appmanifest_123.acf")
        let content = "\"appid\" \"123\"\n\"name\" \"Test\"\n\"installdir\" \"Test\"\n\"SizeOnDisk\" \"4096\"\n"
        try write(content + "\"StateFlags\" \"1048580\"\n", to: manifest)
        let downloading = try SteamWizardDiskState.read(name: fixture.bottle.name, manager: fixture.manager)
        XCTAssertEqual(downloading.games.first?.sizeOnDisk, 4096)
        XCTAssertTrue(downloading.installedAppIDs.isEmpty)
        try write(content + "\"StateFlags\" \"4\"\n", to: manifest)
        XCTAssertEqual(try SteamWizardDiskState.read(name: fixture.bottle.name, manager: fixture.manager).installedAppIDs, ["123"])
        try write(content, to: manifest)
        XCTAssertTrue(try SteamWizardDiskState.read(name: fixture.bottle.name, manager: fixture.manager).installedAppIDs.isEmpty)
    }

    func testMissingBottleIsDistinctFromDamagedExistingBottle() throws {
        let fixture = try workspace()
        XCTAssertNil(try SteamWizardDiskState.read(name: "missing", manager: fixture.manager).bottle)
        try write("damaged", to: fixture.manager.paths.bottleMetadata(fixture.bottle.name))
        XCTAssertThrowsError(try SteamWizardDiskState.read(name: fixture.bottle.name, manager: fixture.manager))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func workspace() throws -> (manager: BottleManager, bottle: DiscoveredBottle) {
        let repo = try temporaryDirectory()
        let root = repo.appendingPathComponent("data")
        let directory = root.appendingPathComponent("Bottles/test")
        let prefix = directory.appendingPathComponent("prefix")
        let engineRoot = directory.appendingPathComponent("engine")
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try write("fixture, never executed", to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try write("fixture", to: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        let engine = BottleEngine(id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"), root: engineRoot, supportsBasaltDXMT: true)
        let managed = ManagedBottle(name: "test", engine: engine, prefix: prefix, engineRoot: engineRoot, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(managed).write(to: directory.appendingPathComponent("bottle.json"))
        return (BottleManager(root: root, repoRoot: repo),
            DiscoveredBottle(name: "test", origin: .managed, prefix: prefix, managed: managed))
    }

    /// The manifest Steam writes when "Download Game" starts Blood Trail's
    /// download: the wizard says Steam has it and shows the total; an
    /// installed game, or no update under way, is no download.
    func testAManifestOfAGameBeingDownloadedShowsTheDownload() {
        let downloading = """
        "AppState"
        {
        \t"appid"\t\t"1032430"
        \t"name"\t\t"Blood Trail"
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t"Blood Trail"
        \t"SizeOnDisk"\t\t"0"
        \t"BytesToDownload"\t\t"9622224784"
        \t"BytesDownloaded"\t\t"123703568"
        }
        """
        XCTAssertEqual(SteamDownloadState.parse(manifest: downloading),
                       SteamDownloadState(bytesToDownload: 9_622_224_784, isRunning: true))
        let paused = downloading.replacingOccurrences(of: "\"1026\"", with: "\"1538\"")
        XCTAssertEqual(SteamDownloadState.parse(manifest: paused)?.isRunning, false, "paused: it stands still on purpose")
        let queued = downloading.replacingOccurrences(of: "\"1026\"", with: "\"6\"")
        XCTAssertEqual(SteamDownloadState.parse(manifest: queued)?.isRunning, false, "queued, not started")
        let installed = downloading.replacingOccurrences(of: "\"1026\"", with: "\"4\"")
        XCTAssertNil(SteamDownloadState.parse(manifest: installed))
        let noTotal = downloading.replacingOccurrences(of: "\"9622224784\"", with: "\"0\"")
        XCTAssertEqual(SteamDownloadState.parse(manifest: noTotal), SteamDownloadState(bytesToDownload: nil, isRunning: true))
        XCTAssertNil(SteamDownloadState.parse(manifest: "\"AppState\" { }"))

        var facts = SteamWizardFacts()
        facts.chosen = true
        facts.bottleExists = true
        facts.prepared = true
        facts.steamExists = true
        facts.bootstrapReady = true
        facts.loggedOn = true
        facts.gameDownloading = true
        XCTAssertEqual(facts.nextStep, .game, "the wizard waits on the same step")
    }

    /// After a game was added the wizard starts over on the first verified
    /// game not yet in the Library (with Blood Trail added, BRUTALISTICK VR
    /// comes next).
    func testStartingOverOffersTheFirstGameNotYetAdded() {
        func steamProfile(_ appID: String, inArguments: Bool = false) -> LaunchProfile {
            LaunchProfile(name: "p\(appID)", bottleName: "b\(appID)", source: .steam, executable: "steam.exe",
                          arguments: inArguments ? ["-applaunch", appID] : [],
                          environment: inArguments ? [:] : ["SteamAppId": appID])
        }
        let first = SteamCatalogGame.verified[0]
        XCTAssertEqual(SteamCatalogGame.firstNotAdded(profiles: []).id, first.id)
        let bloodTrail = steamProfile("1032430")
        XCTAssertTrue(SteamCatalogGame.verified[1].isAdded(in: [bloodTrail]))
        XCTAssertFalse(first.isAdded(in: [bloodTrail]))
        XCTAssertEqual(SteamCatalogGame.firstNotAdded(profiles: [bloodTrail]).id, first.id)
        let both = [bloodTrail, steamProfile(first.appID!, inArguments: true)]
        XCTAssertEqual(SteamCatalogGame.firstNotAdded(profiles: both).id, SteamCatalogGame.verified[2].id)
        let all = SteamCatalogGame.verified.compactMap(\.appID).map { steamProfile($0) }
        XCTAssertEqual(SteamCatalogGame.firstNotAdded(profiles: all).id, first.id, "all added: the first one")
    }

    /// An update log that stands still while Steam runs: a restart after a
    /// minute, a second one a minute later, then the user is told; a moving
    /// download and the quiet steps after the update never count.
    func testAnUpdateThatStandsStillWhileSteamRunsIsRestartedTwiceThenStuck() {
        let stuck = """
        [2026-03-01 12:00:00] Manifest download: send request
        [2026-03-01 12:00:00] Add pending download: https://cdn.steamstatic.com/client/steamui_websrc_sounds_all.zip
        """
        XCTAssertEqual(SteamUpdateStall.restarts, 2)
        var stall = SteamUpdateStall()
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 0), .wait)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 59), .wait)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 60), .restart)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 119), .wait,
                       "a restarted client that never writes gets its own minute")
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 120), .restart)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 179), .wait)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 180), .stuck)
        XCTAssertEqual(stall.observe(log: stuck, running: true, now: 400), .stuck)
        let moved = stuck + "\n[2026-03-01 12:04:06] Downloading update (1,000 of 336,229 KB)..."
        XCTAssertEqual(stall.observe(log: moved, running: true, now: 401), .wait, "moving again: not stuck")

        var moving = SteamUpdateStall()
        for second in 0..<120 {
            let log = stuck + "\n[2026-03-01 12:04:06] Downloading update (\(second * 1000) of 336,229 KB)..."
            XCTAssertEqual(moving.observe(log: log, running: true, now: TimeInterval(second)), .wait)
        }
        var done = SteamUpdateStall()
        let verified = stuck + "\n[2026-03-01 12:04:41] Verification complete"
        for second in 0..<300 {
            XCTAssertEqual(done.observe(log: verified, running: true, now: TimeInterval(second)), .wait)
        }
        // Not running, or not known: the lost-client rule or nothing applies.
        var gone = SteamUpdateStall()
        for second in 0..<120 {
            XCTAssertEqual(gone.observe(log: stuck, running: second < 50 ? true : nil, now: TimeInterval(second)), .wait)
        }
    }

    @MainActor func testWaiterRestartsAStalledClientTwiceThenSaysItIsStuck() async throws {
        var time: TimeInterval = 0
        var stalled = [TimeInterval]()
        var lost = [TimeInterval]()
        var reports = [TimeInterval: Bool]()
        let log = "[x] Add pending download: https://cdn.steamstatic.com/client/a.zip"
        let result = try await SteamBootstrapWaiter.wait(isCurrent: { true }, readReady: { false },
            clientRunning: { true }, restartClient: { lost.append(time) },
            readLog: { log }, restartStalledClient: { stalled.append(time) },
            reportStuck: { reports[time] = $0 },
            now: { time }, pause: { time += 1 })
        XCTAssertEqual(stalled, [60, 120])
        XCTAssertEqual(lost, [])
        XCTAssertEqual(reports[179], false)
        XCTAssertEqual(reports[180], true)
        XCTAssertEqual(reports[899], true)
        XCTAssertEqual(reports[900], false, "the timeout replaces the message")
        XCTAssertEqual(result, .timedOut)
    }

    /// A download is told by the environment's I/O and Steam's content log:
    /// three minutes with less than a megabyte and no new content-log line
    /// while the manifest says it runs. Paused, done or not known: never.
    func testADownloadThatStandsStillForThreeMinutesIsReported() {
        XCTAssertEqual(SteamDownloadStall.limit, 180)
        var stall = SteamDownloadStall()
        XCTAssertFalse(stall.observe(downloading: true, activity: 10_000_000, contentLogSize: 500, now: 0))
        XCTAssertFalse(stall.observe(downloading: true, activity: 10_500_000, contentLogSize: 500, now: 100),
                       "half a megabyte is Steam's bookkeeping")
        XCTAssertFalse(stall.observe(downloading: true, activity: 10_900_000, contentLogSize: 500, now: 179.9))
        XCTAssertTrue(stall.observe(downloading: true, activity: 10_900_000, contentLogSize: 500, now: 180))
        XCTAssertFalse(stall.observe(downloading: true, activity: 12_000_000, contentLogSize: 500, now: 181),
                       "a megabyte more: it moves again")
        XCTAssertFalse(stall.observe(downloading: true, activity: 12_000_000, contentLogSize: 600, now: 300),
                       "a new content-log line counts as a move")
        XCTAssertFalse(stall.observe(downloading: true, activity: 12_000_000, contentLogSize: 600, now: 479))
        XCTAssertTrue(stall.observe(downloading: true, activity: 12_000_000, contentLogSize: 600, now: 480))
        // A process that ended makes the sum fall; that is a change, not a stall.
        XCTAssertFalse(stall.observe(downloading: true, activity: 2_000_000, contentLogSize: 600, now: 481))
        // Paused or finished, or the counter unknown: the count starts again.
        XCTAssertFalse(stall.observe(downloading: false, activity: 2_000_000, contentLogSize: 600, now: 700))
        XCTAssertFalse(stall.observe(downloading: true, activity: 2_000_000, contentLogSize: 600, now: 701))
        XCTAssertFalse(stall.observe(downloading: true, activity: nil, contentLogSize: 600, now: 900))
        XCTAssertFalse(stall.observe(downloading: true, activity: 2_000_000, contentLogSize: 600, now: 901))
        XCTAssertFalse(stall.observe(downloading: true, activity: 2_000_000, contentLogSize: 600, now: 1080))
        XCTAssertTrue(stall.observe(downloading: true, activity: 2_000_000, contentLogSize: 600, now: 1081))
    }
}
