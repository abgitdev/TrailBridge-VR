// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// The serial queue owns the file descriptor. MainActor only enqueues strings;
/// opening, redacting, UTF-8 encoding, writing, flushing and closing happen on
/// the queue.
final class ConsoleTranscript: @unchecked Sendable {
    /// Text waits at most this long before it is redacted and written, so a
    /// chatty process is redacted a few times a second, not once per chunk.
    static let redactionDelay: DispatchTimeInterval = .milliseconds(500)
    /// More waiting text than this is redacted and written at once.
    static let maximumPendingBytes = 256 * 1024

    private let queue = DispatchQueue(label: "org.trailbridge.frame-trace.console", qos: .utility)
    private var fd: Int32 = -1
    private var finished = false
    private var completions = [@Sendable () -> Void]()
    /// Applied to whole lines before they reach the file: the transcript can
    /// be attached to a report like the log Copy hands out.
    private let redact: (@Sendable (String) -> String)?
    private var pending = ""
    private var flushScheduled = false

    init(url: URL, redact: (@Sendable (String) -> String)? = nil) {
        self.redact = redact
        queue.async { [self] in
            fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    /// `text` ends at a line end, so a redacted batch never splits a line.
    func append(_ text: String) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            guard redact != nil else {
                write(text)
                return
            }
            pending += text
            if pending.utf8.count >= Self.maximumPendingBytes {
                flushPending()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + Self.redactionDelay) { [self] in
                    flushScheduled = false
                    flushPending()
                }
            }
        }
    }

    func finish(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            flushPending()
            if fd >= 0 { fsync(fd); close(fd); fd = -1 }
            finished = true
            completions.forEach { $0() }
            completions.removeAll()
            completion?()
        }
    }

    func whenClosed(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if finished { completion() }
            else { completions.append(completion) }
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let text = redact.map { $0(pending) } ?? pending
        pending = ""
        write(text)
    }

    private func write(_ text: String) {
        guard fd >= 0 else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { close(fd); fd = -1; return }
                offset += count
            }
        }
    }
}
