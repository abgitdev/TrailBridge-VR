// SPDX-License-Identifier: MIT
import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

final class GameLogExcerptTests: XCTestCase {
    /// Nothing is read from the Mac the tests run on.
    private let redactor = DiagnosticRedactor(
        homeDirectory: "/Users/ada", userName: "ada", dataFolder: nil, appFolder: nil,
        hostNames: [], volumeNames: [])

    // MARK: - Choosing the lines

    func testAShortLogIsKeptWhole() {
        XCTAssertEqual(excerpt([("Player.log", "first\nsecond\r\nthird")]).text,
                       "==> Player.log <==\nfirst\nsecond\nthird\n")
        XCTAssertEqual(excerpt([("Player.log", "")]).text, "==> Player.log <==\n")
    }

    func testKeepsTheLastLinesAndEveryErrorInTheirOrder() {
        var lines = (0..<1000).map { "line \($0)" }
        lines[10] = "line 10 NullReferenceException: Object reference not set to an instance of an object"
        lines[500] = "line 500 WindowsVideoMedia error 0xc00d36bb while reading sharedassets0.resource"
        lines[799] = "line 799 LogD3D11RHI: Error: device removed"
        lines[850] = "line 850 Failed to load 'aqProf.dll'"

        let text = excerpt([("Player.log", lines.joined(separator: "\n") + "\n")]).text
        XCTAssertEqual(text, (["==> Player.log <==", "[… 10 lines skipped …]", lines[10],
                               "[… 489 lines skipped …]", lines[500], "[… 298 lines skipped …]", lines[799]]
                              + lines[800...]).joined(separator: "\n") + "\n")
        // A gap of one line says so.
        lines[798] = "line 798 error"
        lines[799] = "line 799"
        XCTAssertTrue(excerpt([("Player.log", lines.joined(separator: "\n"))]).text
            .contains("\nline 798 error\n[… 1 line skipped …]\nline 800\n"))
    }

    func testLinesThatReportErrors() {
        let errors = [
            "WindowsVideoMedia error 0xc00d36bb while reading C:/Games/data.resource",
            "Error details: Unexpected error.",
            "NullReferenceException: Object reference not set to an instance of an object",
            "[XR] xrCreateSession: XR_ERROR_RUNTIME_FAILURE",
            "[2026.11.25-10.00.00:000][  0]LogWindows: Error: Fatal error!",
            "Failed to load 'aqProf.dll' (GetLastError=126)",
            "D3D11: FAILED to create the device",
            "Assertion failed on expression: 'IsMatrixValid(matrix)'",
            "FATAL: out of memory",
            "DllNotFoundException: GfxPluginNativeRenderer",
        ]
        let others = [
            "Terror of the deep: chapter 2",
            "Fallback handler could not load library",
            "Initialize engine version: 6000.0.58f2",
            // The runtime refuses the first API version Unity asks for; Unity
            // then asks for 1.0 and the session works.
            "Basalt OpenXR: unsupported application API version 1.1.45 (runtime supports OpenXR 1.0)",
            "Errands are done",
            "",
        ]
        for line in errors { XCTAssertTrue(GameLogExcerpt.reportsError(Substring(line)), line) }
        for line in others { XCTAssertFalse(GameLogExcerpt.reportsError(Substring(line)), line) }
    }

    func testTheWholeTextStaysWithinItsSize() {
        // An error every frame, then long lines at the end.
        let flood = (0..<5000).map { "NullReferenceException at frame \($0) " + String(repeating: "x", count: 60) }
        let tail = (0..<GameLogExcerpt.tailLines).map { "tail \($0) " + String(repeating: "t", count: 590) }
        let text = excerpt([("Player.log", (flood + tail).joined(separator: "\n"))]).text
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertLessThanOrEqual(text.utf8.count, GameLogExcerpt.maximumBytes)
        XCTAssertGreaterThan(text.utf8.count, GameLogExcerpt.maximumBytes * 9 / 10)
        // The first errors and the very end are there; half the room is the errors'.
        XCTAssertEqual(lines[1], flood[0])
        XCTAssertEqual(lines.last, tail.last)
        let kept = lines.filter { $0.hasPrefix("NullReferenceException") }
        let keptTail = lines.filter { $0.hasPrefix("tail ") }
        XCTAssertGreaterThan(kept.count * 99, GameLogExcerpt.maximumBytes / 2 - 1000)
        XCTAssertEqual(Array(flood.prefix(kept.count)), kept)
        XCTAssertEqual(Array(tail.suffix(keptTail.count)), keptTail)
        let skipped = flood.count + tail.count - kept.count - keptTail.count
        XCTAssertTrue(text.contains("\n[… \(skipped) lines skipped …]\n"))

        // Short error lines between ordinary ones: every one needs a note.
        let alternating = (0..<40_000).map { $0 % 2 == 0 ? "error \($0)" : "ok \($0)" }
        let gaps = excerpt([("Player.log", alternating.joined(separator: "\n"))]).text
        XCTAssertLessThanOrEqual(gaps.utf8.count, GameLogExcerpt.maximumBytes)
        XCTAssertTrue(gaps.hasPrefix("==> Player.log <==\nerror 0\n[… 1 line skipped …]\nerror 2\n"))
        XCTAssertTrue(gaps.hasSuffix("\nok 39999\n"))

        // Names a placeholder makes longer, in several logs that were not read whole.
        let wide = (0..<3000).map { "error at C:/users/x/\($0)" }.joined(separator: "\n")
        let several = GameLogExcerpt(logs: (0..<3).map {
            GameLogExcerpt.Log(engine: .unity, label: "Player-\($0).log", text: wide, unreadBytes: 1 << 30)
        }, redactedWith: redactor).text
        XCTAssertLessThanOrEqual(several.utf8.count, GameLogExcerpt.maximumBytes)
        XCTAssertTrue(several.contains("error at C:/users/[user]/0\n"))
        XCTAssertEqual(several.components(separatedBy: "[… earlier lines not read: 1073741824 bytes …]").count, 4)
    }

    func testLongLinesAreRedactedWholeOrLeftOutWhole() {
        // A name that a cut at 4 KB would have split, after a disk name the
        // redactor makes much shorter.
        let crossing = "/Volumes/" + String(repeating: "x", count: 3978) + "/ owner 76561190000000042 "
            + String(repeating: "y", count: 3000)
        // One byte more than is read of a line, with the same name in it.
        let tooLong = "owner 76561190000000042 "
            + String(repeating: "z", count: GameLogExcerpt.maximumReadLineBytes - 24 + 1)
        let longest = String(repeating: "w", count: GameLogExcerpt.maximumReadLineBytes)
        let wide = String(repeating: "\u{E9}", count: 1200)
        XCTAssertEqual(tooLong.utf8.count, GameLogExcerpt.maximumReadLineBytes + 1)
        let text = excerpt([("Player.log", [crossing, tooLong, longest, wide, "short"].joined(separator: "\n"))]).text
        let lines = text.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 6)
        XCTAssertFalse(text.contains("76561"), text)
        let head = "/Volumes/[disk]/ owner [steamid] "
        XCTAssertEqual(lines[1], head + String(repeating: "y", count: GameLogExcerpt.maximumLineBytes - head.utf8.count) + "…")
        XCTAssertEqual(lines[2], "[long line omitted: \(GameLogExcerpt.maximumReadLineBytes + 1) bytes]")
        XCTAssertEqual(lines[3], String(repeating: "w", count: GameLogExcerpt.maximumLineBytes) + "…")
        // Cut between characters, never inside one.
        XCTAssertEqual(lines[4], String(repeating: "\u{E9}", count: GameLogExcerpt.maximumLineBytes / 2) + "…")
        XCTAssertEqual(lines[5], "short")

        // Whether a line reports an error is judged on all of it, also when
        // it is too long to keep.
        let late = String(repeating: "v", count: GameLogExcerpt.maximumReadLineBytes) + " Fatal error"
        let early = ([late] + (0..<GameLogExcerpt.tailLines).map { "line \($0)" }).joined(separator: "\n")
        XCTAssertTrue(excerpt([("Player.log", early)]).text.hasPrefix(
            "==> Player.log <==\n[long line omitted: \(late.utf8.count) bytes]\nline 0\n"))
    }

    func testReadsSeveralLogsOldestFirst() {
        var previous = (0..<150).map { "prev \($0)" }
        previous[10] = "prev 10 error"
        let current = (0..<100).map { "now \($0)" }
        let text = excerpt([
            ("Player-prev.log", previous.joined(separator: "\n") + "\n"),
            // The last line of the newer log has no line break yet.
            ("Player.log", current.joined(separator: "\n")),
        ]).text
        XCTAssertEqual(text, (["==> Player-prev.log <==", "[… 10 lines skipped …]", previous[10],
                               "[… 39 lines skipped …]"] + previous[50...] + ["==> Player.log <=="] + current)
            .joined(separator: "\n") + "\n")

        // A log whose lines are all left out still has its header.
        let quiet = excerpt([("old.log", "one\ntwo\n"), ("new.log", (0..<300).map { "n\($0)" }.joined(separator: "\n"))])
        XCTAssertTrue(quiet.text.hasPrefix(
            "==> old.log <==\n[… 2 lines skipped …]\n==> new.log <==\n[… 100 lines skipped …]\nn100\n"))
    }

    func testOmittedLongErrorsLeaveRoomForLaterErrors() {
        let longError = "Fatal error " + String(repeating: "x", count: GameLogExcerpt.maximumReadLineBytes)
        let early = Array(repeating: longError, count: 80) + ["Error: later cause", "ok"]
        let tail = (0..<GameLogExcerpt.tailLines).map { "line \($0)" }
        let text = excerpt([("Player.log", (early + tail).joined(separator: "\n"))]).text
        XCTAssertTrue(text.contains("[long line omitted: \(longError.utf8.count) bytes]\nError: later cause\n"))
        XCTAssertLessThanOrEqual(text.utf8.count, GameLogExcerpt.maximumBytes)
    }

    // MARK: - Reading a log

    func testReadsUTF16AndUTF8AndSkipsBinaryLogs() throws {
        var utf16LE = Data([0xFF, 0xFE])
        utf16LE.append(try XCTUnwrap("Fatal error\r\nok\r\n".data(using: .utf16LittleEndian)))
        var utf16BE = Data([0xFE, 0xFF])
        utf16BE.append(try XCTUnwrap("Fatal error\r\nok\r\n".data(using: .utf16BigEndian)))
        var utf8 = Data([0xEF, 0xBB, 0xBF])
        utf8.append(Data("Fatal error\r\nok\r\n".utf8))
        for data in [utf16LE, utf16BE, utf8] {
            let read = try XCTUnwrap(read(data))
            XCTAssertEqual(read.unreadBytes, 0)
            XCTAssertEqual(GameLogExcerpt.Log(engine: .unreal, label: "", text: read.text).lines, ["Fatal error", "ok"])
        }
        // What is not UTF-8 is replaced, not left out.
        XCTAssertEqual(try XCTUnwrap(read(Data([0x6F, 0x6B, 0xC3, 0x28, 0x0A]))).text, "ok\u{FFFD}(\n")
        // A log with NULs and no byte order mark is no text.
        XCTAssertNil(read(Data("ok\n\0\0\0binary".utf8)))
        let controls = Data(repeating: 0x01, count: 16)
        XCTAssertNil(read(controls + Data("ok\n".utf8)))
        XCTAssertNil(read(controls + Data(repeating: 0x61, count: 8), maximumBytes: 8))
        XCTAssertEqual(try XCTUnwrap(read(Data("\u{1B}[32mtext\u{1B}[0m\n".utf8))).text,
                       "\u{1B}[32mtext\u{1B}[0m\n")
        XCTAssertEqual(try XCTUnwrap(read(Data())).text, "")
    }

    func testReadsOnlyTheEndOfALargeLog() throws {
        let lines = (0..<100).map { "line \($0)" }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let read = try XCTUnwrap(self.read(data, maximumBytes: 100))
        XCTAssertEqual(read.unreadBytes, Int64(data.count - 100))
        // The line the start falls in is left out whole.
        let kept = GameLogExcerpt.Log(engine: .unity, label: "", text: read.text).lines
        // 100 bytes from the end start inside "line 87".
        XCTAssertEqual(kept.map(String.init), Array(lines[88...]))

        // UTF-16 stays in whole code units from an odd start.
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try XCTUnwrap((lines.joined(separator: "\n") + "\n").data(using: .utf16LittleEndian)))
        let wide = try XCTUnwrap(self.read(utf16, maximumBytes: 101))
        XCTAssertGreaterThan(wide.unreadBytes, 0)
        let wideLines = GameLogExcerpt.Log(engine: .unreal, label: "", text: wide.text).lines
        XCTAssertEqual(wideLines.map(String.init), Array(lines.suffix(wideLines.count)))

        let excerpt = GameLogExcerpt(logs: [GameLogExcerpt.Log(
            engine: .unity, label: "Player.log", text: read.text, unreadBytes: read.unreadBytes)],
                                     redactedWith: redactor)
        XCTAssertTrue(excerpt.text.hasPrefix(
            "==> Player.log <==\n[… earlier lines not read: \(read.unreadBytes) bytes …]\nline "))
    }

    // MARK: - Reading a game's logs

    func testCollectsTheUnityPlayerLogWithPersonalDataReplaced() throws {
        let game = try UnityPrefix(test: self)
        let start = Date()
        try game.writeLog("Player.log", """
            Mono path[0] = 'C:/Program Files (x86)/Steam/steamapps/common/Electrician VR/ElectricianVR_Data/Managed'
            Logging to C:/users/steamuser/AppData/LocalLow/Example Studio/Electrician VR/Player.log
            Data folder: Z:\\Users\\ada\\TrailBridge\\data and Z:/Users/ada/Games
            Steam user 76561190000000042 signed in
            Basalt OpenXR: unsupported application API version 1.1.45 (runtime supports OpenXR 1.0)
            WindowsVideoMedia error 0xc00d36bb while reading C:/Program Files (x86)/Steam/steamapps/common/Electrician VR/ElectricianVR_Data/sharedassets0.resource

            Context: CreateObjectFromByteStream
            Error details: Unexpected error.

            """)

        let excerpt = try XCTUnwrap(GameLogExcerpt.collect(game.search, since: start, redactedWith: redactor))

        // The header and the source name the log as the game does, never by its path on this Mac.
        let path = #"C:\users\[user]\AppData\LocalLow\Example Studio\Electrician VR\Player.log"#
        XCTAssertEqual(excerpt.sources, [GameLogExcerpt.Source(engine: .unity, path: path)])
        XCTAssertTrue(excerpt.text.hasPrefix("==> \(path) <==\nMono path[0] = 'C:/Program Files (x86)/"))
        for kept in [
            "WindowsVideoMedia error 0xc00d36bb while reading C:/Program Files (x86)/Steam/steamapps/common/"
                + "Electrician VR/ElectricianVR_Data/sharedassets0.resource\n\nContext: CreateObjectFromByteStream\n",
            "\nLogging to C:/users/[user]/AppData/LocalLow/Example Studio/Electrician VR/Player.log\n",
            "\nData folder: Z:\\Users\\[user]\\TrailBridge\\data and Z:/Users/[user]/Games\n",
            "\nSteam user [steamid] signed in\n",
        ] {
            XCTAssertTrue(excerpt.text.contains(kept), kept)
        }
        for leaked in ["steamuser", "/ada", "\\ada", "7656119", game.prefix.path] {
            XCTAssertFalse(excerpt.text.contains(leaked), leaked)
        }

        // A game that wrote nothing since it started has no excerpt.
        XCTAssertNil(GameLogExcerpt.collect(game.search, since: Date(timeIntervalSinceNow: 60),
                                            redactedWith: redactor))
    }

    /// A Windows user whose name has a space, and the names Unreal prints
    /// with or without quotes: none of it reaches the saved excerpt or a
    /// report made from it.
    func testNamesWithSpacesAndQuotesReachNeitherTheExcerptNorTheReport() throws {
        let root = try temporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let exe = driveC.appendingPathComponent("Games/Blood Trail/BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe")
        let logs = driveC.appendingPathComponent("users/Jane Doe/AppData/Local/BTVR/Saved/Logs", isDirectory: true)
        for folder in [exe.deletingLastPathComponent(), logs, driveC.appendingPathComponent("users/Public")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: exe)
        let start = Date()
        try Data("""
            [2026.11.25-10.00.00:000][  0]LogInit: Computer: "JANE-DOE-MAC"
            [2026.11.25-10.00.00:000][  0]LogInit: User: "Jane Doe"
            LogInit: User: Jane Doe
            LogInit: Computer: 'Jane Doe's Mac'
            Username: Jane Doe
            User name: Jane "JJ" Doe
            Account: Jane O'Brien; personal
            Steam IDs 76561190000000000 76561200000000000 STEAM_0:1:0 [U:1:0]
            LogPlatformFile: Using C:/Users/Jane Doe/AppData/Local/BTVR/Saved/Config
            LogWindows: Error: Could not open C:\\users\\Jane Doe\\AppData\\Local\\BTVR\\Saved\\x.sav

            """.utf8).write(to: logs.appendingPathComponent("BTVR.log"))
        let run = GameLogRun(
            search: GameLogSearch(prefix: prefix, executable: exe), gameStartedAt: start,
            profileName: "blood-trail", sessionID: UUID(), sessionStartedAt: start, recording: nil,
            dataRoot: try symlinkFreeDirectory())

        let saved = try XCTUnwrap(run.save(redactedWith: redactor))
        let file = try XCTUnwrap(saved.file)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, saved.excerpt.text)
        XCTAssertEqual(saved.excerpt.sources.map(\.path), [#"C:\users\[user]\AppData\Local\BTVR\Saved\Logs\BTVR.log"#])
        for kept in ["LogInit: Computer: [host]\n", "LogInit: User: [user]\n",
                     "Username: [redacted]\n", "User name: [redacted]\n", "Account: [redacted]\n",
                     "Steam IDs [steamid] [steamid] [steamid] [steamid]\n",
                     "Using C:/Users/[user]/AppData/Local/BTVR/Saved/Config\n",
                     #"Could not open C:\users\[user]\AppData\Local\BTVR\Saved\x.sav"#] {
            XCTAssertTrue(text.contains(kept), kept)
        }

        var record = SessionRecord(profileName: "blood-trail", settings: StreamLaunchSettings())
        record.gameLog = file.lastPathComponent
        let report = DiagnosticReport(
            application: .init(version: "0.2.1", build: nil, sourceRevision: nil),
            system: .init(operatingSystem: "macOS 26.0", hardwareModel: nil, chip: nil, architecture: "arm64",
                          memoryGigabytes: 16, processorCount: 8, thermalState: "nominal", lowPowerMode: false),
            setupChecks: [], engines: [], bottles: [], profiles: [],
            defaultStreamSettings: StreamLaunchSettings(), profileStreamSettings: [:],
            currentSession: .init(state: "stopped"), recentSessions: [record], log: nil,
            gameLog: .current(running: nil, history: [record], dataRoot: run.dataRoot, redactedWith: redactor))
        let markdown = report.markdown(redactedWith: redactor)
        let json = try report.json(redactedWith: redactor)
        XCTAssertTrue(markdown.contains("LogInit: User: [user]"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        for output in [text, markdown, json] {
            for leaked in ["Jane", "Doe", "JANE", "76561190000000000", "76561200000000000", "STEAM_0:1:0", "[U:1:0]"] {
                XCTAssertFalse(output.contains(leaked), "\(leaked) in \(output)")
            }
        }
    }

    // MARK: - Saving

    @MainActor
    func testCaptureWaitYieldsToCompletionAndHasATimeout() async {
        var finished = false
        Task { finished = true }
        await SessionTeardown.wait(upTo: .seconds(1)) { finished }
        XCTAssertTrue(finished)

        let clock = ContinuousClock()
        let start = clock.now
        await SessionTeardown.wait(upTo: .milliseconds(25)) { false }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(25))
    }

    func testExternalUnrealLogUsesTheGameFolderLabelInTheExcerptAndReport() throws {
        let root = try temporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let game = root.appendingPathComponent("Example Library/Private Install", isDirectory: true)
        let executablePath = "Example/Binaries/Win64/Example.exe"
        let exe = game.appendingPathComponent(executablePath)
        let log = game.appendingPathComponent("Example/Saved/Logs/Example.log")
        for folder in [exe.deletingLastPathComponent(), log.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: exe)
        let alias = root.appendingPathComponent("Launch Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: game)
        let start = Date()
        let windowsPath = "Z:" + game.path.replacingOccurrences(of: "/", with: #"\"#)
        try Data("""
            Loading \(game.path)/Example/Content
            Error: \(windowsPath)\\Example\\Content
            Loading Z:\(game.path)/Example/Content
            Loading \(alias.standardizedFileURL.path)/Example/Content

            """.utf8).write(to: log)
        let run = GameLogRun(
            search: GameLogSearch(prefix: prefix, executable: alias.appendingPathComponent(executablePath)),
            gameStartedAt: start,
            profileName: "example", sessionID: UUID(), sessionStartedAt: start, recording: nil,
            dataRoot: try symlinkFreeDirectory())
        let saved = try XCTUnwrap(run.save(redactedWith: redactor, wineMayBeRunning: true))
        let file = try XCTUnwrap(saved.file)
        let label = #"[game folder]\Example\Saved\Logs\Example.log"#
        XCTAssertEqual(saved.excerpt.sources.map(\.path), [label])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), """
            [… the game may still have been running; this excerpt can be incomplete …]
            ==> \(label) <==
            Loading [game folder]/Example/Content
            Error: [game folder]\\Example\\Content
            Loading [game folder]/Example/Content
            Loading [game folder]/Example/Content

            """)
        var record = SessionRecord(profileName: "example", settings: StreamLaunchSettings())
        record.gameLog = file.lastPathComponent
        let report = DiagnosticReport.GameLog.current(
            running: nil, history: [record], dataRoot: run.dataRoot, redactedWith: redactor)
        XCTAssertTrue(report.lines.contains("==> \(label) <=="))
        XCTAssertFalse(report.lines.joined().contains("Private Install"))
    }

    func testUnrealFallbackAndFileLimitCountOnlyReadableTextLogs() throws {
        let root = try temporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let exe = prefix.appendingPathComponent("drive_c/Games/Example/Example/Binaries/Win64/Example.exe")
        let appData = prefix.appendingPathComponent("drive_c/users/steamuser/AppData/Local/Example/Saved/Logs")
        let install = prefix.appendingPathComponent("drive_c/Games/Example/Example/Saved/Logs")
        for folder in [exe.deletingLastPathComponent(), appData, install] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: exe)
        let search = GameLogSearch(prefix: prefix, executable: exe)
        let start = Date()
        func write(_ data: Data, named name: String, in folder: URL, at seconds: TimeInterval) throws {
            let file = folder.appendingPathComponent(name)
            try data.write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: start.addingTimeInterval(seconds)], ofItemAtPath: file.path)
        }
        let binary = Data(repeating: 0x01, count: 32)
        try write(binary, named: "binary.log", in: appData, at: 20)
        for number in 0..<4 {
            try write(Data("install \(number)\n".utf8), named: "install-\(number).log", in: install, at: Double(number))
            try write(binary, named: "binary-\(number).log", in: install, at: Double(number + 10))
        }
        let fallback = try XCTUnwrap(GameLogExcerpt.collect(search, since: start, redactedWith: redactor))
        XCTAssertEqual(fallback.sources.map { $0.path.components(separatedBy: "\\").last },
                       ["install-1.log", "install-2.log", "install-3.log"])

        try write(Data("app data\n".utf8), named: "app-data.log", in: appData, at: 5)
        let preferred = try XCTUnwrap(GameLogExcerpt.collect(search, since: start, redactedWith: redactor))
        XCTAssertEqual(preferred.sources.map { $0.path.components(separatedBy: "\\").last }, ["app-data.log"])
        XCTAssertTrue(preferred.text.hasSuffix("\napp data\n"))
    }

    func testSavesTheExcerptBesideTheRecordingOrUnderItsOwnName() throws {
        let game = try UnityPrefix(test: self)
        let root = try symlinkFreeDirectory()
        let start = Date()
        try game.writeLog("Player.log", "Fatal error in the game\n")
        var environment = ["BASALT_FRAME_TRACE": "1"]
        let recording = try XCTUnwrap(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: root, prefix: game.prefix, profile: "electrician",
            now: Date(timeIntervalSince1970: 1_735_689_600)))

        let recorded = try XCTUnwrap(game.run(dataRoot: root, recording: recording, sessionStartedAt: start)
            .save(redactedWith: redactor))
        XCTAssertEqual(recorded.file, recording.gameLog)
        let plain = try XCTUnwrap(game.run(dataRoot: root, sessionStartedAt: Date(timeIntervalSince1970: 1_735_693_200))
            .save(redactedWith: redactor))
        let file = try XCTUnwrap(plain.file)
        XCTAssertEqual(file.lastPathComponent, "20250101T010000.000000Z-electrician.game.log")
        XCTAssertEqual(plain.excerpt.text, recorded.excerpt.text)

        let store = DiagnosticRecordingStore(dataRoot: root)
        XCTAssertEqual(store.list().map { $0.files.map(\.kind) }, [[.gameLog], [.frames, .sessionLog, .gameLog]])
        XCTAssertEqual(store.gameLogText(named: file.lastPathComponent), plain.excerpt.text)
        XCTAssertEqual(store.gameLogFile(named: file.lastPathComponent), file)

        // A game without a log saves nothing.
        XCTAssertNil(game.run(dataRoot: root, sessionStartedAt: start, gameStartedAt: Date(timeIntervalSinceNow: 60))
            .save(redactedWith: redactor))
        XCTAssertEqual(store.list().count, 2)
    }

    func testReadsOnlySavedGameLogsByTheirOwnNames() throws {
        let root = try symlinkFreeDirectory()
        let store = DiagnosticRecordingStore(dataRoot: root)
        let saved = try XCTUnwrap(DiagnosticsStorage.saveGameLog(
            Data("excerpt\n".utf8), dataRoot: root, recording: nil, profile: "game",
            startedAt: Date(timeIntervalSince1970: 1_735_689_600)))
        XCTAssertEqual(store.gameLogText(named: saved.lastPathComponent), "excerpt\n")
        try Data(repeating: 0x61, count: DiagnosticRecordingStore.maximumGameLogBytes).write(to: saved)
        XCTAssertEqual(store.gameLogText(named: saved.lastPathComponent)?.utf8.count,
                       DiagnosticRecordingStore.maximumGameLogBytes)
        try Data(repeating: 0x61, count: DiagnosticRecordingStore.maximumGameLogBytes + 1).write(to: saved)
        XCTAssertNil(store.gameLogText(named: saved.lastPathComponent))

        let outside = root.appendingPathComponent("outside.log")
        try Data("private\n".utf8).write(to: outside)
        let link = store.directory.appendingPathComponent("20250101T000000.000000Z-link.game.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let stem = "20250101T000000.000000Z-game"
        let pipe = store.directory.appendingPathComponent("20250101T000000.000000Z-pipe.game.log")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertNil(store.gameLogText(named: pipe.lastPathComponent))
        for name in [link.lastPathComponent, "../outside.log", stem + ".console.log", stem + ".csv",
                     "notes.game.log", "20250101T000000.000000Z-other.game.log", "x/" + saved.lastPathComponent] {
            XCTAssertNil(store.gameLogText(named: name), name)
        }
        XCTAssertNil(store.gameLogFile(named: "../outside.game.log"))
    }

    func testKeepsOnlyTheNewestGameLogsThatAreAllALaunchLeft() throws {
        let root = try symlinkFreeDirectory()
        let store = DiagnosticRecordingStore(dataRoot: root)
        var environment = ["BASALT_FRAME_TRACE": "1"]
        let recording = try XCTUnwrap(FrameTraceSession.rewrite(
            environment: &environment, dataRoot: root, prefix: root, profile: "recorded",
            now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertNotNil(DiagnosticsStorage.saveGameLog(
            Data("x\n".utf8), dataRoot: root, recording: recording, profile: "recorded",
            startedAt: Date(timeIntervalSince1970: 1_000)))
        for hour in 1...3 {
            XCTAssertNotNil(DiagnosticsStorage.saveGameLog(
                Data("x\n".utf8), dataRoot: root, recording: nil, profile: "game-\(hour)",
                startedAt: Date(timeIntervalSince1970: TimeInterval(hour * 3600))))
        }

        XCTAssertEqual(try store.removeGameLogs(keeping: 1), 2)
        XCTAssertEqual(store.list().map(\.profileName), ["game-3", "recorded"])
        XCTAssertEqual(store.list().last?.files.map(\.kind), [.frames, .sessionLog, .gameLog])
        XCTAssertEqual(try store.removeGameLogs(keeping: 1), 0)

        // Saving after a session keeps as many as the history keeps sessions.
        let game = try UnityPrefix(test: self)
        try game.writeLog("Player.log", "line\n")
        for minute in 0..<GameLogExcerpt.keptExcerpts {
            let start = Date(timeIntervalSince1970: TimeInterval(20_000 + minute * 60))
            XCTAssertNotNil(game.run(dataRoot: root, sessionStartedAt: start).save(redactedWith: redactor)?.file)
        }
        let onlyGameLogs = store.list().filter { $0.files.allSatisfy { $0.kind == .gameLog } }
        XCTAssertEqual(onlyGameLogs.count, GameLogExcerpt.keptExcerpts)
        XCTAssertFalse(onlyGameLogs.contains { $0.profileName == "game-3" })
        XCTAssertTrue(store.list().contains { $0.profileName == "recorded" })
    }

    // MARK: - The diagnostic report

    func testTheReportTakesTheRunningGameOrTheLatestSession() throws {
        let game = try UnityPrefix(test: self)
        let root = try symlinkFreeDirectory()
        let start = Date()
        try game.writeLog("Player.log", "WindowsVideoMedia error 0xc00d36bb\n")

        // While the game runs, its log is read as it is now.
        let running = GameLogExcerpt.collect(game.search, since: start, redactedWith: redactor)
        let live = DiagnosticReport.GameLog.current(
            running: game.run(dataRoot: root, sessionStartedAt: start), history: [], dataRoot: root,
            redactedWith: redactor)
        XCTAssertEqual(live.profileName, "electrician")
        XCTAssertEqual(live.lines, running?.text.split(separator: "\n").map(String.init))
        XCTAssertEqual(live.lines.last, "WindowsVideoMedia error 0xc00d36bb")

        // Afterwards, the excerpt saved with the latest session.
        let saved = try XCTUnwrap(game.run(dataRoot: root, sessionStartedAt: start).save(redactedWith: redactor))
        var record = SessionRecord(profileName: "electrician", settings: StreamLaunchSettings())
        record.gameLog = saved.file?.lastPathComponent
        let older = SessionRecord(profileName: "older", settings: StreamLaunchSettings())
        XCTAssertEqual(DiagnosticReport.GameLog.current(
            running: nil, history: [record, older], dataRoot: root, redactedWith: redactor),
                       DiagnosticReport.GameLog(profileName: "electrician", excerpt: saved.excerpt.text))
        // A latest session without one has none, even when an older one has.
        XCTAssertEqual(DiagnosticReport.GameLog.current(
            running: nil, history: [older, record], dataRoot: root, redactedWith: redactor),
                       DiagnosticReport.GameLog(profileName: "older", excerpt: nil))
        XCTAssertEqual(DiagnosticReport.GameLog.current(
            running: nil, history: [], dataRoot: root, redactedWith: redactor).lines, [])
    }

    // MARK: - Helpers

    private func excerpt(_ logs: [(label: String, text: String)]) -> GameLogExcerpt {
        GameLogExcerpt(logs: logs.map { GameLogExcerpt.Log(engine: .unity, label: $0.label, text: $0.text) },
                       redactedWith: redactor)
    }

    /// `data` as a log file read for an excerpt.
    private func read(_ data: Data, maximumBytes: Int = GameLogExcerpt.maximumReadBytes)
        -> (text: String, unreadBytes: Int64)? {
        guard let url = try? temporaryDirectory().appendingPathComponent("game.log"),
              (try? data.write(to: url)) != nil,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return GameLogExcerpt.read(handle, size: Int64(data.count), maximumBytes: maximumBytes)
    }

    /// The storage walk refuses symlinks, and the system temporary folder is
    /// reached through one, so these tests use the project's own.
    private func symlinkFreeDirectory() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".local/tmp/game-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

/// A prefix with a Unity player, `Electrician VR`, whose Windows user is `steamuser`.
private struct UnityPrefix {
    let prefix: URL
    let executable: URL
    var logFolder: URL {
        prefix.appendingPathComponent(
            "drive_c/users/steamuser/AppData/LocalLow/Example Studio/Electrician VR", isDirectory: true)
    }
    var search: GameLogSearch { GameLogSearch(prefix: prefix, executable: executable) }

    init(test: XCTestCase) throws {
        prefix = try test.temporaryDirectory().appendingPathComponent("prefix", isDirectory: true)
        let game = prefix.appendingPathComponent("drive_c/Games/Electrician VR", isDirectory: true)
        try FileManager.default.createDirectory(
            at: game.appendingPathComponent("ElectricianVR_Data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("drive_c/users/Public"), withIntermediateDirectories: true)
        executable = game.appendingPathComponent("ElectricianVR.exe")
        try Data().write(to: executable)
        try Data("Example Studio\nElectrician VR".utf8)
            .write(to: game.appendingPathComponent("ElectricianVR_Data/app.info"))
    }

    func writeLog(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: logFolder.appendingPathComponent(name))
    }

    func run(dataRoot: URL, recording: FrameTraceSession? = nil, sessionStartedAt: Date,
             gameStartedAt: Date? = nil) -> GameLogRun {
        GameLogRun(search: search, gameStartedAt: gameStartedAt ?? sessionStartedAt, profileName: "electrician",
                   sessionID: UUID(), sessionStartedAt: sessionStartedAt, recording: recording, dataRoot: dataRoot)
    }
}
