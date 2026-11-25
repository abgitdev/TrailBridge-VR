import Combine
import Foundation

/// The live session log and its metric samples. Streamer, Steam, and Wine
/// output arrives in many small chunks, so this state lives apart from the
/// app model: each chunk re-renders only the views that show the log or the
/// charts, not the whole window.
@MainActor
public final class SessionConsole: ObservableObject {
    /// Past `maximumLogBytes` the log drops whole lines from the front,
    /// keeping about `retainedLogBytes`.
    public static let maximumLogBytes = 80_000
    public static let retainedLogBytes = 60_000
    /// Samples kept for CSV export; the charts show the last `chartWindow`.
    public static let maximumSamples = 50_000
    public static let chartWindow = 360
    /// A partial line longer than this is logged as it stands, so a process
    /// that never writes a newline cannot grow its buffer without bound.
    public static let maximumPartialLineBytes = 16_384

    @Published public private(set) var log = ""
    @Published public private(set) var headsetDisconnected = false
    /// Every metric sample since the session started.
    @Published public private(set) var samples = [StreamMetricSample]()
    /// One pending partial line per output source (each process pipe, or
    /// nil for the app's own messages), so concurrent outputs never splice
    /// into each other mid-line.
    private var partialLines = [ObjectIdentifier?: String]()

    /// Messages that can flood the log while a single output pipe is open.
    private enum RepeatedLine: Hashable {
        case deviceError
        case gStreamerWarning(String)
    }

    /// The counts and one line of lookahead for a pipe with a fixed display prefix.
    private struct SourceOutput {
        let prefix: String
        var counts = [RepeatedLine: Int]()
        var pendingBlank: String?

        mutating func count(_ line: RepeatedLine) -> Int {
            counts[line, default: 0] += 1
            return counts[line, default: 0]
        }
    }

    /// Known harmless GLib messages, keyed by the names shown in repeat totals.
    private nonisolated static let gStreamerWarnings: [(name: String, pattern: NSRegularExpression)] = {
        let process = #"(?:\*\* )?\([^():\s]+:[0-9]+\): "#
        let timestamp = #"(?:[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?: )?"#
        let severityEnd = #" \*\*: "#
        /// Wine's GStreamer support doesn't use the Python bindings.
        let pygobject = (name: "pygobject", domainAndLevel: "CRITICAL",
                         message: #"pygobject initialization failed: could not import gobject \(error was: .*\)"#)
        /// GStreamer can report unfixed caps during format negotiation and still play video.
        let videoCaps = (name: "gst_video_info_from_caps", domainAndLevel: "GStreamer-Video-CRITICAL",
                         message: #"gst_video_info_from_caps: assertion 'gst_caps_is_fixed \(caps\)' failed"#)
        return [pygobject, videoCaps].map { rule in
            let pattern = "^" + process + rule.domainAndLevel + severityEnd + timestamp + rule.message + "$"
            return (rule.name, try! NSRegularExpression(pattern: pattern))
        }
    }()

    /// A log can contain totals written before the user changed the app language.
    private nonisolated static let gStreamerTotalPattern: NSRegularExpression = {
        let count = #"\p{Nd}+(?:[.,'’\p{Zs}]\p{Nd}+)*"#
        let formats = AppLanguage.allCases.compactMap {
            LocalizationTables.table(for: $0)?.strings[.modelGStreamerWarningRepeats]
        }
        let patterns = formats.flatMap { format in
            gStreamerWarnings.map { warning in
                format.replacingOccurrences(of: "%1$@", with: warning.name)
                    .components(separatedBy: "%2$lld")
                    .map(NSRegularExpression.escapedPattern(for:))
                    .joined(separator: count)
            }
        }
        return try! NSRegularExpression(pattern: "^(?:" + patterns.joined(separator: "|") + ")$")
    }()

    private var outputBySource = [ObjectIdentifier?: SourceOutput]()
    private var warnedAboutMissingGStreamer = false
    private var transcript: ConsoleTranscript?
    private var transcriptsBySource = [ObjectIdentifier: ConsoleTranscript]()

    public init() {}

    /// The charts' and health checks' recent window of `samples`.
    public var recentSamples: [StreamMetricSample] {
        Array(samples.suffix(Self.chartWindow))
    }

    /// The newest non-empty log line, scanned back from the end so a render
    /// never copies the whole log.
    public var latestLine: String? {
        guard let end = log.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        let start = log[..<end].lastIndex(where: \.isNewline).map(log.index(after:))
            ?? log.startIndex
        return log[start...end].trimmingCharacters(in: .whitespaces)
    }

    /// Repeat totals for sources that have yet to reach EOF.
    public var openRepeatTotals: [String] {
        outputBySource.values.flatMap(Self.repeatTotals(for:)).sorted()
    }

    /// Puts live counts at the end so they survive the report's log tail limit.
    public var diagnosticLog: String {
        let totals = openRepeatTotals
        guard !totals.isEmpty else { return log }
        let separator = log.isEmpty || log.hasSuffix("\n") ? "" : "\n"
        return log + separator + totals.joined(separator: "\n")
    }

    /// Starts a new log. A stream session also clears the samples; a Windows
    /// utility keeps the last stream's charts. The transcript file gets the
    /// same redaction as an exported log; the log on screen stays as it is.
    public func restart(with firstLine: String = "", clearingSamples: Bool = true,
                        transcriptURL: URL? = nil, transcriptRedactor: DiagnosticRedactor? = nil) {
        closeTranscript()
        if let transcriptURL {
            transcript = ConsoleTranscript(
                url: transcriptURL,
                redact: transcriptRedactor.map { redactor in { @Sendable text in redactor.redact(text) } })
            transcript?.append(firstLine)
        }
        log = firstLine
        headsetDisconnected = false
        partialLines.removeAll()
        outputBySource.removeAll()
        warnedAboutMissingGStreamer = false
        if clearingSamples { samples.removeAll() }
    }

    /// Supplies the warning the first time a game launch finds GStreamer missing in this session.
    public func gStreamerWarning(for installation: GStreamerInstallation) -> String? {
        guard !warnedAboutMissingGStreamer, installation == .missing else { return nil }
        warnedAboutMissingGStreamer = true
        return L10n.string(.modelGStreamerMissing, PinnedWine.gStreamerPackageURL.absoluteString)
    }

    /// Appends raw output from `source`, logs the lines it completed with
    /// `prefix`, and returns them. An unfinished line waits for its source's
    /// next chunk or `finish`.
    public func append(_ output: String, from source: ObjectIdentifier? = nil,
                       prefix: String = "") -> [String] {
        // Wine writes CRLF; split on LF and drop the CR so it adds no blank line.
        var lines = (partialLines[source, default: ""] + output)
            .components(separatedBy: "\n")
        var partial = lines.removeLast()
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if partial.utf8.count > Self.maximumPartialLineBytes {
            lines.append(partial)
            partial = ""
        }
        partialLines[source] = partial.isEmpty ? nil : partial
        return commit(lines, from: source, prefix: prefix)
    }

    /// Logs and returns the unfinished line and repeat totals when `source` closes.
    public func finish(_ source: ObjectIdentifier?, prefix: String = "") -> [String] {
        defer {
            if let source, let writer = transcriptsBySource.removeValue(forKey: source),
               writer !== transcript, !transcriptsBySource.values.contains(where: { $0 === writer }) {
                writer.finish()
            }
        }
        let lines = partialLines.removeValue(forKey: source).map { [$0] } ?? []
        return commit(lines, from: source, prefix: prefix, finishing: true)
    }

    private func commit(_ lines: [String], from source: ObjectIdentifier?, prefix: String,
                        finishing: Bool = false) -> [String] {
        guard !lines.isEmpty || finishing else { return [] }
        // Persist before the live console's flood suppression and tail trim.
        // Every source line, including repeated GPU and GStreamer warnings, reaches disk.
        let writer = source.flatMap({ transcriptsBySource[$0] }) ?? transcript
        if !lines.isEmpty, let writer {
            writer.append(lines.map { prefix + $0 + "\n" }.joined())
        }
        if prefix.isEmpty {
            for line in lines {
                if line == "Headset disconnected; waiting for it to reconnect…" {
                    headsetDisconnected = true
                } else if line == "Headset reconnected" {
                    headsetDisconnected = false
                }
            }
        }
        var output = outputBySource.removeValue(forKey: source) ?? SourceOutput(prefix: prefix)
        var prefixed = [String]()
        for line in lines {
            let displayLine = prefix + line
            let message = line.drop(while: \.isWhitespace)
            let precedingBlank = output.pendingBlank
            output.pendingBlank = nil
            if !prefix.isEmpty, message.isEmpty {
                if let precedingBlank { prefixed.append(precedingBlank) }
                output.pendingBlank = displayLine
                continue
            }
            if let warning = Self.harmlessWarning(in: message) {
                // GLib adds one blank immediately before its message.
                if output.count(.gStreamerWarning(warning)) == 1 { prefixed.append(displayLine) }
                continue
            }
            if let precedingBlank { prefixed.append(precedingBlank) }

            // A lost Metal device can reject every subsequent command buffer.
            // Logarithmically spaced counts keep that flood from evicting the
            // compiler errors that preceded it. Match only DXMT's raw error
            // line, after assembling chunks and before prefixing.
            if line.hasPrefix("err:   Device error at frame ") {
                let repeats = output.count(.deviceError) - 1
                if repeats == 0 {
                    prefixed.append(displayLine)
                } else if repeats & (repeats - 1) == 0 {
                    prefixed.append(prefix + "err:   Device error: suppressed \(repeats) repeated command buffer failures")
                }
            } else {
                prefixed.append(displayLine)
            }
        }
        if finishing {
            if let pendingBlank = output.pendingBlank { prefixed.append(pendingBlank) }
            let totals = Self.repeatTotals(for: output)
            prefixed += totals
            if !totals.isEmpty {
                writer?.append(totals.joined(separator: "\n") + "\n")
            }
        } else {
            outputBySource[source] = output
        }
        guard !prefixed.isEmpty else { return [] }
        log += prefixed.map { $0 + "\n" }.joined()
        if log.utf8.count > Self.maximumLogBytes { trimLog() }
        return prefixed
    }

    private static func repeatTotals(for output: SourceOutput) -> [String] {
        var totals = gStreamerWarnings.compactMap { warning -> String? in
            guard let count = output.counts[.gStreamerWarning(warning.name)], count > 1 else { return nil }
            return output.prefix + L10n.string(.modelGStreamerWarningRepeats, warning.name, Int64(count - 1))
        }
        if let count = output.counts[.deviceError], count > 1 {
            totals.append(output.prefix + "err:   Device error: suppressed \(count - 1) repeated command buffer failures (total)")
        }
        return totals
    }

    /// Recognizes known GStreamer warnings and their totals in raw or source-prefixed log lines.
    public nonisolated static func isKnownHarmlessNoise(_ line: String) -> Bool {
        func matches(_ message: Substring) -> Bool {
            if harmlessWarning(in: message) != nil { return true }
            let text = String(message)
            let range = NSRange(text.startIndex..., in: text)
            return gStreamerTotalPattern.firstMatch(in: text, range: range) != nil
        }

        let message = line.drop(while: \.isWhitespace)
        if matches(message) { return true }
        guard let colon = message.firstIndex(of: ":") else { return false }
        let content = message[message.index(after: colon)...]
        guard content.first?.isWhitespace == true else { return false }
        return matches(content.drop(while: \.isWhitespace))
    }

    private nonisolated static func harmlessWarning(in message: Substring) -> String? {
        guard message.hasPrefix("(") || message.hasPrefix("** (") else { return nil }
        let line = String(message)
        let range = NSRange(line.startIndex..., in: line)
        return gStreamerWarnings.first { $0.pattern.firstMatch(in: line, range: range) != nil }?.name
    }

    public func record(_ sample: StreamMetricSample) {
        samples.append(sample)
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples * 9 / 10)
        }
    }

    public func closeTranscript(completion: (@Sendable () -> Void)? = nil) {
        if let writer = transcript {
            if let completion { writer.whenClosed(completion) }
            if !transcriptsBySource.values.contains(where: { $0 === writer }) { writer.finish() }
        } else {
            completion?()
        }
        transcript = nil
    }

    public func registerOutputSource(_ source: ObjectIdentifier) {
        if let transcript { transcriptsBySource[source] = transcript }
    }

    private func trimLog() {
        let bytes = log.utf8
        let cut = bytes.index(bytes.endIndex, offsetBy: -Self.retainedLogBytes)
        // Start on a line boundary rather than mid-line (or mid-character);
        // searching from the byte before `cut` keeps a line that starts there.
        let start = bytes[bytes.index(before: cut)...].firstIndex(of: UInt8(ascii: "\n"))
            .map(bytes.index(after:)) ?? cut
        log = String(log[start...])
    }
}
