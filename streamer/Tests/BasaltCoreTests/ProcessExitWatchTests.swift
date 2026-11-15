import XCTest
import BasaltCore

/// The helper processes here are `/bin/sleep`, started and ended by the test.
final class ProcessExitWatchTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func helper(seconds: String = "30") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        return process
    }

    func testFiresOnceWhenTheWatchedProcessDies() throws {
        let process = try helper()
        let fired = Counter()
        let seen = expectation(description: "the exit is seen")
        let watch = ProcessExitWatch(pid: process.processIdentifier, isGone: { false }) {
            fired.add()
            seen.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fired.count, 0, "quiet while the process runs")
        // Killed outright, as a crashed or force-quit app is.
        kill(process.processIdentifier, SIGKILL)
        wait(for: [seen], timeout: 5)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(fired.count, 1)
        withExtendedLifetime(watch) {}
    }

    func testFiresAtOnceForAProcessThatWasAlreadyGone() throws {
        let process = try helper(seconds: "0")
        process.waitUntilExit()
        let fired = Counter()
        let watch = ProcessExitWatch(pid: process.processIdentifier, isGone: { true }) {
            fired.add()
        }
        XCTAssertEqual(fired.count, 1, "no event is needed")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fired.count, 1, "and a late event does not repeat it")
        withExtendedLifetime(watch) {}
    }

    func testTheTestRunnersOwnParentIsWatchedAndStillThere() throws {
        let fired = Counter()
        let watch = try XCTUnwrap(ProcessExitWatch.parent { fired.add() })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fired.count, 0)
        withExtendedLifetime(watch) {}
    }
}
