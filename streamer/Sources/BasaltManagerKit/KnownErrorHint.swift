// SPDX-License-Identifier: MIT
import Foundation
import BasaltCore

/// An error whose cause TrailBridge knows, as the game's own log or a
/// session's output shows it, and the hint the session log gives for it. A
/// game that runs with a black headset often says why only in a line that
/// means nothing to the person playing it. Each rule is one entry of
/// `rules`; `KnownErrorScanner` reads a session's lines with them.
public struct KnownErrorHint: Sendable {
    /// What a rule reads.
    public enum Reads: Sendable {
        /// What the game wrote itself: the content lines of the excerpt of
        /// its own log, and its output in the session log, where a Unity
        /// player started with `-logFile -` writes its log too.
        case game
        /// What the session's Wine processes printed, the game and Steam:
        /// Wine's own messages go to the process that started its server.
        case wine
    }

    /// What a rule needs besides its line.
    public enum Condition: Sendable {
        /// As the game found it when it started.
        case gStreamerMissing
        case gStreamerInstalled
        /// The game's OpenXR runtime did not connect at any time in the session.
        case runtimeNeverConnected
    }

    /// Matched against one line, without the prefix of the process that
    /// printed it.
    public let pattern: NSRegularExpression
    public let reads: Reads
    public let condition: Condition?
    /// The hint, also what makes it one: a hint is given once however many
    /// rules for it match.
    public let key: L10nKey
    /// The places in the app the hint sends the person to, by the names the
    /// app shows for them, in the order of the hint's placeholders.
    public let places: [L10nKey]

    /// The patterns are literals that the tests read, so they are compiled
    /// once and a mistake in one shows there.
    init(_ pattern: String, reads: Reads, when condition: Condition? = nil, key: L10nKey,
         places: [L10nKey] = []) {
        self.pattern = try! NSRegularExpression(pattern: pattern)
        self.reads = reads
        self.condition = condition
        self.key = key
        self.places = places
    }

    /// The hint in the app's language, without a line break.
    public var text: String {
        L10n.string(key, arguments: places.map { L10n.string($0) as CVarArg })
    }

    public static let rules: [KnownErrorHint] = [
        // Unity plays video through Media Foundation, which Wine implements
        // with GStreamer. Electrician Simulator VR waited forever for an
        // intro video it could not open, and only its Player.log said so.
        KnownErrorHint("WindowsVideoMedia error", reads: .game, when: .gStreamerMissing,
                       key: .modelHintVideoWithoutGStreamer, places: [.sidebarSetup, .setupGStreamerPackage]),
        KnownErrorHint("WindowsVideoMedia error", reads: .game, when: .gStreamerInstalled,
                       key: .modelHintVideoMediaFoundation),
        // OpenVR's DLL that Unity could not load, or OpenVR that found no
        // SteamVR, as Unity's built-in VR support and the SteamVR plugin
        // say it. OpenComposite stands in for SteamVR; the hint names the
        // game card's menu item, which is there even when the game folder
        // has no openvr_api.dll left to replace.
        KnownErrorHint(
            #"DllNotFoundException.*openvr_api|OpenVR failed initialization"#
                + #"|\[SteamVR\](?:</b>)? Initialization (?i:failed)"#,
            reads: .game, key: .modelHintOpenVR, places: [.sidebarLibrary, .libraryOpenVRSupport]),
        // A line naming xrCreateInstance with a failure, an XR_ERROR_ result
        // or a negative XrResult after it, or after a "FAIL:" that starts
        // the line, as TrailBridge's own smoke clients in runtime/tests
        // print it, however an engine words the rest; or the reason the
        // runtime prints to the game's output as it refuses one
        // (runtime/pe/runtime.cpp). Unity asks for OpenXR 1.1 first and
        // falls back to 1.0, so a refusal is an error only when no runtime
        // connected in the session.
        KnownErrorHint(
            #"xrCreateInstance\b.*(?:(?i:fail)|XR_ERROR_|\breturned XrResult -[0-9]+)"#
                + #"|^FAIL: .*\bxrCreateInstance\b"#
                + #"|Basalt OpenXR: (?:xrCreateInstance rejected|unsupported application API version"#
                + #"|null enabled extension name|unsupported enabled extension"#
                + #"|D3D11 runtime support is unavailable)"#,
            reads: .game, when: .runtimeNeverConnected, key: .modelHintOpenXR),
        // Wine's server prints this as it dies (server/signal.c), as a line
        // of its own in the output of the Wine process that started it.
        KnownErrorHint("^wineserver crashed", reads: .wine, key: .modelHintWineCrashed,
                       places: [.menuHelp, .menuDiagnostics]),
    ]
}

/// Reads each session's output for known errors as it arrives, and its
/// game's own log once that has been read, so that neither the session
/// log's trimmed tail nor Clear loses a line; a session's hints are given
/// once, when it has ended. A process's output belongs to the session that
/// started it, also when it arrives after the session has stopped or
/// another launch has taken the log over. The app's own lines are never
/// read: they quote paths and names that can hold anything.
public struct KnownErrorScanner: Sendable {
    /// Who printed a session's output, by the prefix its lines carry in the
    /// session log.
    public enum Printer: String, Sendable {
        case streamer = ""
        case steam = "steam: "
        case game = "game: "
    }

    private struct Session: Sendable {
        let order: Int
        /// The data folder whose history has the session's record.
        let dataRoot: URL
        var gStreamer: GStreamerInstallation?
        var runtimeConnected = false
        /// The rules a line has matched, by their index in `rules`; their
        /// conditions are read when the hints are given.
        var matched = Set<Int>()
    }

    private let rules: [KnownErrorHint]
    private var sessions = [UUID: Session]()
    private var sources = [ObjectIdentifier: (session: UUID, printer: Printer)]()
    private var begun = 0

    public init() {
        self.init(rules: KnownErrorHint.rules)
    }

    init(rules: [KnownErrorHint]) {
        self.rules = rules
    }

    /// Sessions whose hints have yet to be given, oldest first.
    public var unfinished: [UUID] {
        sessions.sorted { $0.value.order < $1.value.order }.map(\.key)
    }

    /// A session the app starts, recorded in the history in `dataRoot`.
    public mutating func begin(_ session: UUID, dataRoot: URL) {
        begun += 1
        sessions[session] = Session(order: begun, dataRoot: dataRoot)
    }

    /// What `source`, a pipe, carries from now on is `printer`'s output in `session`.
    public mutating func attach(_ source: ObjectIdentifier, printer: Printer, to session: UUID) {
        sources[source] = (session, printer)
    }

    /// `source` has closed: a pipe opened later may have its identity.
    public mutating func close(_ source: ObjectIdentifier) {
        sources[source] = nil
    }

    /// Whether a pipe attached to `session` has yet to close.
    public func isReading(_ session: UUID) -> Bool {
        sources.values.contains { $0.session == session }
    }

    /// Nothing more of `session`'s pipes is read, closed or not.
    public mutating func stopReading(_ session: UUID) {
        sources = sources.filter { $0.value.session != session }
    }

    public mutating func gameStarted(in session: UUID, gStreamer: GStreamerInstallation) {
        sessions[session]?.gStreamer = gStreamer
    }

    /// Reads lines as the session log got them (`SessionConsole.append`),
    /// with `source` the pipe they came from: nil, or one no session
    /// attached, for the app's own lines.
    public mutating func read(_ lines: [String], from source: ObjectIdentifier?) {
        guard let source, let (session, printer) = sources[source], var state = sessions[session] else { return }
        for line in lines {
            let message = line.hasPrefix(printer.rawValue) ? line.dropFirst(printer.rawValue.count) : Substring(line)
            switch printer {
            // The streamer's report of an accepted Hello; no game can print a
            // line of the streamer's.
            case .streamer:
                if message.hasPrefix(RuntimeLink.connectedLogPrefix) { state.runtimeConnected = true }
            case .steam:
                match(message, reading: [.wine], into: &state)
            case .game:
                match(message, reading: [.game, .wine], into: &state)
            }
        }
        sessions[session] = state
    }

    /// Reads the excerpt of the session's game's own log, once read.
    public mutating func read(gameLog excerpt: GameLogExcerpt?, of session: UUID) {
        guard let excerpt, var state = sessions[session] else { return }
        for line in Self.contentLines(of: excerpt) {
            match(line, reading: [.game], into: &state)
        }
        sessions[session] = state
    }

    /// The hints of a session that has ended, each once, in the order of
    /// `rules`, with the data folder of its history; nil when they have
    /// been given already.
    public mutating func finish(_ session: UUID) -> (hints: [KnownErrorHint], dataRoot: URL)? {
        guard let state = sessions.removeValue(forKey: session) else { return nil }
        stopReading(session)
        var given = Set<L10nKey>()
        let hints = rules.indices.filter { index in
            let rule = rules[index]
            guard state.matched.contains(index), !given.contains(rule.key) else { return false }
            switch rule.condition {
            case nil: break
            case .gStreamerMissing?: guard state.gStreamer == .missing else { return false }
            case .gStreamerInstalled?: guard case .installed = state.gStreamer else { return false }
            case .runtimeNeverConnected?: guard !state.runtimeConnected else { return false }
            }
            given.insert(rule.key)
            return true
        }.map { rules[$0] }
        return (hints, state.dataRoot)
    }

    /// GStreamer's known harmless warnings never match, whatever they say:
    /// once it is installed, Wine prints them in every session.
    private func match(_ line: Substring, reading reads: Set<KnownErrorHint.Reads>, into state: inout Session) {
        let text = String(line)
        let range = NSRange(text.startIndex..., in: text)
        for (index, rule) in rules.enumerated()
        where reads.contains(rule.reads) && !state.matched.contains(index)
            && rule.pattern.firstMatch(in: text, range: range) != nil
            && !SessionConsole.isKnownHarmlessNoise(text) {
            state.matched.insert(index)
        }
    }

    // MARK: The excerpt's own lines

    /// The lines the game wrote, without the excerpt's headers, which name a
    /// folder of the game's own choosing, and its notes.
    static func contentLines(of excerpt: GameLogExcerpt) -> [Substring] {
        excerpt.text.split(whereSeparator: \.isNewline).filter { line in
            guard !(line.hasPrefix("==> ") && line.hasSuffix(" <==")), line != possiblyIncomplete else { return false }
            let text = String(line)
            return excerptNote.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
        }
    }

    /// As `GameLogExcerpt` writes its notes: `skipped`, `unread` and `omitted`.
    private static let excerptNote = try! NSRegularExpression(
        pattern: #"^\[(?:… [0-9]+ lines? skipped …|… earlier lines not read: [0-9]+ bytes …"#
            + #"|long line omitted: [0-9]+ bytes)\]$"#)

    private static let possiblyIncomplete = L10n.string(.recordingGameLogPossiblyIncomplete, language: .en)
}
