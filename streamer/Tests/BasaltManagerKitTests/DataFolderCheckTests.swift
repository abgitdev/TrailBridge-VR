import XCTest
@testable import BasaltManagerKit

// MARK: - The real file system, in a temporary folder

final class DataFolderCheckRealTests: XCTestCase {
    private let files = FileManager.default
    private let check = DataFolderCheck()

    func testEmptyFolderIsUsedAsItIsAndLeftEmpty() throws {
        let folder = try temporaryDirectory()
        let verdict = try check.check(folder).get()
        XCTAssertEqual(verdict.folder.path, folder.standardizedFileURL.path)
        XCTAssertEqual(verdict.chosen, verdict.folder)
        XCTAssertFalse(verdict.usesSubfolder)
        XCTAssertNil(verdict.subfolderNote)
        XCTAssertGreaterThan(try XCTUnwrap(verdict.volume.freeBytes), 0)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path), [])
    }

    func testFolderThatDoesNotExistYetIsCreated() throws {
        let folder = try temporaryDirectory().appendingPathComponent("new/data", isDirectory: true)
        let verdict = try check.check(folder).get()
        XCTAssertEqual(verdict.folder.path, folder.path)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path), [])
    }

    func testFileInsteadOfFolderIsRefused() throws {
        let file = try temporaryDirectory().appendingPathComponent("data")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(check.check(file), .failure(.notAFolder))
        XCTAssertEqual(check.checkExisting(file), .failure(.notAFolder))
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
    }

    func testFolderBelowAFileCannotBeCreated() throws {
        let file = try temporaryDirectory().appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(check.check(file.appendingPathComponent("data")), .failure(.cannotCreate))
    }

    func testReadOnlyFolderIsRefusedAsNotWritable() throws {
        let folder = try temporaryDirectory()
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        addTeardownBlock { [files] in
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        XCTAssertEqual(check.check(folder), .failure(.notWritable))
        XCTAssertEqual(check.check(folder.appendingPathComponent("inside")), .failure(.notWritable))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path), [])
        // Looking at it writes nothing, so a read-only folder is still found.
        XCTAssertNotNil(try? check.checkExisting(folder).get())
    }

    func testFolderWithOtherFilesGetsATrailBridgeSubfolder() throws {
        let folder = try temporaryDirectory()
        let document = folder.appendingPathComponent("Letter.txt")
        try Data("mine".utf8).write(to: document)

        let verdict = try check.check(folder).get()
        let subfolder = folder.appendingPathComponent("TrailBridge", isDirectory: true)
        XCTAssertEqual(verdict.chosen.path, folder.path)
        XCTAssertEqual(verdict.folder.path, subfolder.path)
        XCTAssertTrue(verdict.usesSubfolder)
        XCTAssertNotNil(verdict.subfolderNote)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: subfolder.path), [])
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path).sorted(), ["Letter.txt", "TrailBridge"])
        XCTAssertEqual(try Data(contentsOf: document), Data("mine".utf8))

        // Choosing the same folder again leads to the same subfolder, and
        // choosing the subfolder itself uses it directly.
        XCTAssertEqual(try check.check(folder).get().folder.path, subfolder.path)
        try files.createDirectory(at: subfolder.appendingPathComponent("Bottles"),
                                  withIntermediateDirectories: true)
        XCTAssertEqual(try check.check(folder).get().folder.path, subfolder.path)
        XCTAssertEqual(try check.check(subfolder).get().folder.path, subfolder.path)
    }

    func testFileNamedTrailBridgeInAForeignFolderIsRefused() throws {
        let folder = try temporaryDirectory()
        try Data("x".utf8).write(to: folder.appendingPathComponent("Letter.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("TrailBridge"))
        XCTAssertEqual(check.check(folder), .failure(.notAFolder))
    }

    func testTrailBridgeDataFolderIsUsedDirectly() throws {
        for marker in ["Bottles", "Profiles"] {
            let folder = try temporaryDirectory()
            try files.createDirectory(at: folder.appendingPathComponent(marker),
                                      withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
            XCTAssertEqual(try check.check(folder).get().folder.path, folder.path, marker)
        }
        let folder = try temporaryDirectory()
        try Data("[]".utf8).write(to: folder.appendingPathComponent("SessionHistory.json"))
        try files.createDirectory(at: folder.appendingPathComponent("Downloads"),
                                  withIntermediateDirectories: true)
        XCTAssertEqual(try check.check(folder).get().folder.path, folder.path)
    }

    func testHiddenFilesDoNotMakeAFolderForeign() throws {
        let folder = try temporaryDirectory()
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try files.createDirectory(at: folder.appendingPathComponent(".Spotlight-V100"),
                                  withIntermediateDirectories: true)
        XCTAssertFalse(try check.check(folder).get().usesSubfolder)
    }

    func testFolderReachedThroughASymbolicLinkWorks() throws {
        let directory = try temporaryDirectory()
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try files.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try files.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(try check.check(link).get().folder.path, link.path)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: real.path), [])
    }

    func testRealFileSystemNameIsRead() throws {
        let name = try XCTUnwrap(SystemDataFolderFileSystem().fileSystemName(at: try temporaryDirectory()))
        XCTAssertFalse(name.isEmpty)
        XCTAssertNil(SystemDataFolderFileSystem().fileSystemName(
            at: try temporaryDirectory().appendingPathComponent("missing")))
    }

    func testLookingAtAMissingFolderCreatesNothing() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("Unplugged/TrailBridge", isDirectory: true)
        XCTAssertEqual(check.checkExisting(folder), .failure(.missing))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: directory.path), [])
    }

    func testLookingAtAFolderInUseWritesNothing() throws {
        let folder = try temporaryDirectory()
        try files.createDirectory(at: folder.appendingPathComponent("Bottles"),
                                  withIntermediateDirectories: true)
        let volume = try check.checkExisting(folder).get()
        XCTAssertGreaterThan(try XCTUnwrap(volume.freeBytes), 0)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path), ["Bottles"])
    }
}

// MARK: - Every branch, with the file system replaced

final class DataFolderCheckTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func fileSystem(_ nodes: [String: FakeDataFolderFileSystem.Node] = [:]) -> FakeDataFolderFileSystem {
        let base: [String: FakeDataFolderFileSystem.Node] = [
            "/": .folder, "/Users": .folder, "/Users/me": .folder, "/Volumes": .folder,
        ]
        return FakeDataFolderFileSystem(nodes: base.merging(nodes) { $1 })
    }

    func testDiskWithoutSymbolicLinksIsRefusedAndLeftClean() {
        let fake = fileSystem(["/Volumes/EXFAT": .folder])
        fake.failures[.createLink] = .ENOTSUP
        let before = fake.nodes
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(URL(fileURLWithPath: "/Volumes/EXFAT")),
                       .failure(.noSymbolicLinks))
        XCTAssertEqual(fake.nodes, before)
    }

    func testFAT32DiskIsRefusedBeforeAnythingIsWritten() {
        let fake = fileSystem(["/Volumes/USB": .folder, "/Volumes/USB/Photos": .folder])
        fake.fileSystemName = "msdos"
        let before = fake.nodes
        let check = DataFolderCheck(fileSystem: fake)
        XCTAssertEqual(check.check(URL(fileURLWithPath: "/Volumes/USB")), .failure(.fat32))
        XCTAssertEqual(fake.writes, 0)
        // A folder made for the check is removed again.
        XCTAssertEqual(check.check(URL(fileURLWithPath: "/Volumes/USB/Games/VR")), .failure(.fat32))
        XCTAssertEqual(fake.nodes, before)
    }

    func testOtherFileSystemsPass() throws {
        for name in ["exfat", "apfs", "hfs", "smbfs", nil] {
            let fake = fileSystem(["/Volumes/Disk": .folder])
            fake.fileSystemName = name
            XCTAssertEqual(try DataFolderCheck(fileSystem: fake).check(URL(fileURLWithPath: "/Volumes/Disk"))
                .get().folder.path, "/Volumes/Disk", name ?? "nil")
        }
    }

    func testFAT32FolderAlreadyInUseStaysUsable() {
        let fake = fileSystem(["/Volumes/USB": .folder, "/Volumes/USB/Bottles": .folder])
        fake.fileSystemName = "msdos"
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).checkExisting(URL(fileURLWithPath: "/Volumes/USB")),
                       .success(fake.volume!))
    }

    func testLinkThatReadsBackWrongCountsAsNoSymbolicLinks() {
        let fake = fileSystem(["/Volumes/Share": .folder])
        fake.linkTargetOverride = "XSym"
        let before = fake.nodes
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(URL(fileURLWithPath: "/Volumes/Share")),
                       .failure(.noSymbolicLinks))
        XCTAssertEqual(fake.nodes, before)

        fake.linkTargetOverride = nil
        fake.failures[.linkTarget] = .EINVAL
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(URL(fileURLWithPath: "/Volumes/Share")),
                       .failure(.noSymbolicLinks))
        XCTAssertEqual(fake.nodes, before)
    }

    func testWriteFailuresSayWhy() {
        for (code, problem): (POSIXErrorCode, DataFolderProblem) in [
            (.EPERM, .accessDenied), (.EACCES, .notWritable), (.EROFS, .notWritable), (.ENOSPC, .notWritable),
        ] {
            let fake = fileSystem(["/Users/me/Data": .folder])
            fake.failures[.createFile] = code
            XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(home.appendingPathComponent("Data")),
                           .failure(problem), "\(code)")
            XCTAssertEqual(fake.nodes.count, 5)
        }
    }

    func testPrivacyRefusalWhileReadingTheFolder() {
        let fake = fileSystem(["/Users/me/Documents": .folder, "/Users/me/Documents/Letter.txt": .file])
        fake.failures[.names] = .EPERM
        let documents = home.appendingPathComponent("Documents")
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(documents), .failure(.accessDenied))
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).checkExisting(documents), .failure(.accessDenied))
        XCTAssertEqual(fake.writes, 0)
    }

    func testCreationFailuresSayWhy() {
        for (code, problem): (POSIXErrorCode, DataFolderProblem) in [
            (.EPERM, .accessDenied), (.EACCES, .notWritable), (.EROFS, .notWritable), (.ENOSPC, .cannotCreate),
        ] {
            let fake = fileSystem()
            fake.failures[.createFolder] = code
            XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(home.appendingPathComponent("Data")),
                           .failure(problem), "\(code)")
        }
    }

    func testDisconnectedDiskGetsNoFolderInItsPlace() {
        let fake = fileSystem()
        let before = fake.nodes
        let check = DataFolderCheck(fileSystem: fake)
        for path in ["/Volumes/Games", "/Volumes/Games/TrailBridge", "/Volumes/Games/a/b/c"] {
            let folder = URL(fileURLWithPath: path)
            XCTAssertEqual(check.check(folder), .failure(.missing), path)
            XCTAssertEqual(check.checkExisting(folder), .failure(.missing), path)
        }
        XCTAssertEqual(fake.nodes, before)
        XCTAssertEqual(fake.writes, 0)
    }

    func testMissingFoldersAreCreatedOnAConnectedDisk() throws {
        let fake = fileSystem(["/Volumes/Games": .folder])
        let verdict = try DataFolderCheck(fileSystem: fake)
            .check(URL(fileURLWithPath: "/Volumes/Games/VR/Data")).get()
        XCTAssertEqual(verdict.folder.path, "/Volumes/Games/VR/Data")
        XCTAssertEqual(fake.nodes["/Volumes/Games/VR"], .folder)
        XCTAssertEqual(fake.nodes["/Volumes/Games/VR/Data"], .folder)
        XCTAssertEqual(fake.nodes.count, 7)
    }

    func testFoldersCreatedForARefusedCheckAreRemoved() {
        let fake = fileSystem(["/Users/me/Documents": .folder, "/Users/me/Documents/Letter.txt": .file])
        fake.failures[.createLink] = .ENOTSUP
        let before = fake.nodes
        let check = DataFolderCheck(fileSystem: fake)
        XCTAssertEqual(check.check(home.appendingPathComponent("new/data")), .failure(.noSymbolicLinks))
        // The subfolder made inside a folder with other files goes too.
        XCTAssertEqual(check.check(home.appendingPathComponent("Documents")), .failure(.noSymbolicLinks))
        XCTAssertEqual(fake.nodes, before)
    }

    func testRefusedCheckKeepsFoldersThatWereAlreadyThere() {
        let fake = fileSystem(["/Users/me/Documents": .folder, "/Users/me/Documents/Letter.txt": .file,
                               "/Users/me/Documents/TrailBridge": .folder])
        fake.failures[.createFile] = .EACCES
        let before = fake.nodes
        XCTAssertEqual(DataFolderCheck(fileSystem: fake).check(home.appendingPathComponent("Documents")),
                       .failure(.notWritable))
        XCTAssertEqual(fake.nodes, before)
    }

    func testFolderWithOtherFilesUsesTheSubfolder() throws {
        let fake = fileSystem(["/Users/me/Documents": .folder, "/Users/me/Documents/Letter.txt": .file])
        let verdict = try DataFolderCheck(fileSystem: fake).check(home.appendingPathComponent("Documents")).get()
        XCTAssertEqual(verdict.chosen.path, "/Users/me/Documents")
        XCTAssertEqual(verdict.folder.path, "/Users/me/Documents/TrailBridge")
        XCTAssertTrue(verdict.usesSubfolder)
        XCTAssertEqual(fake.nodes["/Users/me/Documents/TrailBridge"], .folder)
        XCTAssertEqual(fake.nodes.count, 7)
    }

    func testDefaultFolderIsUsedAsItIsEvenWithOtherFiles() throws {
        let fake = fileSystem(["/Users/me/data": .folder, "/Users/me/data/pip": .folder])
        let verdict = try DataFolderCheck(fileSystem: fake)
            .check(home.appendingPathComponent("data"), usingSubfolder: false).get()
        XCTAssertEqual(verdict.folder.path, "/Users/me/data")
        XCTAssertFalse(verdict.usesSubfolder)
        XCTAssertEqual(fake.nodes.count, 6)
    }

    func testNetworkStorageIsAllowedAndNamed() throws {
        let fake = fileSystem(["/Volumes/nas": .folder])
        fake.volume = DataFolderVolume(kind: .network, freeBytes: 5_000_000_000_000)
        let check = DataFolderCheck(fileSystem: fake)
        let verdict = try check.check(URL(fileURLWithPath: "/Volumes/nas")).get()
        XCTAssertEqual(verdict.volume, DataFolderVolume(kind: .network, freeBytes: 5_000_000_000_000))
        XCTAssertEqual(try check.checkExisting(URL(fileURLWithPath: "/Volumes/nas")).get().kind, .network)
    }

    func testUnknownVolumeStillPasses() throws {
        let fake = fileSystem(["/Users/me/Data": .folder])
        fake.volume = nil
        XCTAssertEqual(try DataFolderCheck(fileSystem: fake).check(home.appendingPathComponent("Data")).get().volume,
                       DataFolderVolume(kind: .thisMac, freeBytes: nil))
    }

    func testLookingAtTheFolderInUse() {
        let fake = fileSystem(["/Volumes/Games": .folder, "/Volumes/Games/Data": .folder,
                               "/Volumes/Games/file": .file])
        let check = DataFolderCheck(fileSystem: fake)
        XCTAssertEqual(check.checkExisting(URL(fileURLWithPath: "/Volumes/Games/Data")),
                       .success(fake.volume!))
        XCTAssertEqual(check.checkExisting(URL(fileURLWithPath: "/Volumes/Games/file")), .failure(.notAFolder))
        XCTAssertEqual(check.checkExisting(URL(fileURLWithPath: "/Volumes/Games/Other")), .failure(.missing))
        // A share that stopped answering is missing, not a crash or a raw error.
        for code in [POSIXErrorCode.ETIMEDOUT, .ESTALE, .EIO] {
            fake.failures[.isFolder] = code
            XCTAssertEqual(check.checkExisting(URL(fileURLWithPath: "/Volumes/Games/Data")),
                           .failure(.missing), "\(code)")
        }
        fake.failures[.isFolder] = .EPERM
        XCTAssertEqual(check.checkExisting(URL(fileURLWithPath: "/Volumes/Games/Data")), .failure(.accessDenied))
        XCTAssertEqual(fake.writes, 0)
    }

    func testMountPoint() {
        XCTAssertEqual(DataFolderCheck.mountPoint(of: URL(fileURLWithPath: "/Volumes/Games/a/b"))?.path,
                       "/Volumes/Games")
        XCTAssertEqual(DataFolderCheck.mountPoint(of: URL(fileURLWithPath: "/Volumes/Games"))?.path,
                       "/Volumes/Games")
        XCTAssertNil(DataFolderCheck.mountPoint(of: URL(fileURLWithPath: "/Volumes")))
        XCTAssertNil(DataFolderCheck.mountPoint(of: URL(fileURLWithPath: "/Users/me/Volumes/Games")))
    }

    // MARK: Kind, free space and texts

    func testKindFromVolumeValues() {
        func kind(_ isLocal: Bool?, _ isInternal: Bool?) -> DataFolderKind {
            DataFolderVolume(isLocal: isLocal, isInternal: isInternal,
                             importantUsageBytes: nil, availableBytes: nil).kind
        }
        XCTAssertEqual(kind(true, true), .thisMac)
        XCTAssertEqual(kind(nil, true), .thisMac)
        XCTAssertEqual(kind(true, false), .external)
        XCTAssertEqual(kind(true, nil), .external)
        XCTAssertEqual(kind(false, nil), .network)
        XCTAssertEqual(kind(false, false), .network)
        XCTAssertEqual(kind(false, true), .network)
    }

    func testFreeSpaceFallsBackToThePlainNumber() {
        func free(_ important: Int64?, _ available: Int?) -> Int64? {
            DataFolderVolume(isLocal: true, isInternal: true,
                             importantUsageBytes: important, availableBytes: available).freeBytes
        }
        XCTAssertEqual(free(10, 5), 10)
        XCTAssertEqual(free(0, 5), 5)
        XCTAssertEqual(free(nil, 5), 5)
        XCTAssertNil(free(nil, nil))
    }

    func testSummaryLine() {
        let previous = L10n.language
        defer { L10n.language = previous }
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let external = DataFolderVolume(kind: .external, freeBytes: 812_000_000_000)
        L10n.language = .ru
        XCTAssertEqual(plain(external.summary), "Внешний диск · свободно 812 ГБ")
        XCTAssertEqual(DataFolderVolume(kind: .network, freeBytes: nil).summary, "Сетевое хранилище")
        XCTAssertEqual(DataFolderKind.thisMac.name, "Диск этого Mac")
        L10n.language = .en
        XCTAssertEqual(plain(external.summary), "External disk · 812 GB free")
        XCTAssertEqual(DataFolderVolume(kind: .thisMac, freeBytes: nil).summary, "This Mac’s disk")
    }

    func testEveryProblemHasItsOwnPlainText() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let problems: [DataFolderProblem] = [
            .notAFolder, .missing, .cannotCreate, .notWritable, .accessDenied, .noSymbolicLinks, .fat32,
            .unsupportedPath,
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            let messages = problems.map(\.message)
            XCTAssertEqual(Set(messages).count, problems.count, "\(language)")
            for message in messages {
                XCTAssertFalse(message.isEmpty, "\(language)")
                XCTAssertFalse(message.contains("%"), "\(language)")
            }
            XCTAssertTrue(DataFolderProblem.noSymbolicLinks.message.contains("APFS"), "\(language)")
            // exFAT and FAT disks do have symbolic links on this macOS.
            XCTAssertFalse(DataFolderProblem.noSymbolicLinks.message.contains("FAT"), "\(language)")
            XCTAssertTrue(DataFolderProblem.fat32.message.contains("FAT32"), "\(language)")
            XCTAssertTrue(DataFolderProblem.fat32.message.contains("exFAT"), "\(language)")
        }
        L10n.language = .ru
        XCTAssertEqual(DataFolderProblem.noSymbolicLinks.message,
                       "Диск с этой папкой не поддерживает символические ссылки, а без них окружения для игр "
                       + "не создать. Так бывает в некоторых сетевых папках. Подойдёт диск в формате APFS "
                       + "или Mac OS Extended.")
        XCTAssertEqual(DataFolderProblem.fat32.message,
                       "Диск с этой папкой в формате FAT32: в нём нельзя хранить файлы больше 4 ГБ, а у игр "
                       + "такие файлы есть. Подойдёт APFS, Mac OS Extended или exFAT.")
        XCTAssertTrue(DataFolderProblem.accessDenied.message.contains(
            "Системные настройки › Конфиденциальность и безопасность › Файлы и папки"))
        L10n.language = .en
        XCTAssertTrue(DataFolderProblem.accessDenied.message.contains(
            "System Settings › Privacy & Security › Files and Folders"))
    }
}

// MARK: - Test file system

/// Folders, files and links by path, with a failure for any step.
final class FakeDataFolderFileSystem: DataFolderFileSystem, @unchecked Sendable {
    enum Node: Equatable { case folder, file, link(String) }
    enum Step { case isFolder, createFolder, names, createFile, createLink, linkTarget }

    var nodes: [String: Node]
    var failures = [Step: POSIXErrorCode]()
    var linkTargetOverride: String?
    var volume: DataFolderVolume? = DataFolderVolume(kind: .external, freeBytes: 100_000_000_000)
    var fileSystemName: String? = "apfs"
    /// Folders, files and links created so far.
    private(set) var writes = 0

    init(nodes: [String: Node]) { self.nodes = nodes }

    private func fail(_ step: Step) throws {
        if let code = failures[step] { throw POSIXError(code) }
    }

    func isFolder(at url: URL) throws -> Bool? {
        try fail(.isFolder)
        return nodes[url.path].map { $0 == .folder }
    }

    func createFolder(at url: URL) throws {
        try fail(.createFolder)
        guard nodes[url.path] == nil else { throw POSIXError(.EEXIST) }
        guard nodes[url.deletingLastPathComponent().path] == .folder else { throw POSIXError(.ENOENT) }
        nodes[url.path] = .folder
        writes += 1
    }

    func removeEmptyFolder(at url: URL) {
        guard nodes[url.path] == .folder, (try? children(of: url))?.isEmpty == true else { return }
        nodes[url.path] = nil
    }

    func names(in folder: URL) throws -> [String] {
        try fail(.names)
        return try children(of: folder)
    }

    func createFile(at url: URL) throws {
        try fail(.createFile)
        guard nodes[url.path] == nil else { throw POSIXError(.EEXIST) }
        nodes[url.path] = .file
        writes += 1
    }

    func createLink(at url: URL, to target: String) throws {
        try fail(.createLink)
        guard nodes[url.path] == nil else { throw POSIXError(.EEXIST) }
        nodes[url.path] = .link(target)
        writes += 1
    }

    func linkTarget(at url: URL) throws -> String {
        try fail(.linkTarget)
        guard case .link(let target)? = nodes[url.path] else { throw POSIXError(.EINVAL) }
        return linkTargetOverride ?? target
    }

    func remove(at url: URL) {
        if nodes[url.path] != .folder { nodes[url.path] = nil }
    }

    func volume(at url: URL) -> DataFolderVolume? { volume }

    func fileSystemName(at url: URL) -> String? { fileSystemName }

    private func children(of folder: URL) throws -> [String] {
        guard nodes[folder.path] == .folder else { throw POSIXError(.ENOENT) }
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        return nodes.keys.filter { $0.hasPrefix(prefix) && $0 != prefix }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.contains("/") }
    }
}
