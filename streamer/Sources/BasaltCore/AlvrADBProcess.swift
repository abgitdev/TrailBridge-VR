import Foundation
import Darwin

/// A bounded subprocess reader for wired setup/recovery. In particular, do
/// not wait for pipe EOF: an adb server can inherit its client's output pipe.
enum AlvrADBProcess {
    static func run(_ process: Process, timeout: TimeInterval = 10) throws -> String {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        defer { try? reader.close() }
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw BasaltError("Cannot read adb command output")
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            // Bound each drain as well as the whole command (a noisy child
            // must not keep us inside read() beyond the deadline).
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                // Setup output is small. Drain excess without retaining it.
                if output.count < 1024 * 1024 {
                    output.append(contentsOf: buffer.prefix(min(count, 1024 * 1024 - output.count)))
                }
            }
            if !process.isRunning {
                process.waitUntilExit()
                // Drain the final bytes, without waiting for inherited writers.
                for _ in 0..<64 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    if output.count < 1024 * 1024 {
                        output.append(contentsOf: buffer.prefix(min(count, 1024 * 1024 - output.count)))
                    }
                }
                guard process.terminationStatus == 0 else {
                    throw BasaltError("adb command failed: "
                        + String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return String(decoding: output, as: UTF8.self)
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                process.terminate()
                // A child ignoring SIGTERM must not wedge Stop or reconnection.
                let grace = DispatchTime.now().uptimeNanoseconds + 200_000_000
                while process.isRunning, DispatchTime.now().uptimeNanoseconds < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw BasaltError(String(format: "adb command timed out after %.1f s", timeout))
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

/// Whether TrailBridge started the adb server that is running, so that it
/// alone is stopped when the app quits. adb says so itself: a command that
/// finds no server starts one and prints "daemon started successfully". A
/// server that was already running (Android Studio's, the user's own) never
/// produces that line here and is left alone.
public final class AlvrADBServerOwnership: @unchecked Sendable {
    public static let shared = AlvrADBServerOwnership()
    /// Printed by the streamer when one of its adb commands started the
    /// server; the management app reads it from the streamer's output.
    public static let startedLine = "adb: started the adb server"

    private let lock = NSLock()
    private var started = false

    public init() {}

    public static func announcesServerStart(_ output: String) -> Bool {
        output.contains("daemon started successfully")
    }

    /// Looks at the output of one adb command of this app.
    public func note(output: String) {
        guard Self.announcesServerStart(output) else { return }
        lock.lock()
        started = true
        lock.unlock()
    }

    /// Looks at one line of the streamer's output; true when the line says
    /// that the streamer started the server.
    @discardableResult
    public func note(streamerLine line: String) -> Bool {
        guard line.trimmingCharacters(in: .whitespacesAndNewlines) == Self.startedLine else {
            return false
        }
        lock.lock()
        started = true
        lock.unlock()
        return true
    }

    /// Whether a start was seen and the server not stopped since.
    public var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// True once after a start was seen: the caller then stops the server.
    public func takeStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = started
        started = false
        return value
    }
}

public enum AlvrADBServer {
    /// `adb kill-server`, bounded: quitting never waits on a stuck adb.
    public static func stop(adb: URL, environment: [String: String],
                            timeout: TimeInterval = 2) {
        let process = Process()
        process.executableURL = adb
        process.arguments = ["kill-server"]
        process.environment = environment
        _ = try? AlvrADBProcess.run(process, timeout: timeout)
    }
}
