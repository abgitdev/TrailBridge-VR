import XCTest
@testable import BasaltManagerKit

final class LearningFirstRunTests: XCTestCase {
    func testOfferedToANewPersonOnceTheChecksAreIn() {
        XCTAssertTrue(LearningFirstRun.shouldOffer(LearningFixture.newcomer))
        // Also when the Mac is not ready: the invitation then says so.
        XCTAssertTrue(LearningFirstRun.shouldOffer(LearningFixture.unbuiltMac))
    }

    /// Without the checks the app does not know yet whom it is talking to:
    /// the refresh has not finished, or it failed.
    func testNotOfferedWithEmptyChecks() {
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFacts()))
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with { $0.setupChecks = [] }))
        XCTAssertNil(LearningFirstRun.invitation(LearningFacts()))
    }

    func testNotOfferedToSomeoneWithAGameOrASession() {
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.withGame))
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.returning))
        // Each fact alone is enough.
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.launchableGames = ["Game"]
        }))
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.sessionHistory = [LearningFixture.session(streamed: true)]
        }))
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.progress.quickPathCompleted = true
        }))
        // A launch that never reached streaming is not a played session.
        XCTAssertTrue(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.sessionHistory = [LearningFixture.session(streamed: false)]
        }))
    }

    func testNotOfferedAfterAnAnswer() {
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.firstRunAnswered = true
        }))
        XCTAssertNil(LearningPage(LearningFixture.newcomer.with { $0.firstRunAnswered = true }).invitation)
    }

    /// The answer could not be remembered, so the invitation would come
    /// back at every launch.
    func testNotOfferedWithADamagedProgressFile() {
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.newcomer.with {
            $0.progressDamaged = true
        }))
        XCTAssertFalse(LearningFirstRun.shouldOffer(LearningFixture.unbuiltMac.with {
            $0.progressDamaged = true
        }))
    }

    func testTheAnswerComesFromTheStoreAndSurvivesARestart() throws {
        let file = try temporaryDirectory().appendingPathComponent("learning.json")
        let store = LearningProgressStore(fileURL: file)
        var facts = LearningFixture.newcomer
        facts.firstRunAnswered = store.firstRun != nil
        facts.progressDamaged = store.isDamaged
        XCTAssertTrue(LearningFirstRun.shouldOffer(facts))

        try store.recordFirstRunAnswer(.later, at: Date(timeIntervalSince1970: 1_800_000_000))
        let reopened = LearningProgressStore(fileURL: file)
        facts.firstRunAnswered = reopened.firstRun != nil
        XCTAssertFalse(LearningFirstRun.shouldOffer(facts))
    }

    func testTheInvitationOpensTheFirstChapterStillToDo() throws {
        let ready = try XCTUnwrap(LearningFirstRun.invitation(LearningFixture.newcomer))
        XCTAssertTrue(ready.macReady)
        XCTAssertEqual(ready.chapter, .headset)
        let unbuilt = try XCTUnwrap(LearningFirstRun.invitation(LearningFixture.unbuiltMac))
        XCTAssertFalse(unbuilt.macReady)
        XCTAssertEqual(unbuilt.chapter, .mac)
        let cabled = try XCTUnwrap(LearningFirstRun.invitation(
            LearningFixture.newcomer.with(LearningFixture.headsetReady)))
        XCTAssertEqual(cabled.chapter, .game)
    }

    func testRussianTexts() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        let ready = try XCTUnwrap(LearningFirstRun.invitation(LearningFixture.newcomer))
        XCTAssertEqual(ready.text, "Пройдём путь до первой игры по шагам?")
        XCTAssertEqual(ready.note, "Обучение всегда в боковой панели.")
        XCTAssertEqual(ready.startTitle, "Начать")
        XCTAssertEqual(ready.laterTitle, "Не сейчас")
        let unbuilt = try XCTUnwrap(LearningFirstRun.invitation(LearningFixture.unbuiltMac))
        XCTAssertEqual(unbuilt.text, "Сначала нужно собрать части программы — это делает тот, "
            + "кто устанавливал TrailBridge. Пока можно подготовить шлем.")
        XCTAssertEqual(unbuilt.startTitle, "Начать")
    }

    /// A packaged app on a new Mac: only the Wine it downloads itself is
    /// missing, so the invitation does not speak of building.
    func testInvitationOnAMacThatOnlyLacksWhatTheSetupPageSupplies() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        var facts = LearningFixture.newcomer
        facts.setupChecks = LearningFixture.checks().filter { $0.id != "wine" } + [
            SetupCheck(id: "wine", title: "wine", detail: "", status: .actionNeeded,
                       required: true, action: SetupInspector.downloadWineAction),
            SetupCheck(id: "rosetta", title: "rosetta", detail: "", status: .actionNeeded,
                       required: true, action: SetupInspector.copyRosettaCommandAction),
        ]
        let invitation = try XCTUnwrap(LearningFirstRun.invitation(facts))
        XCTAssertFalse(invitation.macReady)
        XCTAssertTrue(invitation.macFixedOnSetupPage)
        XCTAssertEqual(invitation.chapter, .mac)
        XCTAssertEqual(invitation.text, "Сначала нужно подготовить Mac: приложение само скачает "
            + "недостающее или подскажет, что сделать. Начнём с этого?")
        // One part that has to be built keeps the old words.
        facts.setupChecks += [SetupCheck(id: "runtime2", title: "runtime", detail: "",
                                         status: .actionNeeded, required: true)]
        let built = try XCTUnwrap(LearningFirstRun.invitation(facts))
        XCTAssertFalse(built.macFixedOnSetupPage)
        XCTAssertTrue(built.text.hasPrefix("Сначала нужно собрать части программы"))
        XCTAssertFalse(try XCTUnwrap(LearningFirstRun.invitation(LearningFixture.newcomer)).macFixedOnSetupPage)
    }
}
