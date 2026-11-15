// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Where diagnostic recordings live: `<data root>/Diagnostics`, beside the
/// bottles and profiles. The data root is writable in every layout; the
/// repository root is a read-only support folder inside a packaged app.
public enum DiagnosticsStorage {
    public static let folderName = "Diagnostics"

    public static func directory(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Opens the folder for the caller to close, or returns -1. The data root
    /// may be reached through symbolic links (a folder under `/tmp`, a home
    /// folder that is a link, `~/Games` pointing at a disk): they are
    /// resolved once. From the resolved root the walk goes from `/` with
    /// directory FDs, so neither a link inside the data folder (a
    /// `Diagnostics` that points out of it) nor a concurrent path
    /// replacement is followed. `create` makes only the folder itself,
    /// private to the user; the data root must already exist.
    public static func open(dataRoot: URL, create: Bool) -> Int32 {
        guard let resolved = realpath(dataRoot.standardizedFileURL.path, nil) else { return -1 }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        let components = root.pathComponents.dropFirst() + [folderName]
        for (index, component) in components.enumerated() {
            let isFolder = index == components.count - 1
            if create && isFolder && mkdirat(fd, component, 0o700) != 0 && errno != EEXIST {
                close(fd)
                return -1
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        if create && fchmod(fd, 0o700) != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Free bytes on the volume holding the data root; nil when unknown.
    public static func freeBytes(dataRoot: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: dataRoot.standardizedFileURL.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

/// One launch's diagnostic files under `<data root>/Diagnostics/`, named
/// `<UTC time>-<profile>`. Two independent choices select them: the runtime's
/// frame CSV with the app's console transcript, and the streamer's encoded
/// video, which can grow to many gigabytes. Each is on when the app's own
/// per-game setting asks for it or the profile carries the literal developer
/// opt-in (`BASALT_FRAME_TRACE=1`, `BASALT_RECORD_VIDEO=1`).
public struct FrameTraceSession: Equatable, Sendable {
    /// Names the session. The file exists only when `tracesFrames` is set.
    public let csv: URL
    /// The runtime writes `csv`, the app writes `console`.
    public let tracesFrames: Bool
    /// The streamer writes `video(codecExtension:)` and creates it itself.
    public let recordsVideo: Bool
    public var console: URL { csv.deletingPathExtension().appendingPathExtension("console.log") }
    /// Raw encoded stream, named after its codec so tools can read it directly.
    public func video(codecExtension: String) -> URL {
        csv.deletingPathExtension().appendingPathExtension(codecExtension)
    }
    /// The console transcript to write, nil when only video is recorded.
    public var transcript: URL? { tracesFrames ? console : nil }
    /// The path for `--record-video`, nil when only frames are traced.
    public func recording(codecExtension: String) -> URL? {
        recordsVideo ? video(codecExtension: codecExtension) : nil
    }

    /// `tracesFrames` and `recordsVideo` are the app's settings; the profile's
    /// literal opt-ins turn the same recordings on. `videoAllowed` withholds
    /// the video for this launch whichever source asked for it. Both variables
    /// are always removed, and the game only ever gets the CSV path. A
    /// diagnostic setup failure leaves the launch untraced and unrecorded.
    public static func rewrite(environment: inout [String: String], dataRoot: URL,
                               prefix: URL, profile: String,
                               tracesFrames: Bool = false, recordsVideo: Bool = false,
                               videoAllowed: Bool = true, now: Date = Date()) -> Self? {
        let profileTraces = environment.removeValue(forKey: "BASALT_FRAME_TRACE") == "1"
        let profileRecords = environment.removeValue(forKey: "BASALT_RECORD_VIDEO") == "1"
        let traces = profileTraces || tracesFrames
        let records = (profileRecords || recordsVideo) && videoAllowed
        guard traces || records else { return nil }
        guard (try? BottleName.validate(profile, kind: "profile name")) != nil else { return nil }
        let fd = DiagnosticsStorage.open(dataRoot: dataRoot, create: true)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        // O_EXCL protects even two launches within the clock's resolution.
        for attempt in 0..<100 {
            let micros = Int64((now.timeIntervalSince1970 * 1_000_000).rounded()) + Int64(attempt)
            let seconds = Date(timeIntervalSince1970: Double(micros / 1_000_000))
            let stamp = formatter.string(from: seconds) + String(format: ".%06lldZ", micros % 1_000_000)
            let stem = "\(stamp)-\(profile)"
            let csvName = stem + ".csv", consoleName = stem + ".console.log"
            if traces {
                let csvFD = openat(fd, csvName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if csvFD < 0 { if errno == EEXIST { continue }; return nil }
                close(csvFD)
                let consoleFD = openat(fd, consoleName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard consoleFD >= 0 else { unlinkat(fd, csvName, 0); return nil }
                close(consoleFD)
            } else if isTaken(csvName, in: fd) || isTaken(consoleName, in: fd) {
                // A recording alone creates no file here: the streamer opens
                // its own with O_EXCL. Never share another launch's name.
                continue
            }
            let csv = DiagnosticsStorage.directory(dataRoot: dataRoot).appendingPathComponent(csvName)
            if traces {
                environment["BASALT_FRAME_TRACE"] = BottleManager.winePath(for: csv, prefix: prefix)
            }
            return Self(csv: csv, tracesFrames: traces, recordsVideo: records)
        }
        return nil
    }

    /// Any entry, including a dangling symlink, or an unreadable directory.
    private static func isTaken(_ name: String, in directory: Int32) -> Bool {
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    }
}
