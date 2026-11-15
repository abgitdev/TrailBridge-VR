import Foundation
import Darwin

/// Tells the streamer that a process it depends on, normally the app that
/// started it, has exited. A crashed or force-quit app cannot send SIGTERM,
/// so without this the streamer would run on with the Mac's audio output and
/// the adb forwards still changed. Fires at most once.
public final class ProcessExitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var source: DispatchSourceProcess?
    private let onExit: @Sendable () -> Void

    /// `isGone` is asked once after the watch is armed: a process that exited
    /// before that may never produce an event.
    public init(pid: pid_t, isGone: @escaping @Sendable () -> Bool,
                queue: DispatchQueue = .global(),
                onExit: @escaping @Sendable () -> Void) {
        self.onExit = onExit
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
        lock.lock()
        self.source = source
        lock.unlock()
        if isGone() { fire() }
    }

    /// Watches the process that started this one. Nil when there is nothing
    /// to watch: launchd is already the parent.
    public static func parent(onExit: @escaping @Sendable () -> Void) -> ProcessExitWatch? {
        let parent = getppid()
        guard parent > 1 else { return nil }
        // An orphan is handed to launchd, so its parent pid changes.
        return ProcessExitWatch(pid: parent, isGone: { getppid() != parent }, onExit: onExit)
    }

    private func fire() {
        lock.lock()
        let first = !fired
        fired = true
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
        if first { onExit() }
    }

    deinit { source?.cancel() }
}
