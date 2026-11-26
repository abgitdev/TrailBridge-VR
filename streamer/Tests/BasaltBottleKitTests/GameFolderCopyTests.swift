// SPDX-License-Identifier: MIT
import Darwin
import XCTest
@testable import BasaltBottleKit

/// Adding a game from a folder: the scan, the copy into `C:\Games`, and every
/// refusal. Each test also proves that Wine never starts.
final class GameFolderCopyTests: XCTestCase {
    // MARK: Copying

    func testCopiesTheTreeByteForByteAndLeavesTheSourceUntouched() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let metadata = fixture.bottleDirectory("hello-xr").appendingPathComponent("bottle.json")
        let metadataBefore = try Data(contentsOf: metadata)
        let source = try makeSource(in: fixture, files: [
            "khr_hello_xr_d3d11.exe": sampleBytes(150_000, seed: 1),
            "readme.txt": Data("hello\n".utf8),
            ".hidden-config": Data("kept".utf8),
            "data/level.pak": sampleBytes(3 << 20, seed: 2),
            "Engine/Binaries/Win64/Game-Win64-Shipping.exe": sampleBytes(4096, seed: 3),
            ".DS_Store": Data("finder".utf8),
            "._readme.txt": Data("appledouble".utf8),
        ], folders: ["data/empty"])
        let readOnly = source.appendingPathComponent("readme.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        let sourceBefore = try snapshot(source)

        let inventory = try fixture.manager.inventoryGameFolder(source)
        XCTAssertEqual(inventory.source.path, source.path)
        XCTAssertEqual(Set(inventory.files.map(\.path)), [
            "khr_hello_xr_d3d11.exe", "readme.txt", ".hidden-config", "data/level.pak",
            "Engine/Binaries/Win64/Game-Win64-Shipping.exe",
        ])
        XCTAssertEqual(Set(inventory.directories),
                       ["data", "data/empty", "Engine", "Engine/Binaries", "Engine/Binaries/Win64"])
        for folder in inventory.directories where folder.contains("/") {
            let parent = (folder as NSString).deletingLastPathComponent
            XCTAssertLessThan(try XCTUnwrap(inventory.directories.firstIndex(of: parent)),
                              try XCTUnwrap(inventory.directories.firstIndex(of: folder)))
        }
        XCTAssertEqual(inventory.totalBytes, 150_000 + 6 + 4 + (3 << 20) + 4096)
        XCTAssertEqual(inventory.entryCount, 12)
        XCTAssertTrue(inventory.isCopyable)

        var reports = [GameFolderCopyProgress]()
        let copy = try fixture.manager.copyGameFolder(
            inventory, intoBottle: "hello-xr", folderName: "hello-xr", reserveBytes: 0,
            progress: { reports.append($0) })
        let destination = fixture.games("hello-xr").appendingPathComponent("hello-xr", isDirectory: true)
        XCTAssertEqual(copy.standardizedFileURL, destination.standardizedFileURL)

        // The same names, sizes and bytes, without Finder's own files.
        let expected = sourceBefore.filter { path, _ in
            let name = (path as NSString).lastPathComponent
            return name != ".DS_Store" && !name.hasPrefix("._")
        }
        let copied = try snapshot(destination)
        XCTAssertEqual(Set(copied.keys), Set(expected.keys))
        for (path, entry) in expected {
            XCTAssertEqual(copied[path]?.kind, entry.kind, path)
            XCTAssertEqual(copied[path]?.size, entry.size, path)
            XCTAssertEqual(copied[path]?.digest, entry.digest, path)
        }
        XCTAssertEqual(try snapshot(source), sourceBefore, "The source must remain untouched")
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBefore)
        XCTAssertEqual(try workFolders(in: fixture.games("hello-xr")), [])

        // The copy of a read-only file belongs to the game; the source keeps its mode.
        XCTAssertEqual(try permissions(of: destination.appendingPathComponent("readme.txt")) & 0o600, 0o600)
        XCTAssertEqual(try permissions(of: readOnly), 0o444)

        XCTAssertEqual(reports.first?.copiedBytes, 0)
        XCTAssertEqual(reports.last, GameFolderCopyProgress(
            copiedBytes: inventory.totalBytes, totalBytes: inventory.totalBytes,
            copiedFiles: 5, totalFiles: 5))
        XCTAssertEqual(reports.map(\.copiedBytes), reports.map(\.copiedBytes).sorted())
        XCTAssertEqual(reports.last?.fraction, 1)
        fixture.assertWineNeverRan()
    }

    func testCopiesFileDataWhereItCannotClone() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let big = sampleBytes(6 << 20, seed: 4)
        let source = try makeSource(in: fixture, files: ["big.pak": big, "small.txt": Data("x".utf8)])
        let inventory = try fixture.manager.inventoryGameFolder(source)
        var reports = [GameFolderCopyProgress]()
        let copy = try copyFolder(fixture, inventory, clones: false, progress: { reports.append($0) })
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("big.pak")), big)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("small.txt")), Data("x".utf8))
        XCTAssertEqual(reports.last?.copiedBytes, inventory.totalBytes)
        XCTAssertEqual(reports.map(\.copiedBytes), reports.map(\.copiedBytes).sorted())
        fixture.assertWineNeverRan()
    }

    func testALockedFileIsCopiedUnlockedSoTheCopyCanBeRemovedAgain() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let source = try makeSource(in: fixture, files: [
            "locked.dat": sampleBytes(4096, seed: 24), "plain.dat": sampleBytes(10, seed: 25),
        ])
        let locked = source.appendingPathComponent("locked.dat")
        guard chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw XCTSkip("This volume does not take file flags")
        }
        let inventory = try fixture.manager.inventoryGameFolder(source)
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        // Cloned, then with the data copy that keeps the source's flags.
        for (folder, clones) in [("cloned", true), ("copied", false)] {
            let copy = try copyFolder(fixture, inventory, as: folder, clones: clones)
            var info = stat()
            XCTAssertEqual(lstat(copy.appendingPathComponent("locked.dat").path, &info), 0)
            XCTAssertEqual(info.st_flags & locks, 0, folder)
            XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("locked.dat")),
                           sampleBytes(4096, seed: 24))
            XCTAssertNoThrow(try FileManager.default.removeItem(at: copy), folder)
        }
        var info = stat()
        XCTAssertEqual(lstat(locked.path, &info), 0)
        XCTAssertNotEqual(info.st_flags & UInt32(UF_IMMUTABLE), 0, "the source keeps its flag")
        fixture.assertWineNeverRan()
    }

    func testTheWorkingGamesStayByteIdenticalWhenAnotherEnvironmentGetsAGame() throws {
        let fixture = try GameFolderFixture(self)
        for (bottle, executable) in zip(WorkingGames.bottles, WorkingGames.executables) {
            try fixture.makeBottle(bottle)
            try populateWorkingEnvironment(fixture, bottle, executable: executable)
        }
        for profile in WorkingGames.profiles { try fixture.manager.saveProfile(profile) }
        try fixture.makeBottle("hello-xr")
        let watched = try WorkingGames.bottles.map(fixture.bottleDirectory)
            + WorkingGames.profiles.map { try fixture.manager.paths.profileFile($0.name) }
        let before = try watched.map(snapshot)

        let source = try makeSource(in: fixture, files: [
            "khr_hello_xr_d3d11.exe": sampleBytes(200_000, seed: 5),
        ])
        let inventory = try fixture.manager.inventoryGameFolder(source)
        let copy = try fixture.manager.copyGameFolder(
            inventory, intoBottle: "hello-xr", folderName: "hello-xr", reserveBytes: 0)
        try fixture.manager.saveNewProfile(LaunchProfile(
            name: "hello-xr", bottleName: "hello-xr", source: .direct,
            executable: #"C:\Games\hello-xr\khr_hello_xr_d3d11.exe"#,
            arguments: ["--graphics", "D3D11", "--space", "Local"],
            workingDirectory: copy.path, gameRoot: #"C:\Games\hello-xr"#, title: "hello_xr"))

        XCTAssertEqual(try watched.map(snapshot), before)
        XCTAssertEqual(try fixture.manager.listProfiles().map(\.name),
                       ["blood-trail-blood-trail", "brutalistick-vr-steam", "hello-xr"])
        fixture.assertWineNeverRan()
    }

    // MARK: Refusals before anything is written

    func testAnExistingFolderOfTheSameNameIsNeverReplaced() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let games = fixture.games("hello-xr")
        let existing = games.appendingPathComponent("Hello-XR", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: existing.appendingPathComponent("save.dat"))
        let inventory = try fixture.manager.inventoryGameFolder(
            try makeSource(in: fixture, files: ["game.exe": sampleBytes(10, seed: 6)]))
        let prefixBefore = try snapshot(fixture.prefix("hello-xr"))

        for name in ["Hello-XR", "hello-xr", "HELLO-XR"] {
            XCTAssertThrowsError(try copyFolder(fixture, inventory, as: name)) { error in
                XCTAssertEqual(error as? GameFolderCopyError, .destinationExists("Hello-XR"))
            }
        }
        XCTAssertEqual(try snapshot(fixture.prefix("hello-xr")), prefixBefore)

        // A dangling link counts as taken, and is never followed.
        let missing = fixture.scratch.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: games.appendingPathComponent("linked"), withDestinationURL: missing)
        XCTAssertThrowsError(try copyFolder(fixture, inventory, as: "linked")) { error in
            XCTAssertEqual(error as? GameFolderCopyError, .destinationExists("linked"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: games.path)),
                       ["Hello-XR", "linked"])
        fixture.assertWineNeverRan()
    }

    func testLinksAndSpecialFilesInTheSourceAreRefusedBeforeAnyWrite() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let outside = fixture.scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("private.txt"))
        let source = try makeSource(in: fixture, files: ["game.exe": sampleBytes(10, seed: 7)])
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("link"),
            withDestinationURL: outside.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("broken"),
            withDestinationURL: outside.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked-folder"), withDestinationURL: outside)
        XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path, 0o600), 0)
        let prefixBefore = try snapshot(fixture.prefix("hello-xr"))

        let inventory = try fixture.manager.inventoryGameFolder(source)
        XCTAssertEqual(inventory.rejected, [
            .init(path: "broken", reason: .symbolicLink),
            .init(path: "link", reason: .symbolicLink),
            .init(path: "linked-folder", reason: .symbolicLink),
            .init(path: "pipe", reason: .namedPipe),
        ])
        XCTAssertEqual(inventory.rejectedCount, 4)
        XCTAssertFalse(inventory.isCopyable)
        XCTAssertEqual(inventory.files.map(\.path), ["game.exe"], "a linked folder is never entered")

        XCTAssertThrowsError(try copyFolder(fixture, inventory)) { error in
            XCTAssertEqual(error as? GameFolderCopyError,
                           .unsupportedEntries(examples: inventory.rejected, count: 4))
        }
        XCTAssertEqual(try snapshot(fixture.prefix("hello-xr")), prefixBefore)

        // Only the first few are kept by name.
        for index in 0..<4 {
            try FileManager.default.createSymbolicLink(
                at: source.appendingPathComponent("more-\(index)"), withDestinationURL: outside)
        }
        let crowded = try fixture.manager.inventoryGameFolder(source)
        XCTAssertEqual(crowded.rejected.count, GameFolderInventory.exampleLimit)
        XCTAssertEqual(crowded.rejectedCount, 8)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["private.txt"])
        fixture.assertWineNeverRan()
    }

    func testALinkOnTheWayToGamesIsRefusedAndNothingIsWrittenThroughIt() throws {
        let fixture = try GameFolderFixture(self)
        let outside = fixture.scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let inventory = try fixture.manager.inventoryGameFolder(
            try makeSource(in: fixture, files: ["game.exe": sampleBytes(10, seed: 8)]))

        try fixture.makeBottle("linked-drive")
        let driveC = fixture.prefix("linked-drive").appendingPathComponent("drive_c")
        try FileManager.default.removeItem(at: driveC)
        try FileManager.default.createSymbolicLink(at: driveC, withDestinationURL: outside)

        try fixture.makeBottle("linked-games")
        try FileManager.default.createSymbolicLink(
            at: fixture.games("linked-games"), withDestinationURL: outside)

        for bottle in ["linked-drive", "linked-games"] {
            XCTAssertThrowsError(try copyFolder(fixture, inventory, into: bottle)) { error in
                guard case .unsafeDestination? = error as? GameFolderCopyError else {
                    return XCTFail("\(bottle): \(error)")
                }
            }
        }
        // An environment whose prefix is a link to another environment's:
        // loading the environment already refuses it.
        try fixture.makeBottle("hello-xr")
        try fixture.makeBottle("linked-prefix")
        try FileManager.default.removeItem(at: fixture.prefix("linked-prefix"))
        try FileManager.default.createSymbolicLink(
            at: fixture.prefix("linked-prefix"), withDestinationURL: fixture.prefix("hello-xr"))
        XCTAssertThrowsError(try copyFolder(fixture, inventory, into: "linked-prefix"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.games("hello-xr").path))
        fixture.assertWineNeverRan()
    }

    func testASourceOverlappingTheDataFolderIsRefused() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let inside = fixture.prefix("hello-xr").appendingPathComponent("drive_c/Some Game", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try sampleBytes(10, seed: 9).write(to: inside.appendingPathComponent("game.exe"))
        let alias = fixture.scratch.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)

        for candidate in [inside, alias, fixture.data, fixture.manager.paths.bottles, fixture.scratch] {
            XCTAssertThrowsError(try fixture.manager.inventoryGameFolder(candidate)) { error in
                guard case .sourceOverlapsDataFolder? = error as? GameFolderCopyError else {
                    return XCTFail("\(candidate.path): \(error)")
                }
            }
        }
        // A scan that already holds such a folder cannot be copied either.
        var info = stat()
        XCTAssertEqual(stat(fixture.scratch.path, &info), 0)
        let around = GameFolderInventory(
            source: fixture.scratch, volume: info.st_dev, sourceInode: info.st_ino,
            files: [], directories: [])
        XCTAssertThrowsError(try copyFolder(fixture, around)) { error in
            XCTAssertEqual(error as? GameFolderCopyError,
                           .sourceOverlapsDataFolder(fixture.scratch.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.prefix("hello-xr").appendingPathComponent("drive_c").path), ["Some Game"])
        fixture.assertWineNeverRan()
    }

    func testNamesThatDifferOnlyInCaseAreRefused() throws {
        XCTAssertEqual(GameFolderWalk.folded("Beat Saber"), GameFolderWalk.folded("beat saber"))
        XCTAssertEqual(GameFolderWalk.folded("Caf\u{E9}"), GameFolderWalk.folded("CAFE\u{301}"))
        XCTAssertNotEqual(GameFolderWalk.folded("Data"), GameFolderWalk.folded("Date"))

        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let scanned = try fixture.manager.inventoryGameFolder(try makeSource(in: fixture, files: [
            "a.bin": sampleBytes(10, seed: 10), "Data/b.bin": sampleBytes(20, seed: 11),
        ]))
        let reported = GameFolderInventory(
            source: scanned.source, volume: scanned.volume, sourceInode: scanned.sourceInode,
            files: scanned.files, directories: scanned.directories,
            caseConflicts: ["Data", "data"], caseConflictCount: 1)
        XCTAssertThrowsError(try copyFolder(fixture, reported)) { error in
            XCTAssertEqual(error as? GameFolderCopyError,
                           .caseConflicts(examples: ["Data", "data"], count: 1))
        }
        // A list whose own entries collide is refused before anything is written.
        let colliding = GameFolderInventory(
            source: scanned.source, volume: scanned.volume, sourceInode: scanned.sourceInode,
            files: scanned.files + [.init(path: "data/B.BIN", size: 20)],
            directories: scanned.directories + ["data"])
        XCTAssertThrowsError(try copyFolder(fixture, colliding)) { error in
            XCTAssertEqual(error as? GameFolderCopyError,
                           .caseConflicts(examples: ["Data", "data"], count: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.games("hello-xr").path))

        // The scan itself reports such names where the source volume can hold them.
        let mixed = try makeSource(in: fixture, named: "mixed", files: ["Game.exe": Data([1])])
        try Data([2]).write(to: mixed.appendingPathComponent("game.exe"))
        if try FileManager.default.contentsOfDirectory(atPath: mixed.path).count == 2 {
            let inventory = try fixture.manager.inventoryGameFolder(mixed)
            XCTAssertEqual(inventory.caseConflictCount, 1)
            XCTAssertFalse(inventory.isCopyable)
        }
        fixture.assertWineNeverRan()
    }

    func testFolderNamesFollowWindowsRules() {
        for valid in ["Beat Saber", "hello-xr", "hello_xr 2", "ゲーム", "COM10", "CONSOLE",
                      "a.b", String(repeating: "x", count: GameFolderName.maximumLength)] {
            XCTAssertNil(GameFolderName.problem(with: valid), valid)
            XCTAssertEqual(try GameFolderName.validate(valid), valid)
        }
        let invalid: [(String, GameFolderName.Problem)] = [
            ("", .empty), (".", .startsWithDot), ("..", .startsWithDot), (".hidden", .startsWithDot),
            ("a/b", .forbiddenCharacter("/")), ("a\\b", .forbiddenCharacter("\\")),
            ("a:b", .forbiddenCharacter(":")), ("a*b", .forbiddenCharacter("*")),
            ("a?b", .forbiddenCharacter("?")), ("a\"b", .forbiddenCharacter("\"")),
            ("<a>", .forbiddenCharacter("<")), ("a|b", .forbiddenCharacter("|")),
            ("tab\there", .forbiddenCharacter("\t")),
            ("Game.", .endsWithDotOrSpace), ("Game ", .endsWithDotOrSpace),
            ("CON", .reservedName), ("con", .reservedName), ("nul.txt", .reservedName),
            ("COM1", .reservedName), ("lpt9.log", .reservedName), ("AUX .txt", .reservedName),
            ("COM¹", .reservedName), ("conin$", .reservedName),
            (String(repeating: "x", count: GameFolderName.maximumLength + 1), .tooLong),
        ]
        for (name, problem) in invalid {
            XCTAssertEqual(GameFolderName.problem(with: name), problem, name)
            XCTAssertFalse(GameFolderName.isValid(name), name)
            XCTAssertThrowsError(try GameFolderName.validate(name)) { error in
                XCTAssertEqual(error as? GameFolderCopyError, .invalidFolderName(name, problem))
            }
        }
    }

    func testTheScanNeedsAFolderAndStopsAtTheEntryLimit() throws {
        let fixture = try GameFolderFixture(self)
        let source = try makeSource(in: fixture, files: [
            "1.bin": Data([1]), "2.bin": Data([2]), "sub/3.bin": Data([3]),
        ])
        XCTAssertEqual(try fixture.manager.inventoryGameFolder(source, entryLimit: 4).entryCount, 4)
        XCTAssertThrowsError(try fixture.manager.inventoryGameFolder(source, entryLimit: 3)) { error in
            XCTAssertEqual(error as? GameFolderCopyError, .tooManyEntries(limit: 3))
        }
        // The chosen URL is resolved once, so a link to the folder works.
        let alias = fixture.scratch.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertEqual(try fixture.manager.inventoryGameFolder(alias).source.path, source.path)

        let file = source.appendingPathComponent("1.bin")
        let missing = fixture.scratch.appendingPathComponent("missing")
        for candidate in [file, missing] {
            XCTAssertThrowsError(try fixture.manager.inventoryGameFolder(candidate)) { error in
                guard case .sourceNotFolder? = error as? GameFolderCopyError else {
                    return XCTFail("\(candidate.path): \(error)")
                }
            }
        }
    }

    // MARK: Failures and cancellation after writing began

    func testAnUnreadableFileFailsTheCopyAndKeepsTheOtherGames() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let games = fixture.games("hello-xr")
        let other = games.appendingPathComponent("Other Game", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: other.appendingPathComponent("save.dat"))
        let otherBefore = try snapshot(other)
        let source = try makeSource(in: fixture, files: [
            "a.bin": sampleBytes(10, seed: 12), "b.bin": sampleBytes(20, seed: 13),
            "c.bin": sampleBytes(30, seed: 14),
        ])
        let inventory = try fixture.manager.inventoryGameFolder(source)
        let locked = source.appendingPathComponent("b.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard access(locked.path, R_OK) != 0 else {
            throw XCTSkip("This volume does not enforce file permissions")
        }

        XCTAssertThrowsError(try copyFolder(fixture, inventory)) { error in
            guard case .failed(let message)? = error as? GameFolderCopyError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("b.bin"), message)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: games.path), ["Other Game"])
        XCTAssertEqual(try snapshot(other), otherBefore)
        fixture.assertWineNeverRan()
    }

    func testCancellingAfterTheFirstFileRemovesTheWorkFolder() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let games = fixture.games("hello-xr")
        let inventory = try fixture.manager.inventoryGameFolder(try makeSource(in: fixture, files: [
            "a.bin": sampleBytes(10, seed: 15), "b.bin": sampleBytes(20, seed: 16),
            "c.bin": sampleBytes(30, seed: 17),
        ]))
        // Cancel as soon as the first file is in the hidden work folder.
        let firstFileCopied = { [unowned self] () -> Bool in
            ((try? self.workFolders(in: games)) ?? []).contains {
                FileManager.default.fileExists(
                    atPath: games.appendingPathComponent($0).appendingPathComponent("a.bin").path)
            }
        }
        XCTAssertThrowsError(try fixture.manager.copyGameFolder(
            inventory, intoBottle: "hello-xr", folderName: "hello-xr", reserveBytes: 0,
            isCancelled: firstFileCopied)) { error in
            XCTAssertEqual(error as? GameFolderCopyError, .cancelled)
            XCTAssertEqual((error as? GameFolderCopyError)?.isCancellation, true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: games.path),
                       "the Games folder this copy created is removed again")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.prefix("hello-xr").appendingPathComponent("drive_c").path))

        // With another game in Games, only the work folder goes.
        let other = games.appendingPathComponent("Other Game", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: other.appendingPathComponent("save.dat"))
        let otherBefore = try snapshot(other)
        XCTAssertThrowsError(try fixture.manager.copyGameFolder(
            inventory, intoBottle: "hello-xr", folderName: "hello-xr", reserveBytes: 0,
            isCancelled: firstFileCopied)) { error in
            XCTAssertEqual(error as? GameFolderCopyError, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: games.path), ["Other Game"])
        XCTAssertEqual(try snapshot(other), otherBefore)
        fixture.assertWineNeverRan()
    }

    func testCancellingInsideALargeFileRemovesTheWorkFolder() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let inventory = try fixture.manager.inventoryGameFolder(try makeSource(in: fixture, files: [
            "big.pak": sampleBytes(8 << 20, seed: 18),
        ]))
        // Polled before writing, before the file, then while its data copies.
        var polls = 0
        XCTAssertThrowsError(try copyFolder(fixture, inventory, clones: false, isCancelled: {
            polls += 1
            return polls >= 3
        })) { error in
            XCTAssertEqual(error as? GameFolderCopyError, .cancelled)
        }
        XCTAssertEqual(polls, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.games("hello-xr").path))
        fixture.assertWineNeverRan()
    }

    func testAFileThatChangesAfterTheScanFailsTheCopy() throws {
        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let games = fixture.games("hello-xr")
        let outside = fixture.scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = try makeSource(in: fixture, files: [
            "a.bin": sampleBytes(10, seed: 19), "b.bin": sampleBytes(20, seed: 20),
            "data/x.bin": sampleBytes(30, seed: 21),
        ])
        let inventory = try fixture.manager.inventoryGameFolder(source)
        let file = source.appendingPathComponent("b.bin")

        func expectChange(_ path: String, _ note: String) {
            XCTAssertThrowsError(try copyFolder(fixture, inventory), note) { error in
                XCTAssertEqual(error as? GameFolderCopyError, .sourceChanged(path), note)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: games.path), note)
        }
        try FileManager.default.removeItem(at: file)
        expectChange("b.bin", "removed")
        try sampleBytes(21, seed: 20).write(to: file)
        expectChange("b.bin", "grown")
        try FileManager.default.removeItem(at: file)
        try sampleBytes(20, seed: 20).write(to: outside.appendingPathComponent("b.bin"))
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: outside.appendingPathComponent("b.bin"))
        expectChange("b.bin", "replaced by a link")
        try FileManager.default.removeItem(at: file)
        try sampleBytes(20, seed: 20).write(to: file)

        // A folder swapped for a link to another folder holding the same file.
        let data = source.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.moveItem(at: data, to: outside.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(
            at: data, withDestinationURL: outside.appendingPathComponent("data"))
        expectChange("data/x.bin", "folder replaced by a link")
        fixture.assertWineNeverRan()
    }

    // MARK: Space

    func testTheSpaceRuleKeepsTheReserveFree() throws {
        let gib: Int64 = 1 << 30
        XCTAssertEqual(GameFolderSpace.defaultReserveBytes, 20 * gib)
        XCTAssertEqual(GameFolderSpace.requiredFreeBytes(
            totalBytes: 5 * gib, clones: true, reserveBytes: 20 * gib), 20 * gib)
        XCTAssertEqual(GameFolderSpace.requiredFreeBytes(
            totalBytes: 5 * gib, clones: false, reserveBytes: 20 * gib), 25 * gib)
        XCTAssertEqual(GameFolderSpace.requiredFreeBytes(
            totalBytes: 5, clones: false, reserveBytes: -1), 5)
        XCTAssertEqual(GameFolderSpace.requiredFreeBytes(
            totalBytes: .max, clones: false, reserveBytes: 1), .max)
        // Sparse files can claim more than an Int64 holds in total: the sum
        // stops at Int64.max instead of trapping in the middle of a copy.
        XCTAssertEqual(GameFolderInventory.addingBytes(.max - 1, 5), .max)
        XCTAssertEqual(GameFolderInventory.addingBytes(10, -3), 10)
        let sparse = GameFolderInventory(
            source: URL(fileURLWithPath: "/nonexistent"), volume: 0, sourceInode: 0,
            files: [.init(path: "a", size: 1 << 62), .init(path: "b", size: 1 << 62),
                    .init(path: "c", size: 1)],
            directories: [])
        XCTAssertEqual(sparse.totalBytes, .max)

        let fixture = try GameFolderFixture(self)
        try fixture.makeBottle("hello-xr")
        let games = fixture.games("hello-xr")
        let inventory = try fixture.manager.inventoryGameFolder(try makeSource(in: fixture, files: [
            "a.bin": sampleBytes(10, seed: 22), "b.bin": sampleBytes(20, seed: 23),
        ]))
        // Files clone only on the scanned folder's own volume.
        XCTAssertTrue(GameFolderVolume(device: inventory.volume, freeBytes: 0, supportsClones: true)
            .clones(inventory))
        XCTAssertFalse(GameFolderVolume(device: inventory.volume &+ 1, freeBytes: 0, supportsClones: true)
            .clones(inventory))
        XCTAssertFalse(GameFolderVolume(device: inventory.volume, freeBytes: 0, supportsClones: false)
            .clones(inventory))
        XCTAssertEqual(GameFolderSpace.volume(at: fixture.scratch)?.device, inventory.volume)

        // The same APFS volume needs only the reserve, and gets nothing below it.
        let reserve: Int64 = 1 << 20
        let volume = try XCTUnwrap(GameFolderSpace.volume(at: games.deletingLastPathComponent()))
        let required = GameFolderSpace.requiredFreeBytes(
            totalBytes: inventory.totalBytes, clones: volume.clones(inventory), reserveBytes: reserve)
        for available in [required - 1, nil] as [Int64?] {
            XCTAssertThrowsError(try copyFolder(fixture, inventory, reserve: reserve,
                                                free: { _ in available })) { error in
                XCTAssertEqual(error as? GameFolderCopyError,
                               .notEnoughSpace(required: required, available: available))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: games.path))

        // While copying, it stops below half the reserve: here before the second file.
        var queries = 0
        XCTAssertThrowsError(try copyFolder(fixture, inventory, reserve: reserve, free: { _ in
            queries += 1
            return queries <= 2 ? required : reserve / 2 - 1
        })) { error in
            XCTAssertEqual(error as? GameFolderCopyError,
                           .notEnoughSpace(required: reserve / 2, available: reserve / 2 - 1))
        }
        XCTAssertEqual(queries, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: games.path))

        XCTAssertNoThrow(try copyFolder(fixture, inventory, reserve: reserve, free: { _ in required }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: games.path), ["hello-xr"])
        fixture.assertWineNeverRan()
    }

    // MARK: Helpers

    /// A game folder outside the data root, as a user would choose it.
    private func makeSource(in fixture: GameFolderFixture, named name: String = "hello-xr",
                            files: [String: Data], folders: [String] = []) throws -> URL {
        let root = fixture.scratch.appendingPathComponent("source/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (path, data) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return root
    }

    /// The copy with a chosen free space and without real clones, so a test
    /// decides what the volume reports.
    @discardableResult
    private func copyFolder(
        _ fixture: GameFolderFixture, _ inventory: GameFolderInventory,
        into bottle: String = "hello-xr", as folder: String = "hello-xr", reserve: Int64 = 0,
        free: @escaping (URL) -> Int64? = { _ in .max }, clones: Bool = true,
        isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (GameFolderCopyProgress) -> Void = { _ in }
    ) throws -> URL {
        try fixture.manager.copyGameFolder(
            inventory, intoBottle: bottle, folderName: folder, reserveBytes: reserve,
            progress: progress, isCancelled: isCancelled, freeBytes: free, clones: clones)
    }

    private func workFolders(in games: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: games.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: games.path)
            .filter { $0.hasPrefix(".trailbridge-import-") }
    }

    private func permissions(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// What Prepare and a few sessions leave in a working environment: the
    /// DXMT files in the engine and in system32, the runtime, the registry,
    /// drive letters, the game, and its shader cache.
    private func populateWorkingEnvironment(_ fixture: GameFolderFixture, _ bottle: String,
                                            executable: String) throws {
        let directory = fixture.bottleDirectory(bottle)
        let prefix = fixture.prefix(bottle)
        var files = [
            "engine/lib/wine/x86_64-unix/winemetal.so",
            "prefix/drive_c/basalt/runtime/basalt_openxr.dll",
            "prefix/drive_c/basalt/runtime/basalt_openxr.json",
            "prefix/system.reg", "prefix/user.reg",
            "prefix/drive_c/Program Files (x86)/Steam/steamapps/common/\(bottle)/\(executable)",
            "host/cache/dxmt/\(executable)/shaders.cache",
            "host/cache/dxmt/\(executable)/pipelines.cache",
        ]
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            files.append("engine/lib/wine/x86_64-windows/\(dll)")
            files.append("prefix/drive_c/windows/system32/\(dll)")
        }
        for (index, path) in files.enumerated() {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sampleBytes(512 + index, seed: UInt8(index)).write(to: file)
        }
        let devices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(
            atPath: devices.appendingPathComponent("z:").path, withDestinationPath: "/")
    }
}
