// SPDX-License-Identifier: MIT
import Foundation
import BasaltBottleKit

/// What a game wrote in its own log, cut to what explains a session: the
/// last lines and every line that reports an error, in the order they were
/// written, with personal data replaced as in a copied session log. It is
/// made after Wine shutdown and for a diagnostic report; code that looks
/// for known problems reads `text`.
public struct GameLogExcerpt: Equatable, Sendable {
    /// A log the excerpt is taken from.
    public struct Source: Equatable, Sendable {
        public var engine: GameLogFile.Engine
        /// As the game names it (`C:\users\[user]\AppData\LocalLow\…\Player.log`),
        /// with personal data replaced; never the path on this Mac.
        public var path: String

        public init(engine: GameLogFile.Engine, path: String) {
            self.engine = engine
            self.path = path
        }
    }

    /// Lines kept from the end of the logs.
    public static let tailLines = 200
    /// The most the whole text takes, in bytes of UTF-8: headers, notes and
    /// line breaks included.
    public static let maximumBytes = 64 * 1024
    /// A longer line is cut and ends with "…".
    public static let maximumLineBytes = 1_000
    /// A longer line is left out whole, for a note: personal data is only
    /// replaced in whole lines, and part of a name or number that a cut
    /// leaves would no longer be recognised.
    public static let maximumReadLineBytes = 16 * 1024
    /// Of a larger log only its end is kept for line selection.
    public static let maximumReadBytes = 8 << 20
    /// The newest logs of one game that are read; older ones stay out.
    public static let maximumFiles = 3
    /// Excerpts kept for launches that recorded nothing else: as many as
    /// the session history keeps sessions.
    public static let keptExcerpts = SessionHistoryStore.defaultLimit

    /// Oldest first.
    public var sources: [Source]
    /// Each log starts with a `==> <path> <==` line, `[… N lines skipped …]`
    /// stands for lines left out, and the text ends with a line break.
    public var text: String

    public init(sources: [Source], text: String) {
        self.sources = sources
        self.text = text
    }

    /// The excerpt of the logs `search` finds for a game started at `start`;
    /// nil when it wrote none that TrailBridge knows of and can read.
    public static func collect(_ search: GameLogSearch, since start: Date,
                               redactedWith redactor: DiagnosticRedactor, wineMayBeRunning: Bool = false,
                               fileManager: FileManager = .default) -> GameLogExcerpt? {
        let logs = search.readLogs(since: start, limit: maximumFiles, fileManager: fileManager) { file -> Log? in
            guard let opened = file.open(), let read = Self.read(opened.handle, size: opened.size) else {
                return nil
            }
            let winePath = BottleManager.winePath(for: file.url, prefix: search.prefix)
            guard winePath.hasPrefix("Z:") else {
                return Log(engine: file.engine, label: winePath, text: read.text, unreadBytes: read.unreadBytes)
            }
            let root = file.root.path
            let base = root == "/" ? root : root + "/"
            let relative = file.url.path.hasPrefix(base)
                ? String(file.url.path.dropFirst(base.count)) : file.url.lastPathComponent
            let label = gameFolderLabel + #"\"# + relative.replacingOccurrences(of: "/", with: #"\"#)
            let standardizedRoot = URL(fileURLWithPath: file.resolvedRoot, isDirectory: true).standardizedFileURL.path
            return Log(engine: file.engine, label: label, text: read.text, unreadBytes: read.unreadBytes,
                       gameFolders: [root, file.resolvedRoot, standardizedRoot])
        }
        return logs.isEmpty ? nil : GameLogExcerpt(
            logs: logs, redactedWith: redactor, wineMayBeRunning: wineMayBeRunning)
    }

    private static let gameFolderLabel = L10n.string(.recordingGameLogFolder, language: .en)

    // MARK: Reading

    /// A log as read, before its lines are chosen.
    struct Log {
        var engine: GameLogFile.Engine
        /// The Windows path its header names, before personal data is replaced.
        var label: String
        var lines: [Substring]
        /// The bytes at its start that were not read.
        var unreadBytes: Int64
        var gameFolders: [String]

        init(engine: GameLogFile.Engine, label: String, text: String, unreadBytes: Int64 = 0,
             gameFolders: [String] = []) {
            self.engine = engine
            self.label = label
            self.unreadBytes = unreadBytes
            self.gameFolders = gameFolders
            var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                .map { Substring($0) }
            // The line break that ends the last line starts no other.
            if lines.last?.isEmpty == true { lines.removeLast() }
            self.lines = lines.map { $0.utf8.last == UInt8(ascii: "\r") ? $0.dropLast() : $0 }
        }
    }

    enum Encoding: Equatable {
        case utf8, utf16LittleEndian, utf16BigEndian

        init(start: Data) {
            if start.starts(with: [0xFF, 0xFE]) {
                self = .utf16LittleEndian
            } else if start.starts(with: [0xFE, 0xFF]) {
                self = .utf16BigEndian
            } else {
                self = .utf8
            }
        }
    }

    /// The text of an open log: all of it, or its last `maximumBytes` without
    /// the line that start falls in. UTF-16 when the log starts with its byte
    /// order mark, as Unreal can write it; else UTF-8 with what is not valid
    /// replaced. nil for a log that looks binary.
    static func read(_ handle: FileHandle, size: Int64,
                     maximumBytes: Int = maximumReadBytes) -> (text: String, unreadBytes: Int64)? {
        let start: Data
        do { start = try handle.read(upToCount: 4096) ?? Data() } catch { return nil }
        let encoding = Encoding(start: start)
        let first: Int64 = encoding == .utf8 ? 0 : 2
        var offset = max(first, size - Int64(maximumBytes))
        // UTF-16 is read in whole code units.
        if encoding != .utf8, (offset - first) % 2 != 0 { offset += 1 }
        if offset > first, decode(start.dropFirst(Int(first)), as: encoding) == nil { return nil }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: Int(max(0, size - offset))) ?? Data(),
              var text = decode(data, as: encoding) else { return nil }
        let unread = offset > first ? offset : 0
        if unread > 0 {
            text = text.utf8.firstIndex(of: UInt8(ascii: "\n"))
                .map { String(text[text.utf8.index(after: $0)...]) } ?? ""
        }
        return (text, unread)
    }

    /// NULs anywhere or a sample dominated by controls indicate binary data.
    static func decode(_ data: Data, as encoding: Encoding) -> String? {
        let text: String
        switch encoding {
        case .utf8:
            guard !data.contains(0) else { return nil }
            text = String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...],
                          as: UTF8.self)
        case .utf16LittleEndian, .utf16BigEndian:
            let bytes = [UInt8](data)
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { index -> UInt16 in
                encoding == .utf16LittleEndian
                    ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                    : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            }
            guard !units.contains(0) else { return nil }
            text = String(decoding: units, as: UTF16.self)
        }
        let sample = text.unicodeScalars.prefix(4096)
        let controls = sample.filter {
            $0.properties.generalCategory == .control && $0 != "\t" && $0 != "\n" && $0 != "\r"
        }.count
        return controls > sample.count / 2 ? nil : text
    }

    // MARK: Choosing the lines

    /// The last `tailLines` lines and every line before them that reports
    /// an error, as many as `maximumBytes` holds. The last lines get what the
    /// errors leave and at least half when they need it; errors are kept from
    /// the first, which usually names the cause.
    init(logs: [Log], redactedWith redactor: DiagnosticRedactor, wineMayBeRunning: Bool = false) {
        let folders = Set(logs.flatMap(\.gameFolders)).sorted { $0.count > $1.count }
            .compactMap(DiagnosticRedactor.gameFolderRule(for:))
        func redact(_ text: String) -> String {
            let withoutFolders = folders.reduce(text) {
                DiagnosticRedactor.replace($1, in: $0, with: Self.gameFolderLabel)
            }
            return redactor.redact(withoutFolders)
        }
        var firsts = [Int]()
        var count = 0
        for log in logs {
            firsts.append(count)
            count += log.lines.count
        }
        func line(_ number: Int) -> Substring {
            let index = firsts.lastIndex { $0 <= number }!
            return logs[index].lines[number - firsts[index]]
        }
        let tail = Array(max(0, count - Self.tailLines)..<count)
        // Every error line until they alone would fill the excerpt.
        var errors = [Int]()
        var rendered = [Int: String]()
        var errorBytes = 0
        var remainingErrors = (0..<count).lazy.filter { Self.reportsError(line($0)) }.makeIterator()
        while errorBytes < Self.maximumBytes {
            let batch = (0..<64).compactMap { _ in remainingErrors.next() }
            guard !batch.isEmpty else { break }
            for (number, text) in zip(batch, Self.render(batch.map(line), redacting: redact)) {
                errors.append(number)
                rendered[number] = text
                errorBytes += text.utf8.count + 1
                if errorBytes >= Self.maximumBytes { break }
            }
        }

        let remainingTail = tail.filter { rendered[$0] == nil }
        for (number, text) in zip(remainingTail, Self.render(remainingTail.map(line), redacting: redact)) {
            rendered[number] = text
        }
        let headers = logs.map { redact("==> \($0.label) <==") }
        let incomplete = wineMayBeRunning ? L10n.string(.recordingGameLogPossiblyIncomplete, language: .en) : nil

        // The longest note a gap can need is reserved for each gap the
        // choice may open, so the whole text never passes `maximumBytes`.
        let note = Self.skipped(count).utf8.count + 1
        var fixed = incomplete.map { $0.utf8.count + 1 } ?? 0
        for (index, log) in logs.enumerated() {
            fixed += headers[index].utf8.count + 1 + note
            if log.unreadBytes > 0 { fixed += Self.unread(log.unreadBytes).utf8.count + 1 }
        }
        let room = max(0, Self.maximumBytes - fixed)
        func cost(_ number: Int) -> Int { rendered[number, default: ""].utf8.count + 1 }
        func gap(before number: Int, after previous: Int?) -> Int {
            firsts.contains(number) || previous == number - 1 ? 0 : note
        }

        let tailCost = tail.reduce(note) { $0 + cost($1) }
        var errorCost = 0
        var previous: Int?
        for number in errors where number < tail.first ?? count {
            errorCost += cost(number) + gap(before: number, after: previous)
            previous = number
        }
        let tailRoom = room - min(errorCost, max(room / 2, room - tailCost))
        var newest = [Int]()
        var used = 0
        for number in tail.reversed() {
            let added = cost(number) + (newest.isEmpty ? note : 0)
            guard used + added <= tailRoom else { break }
            newest.append(number)
            used += added
        }
        var kept = [Int]()
        previous = nil
        for number in errors where number < newest.last ?? count {
            let added = cost(number) + gap(before: number, after: previous)
            guard used + added <= room else { break }
            kept.append(number)
            used += added
            previous = number
        }
        kept += newest.reversed()

        var output = incomplete.map { [$0] } ?? []
        var index = 0
        for (position, log) in logs.enumerated() {
            let end = firsts[position] + log.lines.count
            var next = firsts[position]
            output.append(headers[position])
            if log.unreadBytes > 0 { output.append(Self.unread(log.unreadBytes)) }
            while index < kept.count, kept[index] < end {
                let number = kept[index]
                if number > next { output.append(Self.skipped(number - next)) }
                output.append(rendered[number, default: ""])
                next = number + 1
                index += 1
            }
            if end > next { output.append(Self.skipped(end - next)) }
        }
        self.init(sources: logs.map { Source(engine: $0.engine, path: redact($0.label)) },
                  text: output.joined(separator: "\n") + "\n")
    }

    /// Each line with personal data replaced in the whole line, then cut
    /// after `maximumLineBytes`; a line too long to be read whole becomes
    /// a note.
    private static func render(_ lines: [Substring], redacting redact: (String) -> String) -> [String] {
        guard !lines.isEmpty else { return [] }
        let readable = lines.filter { $0.utf8.count <= maximumReadLineBytes }
        var redacted = redact(readable.joined(separator: "\n")).components(separatedBy: "\n")
        // No rule adds or removes a line break; should one ever do so, each
        // line is redacted on its own.
        if redacted.count != readable.count { redacted = readable.map { redact(String($0)) } }
        var next = redacted.makeIterator()
        return lines.map { line in
            line.utf8.count > maximumReadLineBytes ? omitted(line.utf8.count) : shortened(next.next() ?? "")
        }
    }

    static func shortened(_ line: String) -> String {
        guard line.utf8.count > maximumLineBytes else { return line }
        var kept = ""
        for character in line {
            guard kept.utf8.count + character.utf8.count <= maximumLineBytes else { break }
            kept.append(character)
        }
        return kept + "…"
    }

    static func skipped(_ lines: Int) -> String {
        lines == 1 ? "[… 1 line skipped …]" : "[… \(lines) lines skipped …]"
    }

    static func omitted(_ bytes: Int) -> String { "[long line omitted: \(bytes) bytes]" }

    static func unread(_ bytes: Int64) -> String { "[… earlier lines not read: \(bytes) bytes …]" }

    // MARK: Error lines

    private static let errorWords: [[UInt8]] = ["error", "exception", "fail", "fatal"].map { Array($0.utf8) }

    /// Whether a line reports an error: it has a word that starts with
    /// "error", "exception", "fail" or "fatal" in any case, also as a part
    /// of a CamelCase or snake_case name (`NullReferenceException`,
    /// `XR_ERROR_…`). "Terror" has none. The whole line is looked at, even
    /// one too long to be kept.
    static func reportsError(_ line: Substring) -> Bool {
        line.utf8.withContiguousStorageIfAvailable { reportsError($0) } ?? reportsError(Array(line.utf8))
    }

    private static func reportsError<Bytes: RandomAccessCollection>(_ line: Bytes) -> Bool
    where Bytes.Element == UInt8, Bytes.Index == Int {
        func isLower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
        func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
        var previous: UInt8 = 0x20
        for index in line.indices {
            let byte = line[index]
            defer { previous = byte }
            // A word starts after anything but a letter, and a CamelCase
            // part at a capital after a small letter.
            let startsWord = !(isLower(previous) || isUpper(previous)) || (isUpper(byte) && isLower(previous))
            guard isLower(byte) || isUpper(byte), startsWord else { continue }
            for word in errorWords where index + word.count <= line.endIndex {
                // Setting 0x20 makes an ASCII capital lower case.
                if word.indices.allSatisfy({ line[index + $0] | 0x20 == word[$0] }) { return true }
            }
        }
        return false
    }
}

/// A game the app started, as reading the game's own log needs it: where
/// the game runs and since when, the session and recording it belongs to,
/// and the data folder the session started in.
public struct GameLogRun: Sendable {
    public var search: GameLogSearch
    public var gameStartedAt: Date
    public var profileName: String
    /// The session's `SessionRecord`.
    public var sessionID: UUID
    public var sessionStartedAt: Date
    /// The launch's recording, which lends the saved excerpt its name; nil
    /// when the launch records nothing.
    public var recording: FrameTraceSession?
    /// Where the excerpt is saved and the session recorded, as it was at launch.
    public var dataRoot: URL

    public init(search: GameLogSearch, gameStartedAt: Date, profileName: String, sessionID: UUID,
                sessionStartedAt: Date, recording: FrameTraceSession?, dataRoot: URL) {
        self.search = search
        self.gameStartedAt = gameStartedAt
        self.profileName = profileName
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.recording = recording
        self.dataRoot = dataRoot
    }

    /// What the game has written so far.
    public func excerpt(redactedWith redactor: DiagnosticRedactor,
                        wineMayBeRunning: Bool = false,
                        fileManager: FileManager = .default) -> GameLogExcerpt? {
        GameLogExcerpt.collect(search, since: gameStartedAt, redactedWith: redactor,
                               wineMayBeRunning: wineMayBeRunning, fileManager: fileManager)
    }

    /// After trying to stop the session's Wine processes, saves the excerpt
    /// in `Diagnostics` beside the session's other files (`file` is nil when
    /// it could not be saved). Of the excerpts that are all a launch left,
    /// the newest `GameLogExcerpt.keptExcerpts` stay.
    public func save(redactedWith redactor: DiagnosticRedactor,
                     wineMayBeRunning: Bool = false,
                     fileManager: FileManager = .default) -> (excerpt: GameLogExcerpt, file: URL?)? {
        guard let excerpt = excerpt(redactedWith: redactor, wineMayBeRunning: wineMayBeRunning,
                                    fileManager: fileManager) else { return nil }
        let file = DiagnosticsStorage.saveGameLog(
            Data(excerpt.text.utf8), dataRoot: dataRoot, recording: recording,
            profile: profileName, startedAt: sessionStartedAt)
        if file != nil {
            _ = try? DiagnosticRecordingStore(dataRoot: dataRoot)
                .removeGameLogs(keeping: GameLogExcerpt.keptExcerpts)
        }
        return (excerpt, file)
    }
}

extension DiagnosticReport.GameLog {
    /// The running game's log, read now; else the excerpt saved with the
    /// latest session, which is empty when that session saved none.
    public static func current(running: GameLogRun?, history: [SessionRecord], dataRoot: URL,
                               redactedWith redactor: DiagnosticRedactor,
                               fileManager: FileManager = .default) -> Self {
        if let running {
            return Self(profileName: running.profileName,
                        excerpt: running.excerpt(redactedWith: redactor, fileManager: fileManager)?.text)
        }
        guard let latest = history.first else { return Self(profileName: nil, excerpt: nil) }
        return Self(profileName: latest.profileName, excerpt: latest.gameLog.flatMap {
            DiagnosticRecordingStore(dataRoot: dataRoot).gameLogText(named: $0)
        })
    }
}
