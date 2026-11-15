import Foundation
import Darwin

/// A process identity includes its start time so a reused PID is not targeted.
public struct BottleProcess: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let realUID: UInt32
    public let executable: String
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, uid: UInt32, realUID: UInt32, executable: String,
                startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.uid = uid; self.realUID = realUID
        self.executable = executable
        self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}

public protocol BottleProcessAccess: Sendable {
    var currentPID: Int32 { get }
    var currentUID: UInt32 { get }
    func processes() throws -> [BottleProcess]
    func signal(_ signal: Int32, process: BottleProcess) -> Bool
    func pause()
    func ioBytes(of process: BottleProcess) -> UInt64?
    /// Whether the process that had this pid and start time still runs. The
    /// two together are never given to another process, so its executable
    /// is not looked at.
    func isRunning(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) throws -> Bool
}

extension BottleProcessAccess {
    public func ioBytes(of process: BottleProcess) -> UInt64? { nil }

    public func isRunning(pid: Int32, startSeconds: UInt64,
                          startMicroseconds: UInt64) throws -> Bool {
        try processes().contains {
            $0.pid == pid && $0.startSeconds == startSeconds
                && $0.startMicroseconds == startMicroseconds
        }
    }
}

public struct SystemBottleProcessAccess: BottleProcessAccess {
    public init() {}
    public var currentPID: Int32 { getpid() }
    public var currentUID: UInt32 { getuid() }

    private func inspect(_ pid: Int32) -> BottleProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == currentUID, info.pbi_ruid == currentUID else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return BottleProcess(pid: pid, uid: info.pbi_uid, realUID: info.pbi_ruid,
                             executable: String(cString: path),
                             startSeconds: info.pbi_start_tvsec,
                             startMicroseconds: info.pbi_start_tvusec)
    }

    public func processes() throws -> [BottleProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw BottleToolError("Could not list processes") }
        // Retry if the process table grew while we were reading it.
        var capacity = Int(count) + 128
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let found = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard found >= 0 else { throw BottleToolError("Could not list processes") }
            if Int(found) < capacity {
                return pids.prefix(Int(found)).filter { $0 > 0 }.compactMap(inspect)
            }
            capacity *= 2
        }
    }

    public func signal(_ signal: Int32, process: BottleProcess) -> Bool {
        // Recheck owner, image and start time immediately before every signal.
        guard process.pid != currentPID, inspect(process.pid) == process else { return false }
        return kill(process.pid, signal) == 0
    }

    public func ioBytes(of process: BottleProcess) -> UInt64? {
        guard inspect(process.pid) == process else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        return info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten &+ info.ri_logical_writes
    }

    public func pause() { Thread.sleep(forTimeInterval: 0.1) }

    /// Asked of the system directly: `processes()` leaves out a process
    /// whose executable path cannot be read.
    public func isRunning(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_status != UInt32(SZOMB)
            && info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds
    }
}

public struct WineProcessesSurvived: Error, LocalizedError, Equatable {
    public let count: Int

    public init(count: Int) { self.count = count }
    public var errorDescription: String? { "Could not remove \(count) leftover Wine processes" }
}

struct BottleProcessSweep {
    let access: any BottleProcessAccess

    /// How many processes of this user run from `engine` now; it signals
    /// nothing. Wine keeps the wineserver and its services alive across
    /// every handoff between Steam's updater generations, so zero means
    /// that nothing of the bottle is left to finish an update.
    func count(engine: URL) throws -> Int {
        try countedProcesses(engine: engine).count
    }

    func ioActivity(engine: URL) throws -> UInt64 {
        try countedProcesses(engine: engine).reduce(UInt64(0)) {
            $0 &+ (access.ioBytes(of: $1) ?? 0)
        }
    }

    private func countedProcesses(engine: URL) throws -> [BottleProcess] {
        let prefix = engine.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try access.processes().filter {
            $0.pid > 0 && $0.pid != access.currentPID && $0.uid == access.currentUID &&
            $0.realUID == access.currentUID &&
            // Asked once a second: resolve links only for a likely path.
            $0.executable.contains("/engine/") &&
            URL(fileURLWithPath: $0.executable).resolvingSymlinksInPath()
                .standardizedFileURL.path.hasPrefix(prefix)
        }
    }

    func remove(engine: URL) throws -> Int {
        let prefix = engine.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let targets = try access.processes().filter {
            $0.pid > 0 && $0.pid != access.currentPID && $0.uid == access.currentUID &&
            $0.realUID == access.currentUID &&
            URL(fileURLWithPath: $0.executable).resolvingSymlinksInPath()
                .standardizedFileURL.path.hasPrefix(prefix)
        }
        guard !targets.isEmpty else { return 0 }
        for process in targets { _ = access.signal(SIGTERM, process: process) }
        var survivors = targets
        for _ in 0..<15 {
            access.pause()
            let running = try access.processes()
            survivors = survivors.filter { running.contains($0) }
            if survivors.isEmpty { break }
        }
        for process in survivors { _ = access.signal(SIGKILL, process: process) }
        if !survivors.isEmpty {
            for _ in 0..<30 {
                access.pause()
                let running = try access.processes()
                survivors = survivors.filter { running.contains($0) }
                if survivors.isEmpty { break }
            }
        }
        guard survivors.isEmpty else {
            throw WineProcessesSurvived(count: survivors.count)
        }
        return targets.count
    }
}
