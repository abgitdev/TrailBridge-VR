import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

/// A process table of its own: nothing here looks at or signals a real
/// process, except the two `/bin/sh` helpers the last tests start themselves.
/// `isRunning(pid:…)` is the protocol's own: by pid and start time in `list`.
private final class FakeProcesses: BottleProcessAccess, @unchecked Sendable {
    struct Unreadable: Error {}
    var list: [BottleProcess]
    /// The signals that end a process.
    var fatal: Set<Int32> = [SIGTERM, SIGKILL]
    var unreadable = false
    private(set) var signals = [String]()
    private(set) var pauses = 0
    let currentPID: Int32 = 4000
    let currentUID: UInt32 = 501

    init(_ list: [BottleProcess]) { self.list = list }

    func processes() throws -> [BottleProcess] {
        if unreadable { throw Unreadable() }
        return list
    }

    func signal(_ signal: Int32, process: BottleProcess) -> Bool {
        // As the real one: the exact process, checked right before the signal.
        guard list.contains(process) else { return false }
        signals.append("\(signal == SIGTERM ? "TERM" : signal == SIGKILL ? "KILL" : "\(signal)") \(process.pid)")
        if fatal.contains(signal) { list.removeAll { $0 == process } }
        return true
    }

    func pause() { pauses += 1 }
}

private final class FakeAudioOutput: AudioOutputAccess, @unchecked Sendable {
    var current: String?
    private(set) var set = [String]()
    init(current: String?) { self.current = current }
    func defaultOutputUID() -> String? { current }
    func setDefaultOutput(uid: String) -> Bool {
        set.append(uid)
        current = uid
        return true
    }
}

final class SessionMarkerTests: XCTestCase {
    private func process(_ pid: Int32, _ executable: String, start: UInt64 = 1_000) -> BottleProcess {
        BottleProcess(pid: pid, uid: 501, realUID: 501, executable: executable,
                      startSeconds: start, startMicroseconds: 42)
    }
    private lazy var app = process(700, "/Applications/TrailBridge VR.app/Contents/MacOS/BasaltVR")
    private lazy var streamer = process(701, "/Applications/TrailBridge VR.app/Contents/Resources/basalt-streamer")
    private let route = SessionMarker.AudioRoute(
        previousOutputUID: "BuiltInSpeakerDevice", routedOutputUID: "BlackHole2ch_UID")

    private func marker(audio: SessionMarker.AudioRoute? = nil) -> SessionMarker {
        SessionMarker(app: .init(app), streamer: .init(streamer), bottles: ["steam-games"], audio: audio)
    }

    private func store(holding marker: SessionMarker?) throws -> SessionMarkerStore {
        let store = SessionMarkerStore(dataRoot: try temporaryDirectory())
        if let marker { try store.write(marker) }
        return store
    }

    func testTheMarkerIsOneFileInTheDataFolderAndReadsBackTheSame() throws {
        let root = try temporaryDirectory()
        let store = SessionMarkerStore(dataRoot: root)
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load())
        try store.write(marker(audio: route))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       ["ActiveSession.json"], "no temporary file stays beside it")
        XCTAssertEqual(store.load(), marker(audio: route))
        var changed = marker(audio: route)
        changed.streamer = nil
        try store.write(changed)
        XCTAssertEqual(store.load(), changed, "a second write replaces the first")
        store.remove()
        XCTAssertFalse(store.exists)
        store.remove()
    }

    func testProcessIdentityIsTakenFromTheProcessTable() {
        let processes = FakeProcesses([app, streamer])
        XCTAssertEqual(SessionMarker.ProcessIdentity.of(701, access: processes), .init(streamer))
        XCTAssertNil(SessionMarker.ProcessIdentity.of(999, access: processes))
        processes.unreadable = true
        XCTAssertNil(SessionMarker.ProcessIdentity.of(701, access: processes))
    }

    func testWithoutAMarkerThereIsNothingToDo() throws {
        let processes = FakeProcesses([streamer])
        let cleanup = LeftoverSession.cleanUp(in: try store(holding: nil), access: processes,
                                              audio: FakeAudioOutput(current: "BlackHole2ch_UID")) { _, _ in
            XCTFail("no Wine to stop")
        }
        XCTAssertNil(cleanup)
        XCTAssertEqual(processes.signals, [])
    }

    func testAMarkerWhoseAppStillRunsIsLeftAlone() throws {
        let store = try store(holding: marker(audio: route))
        let processes = FakeProcesses([app, streamer])
        let audio = FakeAudioOutput(current: "BlackHole2ch_UID")
        let cleanup = LeftoverSession.cleanUp(in: store, access: processes, audio: audio) { _, _ in
            XCTFail("that session is running")
        }
        XCTAssertNil(cleanup)
        XCTAssertEqual(processes.signals, [])
        XCTAssertEqual(audio.set, [])
        XCTAssertEqual(store.load(), marker(audio: route), "the marker stays")
    }

    func testASessionWhoseAppIsGoneIsStoppedAndItsMarkerRemoved() throws {
        let store = try store(holding: marker())
        let processes = FakeProcesses([streamer, process(900, "/usr/bin/other")])
        var stopped = [String]()
        let cleanup = LeftoverSession.cleanUp(in: store, access: processes,
                                              audio: FakeAudioOutput(current: "BuiltInSpeakerDevice")) { bottle, _ in
            stopped.append(bottle)
        }
        XCTAssertEqual(cleanup, .init(stoppedStreamer: true, bottles: ["steam-games"], restoredOutput: false))
        XCTAssertEqual(processes.signals, ["TERM 701"], "asked to stop, and it did")
        XCTAssertEqual(stopped, ["steam-games"])
        XCTAssertFalse(store.exists)
    }

    func testAnotherProcessThatGotTheAppsPidDoesNotCountAsTheApp() throws {
        let store = try store(holding: marker())
        let processes = FakeProcesses([process(700, "/usr/bin/other", start: 2_000)])
        var stopped = [String]()
        XCTAssertNotNil(LeftoverSession.cleanUp(in: store, access: processes,
                                                audio: FakeAudioOutput(current: nil)) { bottle, _ in stopped.append(bottle) })
        XCTAssertEqual(stopped, ["steam-games"])
        XCTAssertEqual(processes.signals, [])
        XCTAssertFalse(store.exists)
    }

    func testAProcessThatOnlySharesTheStreamersPidIsNotSignalled() throws {
        let store = try store(holding: marker())
        // Same pid: once started later, once another program started at that time.
        for stranger in [process(701, streamer.executable, start: 2_000),
                         process(701, "/usr/bin/other")] {
            try store.write(marker())
            let processes = FakeProcesses([stranger])
            let cleanup = LeftoverSession.cleanUp(in: store, access: processes,
                                                  audio: FakeAudioOutput(current: nil)) { _, _ in }
            XCTAssertEqual(cleanup?.stoppedStreamer, false)
            XCTAssertEqual(processes.signals, [])
            XCTAssertEqual(processes.list, [stranger])
            XCTAssertFalse(store.exists)
        }
    }

    func testAStreamerThatDoesNotStopIsKilledAfterItsGrace() throws {
        let store = try store(holding: marker())
        let processes = FakeProcesses([streamer])
        processes.fatal = [SIGKILL]
        let cleanup = LeftoverSession.cleanUp(in: store, access: processes,
                                              audio: FakeAudioOutput(current: nil)) { _, _ in }
        XCTAssertEqual(cleanup?.stoppedStreamer, true)
        XCTAssertEqual(processes.signals, ["TERM 701", "KILL 701"])
        XCTAssertEqual(processes.pauses, 30, "about three seconds for its own teardown")
    }

    func testAudioOutputGoesBackOnlyWhileItIsStillTheLoopbackDevice() throws {
        XCTAssertEqual(LeftoverSession.outputToRestore(route, currentOutputUID: "BlackHole2ch_UID"),
                       "BuiltInSpeakerDevice")
        XCTAssertNil(LeftoverSession.outputToRestore(route, currentOutputUID: "BuiltInSpeakerDevice"),
                     "the streamer has put it back itself")
        XCTAssertNil(LeftoverSession.outputToRestore(route, currentOutputUID: "USB-Headphones"),
                     "a choice the user made since then stays")
        XCTAssertNil(LeftoverSession.outputToRestore(route, currentOutputUID: nil))
        XCTAssertNil(LeftoverSession.outputToRestore(nil, currentOutputUID: "BlackHole2ch_UID"),
                     "a session that did not route audio restores nothing")

        for (current, expected) in [("BlackHole2ch_UID", ["BuiltInSpeakerDevice"]),
                                    ("USB-Headphones", [])] {
            let store = try store(holding: marker(audio: route))
            let audio = FakeAudioOutput(current: current)
            let cleanup = LeftoverSession.cleanUp(in: store, access: FakeProcesses([]), audio: audio) { _, _ in }
            XCTAssertEqual(audio.set, expected)
            XCTAssertEqual(cleanup?.restoredOutput, !expected.isEmpty)
        }
    }

    func testAudioRouteIsRecordedOnlyForARealSwitch() {
        XCTAssertNotNil(route)
        XCTAssertNil(SessionMarker.AudioRoute(previousOutputUID: "BlackHole2ch_UID",
                                              routedOutputUID: "BlackHole2ch_UID"),
                     "the output already was the loopback device")
        XCTAssertNil(SessionMarker.AudioRoute(previousOutputUID: nil, routedOutputUID: "BlackHole2ch_UID"))
        XCTAssertNil(SessionMarker.AudioRoute(previousOutputUID: "BuiltInSpeakerDevice", routedOutputUID: nil))
        var settings = StreamLaunchSettings()
        settings.gameAudioChoice = .mac
        XCTAssertNil(SessionMarker.AudioRoute.expected(for: settings), "the Mac's own audio changes nothing")
        settings.gameAudioChoice = .off
        XCTAssertNil(SessionMarker.AudioRoute.expected(for: settings))
    }

    // MARK: - The app that wrote the marker

    func testAnAppWhoseExecutableMovedStillCountsAsRunning() throws {
        let store = try store(holding: marker(audio: route))
        // Its folder was renamed while it runs: same pid, same start time.
        let processes = FakeProcesses([process(700, "/Volumes/Renamed/TrailBridge VR.app/Contents/MacOS/BasaltVR"),
                                       streamer])
        let audio = FakeAudioOutput(current: "BlackHole2ch_UID")
        XCTAssertNil(LeftoverSession.cleanUp(in: store, access: processes, audio: audio,
                                             stopADBServer: { XCTFail("that session is running") }) { _, _ in
            XCTFail("that session is running")
        })
        XCTAssertEqual(processes.signals, [])
        XCTAssertEqual(audio.set, [])
        XCTAssertEqual(store.load(), marker(audio: route), "the marker stays")
    }

    // MARK: - Wine that could not be stopped

    private struct Failure: Error {}

    func testWineThatCannotBeStoppedKeepsTheMarkerForTheNextStart() throws {
        var left = marker(audio: route)
        left.bottles = ["blood-trail", "steam-games"]
        left.adbServerStarted = true
        let store = try store(holding: left)
        let audio = FakeAudioOutput(current: "BlackHole2ch_UID")
        var adbStops = 0
        let first = LeftoverSession.cleanUp(in: store, access: FakeProcesses([streamer]), audio: audio,
                                            stopADBServer: { adbStops += 1 }) { bottle, _ in
            if bottle == "blood-trail" { throw Failure() }
        }
        XCTAssertEqual(first, .init(stoppedStreamer: true, bottles: ["steam-games"], restoredOutput: true,
                                    stoppedADBServer: true, unfinished: ["blood-trail"]))
        XCTAssertEqual(store.load(), SessionMarker(app: .init(app), bottles: ["blood-trail"]),
                       "only what is left to do stays noted")

        var stopped = [String]()
        let second = LeftoverSession.cleanUp(in: store, access: FakeProcesses([]), audio: audio,
                                             stopADBServer: { adbStops += 1 }) { bottle, _ in
            stopped.append(bottle)
        }
        XCTAssertEqual(second, .init(bottles: ["blood-trail"]))
        XCTAssertEqual(stopped, ["blood-trail"])
        XCTAssertEqual(adbStops, 1, "the adb server is not stopped a second time")
        XCTAssertEqual(audio.set, ["BuiltInSpeakerDevice"])
        XCTAssertFalse(store.exists)
    }

    func testAnEnvironmentDeletedSinceThenDoesNotKeepTheMarker() throws {
        var gone = marker()
        gone.bottles = ["deleted", "steam-games"]
        let store = try store(holding: gone)
        var asked = [String]()
        let cleanup = LeftoverSession.cleanUp(in: store, access: FakeProcesses([]),
                                              audio: FakeAudioOutput(current: nil),
                                              bottleExists: { $0 != "deleted" }) { bottle, _ in
            asked.append(bottle)
        }
        XCTAssertEqual(asked, ["steam-games"], "nothing is run for an environment that is gone")
        XCTAssertEqual(cleanup?.bottles, ["steam-games"])
        XCTAssertEqual(cleanup?.unfinished, [])
        XCTAssertFalse(store.exists)
    }

    func testAStoppedSessionRemovesItsMarkerAndAFailedStopKeepsIt() throws {
        let store = try store(holding: marker(audio: route))
        store.end(marker(audio: route), stopped: false)
        XCTAssertEqual(store.load(), marker(audio: route), "Wine may still run there")
        store.end(marker(audio: route), stopped: true)
        XCTAssertFalse(store.exists)
    }

    func testEnvironmentsKeptFromAnEarlierFailedStopOutliveTheNextSession() throws {
        var kept = marker(audio: route)
        kept.bottles = ["blood-trail"]
        // The next Play, in another environment and in the same one.
        let next = SessionMarker(app: .init(app), startingIn: "steam-games", audio: nil,
                                 adbServerStarted: true, keeping: kept)
        XCTAssertEqual(next, SessionMarker(app: .init(app), bottles: ["steam-games", "blood-trail"],
                                           adbServerStarted: true))
        XCTAssertEqual(SessionMarker(app: .init(app), startingIn: "blood-trail", audio: nil,
                                     adbServerStarted: false, keeping: kept).bottles, ["blood-trail"],
                       "Play has just stopped Wine there itself")
        XCTAssertEqual(SessionMarker(app: .init(app), startingIn: "steam-games", audio: route,
                                     adbServerStarted: false, keeping: nil),
                       SessionMarker(app: .init(app), bottles: ["steam-games"], audio: route))

        let store = try store(holding: next)
        store.end(next, stopped: true)
        XCTAssertEqual(store.load(), SessionMarker(app: .init(app), bottles: ["blood-trail"],
                                                   adbServerStarted: true),
                       "the session's own environment is done, the other is not")
    }

    // MARK: - The adb server of a session that crashed

    func testAnADBServerTheMarkerSaysWasStartedIsStoppedAfterTheStreamer() throws {
        var left = marker()
        left.adbServerStarted = true
        let store = try store(holding: left)
        XCTAssertEqual(store.load(), left, "the marker records it")
        let processes = FakeProcesses([streamer])
        var streamerGoneAtStop: Bool?
        let cleanup = LeftoverSession.cleanUp(in: store, access: processes,
                                              audio: FakeAudioOutput(current: nil),
                                              stopADBServer: {
            XCTAssertNil(streamerGoneAtStop, "asked once")
            streamerGoneAtStop = processes.list.isEmpty
        }) { _, _ in }
        XCTAssertEqual(streamerGoneAtStop, true, "the streamer still removes its adb forwards first")
        XCTAssertEqual(cleanup?.stoppedADBServer, true)
        XCTAssertFalse(store.exists)
    }

    func testAnADBServerTheMarkerDoesNotClaimIsNeverStopped() throws {
        let store = try store(holding: marker())
        let cleanup = LeftoverSession.cleanUp(in: store, access: FakeProcesses([streamer]),
                                              audio: FakeAudioOutput(current: nil),
                                              stopADBServer: {
            XCTFail("someone else's adb server must not be stopped")
        }) { _, _ in }
        XCTAssertEqual(cleanup?.stoppedADBServer, false)

        // A marker from before this was recorded claims nothing either.
        try Data(#"{"app":{"pid":700,"startSeconds":1000,"startMicroseconds":42,"executable":"/a"},"bottles":["steam-games"]}"#.utf8)
            .write(to: store.file)
        XCTAssertEqual(store.load()?.adbServerStarted, false)
        XCTAssertEqual(store.load()?.bottles, ["steam-games"])
    }

    // MARK: - The bound on the whole cleanup

    func testCleanupGivesUpAtItsBoundAndKeepsTheMarkerForWhatIsLeft() throws {
        var left = marker(audio: route)
        left.bottles = ["blood-trail", "hung", "steam-games"]
        let store = try store(holding: left)
        let audio = FakeAudioOutput(current: "BlackHole2ch_UID")
        var clock: TimeInterval = 1_000
        var allowed = [String]()
        let cleanup = LeftoverSession.cleanUp(
            in: store, access: FakeProcesses([]), audio: audio, bound: 15, uptime: { clock }
        ) { bottle, timeout in
            allowed.append("\(bottle) \(Int(timeout))")
            if bottle == "hung" {
                // As the bounded runner: gives up when its time is over.
                clock += timeout
                throw Failure()
            }
            clock += 4
        }
        XCTAssertEqual(allowed, ["blood-trail 15", "hung 11"],
                       "each stop gets the time that is left, and none is started without any")
        XCTAssertEqual(clock, 1_015, "the whole cleanup took its bound, not longer")
        XCTAssertEqual(cleanup, .init(bottles: ["blood-trail"], restoredOutput: true,
                                      unfinished: ["hung", "steam-games"]))
        XCTAssertEqual(store.load(), SessionMarker(app: .init(app), bottles: ["hung", "steam-games"]),
                       "the next start tries again")
    }

    func testAMarkerThatCannotBeReadIsRemovedAndNothingIsTouched() throws {
        let store = try store(holding: nil)
        try Data("{ not a marker".utf8).write(to: store.file)
        let processes = FakeProcesses([streamer])
        XCTAssertNil(LeftoverSession.cleanUp(in: store, access: processes,
                                             audio: FakeAudioOutput(current: nil)) { _, _ in
            XCTFail("nothing is known about that session")
        })
        XCTAssertEqual(processes.signals, [])
        XCTAssertFalse(store.exists)
    }

    /// The file is intact and only cannot be read at this moment (no
    /// permission here; a read error on a share): the session it describes
    /// is still to be cleaned up, at a later start.
    func testAMarkerThatCannotBeReadRightNowIsKeptForTheNextStart() throws {
        let store = try store(holding: marker())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.file.path)
        XCTAssertEqual(store.read(), .unreadable)
        let processes = FakeProcesses([streamer])
        XCTAssertNil(LeftoverSession.cleanUp(in: store, access: processes,
                                             audio: FakeAudioOutput(current: nil)) { _, _ in
            XCTFail("nothing is known about that session yet")
        })
        XCTAssertEqual(processes.signals, [])
        XCTAssertTrue(store.exists, "kept")

        // Readable again at the next start: now the session is stopped.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
        XCTAssertEqual(store.read(), .marker(marker()))
        var stopped = [String]()
        XCTAssertNotNil(LeftoverSession.cleanUp(in: store, access: processes,
                                                audio: FakeAudioOutput(current: nil)) { bottle, _ in
            stopped.append(bottle)
        })
        XCTAssertEqual(stopped, ["steam-games"])
        XCTAssertFalse(store.exists)
    }

    func testAFolderAtTheMarkersPathIsNotRemoved() throws {
        let store = try store(holding: nil)
        let own = store.file.appendingPathComponent("keep-me.txt")
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: true)
        try Data("the person's own file".utf8).write(to: own)
        XCTAssertEqual(store.read(), .unreadable)
        XCTAssertNil(LeftoverSession.cleanUp(in: store, access: FakeProcesses([]),
                                             audio: FakeAudioOutput(current: nil)) { _, _ in XCTFail() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    func testTheMarkersFileIsReadAsOneOfFourThings() throws {
        let store = try store(holding: nil)
        XCTAssertEqual(store.read(), .absent)
        XCTAssertNil(store.load())
        try Data("{ not a marker".utf8).write(to: store.file)
        XCTAssertEqual(store.read(), .damaged)
        XCTAssertNil(store.load())
        try store.write(marker(audio: route))
        XCTAssertEqual(store.read(), .marker(marker(audio: route)))
        XCTAssertEqual(store.load(), marker(audio: route))
    }

    func testWithoutTheProcessListNothingIsTouched() throws {
        let store = try store(holding: marker(audio: route))
        let processes = FakeProcesses([streamer])
        processes.unreadable = true
        let audio = FakeAudioOutput(current: "BlackHole2ch_UID")
        XCTAssertNil(LeftoverSession.cleanUp(in: store, access: processes, audio: audio) { _, _ in
            XCTFail("the app that wrote the marker may still be running")
        })
        XCTAssertEqual(audio.set, [])
        XCTAssertTrue(store.exists, "the next start looks again")
    }

    // MARK: - Waiting for the streamer on quit

    func testTheWaitEndsAsSoonAsTheStreamerIsGone() {
        var checks = 0
        var slept: TimeInterval = 0
        let done = SessionTeardown.wait(upTo: 3, interval: 0.5, sleep: { slept += $0 }) {
            checks += 1
            return checks == 3
        }
        XCTAssertTrue(done)
        XCTAssertEqual(slept, 1.0, accuracy: 0.001)
    }

    func testTheWaitNeverLastsLongerThanItsBound() {
        var slept: TimeInterval = 0
        XCTAssertFalse(SessionTeardown.wait(upTo: 3, interval: 0.5, sleep: { slept += $0 }) { false })
        XCTAssertEqual(slept, 3.0, accuracy: 0.001)
        XCTAssertTrue(SessionTeardown.wait(upTo: 0, sleep: { _ in XCTFail("nothing to wait for") }) { true })
    }

    private func shell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Let the shell install its trap.
        Thread.sleep(forTimeInterval: 0.3)
        return process
    }

    /// Quitting blocks the main thread, as this test does: a child that
    /// finishes its teardown is seen without the run loop turning.
    func testAChildFinishingItsTeardownIsSeenFromTheBlockedMainThread() throws {
        XCTAssertTrue(Thread.isMainThread)
        let child = try shell("trap 'sleep 0.3; exit 0' TERM; while :; do sleep 0.05; done")
        child.terminate()
        XCTAssertTrue(child.isRunning, "still tearing down")
        let start = Date()
        XCTAssertTrue(SessionTeardown.wait(upTo: 3) { !child.isRunning })
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAChildThatDoesNotStopHoldsTheQuitOnlyForTheBound() throws {
        let child = try shell("trap '' TERM; while :; do sleep 0.05; done")
        child.terminate()
        let start = Date()
        XCTAssertFalse(SessionTeardown.wait(upTo: 0.3) { !child.isRunning })
        // The bound counts its own steps; on a busy machine each step can
        // last longer than planned. What matters is that the wait ends.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
