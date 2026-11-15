import XCTest
import BasaltManagerKit

final class GameFocusTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// An app relaunching after its update takes the front while someone
    /// plays in the headset, and the game goes quiet.
    func testGameComesBackWhenAnotherAppTakesTheFrontWhileNobodyUsesTheMac() {
        var policy = GameFocusPolicy()
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .game, headsetConnected: true, idleSeconds: 60, now: start))
        XCTAssertTrue(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true, idleSeconds: 60,
            now: start.addingTimeInterval(2)))
    }

    func testPersonWorkingAtTheMacKeepsTheFrontTheyChose() {
        var policy = GameFocusPolicy()
        _ = policy.shouldBringGameForward(front: .game, headsetConnected: true,
                                          idleSeconds: 0, now: start)
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true,
            idleSeconds: GameFocusPolicy.idleSeconds - 0.1, now: start.addingTimeInterval(2)))
        XCTAssertTrue(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true,
            idleSeconds: GameFocusPolicy.idleSeconds, now: start.addingTimeInterval(4)))
    }

    func testNothingHappensBeforeTheGameHadTheFront() {
        var policy = GameFocusPolicy()
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true, idleSeconds: 60, now: start))
    }

    func testSystemPromptsAndAWaitingHeadsetAreLeftAlone() {
        var policy = GameFocusPolicy()
        _ = policy.shouldBringGameForward(front: .game, headsetConnected: true,
                                          idleSeconds: 60, now: start)
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .systemPrompt, headsetConnected: true, idleSeconds: 60,
            now: start.addingTimeInterval(2)))
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: false, idleSeconds: 60,
            now: start.addingTimeInterval(4)))
    }

    func testAttemptsAreSpacedOut() {
        var policy = GameFocusPolicy()
        _ = policy.shouldBringGameForward(front: .game, headsetConnected: true,
                                          idleSeconds: 60, now: start)
        XCTAssertTrue(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true, idleSeconds: 60, now: start))
        XCTAssertFalse(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true, idleSeconds: 60,
            now: start.addingTimeInterval(GameFocusPolicy.retrySeconds - 1)))
        XCTAssertTrue(policy.shouldBringGameForward(
            front: .otherApp, headsetConnected: true, idleSeconds: 60,
            now: start.addingTimeInterval(GameFocusPolicy.retrySeconds)))
    }

    func testGameFamilyFollowsParentsAndStopsAtTheEnd() {
        let parents: [pid_t: pid_t] = [300: 200, 200: 100, 100: 1, 400: 1]
        let parent = { (pid: pid_t) in parents[pid] }
        XCTAssertTrue(GameProcessFamily.contains(100, gamePID: 100, parent: parent))
        XCTAssertTrue(GameProcessFamily.contains(300, gamePID: 100, parent: parent))
        XCTAssertFalse(GameProcessFamily.contains(400, gamePID: 100, parent: parent))
        XCTAssertFalse(GameProcessFamily.contains(500, gamePID: 100, parent: parent))
        XCTAssertFalse(GameProcessFamily.contains(300, gamePID: 0, parent: parent))
        // A loop in a broken table ends after the depth limit.
        XCTAssertFalse(GameProcessFamily.contains(7, gamePID: 100,
                                                  parent: { $0 == 7 ? 8 : 7 }))
    }

    func testThisProcessParentIsKnown() {
        XCTAssertEqual(GameProcessFamily.systemParent(of: getpid()), getppid())
        XCTAssertTrue(GameProcessFamily.contains(getpid(), gamePID: getppid(),
                                                 parent: GameProcessFamily.systemParent(of:)))
    }
}
