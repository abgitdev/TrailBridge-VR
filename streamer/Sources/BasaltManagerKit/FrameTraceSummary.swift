// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// What limited a recorded session, from the runtime's frame CSV
/// (`runtime/pe/frame_trace.cpp`): how fast the game produced frames on the
/// Mac, how many frames came late, and what each late frame was waiting for.
///
/// Thresholds scale with the session's own frame time, taken as the median
/// interval between consecutive frames. At 72 Hz (13.9 ms) the cause
/// thresholds are the GPU taking 13.9 ms or the game or render thread 8 ms.
public struct FrameTraceSummary: Equatable, Sendable {
    public struct Causes: Equatable, Sendable {
        public var gpu = 0
        public var gameThread = 0
        public var renderThread = 0
        public var other = 0

        public init(gpu: Int = 0, gameThread: Int = 0, renderThread: Int = 0, other: Int = 0) {
            self.gpu = gpu
            self.gameThread = gameThread
            self.renderThread = renderThread
            self.other = other
        }
    }

    /// A frame is late at this many frame times, and very late at `veryLateFactor`.
    public static let lateFactor = 1.2
    public static let veryLateFactor = 1.9
    /// The GPU is the cause when its fence wait reaches this many frame times.
    public static let gpuFactor = 13.9 * 72 / 1000
    /// A thread is the cause when its part of the frame reaches this many frame times.
    public static let threadFactor = 8.0 * 72 / 1000

    /// Intervals between consecutive completed frames.
    public let intervals: Int
    /// First to last completed frame.
    public let duration: TimeInterval
    /// Frames the game completed per second on the Mac.
    public let framesPerSecond: Double
    /// The median interval, in microseconds.
    public let framePeriodMicroseconds: Double
    /// Share of intervals at or above `lateFactor` frame times, 0...1.
    public let lateShare: Double
    /// Share of intervals at or above `veryLateFactor` frame times, 0...1.
    public let veryLateShare: Double
    public let longestPauseMicroseconds: Int64
    /// Late frames by what they waited for; the counts add up to the late frames.
    public let lateCauses: Causes

    public var lateFrames: Int {
        lateCauses.gpu + lateCauses.gameThread + lateCauses.renderThread + lateCauses.other
    }

    /// Nil when the file is missing, is not a regular file, or holds no two
    /// consecutive completed frames.
    public static func load(_ url: URL) -> FrameTraceSummary? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.readToEnd() else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> FrameTraceSummary? {
        var frames = [Int64: Frame]()
        var gpuWaits = [Int64: Int64]()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            // A killed writer can leave a partial last line; only whole lines count.
            guard let end = bytes.lastIndex(of: newline) else { return }
            var columns: Columns?
            var start = 0
            while start <= end {
                var stop = start
                while bytes[stop] != newline { stop += 1 }
                let next = stop + 1
                if stop > start, bytes[stop - 1] == carriageReturn { stop -= 1 }
                let line = UnsafeRawBufferPointer(rebasing: bytes[start..<stop])
                start = next
                guard line.contains(where: { $0 != space && $0 != tab }), line[0] != hash else { continue }
                guard let columns else {
                    guard let header = Columns(header: line) else { return }
                    columns = header
                    continue
                }
                read(line, columns: columns, frames: &frames, gpuWaits: &gpuWaits)
            }
        }

        let ordered = frames.values.filter { $0.waitExit > 0 && $0.endExit > 0 }
            .sorted { ($0.waitExit, $0.number) < ($1.waitExit, $1.number) }
        var samples = [Sample]()
        samples.reserveCapacity(ordered.count)
        for (frame, next) in zip(ordered, ordered.dropFirst()) where next.number == frame.number + 1 {
            samples.append(Sample(
                interval: next.waitExit - frame.waitExit,
                gpu: max(gpuWaits[frame.number] ?? -1, gpuWaits[frame.number - 1] ?? -1),
                renderThread: frame.endEnter - frame.begin,
                gameThread: next.waitEnter - frame.endExit))
        }
        guard let first = ordered.first, let last = ordered.last, !samples.isEmpty,
              last.waitExit > first.waitExit else { return nil }

        let sorted = samples.map(\.interval).sorted()
        let middle = sorted.count / 2
        let period = sorted.count.isMultiple(of: 2)
            ? (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2 : Double(sorted[middle])
        var late = 0, veryLate = 0
        var causes = Causes()
        for sample in samples where Double(sample.interval) >= lateFactor * period {
            late += 1
            if Double(sample.interval) >= veryLateFactor * period { veryLate += 1 }
            if Double(sample.gpu) >= gpuFactor * period {
                causes.gpu += 1
            } else if Double(sample.gameThread) >= threadFactor * period {
                causes.gameThread += 1
            } else if Double(sample.renderThread) >= threadFactor * period {
                causes.renderThread += 1
            } else {
                causes.other += 1
            }
        }
        let seconds = Double(last.waitExit - first.waitExit) / 1_000_000
        return FrameTraceSummary(
            intervals: samples.count, duration: seconds,
            framesPerSecond: Double(samples.count) / seconds,
            framePeriodMicroseconds: period,
            lateShare: Double(late) / Double(samples.count),
            veryLateShare: Double(veryLate) / Double(samples.count),
            longestPauseMicroseconds: sorted[sorted.count - 1],
            lateCauses: causes)
    }

    private struct Frame {
        var number: Int64
        var waitEnter: Int64
        var waitExit: Int64
        var begin: Int64
        var endEnter: Int64
        var endExit: Int64
    }

    private struct Sample {
        var interval: Int64
        var gpu: Int64
        var renderThread: Int64
        var gameThread: Int64
    }

    /// Positions of the columns the summary reads, from the CSV's own header.
    private struct Columns {
        var count = 0
        var type = -1, text = -1, frame = -1
        var waitEnter = -1, waitExit = -1, begin = -1, endEnter = -1, endExit = -1, gpuFenceWait = -1

        init?(header: UnsafeRawBufferPointer) {
            for (index, name) in header.split(separator: comma, omittingEmptySubsequences: false).enumerated() {
                switch String(decoding: name, as: UTF8.self) {
                case "type": type = index
                case "text": text = index
                case "frame": frame = index
                case "wait_enter": waitEnter = index
                case "wait_exit": waitExit = index
                case "begin": begin = index
                case "end_enter": endEnter = index
                case "end_exit": endExit = index
                case "gpu_fence_wait": gpuFenceWait = index
                default: break
                }
                count = index + 1
            }
            guard [type, frame, waitEnter, waitExit, begin, endEnter, endExit, gpuFenceWait]
                .allSatisfy({ $0 >= 0 }) else { return nil }
        }
    }

    /// The largest frame number or microsecond timestamp a row may carry: 285
    /// years, the last value a `Double` holds exactly. The runtime writes
    /// neither a negative nor a larger one; a damaged or hand-made file can,
    /// and sums and differences of such values would overflow.
    private static let maximumValue: Int64 = 1 << 53

    /// One row. A row with a missing, extra or non-numeric field, or with a
    /// frame number or timestamp outside 0...`maximumValue`, is skipped
    /// whole. A later row for the same frame replaces the earlier one.
    private static func read(_ line: UnsafeRawBufferPointer, columns: Columns,
                             frames: inout [Int64: Frame], gpuWaits: inout [Int64: Int64]) {
        var frame = Frame(number: 0, waitEnter: 0, waitExit: 0, begin: 0, endEnter: 0, endExit: 0)
        var gpuFenceWait: Int64 = -1
        var isFrame = false, isLate = false
        var column = 0
        var fieldStart = 0
        for position in 0...line.count {
            guard position == line.count || line[position] == comma else { continue }
            let field = UnsafeRawBufferPointer(rebasing: line[fieldStart..<position])
            fieldStart = position + 1
            defer { column += 1 }
            if column == columns.type {
                isFrame = field.elementsEqual(frameType)
                isLate = field.elementsEqual(lateType)
                continue
            }
            if column == columns.text { continue }
            guard let value = integer(field) else { return }
            switch column {
            case columns.frame: frame.number = value
            case columns.waitEnter: frame.waitEnter = value
            case columns.waitExit: frame.waitExit = value
            case columns.begin: frame.begin = value
            case columns.endEnter: frame.endEnter = value
            case columns.endExit: frame.endExit = value
            case columns.gpuFenceWait: gpuFenceWait = value
            default: break
            }
        }
        guard column == columns.count, frame.number >= 0, frame.number <= maximumValue else { return }
        if isFrame {
            guard min(frame.waitEnter, frame.waitExit, frame.begin, frame.endEnter, frame.endExit) >= 0,
                  max(frame.waitEnter, frame.waitExit, frame.begin, frame.endEnter, frame.endExit)
                    <= maximumValue else { return }
            frames[frame.number] = frame
        } else if isLate, gpuFenceWait >= 0 {
            gpuWaits[frame.number] = gpuFenceWait
        }
    }

    private static func integer(_ field: UnsafeRawBufferPointer) -> Int64? {
        var index = 0
        var negative = false
        if let sign = field.first, sign == minus || sign == plus {
            negative = sign == minus
            index = 1
        }
        guard index < field.count else { return nil }
        var value: Int64 = 0
        while index < field.count {
            let byte = field[index]
            guard byte >= zero, byte <= zero + 9 else { return nil }
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
            let (sum, carried) = scaled.addingReportingOverflow(Int64(byte - zero))
            guard !overflowed, !carried else { return nil }
            value = sum
            index += 1
        }
        return negative ? -value : value
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let comma = UInt8(ascii: ",")
    private static let hash = UInt8(ascii: "#")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let minus = UInt8(ascii: "-")
    private static let plus = UInt8(ascii: "+")
    private static let zero = UInt8(ascii: "0")
    private static let frameType = Array("frame".utf8)
    private static let lateType = Array("late".utf8)
}

/// Remembers each CSV's summary until the file changes, so a long recording
/// is read once. Call it off the main thread.
public final class FrameTraceSummaryCache: @unchecked Sendable {
    private struct Entry {
        let bytes: Int64
        let modified: Date
        let summary: FrameTraceSummary?
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()

    public init() {}

    public func summary(for file: DiagnosticRecording.File) -> FrameTraceSummary? {
        let key = file.url.path
        if let entry = lock.withLock({ entries[key] }),
           entry.bytes == file.bytes, entry.modified == file.modified {
            return entry.summary
        }
        let summary = FrameTraceSummary.load(file.url)
        lock.withLock {
            entries[key] = Entry(bytes: file.bytes, modified: file.modified, summary: summary)
        }
        return summary
    }

    /// Forgets files that are no longer listed.
    public func keep(only files: [DiagnosticRecording.File]) {
        let paths = Set(files.map(\.url.path))
        lock.withLock { entries = entries.filter { paths.contains($0.key) } }
    }
}
