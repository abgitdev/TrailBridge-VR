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
    private var deviceErrorCounts = [ObjectIdentifier?: Int]()
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
        deviceErrorCounts.removeAll()
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

    /// Logs and returns the unfinished line `source` left when it closed.
    public func finish(_ source: ObjectIdentifier?, prefix: String = "") -> [String] {
        defer {
            if let source, let writer = transcriptsBySource.removeValue(forKey: source),
               writer !== transcript, !transcriptsBySource.values.contains(where: { $0 === writer }) {
                writer.finish()
            }
        }
        let lines = partialLines.removeValue(forKey: source).map { [$0] } ?? []
        let completed = commit(lines, from: source, prefix: prefix)
        if let count = deviceErrorCounts.removeValue(forKey: source), count > 1 {
            return completed + commit(
                ["err:   Device error: suppressed \(count - 1) repeated command buffer failures (total)"],
                from: source, prefix: prefix)
        }
        return completed
    }

    private func commit(_ lines: [String], from source: ObjectIdentifier?, prefix: String) -> [String] {
        guard !lines.isEmpty else { return [] }
        // Persist before the live console's flood suppression and tail trim.
        // Every source line, including repeated GPU errors, reaches disk.
        if let writer = source.flatMap({ transcriptsBySource[$0] }) ?? transcript {
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
        // A lost Metal device can reject every subsequent command buffer. Keep
        // the first full error and logarithmically spaced counts so that this
        // flood cannot evict the compiler errors that preceded it. Match only
        // DXMT's raw error line, after assembling chunks and before prefixing.
        let prefixed = lines.compactMap { line -> String? in
            guard line.hasPrefix("err:   Device error at frame ") else { return prefix + line }
            let count = deviceErrorCounts[source, default: 0] + 1
            deviceErrorCounts[source] = count
            if count == 1 { return prefix + line }
            let repeats = count - 1
            guard repeats & (repeats - 1) == 0 else { return nil }
            return prefix + "err:   Device error: suppressed \(repeats) repeated command buffer failures"
        }
        guard !prefixed.isEmpty else { return [] }
        log += prefixed.map { $0 + "\n" }.joined()
        if log.utf8.count > Self.maximumLogBytes { trimLog() }
        return prefixed
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
