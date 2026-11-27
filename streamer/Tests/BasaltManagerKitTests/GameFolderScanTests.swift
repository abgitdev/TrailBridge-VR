import XCTest
@testable import BasaltBottleKit
@testable import BasaltManagerKit

/// Add Game from Folder: what the sheet offers for a scanned folder, the
/// names it suggests, the space rule, and the profile of the copied game.
final class GameFolderScanTests: XCTestCase {
    // MARK: - Executables

    func testTheShippingBinaryLeadsAndHelpersAreCollapsed() {
        // An Unreal game laid out like Blood Trail's install folder.
        let scan = GameFolderScan(inventory: inventory("Blood Trail", files: [
            "BTVR.exe",
            "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe",
            "BTVR/Binaries/ThirdParty/Steamworks/Steamv153/Win64/steam_api64.dll",
            "Engine/Binaries/Win64/CrashReportClient.exe",
            "Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe",
            "_CommonRedist/vcredist/2019/VC_redist.x64.exe",
            "_CommonRedist/DirectX/Jun2010/DXSETUP.exe",
            "unins000.exe",
        ]))

        XCTAssertEqual(scan.gameExecutables.map(\.path), [
            "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe", "BTVR.exe",
        ])
        XCTAssertEqual(scan.suggestedExecutable?.path, "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe")
        XCTAssertEqual(scan.otherExecutables.map(\.path), [
            "unins000.exe",
            "Engine/Binaries/Win64/CrashReportClient.exe",
            "_CommonRedist/DirectX/Jun2010/DXSETUP.exe",
            "_CommonRedist/vcredist/2019/VC_redist.x64.exe",
            "Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe",
        ])
        XCTAssertTrue(scan.otherExecutables.allSatisfy { $0.kind == .helper })
        XCTAssertEqual(scan.executables, scan.gameExecutables + scan.otherExecutables)
        XCTAssertEqual(scan.hints, [.steamAPI])
        XCTAssertNil(scan.refusal)
        XCTAssertEqual(scan.suggestedTitle, "Blood Trail")
        XCTAssertEqual(scan.destinationFolderName, "Blood Trail")
    }

    func testTheExecutableNamedLikeTheFolderComesFirstThenShallowerThenByName() {
        let unity = GameFolderScan(inventory: inventory("Beat Saber", files: [
            "Beat Saber_Data/Plugins/x86_64/steam_api64.dll",
            "UnityCrashHandler64.exe",
            "Beat Saber.exe",
        ]))
        XCTAssertEqual(unity.executables.map(\.path), ["Beat Saber.exe", "UnityCrashHandler64.exe"])
        XCTAssertEqual(unity.executables.map(\.kind), [.game, .helper])

        // Case, spaces and punctuation do not count when matching the folder.
        let spaced = GameFolderScan(inventory: inventory("Some Game", files: [
            "Launcher.exe", "SOMEGAME.exe", "Tools/Editor.exe",
        ]))
        XCTAssertEqual(spaced.suggestedExecutable?.path, "SOMEGAME.exe")

        // Without a name match: shallower first, then natural name order.
        let plain = GameFolderScan(inventory: inventory("hello-xr", files: [
            "bin/a.exe", "Game10.exe", "game2.exe", "Alpha.exe",
        ]))
        XCTAssertEqual(plain.executables.map(\.path), ["Alpha.exe", "game2.exe", "Game10.exe", "bin/a.exe"])
        XCTAssertEqual(plain.executables.map(\.depth), [0, 0, 0, 1])

        // The executable named like the folder comes before the Shipping binary.
        let named = GameFolderScan(inventory: inventory("BTVR", files: [
            "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe", "BTVR.exe",
        ]))
        XCTAssertEqual(named.executables.map(\.path), [
            "BTVR.exe", "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe",
        ])
    }

    func testHelpersAndInstallersAreKnownByNameAndFolder() {
        let cases: [(String, GameFolderExecutable.Kind)] = [
            ("UnityCrashHandler64.exe", .helper),
            ("UnityCrashHandler32.exe", .helper),
            ("Engine/Binaries/Win64/CrashReportClient.exe", .helper),
            ("crashpad_handler.exe", .helper),
            ("vc_redist.x64.exe", .helper),
            ("vcredist_x86.exe", .helper),
            ("DXSETUP.exe", .helper),
            ("dxsetup.EXE", .helper),
            ("dotNetFx40_Full_setup.exe", .helper),
            ("UE4PrereqSetup_x64.exe", .helper),
            ("UEPrereqSetup_x64.exe", .helper),
            ("unins000.exe", .helper),
            ("Uninstall.exe", .helper),
            ("_CommonRedist/Anything/Tool.exe", .helper),
            ("Redist/tool.exe", .helper),
            ("__Installer/directx/redist/DXSETUP.exe", .helper),
            ("Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe", .helper),
            ("setup.exe", .installer),
            ("setup_some_game_1.2.exe", .installer),
            ("GameInstaller.exe", .installer),
            ("Install.exe", .installer),
            ("Beat Saber.exe", .game),
            ("BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe", .game),
            ("Launcher.exe", .game),
            ("Engine/Binaries/Win64/Game.exe", .game),
            ("khr_hello_xr_d3d11.exe", .game),
        ]
        for (path, kind) in cases {
            XCTAssertEqual(GameFolderScan.kind(ofExecutableAt: path), kind, path)
        }
    }

    func testHiddenFilesAndFoldersAreSkipped() {
        let scan = GameFolderScan(inventory: inventory("Game", files: [
            "._Game.exe",
            ".Game.exe",
            ".backup/Game.exe",
            "__MACOSX/._Game.exe",
            "Data/.cache/steam_api64.dll",
            "Data/.cache/openvr_api.dll",
            "Game.EXE",
            "readme.txt",
        ]))
        XCTAssertEqual(scan.executables.map(\.path), ["Game.EXE"])
        XCTAssertEqual(scan.hints, [])

        let onlyHidden = GameFolderScan(inventory: inventory("Game", files: [".backup/Game.exe", "._Game.exe"]))
        XCTAssertEqual(onlyHidden.executables, [])
        XCTAssertEqual(onlyHidden.refusal, .noExecutable)
    }

    // MARK: - Hints and refusals

    func testSteamAndOpenVRLibrariesGiveHintsByNameAnywhere() {
        func hints(_ files: [String]) -> [GameFolderHint] {
            GameFolderScan(inventory: inventory("Game", files: ["Game.exe"] + files)).hints
        }
        XCTAssertEqual(hints([]), [])
        XCTAssertEqual(hints(["steam_api64.dll"]), [.steamAPI])
        XCTAssertEqual(hints(["Game_Data/Plugins/x86/steam_api.dll"]), [.steamAPI])
        XCTAssertEqual(hints(["Game_Data/Plugins/STEAM_API64.DLL"]), [.steamAPI])
        XCTAssertEqual(hints(["Game_Data/Plugins/x86_64/openvr_api.dll"]), [.openVR])
        XCTAssertEqual(hints(["openvr_api.dll", "steam_api64.dll", "steam_api.dll"]), [.steamAPI, .openVR])
        // Similar names are not the libraries.
        XCTAssertEqual(hints(["steam_api64.dll.bak", "my_openvr_api.dll", "steam_appid.txt"]), [])
        XCTAssertEqual(GameFolderScan.hints(in: inventory("Game", files: ["Game.exe", "openvr_api.dll"])),
                       [.openVR])
    }

    func testAnEmptyFolderIsRefusedWithoutHints() {
        let scan = GameFolderScan(inventory: inventory("Empty", files: []))
        XCTAssertEqual(scan.executables, [])
        XCTAssertNil(scan.suggestedExecutable)
        XCTAssertEqual(scan.hints, [])
        XCTAssertEqual(scan.refusal, .noExecutable)
        XCTAssertEqual(GameFolderScan.refusal(for: inventory("Docs", files: ["readme.txt"])), .noExecutable)
    }

    func testAFolderWithOnlyAnInstallerSaysSo() {
        let gog = GameFolderScan(inventory: inventory("Downloads", files: [
            "setup_some_game_1.2.exe", "setup_some_game_1.2-1.bin",
        ]))
        XCTAssertEqual(gog.executables.map(\.kind), [.installer])
        XCTAssertNil(gog.suggestedExecutable)
        XCTAssertEqual(gog.hints, [.installerOnly])
        // The user can still pick it under "Other .exe files".
        XCTAssertNil(gog.refusal)

        let package = GameFolderScan(inventory: inventory("Package", files: ["Game.msi", "readme.txt"]))
        XCTAssertEqual(package.hints, [.installerOnly])
        XCTAssertEqual(package.refusal, .noExecutable)

        // A game next to its installer is a game folder.
        let game = GameFolderScan(inventory: inventory("Game", files: [
            "Game.exe", "Setup.exe", "redist/vcredist_x64.exe",
        ]))
        XCTAssertEqual(game.hints, [])
        XCTAssertEqual(game.executables.map(\.kind), [.game, .installer, .helper])

        // Helpers alone are not an installer, runtime packages neither, and
        // nothing is preselected.
        let helpers = GameFolderScan(inventory: inventory("Redist", files: [
            "unins000.exe", "_CommonRedist/XNA/4.0/xnafx40_redist.msi", "vcredist_x64.msi",
        ]))
        XCTAssertEqual(helpers.hints, [])
        XCTAssertNil(helpers.suggestedExecutable)
        XCTAssertNil(helpers.refusal)
    }

    func testRejectedEntriesAreRefusedBeforeAMissingExecutable() {
        // The only .exe is a link, so the scan has no .exe file at all.
        let linked = GameFolderScan(inventory: inventory(
            "Game", files: ["data.bin"],
            rejected: [.init(path: "Game.exe", reason: .symbolicLink),
                       .init(path: "pipe", reason: .namedPipe)],
            rejectedCount: 7))
        XCTAssertEqual(linked.refusal, .unsupportedEntries(examples: ["Game.exe", "pipe"], count: 7))

        let conflicts = GameFolderScan(inventory: inventory(
            "Game", files: ["Game.exe", "data/a.bin", "Data/a.bin"],
            caseConflicts: ["data", "Data"], caseConflictCount: 1))
        XCTAssertEqual(conflicts.refusal, .caseConflicts(examples: ["data", "Data"], count: 1))
    }

    func testScanErrorsBecomeRefusalsAndOtherErrorsDoNot() {
        XCTAssertEqual(GameFolderRefusal(error: GameFolderCopyError.tooManyEntries(limit: 100_000)),
                       .tooManyEntries(limit: 100_000))
        XCTAssertEqual(GameFolderRefusal(error: GameFolderCopyError.sourceOverlapsDataFolder("/data")),
                       .insideDataFolder)
        XCTAssertEqual(GameFolderRefusal(error: GameFolderCopyError.unsupportedEntries(
            examples: [.init(path: "Link.exe", reason: .symbolicLink)], count: 3)),
                       .unsupportedEntries(examples: ["Link.exe"], count: 3))
        XCTAssertEqual(GameFolderRefusal(error: GameFolderCopyError.caseConflicts(examples: ["a", "A"], count: 1)),
                       .caseConflicts(examples: ["a", "A"], count: 1))
        for error: Error in [GameFolderCopyError.cancelled, GameFolderCopyError.sourceNotFolder("/x"),
                             GameFolderCopyError.failed("disk"), BottleToolError("other")] {
            XCTAssertNil(GameFolderRefusal(error: error), "\(error)")
        }
    }

    func testRefusalsHintsAndNameProblemsSpeakTheAppLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(
            GameFolderRefusal.unsupportedEntries(examples: ["Data/link", "pipe"], count: 7).message,
            "The folder contains items that cannot be copied safely, such as symbolic links or special "
            + "files (7 in all): Data/link, pipe")
        XCTAssertEqual(GameFolderRefusal.caseConflicts(examples: ["data", "Data"], count: 1).message,
                       "The folder contains names that differ only in letter case, which Windows cannot "
                       + "tell apart: data, Data")
        XCTAssertEqual(GameFolderRefusal.tooManyEntries(limit: 100_000).message,
                       "The folder holds more than 100,000 files and folders. Choose the game’s own folder.")
        XCTAssertEqual(GameFolderRefusal.noExecutable.message, L10n.string(.folderImportNoExecutable))
        XCTAssertEqual(GameFolderRefusal.insideDataFolder.message, L10n.string(.folderImportInsideData))
        XCTAssertEqual(GameFolderHint.steamAPI.message, L10n.string(.folderImportSteamHint))
        XCTAssertEqual(GameFolderHint.openVR.message, L10n.string(.folderImportOpenVRHint))
        XCTAssertEqual(GameFolderHint.installerOnly.message, L10n.string(.folderImportInstallerHint))
        XCTAssertEqual(GameFolderEnvironmentNameProblem.taken.message(for: "beat-saber"),
                       "The name “beat-saber” is already in use. Choose another one.")
        XCTAssertEqual(GameFolderEnvironmentNameProblem.invalid.message(for: "beat saber"),
                       L10n.string(.folderImportEnvironmentInvalid))

        L10n.language = .ru
        let limit = 100_000.formatted(.number.locale(Locale(identifier: "ru")))
        XCTAssertEqual(GameFolderRefusal.tooManyEntries(limit: 100_000).message,
                       L10n.string(.folderImportTooManyEntries, language: .ru, arguments: [limit]))
        XCTAssertEqual(GameFolderEnvironmentNameProblem.taken.message(for: "beat-saber"),
                       L10n.string(.folderImportEnvironmentTaken, language: .ru, arguments: ["beat-saber"]))
        let addSteam = L10n.string(.libraryAddSteam, language: .ru, arguments: [])
        let quotedAddSteam = L10n.string(.learningQuoted, language: .ru, arguments: [addSteam])
        XCTAssertTrue(GameFolderHint.steamAPI.message.contains(quotedAddSteam))
    }

    // MARK: - Names

    func testTheTitleAndTheCopysNameComeFromTheFolder() {
        XCTAssertEqual(GameFolderScan.suggestedTitle(forFolderNamed: "Beat Saber"), "Beat Saber")
        XCTAssertEqual(GameFolderScan.suggestedTitle(forFolderNamed: "  hello_xr \n"), "hello_xr")
        // No name to offer: the sheet asks for one.
        XCTAssertEqual(GameFolderScan.suggestedTitle(forFolderNamed: "/"), "")
        XCTAssertEqual(GameFolderScan.suggestedTitle(forFolderNamed: "   "), "")

        let names: [(String, String)] = [
            ("Beat Saber", "Beat Saber"),
            ("ゲーム", "ゲーム"),
            ("hello-xr", "hello-xr"),
            ("Half-Life: Alyx", "half-life-alyx"),
            ("Game.", "game"),
            ("Game ", "game"),
            (".hidden", "hidden"),
            ("***", "game"),
            ("CON", "game-con"),
            ("nul.txt", "game-nul.txt"),
            ("com1", "game-com1"),
            ("LPT9.", "game-lpt9"),
        ]
        for (folder, expected) in names {
            let name = GameFolderScan.destinationFolderName(forFolderNamed: folder)
            XCTAssertEqual(name, expected, folder)
            XCTAssertTrue(GameFolderName.isValid(name), folder)
        }
        // The slug is cut at 56 characters; a dot left at the end goes too.
        let long = String(repeating: "a", count: 55) + ".bcd:efg"
        let cut = GameFolderScan.destinationFolderName(forFolderNamed: long)
        XCTAssertEqual(cut, String(repeating: "a", count: 55))
        XCTAssertTrue(GameFolderName.isValid(cut))
        let tooLong = String(repeating: "Long Name ", count: 10)
        XCTAssertTrue(GameFolderName.isValid(GameFolderScan.destinationFolderName(forFolderNamed: tooLong)))
    }

    func testEnvironmentNamesAreNewSlugsIgnoringCase() {
        XCTAssertEqual(GameFolderScan.environmentName(for: "Beat Saber", taken: []), "beat-saber")
        // The Steam wizard remembers "Beat-Saber" for an environment it may still create.
        XCTAssertEqual(GameFolderScan.environmentName(for: "Beat Saber", taken: ["Beat-Saber"]), "beat-saber-2")
        XCTAssertEqual(GameFolderScan.environmentName(for: "Beat Saber", taken: ["beat-saber", "BEAT-SABER-2"]),
                       "beat-saber-3")
        // The verified games' environments are reserved even before they exist.
        XCTAssertEqual(GameFolderScan.reservedEnvironmentNames,
                       ["brutalistick-vr", "blood-trail", "vtol-vr", "bonelab", "blade-sorcery",
                        "tactical-assault-vr", "skyrim-vr"])
        XCTAssertEqual(GameFolderScan.environmentName(for: "Blood Trail", taken: []), "blood-trail-2")
        XCTAssertEqual(GameFolderScan.environmentName(for: "BRUTALISTICK VR", taken: ["brutalistick-vr-2"]),
                       "brutalistick-vr-3")
        XCTAssertEqual(GameFolderScan.environmentName(for: "hello_xr", taken: ["steam-games"]), "hello_xr")
        XCTAssertEqual(GameFolderScan.environmentName(for: "ゲーム", taken: []), "game")
        XCTAssertEqual(GameFolderScan.environmentName(for: "", taken: []), "game")
        for title in ["Beat Saber", "***", "Café Über", String(repeating: "Long Name ", count: 10)] {
            let name = GameFolderScan.environmentName(for: title, taken: ["game", "game-2"])
            XCTAssertNoThrow(try BottleName.validate(name), title)
        }
    }

    func testEveryEntryInBottlesCountsAsTaken() throws {
        let bottles = try scratchFolder().appendingPathComponent("Bottles", isDirectory: true)
        XCTAssertEqual(GameFolderScan.environmentFolderNames(in: bottles), [])

        // A half-made environment without bottle.json, a ready one, and a stray file.
        try FileManager.default.createDirectory(
            at: bottles.appendingPathComponent("beat-saber/prefix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bottles.appendingPathComponent("Hello-XR"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bottles.appendingPathComponent("Hello-XR/bottle.json"))
        try Data().write(to: bottles.appendingPathComponent("stray"))

        let taken = GameFolderScan.environmentFolderNames(in: bottles)
        XCTAssertEqual(Set(taken), ["beat-saber", "Hello-XR", "stray"])
        XCTAssertEqual(GameFolderScan.environmentName(for: "Beat Saber", taken: taken), "beat-saber-2")
        XCTAssertEqual(GameFolderScan.environmentName(for: "hello xr", taken: taken), "hello-xr-2")
        XCTAssertEqual(GameFolderScan.environmentName(for: "Stray", taken: taken), "stray-2")
        XCTAssertEqual(GameFolderScan.environmentName(for: "Beat Saber", taken: taken + ["Beat-Saber-2"]),
                       "beat-saber-3")
    }

    func testATypedEnvironmentNameMustBeValidAndFree() {
        let taken = ["beat-saber", "Beat-Saber-2"]
        XCTAssertNil(GameFolderScan.environmentNameProblem("beat-saber-3", taken: taken))
        XCTAssertNil(GameFolderScan.environmentNameProblem("My.Game_1", taken: taken))
        XCTAssertEqual(GameFolderScan.environmentNameProblem("BEAT-SABER", taken: taken), .taken)
        XCTAssertEqual(GameFolderScan.environmentNameProblem("beat-saber-2", taken: taken), .taken)
        XCTAssertEqual(GameFolderScan.environmentNameProblem("Blood-Trail", taken: []), .taken)
        XCTAssertEqual(GameFolderScan.environmentNameProblem("brutalistick-vr", taken: []), .taken)
        for invalid in ["", "beat saber", "-game", ".game", "ゲーム", "a/b", String(repeating: "a", count: 65)] {
            XCTAssertEqual(GameFolderScan.environmentNameProblem(invalid, taken: []), .invalid, invalid)
        }
    }

    // MARK: - Space

    func testClonesNeedOnlyTheReserveAndCopiesNeedTheirSizeToo() {
        let game = inventory("Game", files: ["Game.exe"], size: 5_200_000_000, volume: 7)
        let reserve = GameFolderSpace.defaultReserveBytes
        XCTAssertEqual(reserve, 20 << 30)

        let clone = GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 7, freeBytes: reserve, supportsClones: true))
        XCTAssertTrue(clone.clones)
        XCTAssertEqual(clone.gameBytes, 5_200_000_000)
        XCTAssertEqual(clone.reserveBytes, reserve)
        XCTAssertEqual(clone.requiredBytes, reserve)
        XCTAssertEqual(clone.availableBytes, reserve)
        XCTAssertTrue(clone.isEnough)
        XCTAssertFalse(GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 7, freeBytes: reserve - 1, supportsClones: true)).isEnough)

        let otherDisk = GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 8, freeBytes: 300_000_000_000, supportsClones: true))
        XCTAssertFalse(otherDisk.clones)
        XCTAssertEqual(otherDisk.requiredBytes, 5_200_000_000 + reserve)
        XCTAssertTrue(otherDisk.isEnough)
        XCTAssertFalse(GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 8, freeBytes: 5_200_000_000 + reserve - 1,
                                             supportsClones: true)).isEnough)

        // The same disk without APFS cannot clone: a full copy.
        let noClones = GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 7, freeBytes: 300_000_000_000, supportsClones: false))
        XCTAssertFalse(noClones.clones)
        XCTAssertEqual(noClones.requiredBytes, 5_200_000_000 + reserve)

        // Unknown free space is never enough, as for the copy itself.
        let unknown = GameFolderScan.space(for: game, on: nil)
        XCTAssertFalse(unknown.clones)
        XCTAssertNil(unknown.availableBytes)
        XCTAssertFalse(unknown.isEnough)

        // The copy's own rule, and a custom reserve.
        XCTAssertEqual(otherDisk.requiredBytes, GameFolderSpace.requiredFreeBytes(
            totalBytes: 5_200_000_000, clones: false, reserveBytes: reserve))
        let small = GameFolderScan.space(
            for: game, on: GameFolderVolume(device: 8, freeBytes: 6_000_000_000, supportsClones: true),
            reserveBytes: 1_000)
        XCTAssertEqual(small.requiredBytes, 5_200_001_000)
        XCTAssertTrue(small.isEnough)
    }

    func testTheSpaceLineNamesTheNumbersTheCopyChecks() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let game = inventory("Game", files: ["Game.exe"], size: 5_200_000_000, volume: 7)
        func line(device: Int32, free: Int64?, clones: Bool = true) -> String {
            GameFolderScan.space(for: game, on: free.map {
                GameFolderVolume(device: device, freeBytes: $0, supportsClones: clones)
            }).message
        }

        L10n.language = .en
        XCTAssertEqual(line(device: 7, free: 300_000_000_000), "Same disk: copied as a clone, almost no extra space")
        XCTAssertEqual(line(device: 8, free: 300_000_000_000), "Needs 5.2 GB, 300 GB free")
        XCTAssertEqual(line(device: 8, free: 15_000_000_000),
                       "Not enough space on the disk: 15 GB free, 26.67 GB needed. TrailBridge always "
                       + "leaves about 20 GB free.")
        XCTAssertEqual(line(device: 7, free: 15_000_000_000),
                       "Not enough space on the disk: 15 GB free, 21.47 GB needed. TrailBridge always "
                       + "leaves about 20 GB free.")
        XCTAssertEqual(line(device: 7, free: nil), "Could not read the free space on the disk.")

        L10n.language = .ru
        let ru = Locale(identifier: "ru")
        let needed = Int64(5_200_000_000).formatted(.byteCount(style: .file).locale(ru))
        let available = Int64(300_000_000_000).formatted(.byteCount(style: .file).locale(ru))
        XCTAssertEqual(line(device: 8, free: 300_000_000_000),
                       L10n.string(.folderImportSpaceCopy, language: .ru, arguments: [needed, available]))
        XCTAssertEqual(line(device: 7, free: 300_000_000_000),
                       L10n.string(.folderImportSpaceClone, language: .ru, arguments: []))
    }

    // MARK: - Profile

    func testTheProfileStartsTheCopiedExecutableDirectly() throws {
        let bottle = managedBottle("beat-saber", prefix: "/Data/Bottles/beat-saber/prefix")
        let profile = try GameFolderScan.profile(
            named: "beat-saber", title: "  Beat Saber ", executable: "Beat Saber.exe",
            arguments: ["--verbose"], folderName: "Beat Saber", in: bottle)
        XCTAssertEqual(profile, LaunchProfile(
            name: "beat-saber", bottleName: "beat-saber", source: .direct,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#, arguments: ["--verbose"],
            workingDirectory: "/Data/Bottles/beat-saber/prefix/drive_c/Games/Beat Saber",
            gameRoot: #"C:\Games\Beat Saber"#, title: "Beat Saber"))
        XCTAssertEqual(profile.environment, [:])
        XCTAssertEqual(profile.formatVersion, LaunchProfile.currentFormatVersion)
        XCTAssertFalse(SteamCatalogGame.isVerified(profile: profile))

        // An Unreal game starts its Shipping binary in that binary's folder.
        let unreal = try GameFolderScan.profile(
            named: "blood-trail", title: "Blood Trail",
            executable: "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe",
            folderName: "Blood Trail", in: bottle)
        XCTAssertEqual(unreal.executable, #"C:\Games\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe"#)
        XCTAssertEqual(unreal.workingDirectory,
                       "/Data/Bottles/beat-saber/prefix/drive_c/Games/Blood Trail/BTVR/Binaries/Win64")
        XCTAssertEqual(unreal.gameRoot, #"C:\Games\Blood Trail"#)
        XCTAssertEqual(unreal.arguments, [])

        // The same paths BottleManager and the Library derive for that file.
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let host = prefix.appendingPathComponent(
            "drive_c/Games/Blood Trail/BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe")
        XCTAssertEqual(unreal.executable, BottleManager.winePath(for: host, prefix: prefix))
        XCTAssertEqual(unreal.gameRoot, BottleManager.winePath(
            for: prefix.appendingPathComponent("drive_c/Games/Blood Trail"), prefix: prefix))
        XCTAssertEqual(GameDetector.hostURL(for: unreal.executable, bottle: bottle)?.path, host.path)
        XCTAssertEqual(unreal.workingDirectory, host.deletingLastPathComponent().path)

        let untitled = try GameFolderScan.profile(
            named: "game", title: " \n ", executable: "Game.exe", folderName: "Game", in: bottle)
        XCTAssertNil(untitled.title)
    }

    func testAProfileIsNeverBuiltFromAnUnsafePath() {
        let bottle = managedBottle("game", prefix: "/Data/Bottles/game/prefix")
        for executable in ["", "/Game.exe", "../Game.exe", "Data/../Game.exe", "Data//Game.exe",
                           "./Game.exe", #"Data\Game.exe"#, "Ga:me.exe", "Game?.exe", "Data/\u{1}.exe"] {
            XCTAssertThrowsError(try GameFolderScan.profile(
                named: "game", title: "Game", executable: executable, folderName: "Game", in: bottle),
                                 executable)
        }
        for folder in ["", "CON", "Game.", ".hidden", "a/b", #"a\b"#] {
            XCTAssertThrowsError(try GameFolderScan.profile(
                named: "game", title: "Game", executable: "Game.exe", folderName: folder, in: bottle)) {
                error in
                guard case .invalidFolderName? = error as? GameFolderCopyError else {
                    return XCTFail("\(folder): \(error)")
                }
            }
        }
    }

    // MARK: - With BottleKit

    /// The sheet's path through a real scan and copy in a throwaway data
    /// folder: the environment name avoids the working games, the copy is
    /// where the profile says, and the Library shows the stored title. A
    /// fake bottle stands in for the new environment; Wine never runs.
    func testAScannedFolderBecomesADirectGameInItsOwnEnvironment() throws {
        let scratch = try scratchFolder()
        let data = scratch.appendingPathComponent("data", isDirectory: true)
        let source = scratch.appendingPathComponent("source/Blood Trail", isDirectory: true)
        for (path, size) in [
            ("BTVR.exe", 64), ("BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe", 4096),
            ("BTVR/Binaries/ThirdParty/Steamworks/Steamv153/Win64/steam_api64.dll", 128),
            ("Engine/Binaries/Win64/CrashReportClient.exe", 256), ("._BTVR.exe", 4),
            (".DS_Store", 8), (".hidden/Tool.exe", 16),
        ] {
            try write(size, to: source.appendingPathComponent(path))
        }
        let runner = RecordingRunner()
        let manager = BottleManager(root: data, repoRoot: scratch.appendingPathComponent("repo"),
                                    runner: runner)
        try manager.prepare()

        let inventory = try manager.inventoryGameFolder(source)
        let scan = GameFolderScan(inventory: inventory)
        XCTAssertEqual(scan.executables.map(\.path), [
            "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe", "BTVR.exe",
            "Engine/Binaries/Win64/CrashReportClient.exe",
        ])
        XCTAssertEqual(scan.hints, [.steamAPI])
        XCTAssertNil(scan.refusal)
        XCTAssertEqual(scan.suggestedTitle, "Blood Trail")
        XCTAssertEqual(scan.destinationFolderName, "Blood Trail")

        let volume = try XCTUnwrap(GameFolderSpace.volume(at: data))
        let verdict = GameFolderScan.space(for: inventory, on: volume)
        XCTAssertEqual(verdict.clones, volume.supportsClones)
        XCTAssertEqual(verdict.requiredBytes, volume.supportsClones
                       ? GameFolderSpace.defaultReserveBytes
                       : inventory.totalBytes + GameFolderSpace.defaultReserveBytes)

        let environment = GameFolderScan.environmentName(
            for: scan.suggestedTitle,
            taken: GameFolderScan.environmentFolderNames(in: manager.paths.bottles) + ["Beat-Saber"])
        XCTAssertEqual(environment, "blood-trail-2")
        let bottle = try makeBottle(environment, in: data)

        let destination = try manager.copyGameFolder(
            inventory, intoBottle: environment, folderName: scan.destinationFolderName, reserveBytes: 0)
        let executable = try XCTUnwrap(scan.suggestedExecutable)
        let name = ProfileNaming.unique(scan.suggestedTitle, existing: try manager.listProfiles().map(\.name))
        let profile = try GameFolderScan.profile(
            named: name, title: scan.suggestedTitle, executable: executable.path,
            arguments: ManualGame.arguments(from: "--graphics D3D11"),
            folderName: scan.destinationFolderName, in: bottle)
        XCTAssertEqual(profile.workingDirectory,
                       destination.appendingPathComponent("BTVR/Binaries/Win64").path)
        let host = try XCTUnwrap(GameDetector.hostURL(for: profile.executable, bottle: bottle))
        XCTAssertEqual(try Data(contentsOf: host).count, 4096)

        try manager.saveNewProfile(profile)
        XCTAssertEqual(try manager.loadProfile(name), profile)
        let games = GameDetector().detect(bottles: try manager.listBottles(),
                                          profiles: try manager.listProfiles())
        XCTAssertEqual(games.map(\.title), ["Blood Trail"])
        XCTAssertEqual(games.first?.profileName, "blood-trail")
        XCTAssertEqual(games.first?.source, .direct)
        XCTAssertEqual(games.first?.hostExecutable?.path, host.path)
        XCTAssertEqual(runner.calls, [])

        // What the scan throws maps onto the sheet's refusals.
        let inside = data.appendingPathComponent("Bottles/\(environment)/prefix/drive_c/Games", isDirectory: true)
        XCTAssertThrowsError(try manager.inventoryGameFolder(inside)) {
            XCTAssertEqual(GameFolderRefusal(error: $0), .insideDataFolder)
        }
        XCTAssertThrowsError(try manager.inventoryGameFolder(source, entryLimit: 2)) {
            XCTAssertEqual(GameFolderRefusal(error: $0), .tooManyEntries(limit: 2))
        }
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("Link.exe"),
            withDestinationURL: source.appendingPathComponent("BTVR.exe"))
        XCTAssertEqual(GameFolderScan(inventory: try manager.inventoryGameFolder(source)).refusal,
                       .unsupportedEntries(examples: ["Link.exe"], count: 1))
    }

    // MARK: - Helpers

    /// A hand-made scan of a folder named `folder`, as `inventoryGameFolder`
    /// returns it.
    private func inventory(
        _ folder: String, files paths: [String], size: Int64 = 1, volume: Int32 = 1,
        rejected: [GameFolderInventory.RejectedEntry] = [], rejectedCount: Int? = nil,
        caseConflicts: [String] = [], caseConflictCount: Int = 0
    ) -> GameFolderInventory {
        var directories = Set<String>()
        for path in paths {
            let components = path.split(separator: "/").dropLast()
            for end in components.indices {
                directories.insert(components[...end].joined(separator: "/"))
            }
        }
        return GameFolderInventory(
            source: URL(fileURLWithPath: "/Volumes/Games/\(folder)", isDirectory: true),
            volume: volume, sourceInode: 2,
            files: paths.map { GameFolderInventory.File(path: $0, size: size) },
            directories: directories.sorted(), rejected: rejected,
            rejectedCount: rejectedCount ?? rejected.count, caseConflicts: caseConflicts,
            caseConflictCount: caseConflictCount, entryCount: paths.count + directories.count)
    }

    private func managedBottle(_ name: String, prefix: String) -> ManagedBottle {
        let engine = URL(fileURLWithPath: prefix, isDirectory: true)
            .deletingLastPathComponent().appendingPathComponent("engine", isDirectory: true)
        let wine = engine.appendingPathComponent("bin/wine")
        return ManagedBottle(
            name: name,
            engine: BottleEngine(id: BottleEngineDiscovery.pinnedDXMTEngineID, kind: .pinned,
                                 wineBinary: wine, wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
                                 root: engine, supportsBasaltDXMT: true),
            prefix: URL(fileURLWithPath: prefix, isDirectory: true), engineRoot: engine, wineBinary: wine)
    }

    /// A ready managed bottle with an empty drive C, shaped like the ones
    /// `createBottle` makes. Its engine folder holds no Wine at all, so
    /// nothing can start one; `loadBottle` only needs the folder to exist.
    private func makeBottle(_ name: String, in data: URL) throws -> ManagedBottle {
        let directory = data.appendingPathComponent("Bottles/\(name)", isDirectory: true)
        var bottle = managedBottle(
            name, prefix: directory.appendingPathComponent("prefix", isDirectory: true).path)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        for folder in ["prefix/drive_c", "engine/bin"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        return bottle
    }

    private func write(_ size: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
    }

    /// A scratch folder in the project's `.local/tmp`: the scan resolves and
    /// refuses symbolic links, and the system temporary folder is reached
    /// through one.
    private func scratchFolder() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(
            ".local/tmp/game-folder-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

/// Records every command and fails it, so a test sees any attempt to run Wine.
private final class RecordingRunner: BottleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [[String]]()

    var calls: [[String]] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput {
        lock.withLock { recorded.append([executable.path] + arguments) }
        return CommandOutput(status: 71, output: "Wine must not run in this test")
    }
}
