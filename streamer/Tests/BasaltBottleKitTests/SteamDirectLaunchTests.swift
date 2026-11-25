import XCTest
@testable import BasaltBottleKit

final class SteamDirectLaunchTests: XCTestCase {
    // MARK: - appinfo.vdf

    func testReadsLaunchOptionsInEveryFormat() throws {
        let formats = [SteamAppInfo.format27, SteamAppInfo.format28, SteamAppInfo.format29,
                       SteamAppInfo.format2A]
        for format in formats {
            let data = AppInfoFixture(format: format, apps: [
                (id: 480, information: Self.information(launch: [
                    [("executable", .string("Spacewar.exe"))],
                ])),
                (id: 3_256_020, information: Self.information(launch: [
                    [
                        ("executable", .string("Game.exe")),
                        ("type", .string("default")),
                        ("config", .object([("oslist", .string("windows")), ("osarch", .int32(64))])),
                    ],
                    [
                        ("executable", .string(#"bin\win64\GameVR.exe"#)),
                        ("arguments", .string(#"-vr -name "Two Words""#)),
                        ("workingdir", .string(#"bin\win64"#)),
                        ("type", .string("vr")),
                        ("config", .object([("BetaKey", .string("public-test"))])),
                    ],
                ])),
            ]).data()

            let options = try XCTUnwrap(
                SteamAppInfo.launchOptions(appID: 3_256_020, in: data), "format \(format)")
            XCTAssertEqual(options, [
                SteamLaunchOption(executable: "Game.exe", type: "default",
                                  operatingSystems: "windows", architecture: "64"),
                SteamLaunchOption(executable: #"bin\win64\GameVR.exe"#,
                                  arguments: #"-vr -name "Two Words""#,
                                  workingDirectory: #"bin\win64"#, type: "vr",
                                  betaKey: "public-test"),
            ], "format \(format)")
            // The entry before it is skipped by its size, and read when asked for.
            XCTAssertEqual(SteamAppInfo.launchOptions(appID: 480, in: data)?.map(\.executable),
                           ["Spacewar.exe"], "format \(format)")
            XCTAssertNil(SteamAppInfo.launchOptions(appID: 1, in: data), "format \(format)")
        }
    }

    func testOtherFormatsAndDamagedFilesReadAsNothing() {
        for format in [SteamAppInfo.format28, SteamAppInfo.format29, SteamAppInfo.format2A] {
            let good = AppInfoFixture(format: format, apps: [
                (id: 7, information: Self.information(launch: [[("executable", .string("A.exe"))]])),
            ]).data()
            XCTAssertEqual(SteamAppInfo.launchOptions(appID: 7, in: good)?.map(\.executable), ["A.exe"],
                           "format \(format)")

            var unknownFormat = good
            unknownFormat[unknownFormat.startIndex] = 0x26
            XCTAssertNil(SteamAppInfo.launchOptions(appID: 7, in: unknownFormat), "format \(format)")
            // Only the terminating AppID 0 follows the last entry in formats 39
            // to 40, so 5 bytes short ends inside it, as in every format.
            for length in [0, 3, 12, 20, good.count / 2, good.count - 5] {
                XCTAssertNil(SteamAppInfo.launchOptions(appID: 7, in: good.prefix(length)),
                             "format \(format), \(length) bytes")
            }
        }
        XCTAssertNil(SteamAppInfo.launchOptions(
            appID: 7, inFileAt: URL(fileURLWithPath: "/nonexistent/appinfo.vdf")))
    }

    // MARK: - Choosing a launch option

    func testLaunchRankPrefersSteamVRThenTheDefaultAndNeverServersOrBetas() {
        func rank(_ option: SteamLaunchOption) -> Int? { SteamDirectLaunch.launchRank(option) }
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", type: "vr")), 0)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe")), 1)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", type: "Default")), 1)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", type: "option1")), 2)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", type: "othervr")), 3)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", architecture: "32")), 11)
        XCTAssertEqual(rank(SteamLaunchOption(executable: "a.exe", operatingSystems: "windows, macos")), 1)
        for option in [
            SteamLaunchOption(executable: "a.exe", operatingSystems: "linux"),
            SteamLaunchOption(executable: "a.exe", operatingSystems: "macos,linux"),
            SteamLaunchOption(executable: "a.exe", betaKey: "beta"),
            SteamLaunchOption(executable: "a.exe", type: "server"),
            SteamLaunchOption(executable: "a.exe", type: "editor"),
            SteamLaunchOption(executable: "a.exe", type: "manual"),
            SteamLaunchOption(executable: "a.exe", realm: "SteamChina"),
        ] {
            XCTAssertNil(rank(option), "\(option)")
        }
    }

    func testCommandLineArgumentsKeepQuotedSpaces() {
        XCTAssertEqual(
            SteamDirectLaunch.commandLineArguments("  -vr\t -name \"Two Words\" -empty \"\" "),
            ["-vr", "-name", "Two Words", "-empty", ""])
        XCTAssertEqual(SteamDirectLaunch.commandLineArguments(""), [])
    }

    // MARK: - Finding the game on disk

    func testStartsSteamsVRLaunchOptionWithItsArguments() throws {
        let steam = try SteamPrefix(test: self)
        let install = try steam.install(appID: "3256020", folder: "Electrician Simulator VR", files: [
            "Electrician Simulator VR.exe", "Electrician Simulator VR_Data/",
            "bin/win64/GameVR.exe", "UnityCrashHandler64.exe",
        ])
        try steam.writeAppInfo(AppInfoFixture(format: SteamAppInfo.format29, apps: [
            (id: 3_256_020, information: Self.information(launch: [
                [("executable", .string("Electrician Simulator VR.exe")), ("type", .string("default"))],
                [
                    // Windows ignores case; the result is spelled as on disk.
                    ("executable", .string(#"BIN\Win64\gamevr.exe"#)),
                    ("arguments", .string("-vr -openxr")),
                    ("type", .string("vr")),
                    ("config", .object([("oslist", .string("windows"))])),
                ],
                [("executable", .string("Server.exe")), ("type", .string("server"))],
            ])),
        ]).data())

        let launch = try SteamDirectLaunch.resolve(appID: "3256020", prefix: steam.prefix)

        XCTAssertEqual(launch.origin, .steamLaunchOptions)
        XCTAssertEqual(launch.executable.standardizedFileURL.path,
                       install.appendingPathComponent("bin/win64/GameVR.exe").standardizedFileURL.path)
        XCTAssertEqual(launch.arguments, ["-vr", "-openxr"])
        XCTAssertEqual(launch.workingDirectory.standardizedFileURL.path,
                       install.appendingPathComponent("bin/win64").standardizedFileURL.path)
    }

    func testSkipsLaunchOptionsWhoseExecutableIsMissingOrOutsideTheGame() throws {
        let steam = try SteamPrefix(test: self)
        let install = try steam.install(appID: "10", folder: "Game", files: ["Game.exe", "Tool.exe"])
        try steam.writeAppInfo(AppInfoFixture(format: SteamAppInfo.format28, apps: [
            (id: 10, information: Self.information(launch: [
                [("executable", .string(#"..\..\..\steam.exe"#)), ("type", .string("vr"))],
                [("executable", .string(#"C:\Windows\notepad.exe"#)), ("type", .string("vr"))],
                [("executable", .string("Missing.exe")), ("type", .string("vr"))],
                [("executable", .string("Game.exe")), ("arguments", .string("-vr"))],
            ])),
        ]).data())

        let launch = try SteamDirectLaunch.resolve(appID: "10", prefix: steam.prefix)

        XCTAssertEqual(launch.executable.standardizedFileURL.path,
                       install.appendingPathComponent("Game.exe").standardizedFileURL.path)
        XCTAssertEqual(launch.arguments, ["-vr"])
    }

    func testFindsTheUnityPlayerInTheGameFolder() throws {
        let steam = try SteamPrefix(test: self)
        _ = try steam.install(appID: "20", folder: "Some VR Game", files: [
            "Electrician.exe", "Electrician_Data/", "UnityCrashHandler64.exe",
            "_CommonRedist/vcredist/vc_redist.x64.exe", "Tools/Setup.exe", "Tools/Editor.exe",
        ])

        let launch = try SteamDirectLaunch.resolve(appID: "20", prefix: steam.prefix)

        XCTAssertEqual(launch.origin, .gameFolder)
        XCTAssertEqual(launch.executable.lastPathComponent, "Electrician.exe")
        XCTAssertEqual(launch.arguments, [])
        XCTAssertEqual(launch.workingDirectory.lastPathComponent, "Some VR Game")
    }

    func testStartsTheUnrealGameBinaryInsteadOfItsLauncher() throws {
        let steam = try SteamPrefix(test: self)
        _ = try steam.install(appID: "30", folder: "Blade Runner", files: [
            "BladeRunner.exe", "BladeRunner/Binaries/Win64/BladeRunner-Win64-Shipping.exe",
            "Engine/Binaries/Win64/CrashReportClient.exe",
        ])

        // Found in the game's folder…
        var launch = try SteamDirectLaunch.resolve(appID: "30", prefix: steam.prefix)
        XCTAssertEqual(launch.origin, .gameFolder)
        XCTAssertEqual(launch.executable.lastPathComponent, "BladeRunner-Win64-Shipping.exe")
        XCTAssertEqual(launch.workingDirectory.lastPathComponent, "Win64")

        // …and when Steam names the launcher, whose arguments the game keeps.
        try steam.writeAppInfo(AppInfoFixture(format: SteamAppInfo.format29, apps: [
            (id: 30, information: Self.information(launch: [
                [("executable", .string("BladeRunner.exe")), ("arguments", .string("-vr"))],
            ])),
        ]).data())
        launch = try SteamDirectLaunch.resolve(appID: "30", prefix: steam.prefix)
        XCTAssertEqual(launch.origin, .steamLaunchOptions)
        XCTAssertEqual(launch.executable.lastPathComponent, "BladeRunner-Win64-Shipping.exe")
        XCTAssertEqual(launch.arguments, ["-vr"])
    }

    func testFindsGamesInEveryLibraryOfTheEnvironment() throws {
        let steam = try SteamPrefix(test: self)
        let library = steam.prefix.appendingPathComponent("drive_c/SteamLibrary", isDirectory: true)
        try steam.writeLibraryFolders("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"C:\\\\SteamLibrary"
        \t}
        }
        """)
        let install = try steam.install(appID: "40", folder: "Far Game", files: ["FarGame.exe"],
                                        library: library)

        let launch = try SteamDirectLaunch.resolve(appID: "40", prefix: steam.prefix)

        XCTAssertEqual(launch.executable.standardizedFileURL.path,
                       install.appendingPathComponent("FarGame.exe").standardizedFileURL.path)
    }

    func testUsesTheProfilesGameFolderWhenSteamHasNoManifest() throws {
        let steam = try SteamPrefix(test: self)
        let folder = steam.steam.appendingPathComponent("steamapps/common/Copied Game", isDirectory: true)
        try SteamPrefix.create(["CopiedGame.exe"], in: folder)

        let launch = try SteamDirectLaunch.resolve(appID: "50", prefix: steam.prefix, gameRoot: folder)

        XCTAssertEqual(launch.executable.lastPathComponent, "CopiedGame.exe")
    }

    func testRefusesToGuessBetweenEquallyLikelyExecutables() throws {
        let steam = try SteamPrefix(test: self)
        _ = try steam.install(appID: "60", folder: "Two Tools", files: ["Alpha.exe", "Beta.exe"])

        XCTAssertThrowsError(try SteamDirectLaunch.resolve(appID: "60", prefix: steam.prefix)) {
            let message = ($0 as? BottleToolError)?.message ?? ""
            XCTAssertTrue(message.contains("Two Tools"), message)
            XCTAssertTrue(message.contains("Edit Launch Profile"), message)
        }
        // Not installed, and not an AppID at all.
        XCTAssertThrowsError(try SteamDirectLaunch.resolve(appID: "61", prefix: steam.prefix)) {
            XCTAssertTrue((($0 as? BottleToolError)?.message ?? "").contains("not installed"))
        }
        XCTAssertThrowsError(try SteamDirectLaunch.resolve(appID: "6a", prefix: steam.prefix))
        XCTAssertThrowsError(try SteamDirectLaunch.resolve(appID: "", prefix: steam.prefix))
    }

    // MARK: - A profile's launch

    func testAnySteamProfileStartsTheGameItselfWithTheSessionEnvironment() throws {
        let steam = try SteamPrefix(test: self)
        let install = try steam.install(appID: "3256020", folder: "Electrician Simulator VR", files: [
            "Electrician Simulator VR.exe", "Electrician Simulator VR_Data/", "UnityCrashHandler64.exe",
        ])
        let manager = try steam.manager(bottleName: "Steam")
        // What Add Steam Game saves for a game that is not verified. The
        // Steam client's own arguments before -applaunch never reach the game.
        try manager.saveProfile(LaunchProfile(
            name: "electrician", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-silent", "-applaunch", "3256020", "-force-d3d11"],
            workingDirectory: steam.steam.path,
            gameRoot: #"C:\Program Files (x86)\Steam\steamapps\common\Electrician Simulator VR"#))
        let control = steam.root.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let command = try manager.profileLaunchCommand("electrician", controlFile: control)

        XCTAssertEqual(command.arguments, [
            #"C:\Program Files (x86)\Steam\steamapps\common\Electrician Simulator VR\Electrician Simulator VR.exe"#,
            "-force-d3d11",
        ])
        XCTAssertEqual(command.currentDirectory?.standardizedFileURL.path,
                       install.standardizedFileURL.path)
        XCTAssertEqual(command.environment["SteamAppId"], "3256020")
        XCTAssertEqual(command.environment["SteamGameId"], "3256020")
        XCTAssertEqual(command.environment["DXMT_BASALT_IOSURFACE"], "1")
        XCTAssertEqual(
            command.environment["BASALT_CONTROL"],
            "Z:" + control.path.replacingOccurrences(of: "/", with: #"\"#))
        XCTAssertEqual(command.steamLaunch?.origin, .gameFolder)

        // A profile that names its executable is started as it is.
        try manager.saveProfile(LaunchProfile(
            name: "direct", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\Electrician Simulator VR\Electrician Simulator VR.exe"#,
            environment: ["SteamAppId": "3256020"]))
        let direct = try manager.profileLaunchCommand("direct", controlFile: control)
        XCTAssertNil(direct.steamLaunch)
        XCTAssertEqual(direct.arguments.count, 1)
    }

    func testSteamProfileForAMissingGameFailsBeforeAnythingStarts() throws {
        let steam = try SteamPrefix(test: self)
        let manager = try steam.manager(bottleName: "Steam")
        try manager.saveProfile(LaunchProfile(
            name: "gone", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-applaunch", "123456"]))
        let control = steam.root.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        XCTAssertThrowsError(try manager.profileLaunchCommand("gone", controlFile: control)) {
            XCTAssertTrue((($0 as? BottleToolError)?.message ?? "").contains("123456"))
        }
    }

    // MARK: - Fixtures

    /// An app's information with the given launch options, as Steam nests it.
    static func information(
        launch options: [[(String, AppInfoFixture.Value)]]
    ) -> [(String, AppInfoFixture.Value)] {
        let launch = options.enumerated().map { item -> (String, AppInfoFixture.Value) in
            (String(item.offset), AppInfoFixture.Value.object(item.element))
        }
        return [
            ("appid", .int32(1)),
            ("common", .object([("name", .string("Game")), ("type", .string("Game"))])),
            ("config", .object([("installdir", .string("Game")), ("launch", .object(launch))])),
        ]
    }
}

/// Steam's binary `appinfo.vdf`, written the way the client writes it.
struct AppInfoFixture {
    indirect enum Value {
        case object([(String, Value)])
        case string(String)
        case int32(Int32)
    }

    var format: UInt32
    var apps: [(id: UInt32, information: [(String, Value)])]

    func data() -> Data {
        var keys = [String]()
        var indices = [String: UInt32]()
        func key(_ name: String) -> [UInt8] {
            guard format == SteamAppInfo.format29 || format == SteamAppInfo.format2A else {
                return Array(name.utf8) + [0]
            }
            if let index = indices[name] { return Self.littleEndian(index) }
            let index = UInt32(keys.count)
            keys.append(name)
            indices[name] = index
            return Self.littleEndian(index)
        }
        func encode(_ entries: [(String, Value)]) -> [UInt8] {
            var bytes = [UInt8]()
            for (name, value) in entries {
                switch value {
                case .object(let children):
                    bytes.append(0x00)
                    bytes += key(name)
                    bytes += encode(children)
                    bytes.append(0x08)
                case .string(let text):
                    bytes.append(0x01)
                    bytes += key(name)
                    bytes += Array(text.utf8)
                    bytes.append(0)
                case .int32(let number):
                    bytes.append(0x02)
                    bytes += key(name)
                    bytes += Self.littleEndian(UInt32(bitPattern: number))
                }
            }
            return bytes
        }

        if format == SteamAppInfo.format2A { return shard(encode: encode, keys: { keys }) }
        var body = [UInt8]()
        for app in apps {
            // Info state, last update, PICS token, SHA-1, change number and,
            // from format 28, the binary SHA-1.
            let fixed = 4 + 4 + 8 + 20 + 4 + (format == SteamAppInfo.format27 ? 0 : 20)
            var entry = [UInt8](repeating: 0xA5, count: fixed)
            entry += encode([("appinfo", Value.object(app.information))])
            entry.append(0x08)
            body += Self.littleEndian(app.id)
            body += Self.littleEndian(UInt32(entry.count))
            body += entry
        }
        body += Self.littleEndian(UInt32(0))
        var header = Self.littleEndian(format)
        header += Self.littleEndian(UInt32(1))
        guard format == SteamAppInfo.format29 else { return Data(header + body) }
        header += Self.littleEndian(UInt64(header.count + 8 + body.count))
        var table = Self.littleEndian(UInt32(keys.count))
        for name in keys {
            table += Array(name.utf8)
            table.append(0)
        }
        return Data(header + body + table)
    }

    /// Version 42: header, index with summaries, key table, then each app's
    /// binary SHA-1 and KeyValues.
    private func shard(encode: ([(String, Value)]) -> [UInt8], keys: () -> [String]) -> Data {
        var index = [UInt8]()
        var data = [UInt8]()
        for app in apps {
            var blob = [UInt8](repeating: 0x5A, count: 20)
            blob += encode([("appinfo", Value.object(app.information))])
            blob.append(0x08)
            // Change number, last update, PICS token, info state, SHA-1.
            let summary = [UInt8](repeating: 0x11, count: 4 + 4 + 8 + 1 + 20)
            index += Self.littleEndian(app.id)
            index += Self.littleEndian(UInt32(data.count))
            index += Self.littleEndian(UInt32(blob.count))
            index += Self.littleEndian(UInt32(summary.count))
            index += summary
            data += blob
        }
        let names = keys()
        var table = [UInt8]()
        for name in names {
            table += Array(name.utf8)
            table.append(0)
        }
        var header = Self.littleEndian(format)
        let fields: [UInt32] = [
            1, 0, 1, UInt32(apps.count), UInt32(index.count), UInt32(names.count),
            UInt32(table.count), UInt32(data.count), 0, 0,
        ]
        for field in fields { header += Self.littleEndian(field) }
        return Data(header + index + table + data)
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}

/// A Wine prefix with Steam in `C:\Program Files (x86)\Steam`.
struct SteamPrefix {
    let root: URL
    let prefix: URL
    let steam: URL

    init(test: XCTestCase) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltSteamDirectLaunch-\(UUID().uuidString)", isDirectory: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        root = directory
        prefix = directory.appendingPathComponent("data/Bottles/Steam/prefix", isDirectory: true)
        steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try Self.create(["steam.exe", "steamapps/"], in: steam)
    }

    /// Installs a game as Steam does: its manifest, then its files under
    /// `steamapps/common/<folder>`. A path ending in "/" is a folder.
    func install(appID: String, folder: String, files: [String], library: URL? = nil) throws -> URL {
        let steamApps = (library ?? steam).appendingPathComponent("steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try Data("""
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"\(folder)"
        \t"installdir"\t\t"\(folder)"
        }

        """.utf8).write(to: steamApps.appendingPathComponent("appmanifest_\(appID).acf"))
        let install = steamApps.appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        try Self.create(files, in: install)
        return install
    }

    func writeAppInfo(_ data: Data) throws {
        let cache = steam.appendingPathComponent("appcache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: cache.appendingPathComponent("appinfo.vdf"))
    }

    func writeLibraryFolders(_ text: String) throws {
        try Data(text.utf8).write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
    }

    /// A managed bottle around the prefix, ready to launch.
    func manager(bottleName: String) throws -> BottleManager {
        let data = root.appendingPathComponent("data", isDirectory: true)
        let directory = prefix.deletingLastPathComponent()
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: bottleName, engine: engine, prefix: prefix,
            engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        return BottleManager(root: data, repoRoot: root)
    }

    static func create(_ files: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let url = folder.appendingPathComponent(file)
            if file.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0x4d, 0x5a]).write(to: url)
            }
        }
    }
}
