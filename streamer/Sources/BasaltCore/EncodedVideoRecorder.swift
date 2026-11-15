// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Optional copy of the encoded stream, used to find single bad frames after a
/// session. The encoder thread only enqueues. When the backlog is full the
/// recording skips ahead to the next keyframe, so a skipped frame can never
/// show up later as decoder corruption that the headset did not see.
public final class EncodedVideoRecorder: @unchecked Sendable {
    public static let defaultMaximumBacklogBytes = 256 << 20
    public static let defaultMaximumFileBytes: Int64 = 20 << 30
    public static let defaultMinimumFreeBytes: Int64 = 20 << 30

    let queue = DispatchQueue(label: "org.trailbridge.encoded-video", qos: .utility)
    private let lock = NSLock()
    private let maximumBacklogBytes: Int
    private let maximumFileBytes: Int64
    private var backlogBytes = 0
    private var waitingForKeyframe = true
    private var closed = false
    private var acceptedFrames: UInt64 = 0
    private var skippedFrames: UInt64 = 0

    // Owned by `queue` after init.
    private var videoFD: Int32
    private var indexFD: Int32
    private var fileBytes: Int64 = 0

    public init(path: String,
                maximumBacklogBytes: Int = defaultMaximumBacklogBytes,
                maximumFileBytes: Int64 = defaultMaximumFileBytes,
                minimumFreeBytes: Int64 = defaultMinimumFreeBytes) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= minimumFreeBytes else {
            throw BasaltError("not enough free disk space for a video recording")
        }
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let video = open(path, flags, 0o600)
        guard video >= 0 else {
            throw BasaltError("cannot create video recording: \(String(cString: strerror(errno)))")
        }
        let index = open(path + ".index.csv", flags, 0o600)
        guard index >= 0 else {
            let reason = String(cString: strerror(errno))
            close(video)
            unlink(path)
            throw BasaltError("cannot create video recording index: \(reason)")
        }
        videoFD = video
        indexFD = index
        self.maximumBacklogBytes = maximumBacklogBytes
        self.maximumFileBytes = maximumFileBytes
        _ = writeAll(indexFD, Data((
            "# trailbridge_encoded_video_version=1\n"
            + "frame,utc_us,quest_timestamp_ns,offset,bytes,keyframe,skipped_before\n").utf8))
    }

    /// Never blocks on the disk; safe to call from the encoder callback.
    public func append(annexB: Data, isKeyframe: Bool, questTimestampNanoseconds: UInt64?) {
        lock.lock()
        if closed || (waitingForKeyframe && !isKeyframe) {
            if !closed { skippedFrames += 1 }
            lock.unlock()
            return
        }
        if backlogBytes + annexB.count > maximumBacklogBytes {
            waitingForKeyframe = true
            skippedFrames += 1
            lock.unlock()
            return
        }
        waitingForKeyframe = false
        backlogBytes += annexB.count
        let frame = acceptedFrames
        acceptedFrames += 1
        let skipped = skippedFrames
        lock.unlock()
        let utc = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        queue.async { [self] in
            write(annexB, frame: frame, utc: utc, quest: questTimestampNanoseconds ?? 0,
                  isKeyframe: isKeyframe, skipped: skipped)
        }
    }

    /// Writes everything already accepted and closes the files.
    public func finish() {
        queue.sync { closeFiles() }
    }

    private func write(_ data: Data, frame: UInt64, utc: UInt64, quest: UInt64,
                       isKeyframe: Bool, skipped: UInt64) {
        defer {
            lock.lock()
            backlogBytes -= data.count
            lock.unlock()
        }
        guard videoFD >= 0 else { return }
        guard fileBytes + Int64(data.count) <= maximumFileBytes else {
            fputs("video recording stopped: size limit reached\n", stderr)
            closeFiles()
            return
        }
        guard writeAll(videoFD, data) else {
            fputs("video recording stopped: \(String(cString: strerror(errno)))\n", stderr)
            closeFiles()
            return
        }
        let line = "\(frame),\(utc),\(quest),\(fileBytes),\(data.count),\(isKeyframe ? 1 : 0),\(skipped)\n"
        _ = writeAll(indexFD, Data(line.utf8))
        fileBytes += Int64(data.count)
    }

    private func closeFiles() {
        lock.lock()
        closed = true
        lock.unlock()
        if videoFD >= 0 { fsync(videoFD); close(videoFD); videoFD = -1 }
        if indexFD >= 0 { close(indexFD); indexFD = -1 }
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
    }
}
