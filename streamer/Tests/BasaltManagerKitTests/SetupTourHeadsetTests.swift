import XCTest
import BasaltCore
@testable import BasaltManagerKit

/// Chapter 2, "Headset": seven steps on the Headset page, in the phone and
/// in the headset, from what that page's own polling sees.
final class SetupTourHeadsetTests: XCTestCase {
    private typealias Step = SetupTour.Step

    private let tested = PinnedHeadsetDownload.testedALVR.version
    private let intro = "Шлем настраивается по кабелю один раз — даже если потом играть по Wi‑Fi."
    private let otherError = "Headset command failed: adb: protocol fault"

    /// A new person on the Headset page; the page has not asked yet.
    private var onPage: LearningFacts {
        LearningFixture.newcomer.with { $0.section = .headset }
    }

    /// adb answered: the cable is out.
    private var noCable: LearningFacts { onPage.with(LearningFixture.headset(.none)) }

    private func tour(
        _ facts: LearningFacts, _ mode: SetupTour.Mode = .firstPass, resumeAt: Step? = nil
    ) throws -> SetupTour {
        try XCTUnwrap(SetupTour(chapter: .headset, mode: mode, facts: facts, resumeAt: resumeAt?.rawValue))
    }

    private func shown(_ tour: SetupTour) throws -> SetupPresentation {
        try XCTUnwrap(tour.presentation)
    }

    private func russian(_ body: () throws -> Void) rethrows {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        try body()
    }

    private func feed(_ tour: inout SetupTour, _ change: (inout LearningFacts) -> Void) {
        tour.handle(.facts(tour.facts.with(change)))
    }

    /// Presses a button the strip shows now.
    private func press(_ button: SetupButton, in tour: inout SetupTour,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let hint = try shown(tour)
        XCTAssertTrue((hint.buttons + (hint.help?.options ?? [])).contains(button),
                      "\(button) is not offered in \(hint.id)", file: file, line: line)
        tour.handle(try XCTUnwrap(button.event, file: file, line: line))
    }

    // MARK: - The whole way

    func testANewPersonWalksTheSevenSteps() throws {
        try russian {
            // Started from the Learning page: the Headset page has not asked.
            var tour = try tour(LearningFixture.newcomer.with { $0.section = .learning })
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            var hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 1 из 7")
            XCTAssertEqual(hint.text, intro + " Проверяем инструменты USB…")
            XCTAssertEqual(hint.target, .headsetStatus)
            XCTAssertEqual(hint.opensSection(afterShowing: nil), .headset)
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertNil(hint.primaryButton)
            XCTAssertEqual(hint.help?.tips,
                           ["Раздел «Шлем» сам проверяет шлем каждые несколько секунд, пока он открыт."])
            XCTAssertEqual(hint.help?.options, [])

            // The page opens and asks. The wrapper has no adb to run.
            feed(&tour) { $0.section = .headset }
            feed(&tour, LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            hint = try shown(tour)
            XCTAssertEqual(hint.text, intro
                + " Нажмите «Скачать Android Platform Tools…», затем «Принять и скачать».")
            XCTAssertEqual(hint.target, .headsetGetTools)
            XCTAssertNil(hint.section)
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["Не получается?"])
            XCTAssertEqual(hint.help?.tips, [
                "Если появилась ошибка, причина — в карточке выше, под «Подробнее». "
                    + "Нажмите «Скачать Android Platform Tools…» ещё раз.",
            ])

            // The confirmation is a sheet: nothing is drawn, nothing moves.
            feed(&tour) { $0.pageSheetOpen = true }
            XCTAssertNil(tour.presentation)
            feed(&tour, LearningFixture.headset(.none))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            // It closes, the download ends, adb answers: the step counts.
            feed(&tour) { $0.pageSheetOpen = false }
            XCTAssertEqual(tour.phase, .step(.headsetAccount))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 2 из 7")
            XCTAssertEqual(hint.text, "Нужен аккаунт разработчика Meta: от 18 лет, с организацией "
                + "и подтверждением аккаунта. Это самый трудный шаг — можно попросить помощи.")
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.buttons, [.link(.metaDeveloperSignUp), .confirm])
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["Открыть сайт Meta", "Готово"])
            XCTAssertEqual(hint.primaryButton, .confirm)
            XCTAssertEqual(SetupLink.metaDeveloperSignUp.url.absoluteString,
                           "https://developers.meta.com/horizon/sign-up/")
            // The site's button opens a page; the tour stays where it is.
            XCTAssertNil(SetupButton.link(.metaDeveloperSignUp).event)
            XCTAssertEqual(hint.help?.title, "Не получается?")
            XCTAssertEqual(hint.help?.tips, [
                "На сайте Meta попросит создать организацию (команду разработчиков) и подтвердить аккаунт.",
                "Без компании организацию подтверждают своей личностью: Meta называет это "
                    + "«Admin Verification». Делается один раз.",
            ])
            XCTAssertEqual(hint.help?.options, [])

            try press(.confirm, in: &tour)
            XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 3 из 7")
            XCTAssertEqual(hint.text, "В телефоне, в Meta Horizon: значок шлема на панели → ваш шлем вверху → "
                + "«Headset Settings» (настройки шлема) → включите «Developer Mode» (режим разработчика).")
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.buttons, [.back, .confirm])
            XCTAssertEqual(hint.help?.tips, [
                "Если «Developer Mode» не включается, сначала нужен аккаунт разработчика Meta — "
                    + "это предыдущий шаг.",
            ])

            try press(.confirm, in: &tour)
            XCTAssertEqual(tour.phase, .step(.headsetCable))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 4 из 7")
            XCTAssertEqual(hint.text, "Подключите шлем к этому Mac кабелем USB‑C, который передаёт данные, "
                + "и включите шлем. Шаг засчитается сам, когда Mac увидит шлем.")
            XCTAssertEqual(hint.target, .headsetStatus)
            XCTAssertEqual(hint.buttons, [.back, .help])
            XCTAssertEqual(hint.help?.tips, [
                "Кабель должен передавать данные, а не только заряжать. Шлем должен быть включён.",
                "Проверьте в Meta Horizon, что «Developer Mode» (режим разработчика) включён.",
                "Раздел «Шлем» сам проверяет шлем каждые несколько секунд, пока он открыт.",
            ])
            // Waiting: "Next" is not a way on.
            tour.handle(.next)
            XCTAssertEqual(tour.phase, .step(.headsetCable))

            // The Mac sees the headset; debugging is not allowed yet.
            feed(&tour, LearningFixture.headset(.unauthorized))
            XCTAssertEqual(tour.phase, .step(.headsetDebugging))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 5 из 7")
            XCTAssertEqual(hint.text, "В шлеме: «Allow USB debugging?» (разрешить отладку?). Отметьте "
                + "«Always allow from this computer» (всегда с этого Mac), затем «Allow» (разрешить).")
            XCTAssertEqual(hint.text.count, 145)
            XCTAssertEqual(hint.target, .headsetStatus)
            // The cable is in: nothing before this is left to do again.
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertEqual(hint.help?.tips, [
                "Запроса нет? Выньте кабель и вставьте снова.",
                "Не нажимайте «Don't show again» (больше не показывать): запрос вернётся, только если "
                    + "в настройках разработчика шлема снова включить «USB Connection Dialog».",
                "Шлем должен быть включён и разблокирован.",
            ])

            // Allowed. No ALVR on the headset.
            feed(&tour, LearningFixture.headset(.connected))
            XCTAssertEqual(tour.phase, .step(.headsetInstall))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 6 из 7")
            XCTAssertEqual(hint.text, "Нажмите «Установить на шлем…», затем «Скачать и установить». "
                + "Не отключайте кабель, пока идёт установка.")
            XCTAssertEqual(hint.target, .headsetInstall)
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertEqual(hint.help?.tips, [
                "Если появилась ошибка, причина — в карточке выше, под «Подробнее». "
                    + "Нажмите «Установить на шлем…» ещё раз.",
                "ALVR уже стоит на шлеме, а здесь написано «Клиент ALVR не установлен»? ALVR, установленный "
                    + "другим способом, раздел может не видеть. Тогда пропустите шаг.",
            ])
            XCTAssertEqual(hint.help?.options, [.skip])
            XCTAssertFalse(tour.facts.isDone(.headset))

            // The tested version is on the headset.
            feed(&tour, LearningFixture.headsetReady)
            XCTAssertEqual(tour.phase, .step(.headsetOpenALVR))
            hint = try shown(tour)
            XCTAssertEqual(hint.label, "Шлем · шаг 7 из 7")
            XCTAssertEqual(hint.text, "В шлеме: кнопка Meta на правом контроллере → меню слева → "
                + "«Unknown Sources» (неизвестные источники) → ALVR. Когда ALVR откроется, нажмите «Готово».")
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.buttons, [.confirm])
            XCTAssertEqual(hint.primaryButton, .confirm)
            XCTAssertNil(hint.help)
            XCTAssertFalse(tour.isCompleted)

            try press(.confirm, in: &tour)
            XCTAssertEqual(tour.phase, .finished)
            XCTAssertTrue(tour.isCompleted)
            XCTAssertNil(tour.pausedStep)
            hint = try shown(tour)
            XCTAssertEqual(hint.id, "setup-headset-end")
            XCTAssertEqual(hint.text, "Глава «Шлем» готова. Дальше — «Игра».")
            XCTAssertEqual(hint.buttons, [.continueTo(.game), .later])
        }
    }

    // MARK: - USB tools

    /// The tools state is one rule, from what the Headset page's polling
    /// last saw.
    func testTheToolsStateGoesByThePollResult() {
        typealias Connection = HeadsetStatus.Connection
        let wrapper = LearningFixture.wrapperWithoutADB
        let cases: [(Bool, Connection, String?, HeadsetTools)] = [
            // Before the first answer nothing is known, whatever is held.
            (false, .noTools, nil, .checking),
            (false, .connected, nil, .checking),
            (false, .noTools, wrapper, .checking),
            // No adb was found at all.
            (true, .noTools, nil, .missing),
            // adb was found (the wrapper), and it had nothing to run.
            (true, .noTools, wrapper, .missing),
            (true, .connected, wrapper, .missing),
            (true, .noTools, AlvrWiredFailure.adbMissing, .missing),
            // adb was found and the question failed for another reason:
            // the download is not the fix.
            (true, .noTools, otherError, .failed),
            (true, .none, otherError, .failed),
            (true, .connected, "The operation couldn’t be completed.", .failed),
            // adb answered.
            (true, .none, nil, .ready),
            (true, .unauthorized, nil, .ready),
            (true, .connected, nil, .ready),
        ]
        for (checked, connection, error, expected) in cases {
            XCTAssertEqual(HeadsetTools(checked: checked, connection: connection, scanError: error), expected,
                           "\(checked) \(connection) \(error ?? "-")")
            var facts = LearningFacts()
            facts.headsetChecked = checked
            facts.headsetConnection = connection
            facts.headsetScanError = error
            XCTAssertEqual(facts.headsetTools, expected)
        }
        // Fresh facts are the placeholder: not asked yet.
        XCTAssertEqual(LearningFacts().headsetTools, .checking)
    }

    /// "adb found but the poll failed": the wrapper's own sentence means the
    /// tools are missing, and the download is offered. Any other error is
    /// shown as an error, and the download is not offered.
    func testTheToolsStepFollowsThePollResult() throws {
        try russian {
            // A resumed pass: without the opening sentence.
            var tour = try tour(onPage, resumeAt: .headsetTools)
            XCTAssertEqual(try shown(tour).text, "Проверяем инструменты USB…")
            XCTAssertEqual(try shown(tour).target, .headsetStatus)

            // No adb at all, and the wrapper with nothing behind it.
            for missing in [onPage.with { $0.headsetChecked = true },
                            onPage.with(LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB))] {
                tour.handle(.facts(missing))
                XCTAssertEqual(tour.phase, .step(.headsetTools))
                let hint = try shown(tour)
                XCTAssertEqual(hint.text, "Нажмите «Скачать Android Platform Tools…», затем «Принять и скачать».")
                XCTAssertEqual(hint.target, .headsetGetTools)
                XCTAssertEqual(hint.buttons, [.help])
            }

            // adb is there; the question failed for another reason.
            tour.handle(.facts(onPage.with(LearningFixture.headsetScanFailed(otherError))))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            var hint = try shown(tour)
            XCTAssertEqual(hint.text,
                           "Не удалось проверить шлем. Причина — в карточке выше: «Ошибка» → «Подробнее».")
            XCTAssertEqual(hint.target, .headsetStatus)
            XCTAssertFalse(hint.text.contains("Android Platform Tools"))
            XCTAssertEqual(hint.buttons, [.help])
            XCTAssertEqual(hint.help?.tips, [
                "Проверьте USB-кабель и разрешение отладки в шлеме. "
                    + "Если настройка не завершилась, повторите её.",
                "Раздел «Шлем» сам проверяет шлем каждые несколько секунд, пока он открыт.",
            ])
            XCTAssertEqual(hint.help?.options, [])

            // The same error over a status seen earlier: that status may be
            // an old one, so nothing is taken from it.
            tour.handle(.facts(onPage.with(LearningFixture.headsetReady)
                .with(LearningFixture.headsetScanFailed(otherError))))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            XCTAssertEqual(try shown(tour).target, .headsetStatus)
            tour.handle(.facts(onPage.with(LearningFixture.headsetReady)
                .with(LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB))))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            XCTAssertEqual(try shown(tour).target, .headsetGetTools)

            // The next question is answered: the step counts itself.
            tour.handle(.facts(noCable))
            XCTAssertEqual(tour.phase, .step(.headsetAccount))
            // The tools are lost again on the way: the tools come first.
            try press(.confirm, in: &tour)
            feed(&tour, LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB))
            XCTAssertEqual(tour.phase, .step(.headsetTools))
            hint = try shown(tour)
            XCTAssertEqual(hint.buttons, [.help])
            feed(&tour, LearningFixture.headset(.none))
            // What was answered with "Done" is still answered.
            XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
        }
    }

    // MARK: - The opening sentence

    func testTheOpeningSentenceGoesIntoTheToolsStepOrOntoItsOwnCard() throws {
        try russian {
            // The tools are missing: the sentence is the step's first words,
            // and it is not said again.
            var missing = try tour(onPage.with(LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB)))
            XCTAssertEqual(missing.headsetIntro, .withTools)
            XCTAssertTrue(try shown(missing).text.hasPrefix(intro + " Нажмите"))
            feed(&missing, LearningFixture.headset(.none))
            XCTAssertEqual(missing.phase, .step(.headsetAccount))
            XCTAssertFalse(try shown(missing).text.contains(intro))

            // The same with a question that failed.
            let failed = try tour(onPage.with(LearningFixture.headsetScanFailed(otherError)))
            XCTAssertEqual(try shown(failed).text, intro
                + " Не удалось проверить шлем. Причина — в карточке выше: «Ошибка» → «Подробнее».")

            // The tools are there: no step has room for the sentence, so it
            // gets a card of its own, once.
            var ready = try tour(noCable)
            XCTAssertEqual(ready.phase, .step(.headsetIntro))
            var hint = try shown(ready)
            XCTAssertEqual(hint.label, "Шлем")
            XCTAssertEqual(hint.text, intro)
            XCTAssertNil(hint.target)
            XCTAssertEqual(hint.buttons, [.next])
            XCTAssertEqual(hint.buttons.map(hint.title(of:)), ["Далее"])
            XCTAssertNil(hint.help)
            // The headset shows up meanwhile: the card stays to be read.
            feed(&ready, LearningFixture.headset(.unauthorized))
            XCTAssertEqual(ready.phase, .step(.headsetIntro))
            try press(.next, in: &ready)
            XCTAssertEqual(ready.phase, .step(.headsetDebugging))
            XCTAssertEqual(ready.headsetIntro, .said)
            feed(&ready, LearningFixture.headset(.none))
            XCTAssertEqual(ready.phase, .step(.headsetCable))

            // "Checking…" for a moment is not the sentence said: the tools
            // turn out to be there, and the card comes.
            var checking = try tour(onPage)
            XCTAssertEqual(try shown(checking).text, intro + " Проверяем инструменты USB…")
            XCTAssertEqual(checking.headsetIntro, .pending)
            feed(&checking, LearningFixture.headset(.none))
            XCTAssertEqual(checking.phase, .step(.headsetIntro))
            hint = try shown(checking)
            XCTAssertEqual(hint.text, intro)
            try press(.next, in: &checking)
            XCTAssertEqual(checking.phase, .step(.headsetAccount))

            // A resumed pass has heard it.
            for step in [Step.headsetTools, .headsetAccount, .headsetCable] {
                let resumed = try tour(noCable, resumeAt: step)
                XCTAssertEqual(resumed.headsetIntro, .none)
                XCTAssertNotEqual(resumed.step, .headsetIntro)
                XCTAssertFalse(try shown(resumed).text.contains(intro), "\(step)")
            }
            // Stopped on the card itself: it is shown again.
            var stopped = try tour(noCable)
            stopped.handle(.close)
            XCTAssertEqual(stopped.pausedStep, .headsetIntro)
            XCTAssertEqual(try tour(noCable, resumeAt: .headsetIntro).phase, .step(.headsetIntro))
        }
    }

    // MARK: - Account and Developer Mode

    /// The Mac sees the headset over USB only with Developer Mode on, so
    /// steps 2 and 3 are behind then.
    func testAccountAndDeveloperModeCountWhenTheHeadsetIsSeen() throws {
        // Seen at the start: straight to what is left.
        let cases: [(HeadsetStatus.Connection, String?, Step)] = [
            (.unauthorized, nil, .headsetDebugging),
            (.connected, nil, .headsetInstall),
            (.connected, "20.11.0", .headsetInstall),
            (.connected, tested, .headsetOpenALVR),
        ]
        for (connection, client, expected) in cases {
            var tour = try tour(onPage.with(LearningFixture.headset(connection, client: client)))
            // Only the last step needs no opening card: the headset is set
            // up by then.
            if expected != .headsetOpenALVR {
                XCTAssertEqual(tour.phase, .step(.headsetIntro), "\(connection)")
                tour.handle(.next)
            }
            XCTAssertEqual(tour.phase, .step(expected), "\(connection) \(client ?? "-")")
            XCTAssertFalse(tour.hasPrevious)
        }

        // Seen while a step done outside the app is shown.
        for (step, seen) in [(Step.headsetAccount, HeadsetStatus.Connection.unauthorized),
                             (.headsetAccount, .connected), (.headsetDeveloperMode, .unauthorized),
                             (.headsetDeveloperMode, .connected), (.headsetCable, .unauthorized),
                             (.headsetCable, .connected)] {
            var tour = try tour(noCable, resumeAt: step)
            XCTAssertEqual(tour.phase, .step(step))
            feed(&tour, LearningFixture.headset(seen))
            XCTAssertEqual(tour.phase, .step(seen == .connected ? .headsetInstall : .headsetDebugging),
                           "\(step) \(seen)")
            // The cable comes out: it goes back in. Nothing before it is
            // asked again, though it can be read again with "Back".
            feed(&tour, LearningFixture.headset(.none))
            XCTAssertEqual(tour.phase, .step(.headsetCable), "\(step) \(seen)")
            XCTAssertEqual(try shown(tour).buttons, [.back, .help])
        }

        // Not seen: both are asked, in order, and answered with "Done".
        var tour = try tour(noCable, resumeAt: .headsetAccount)
        feed(&tour, LearningFixture.headset(.none))
        XCTAssertEqual(tour.phase, .step(.headsetAccount))
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetCable))
    }

    // MARK: - ALVR

    func testInstallCountsByTheTestedVersion() throws {
        for client in [nil, "20.11.0", "21.0.0", "20.14.10"] as [String?] {
            var tour = try tour(onPage.with(LearningFixture.headset(.connected, client: client)),
                                resumeAt: .headsetInstall)
            XCTAssertEqual(tour.phase, .step(.headsetInstall), client ?? "-")
            XCTAssertEqual(try shown(tour).target, .headsetInstall)
            // Something else changes on the page: still waiting.
            feed(&tour) { $0.appBusy = true }
            XCTAssertEqual(tour.phase, .step(.headsetInstall))
            feed(&tour, LearningFixture.headset(.connected, client: tested))
            XCTAssertEqual(tour.phase, .step(.headsetOpenALVR), client ?? "-")
        }
        // An ALVR whose version the headset did not tell is not the tested one.
        let unknown = try tour(onPage.with(LearningFixture.headset(.connected)).with {
            $0.headsetClientInstalled = true
        }, resumeAt: .headsetInstall)
        XCTAssertEqual(unknown.phase, .step(.headsetInstall))
    }

    /// "Replace the old ALVR client?" can only be asked when an ALVR is on
    /// the headset already.
    func testTheReplaceSentenceNeedsAnotherALVROnTheHeadset() throws {
        try russian {
            let plain = "Нажмите «Установить на шлем…», затем «Скачать и установить». "
                + "Не отключайте кабель, пока идёт установка."
            let replace = "Нажмите «Установить на шлем…», затем «Скачать и установить». "
                + "Если спросит «Заменить старый клиент ALVR?» — «Удалить и установить»."
            let none = try tour(onPage.with(LearningFixture.headset(.connected)), resumeAt: .headsetInstall)
            XCTAssertEqual(try shown(none).text, plain)
            for client in ["20.11.0", "21.0.0"] {
                let other = try tour(onPage.with(LearningFixture.headset(.connected, client: client)),
                                     resumeAt: .headsetInstall)
                XCTAssertEqual(try shown(other).text, replace, client)
            }
            let unknown = try tour(onPage.with(LearningFixture.headset(.connected)).with {
                $0.headsetClientInstalled = true
            }, resumeAt: .headsetInstall)
            XCTAssertEqual(try shown(unknown).text, replace)
            // A review speaks the same way of the button while it is there.
            var review = try tour(onPage.with(LearningFixture.headset(.connected, client: "20.11.0")), .review)
            while review.step != .headsetInstall { review.handle(.next) }
            XCTAssertEqual(try shown(review).text, replace)
            feed(&review, LearningFixture.headset(.connected))
            XCTAssertEqual(try shown(review).text, plain)
        }
    }

    /// An ALVR under another package name is not seen from here: the step
    /// can be skipped, and the chapter ends on the user's word.
    func testInstallCanBeSkippedAndTheChapterStillEnds() throws {
        var tour = try tour(onPage.with(LearningFixture.headset(.connected)), resumeAt: .headsetInstall)
        try press(.skip, in: &tour)
        XCTAssertEqual(tour.phase, .step(.headsetOpenALVR))
        // The button is still on the page: the step can be read again.
        XCTAssertEqual(try shown(tour).buttons, [.back, .confirm])
        try press(.back, in: &tour)
        XCTAssertEqual(tour.phase, .step(.headsetInstall))
        XCTAssertTrue(tour.isRevisit)
        XCTAssertEqual(try shown(tour).buttons, [.next])
        XCTAssertEqual(try shown(tour).target, .headsetInstall)
        try press(.next, in: &tour)
        XCTAssertEqual(tour.phase, .step(.headsetOpenALVR))
        // The facts still say "no ALVR": the chapter ends all the same.
        XCTAssertFalse(tour.facts.isDone(.headset))
        try press(.confirm, in: &tour)
        XCTAssertEqual(tour.phase, .finished)
        XCTAssertTrue(tour.isCompleted)

        // Skipping is offered on the install step only, and never in a review.
        var cable = try self.tour(noCable, resumeAt: .headsetCable)
        cable.handle(.skip)
        XCTAssertEqual(cable.phase, .step(.headsetCable))
        var review = try self.tour(onPage.with(LearningFixture.headset(.connected)), .review)
        while review.step != .headsetInstall { review.handle(.next) }
        review.handle(.skip)
        XCTAssertEqual(review.phase, .step(.headsetInstall))
    }

    /// ALVR is on the headset: the cable may come out before "Done".
    func testTheLastStepStaysWhenTheCableComesOut() throws {
        var tour = try tour(onPage.with(LearningFixture.headsetReady), resumeAt: .headsetInstall)
        XCTAssertEqual(tour.phase, .step(.headsetOpenALVR))
        for change in [LearningFixture.headset(.none), LearningFixture.headset(.unauthorized),
                       LearningFixture.headsetScanFailed(otherError),
                       LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB),
                       LearningFixture.headset(.connected, client: "20.11.0")] {
            feed(&tour, change)
            XCTAssertEqual(tour.phase, .step(.headsetOpenALVR))
            XCTAssertEqual(try shown(tour).buttons, tour.hasPrevious ? [.back, .confirm] : [.confirm])
        }
        // Leaving the page does not hold this step up either.
        feed(&tour) { $0.section = .learning }
        XCTAssertEqual(try shown(tour).buttons.last, .confirm)
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .finished)
        XCTAssertTrue(tour.isCompleted)
    }

    // MARK: - Leaving the Headset page

    /// Only the open Headset page asks the headset. A step that waits for
    /// its answer says so when the user leaves, instead of waiting forever.
    func testAWaitingStepOffersTheHeadsetPageWhenTheUserLeaves() throws {
        try russian {
            for step in [Step.headsetTools, .headsetCable, .headsetDebugging, .headsetInstall] {
                let facts: LearningFacts
                switch step {
                case .headsetTools: facts = onPage.with { $0.headsetChecked = true }
                case .headsetDebugging: facts = onPage.with(LearningFixture.headset(.unauthorized))
                case .headsetInstall: facts = onPage.with(LearningFixture.headset(.connected))
                default: facts = noCable
                }
                var tour = try tour(facts, resumeAt: step)
                XCTAssertEqual(tour.phase, .step(step))
                let waiting = try shown(tour)
                XCTAssertNotNil(waiting.target)

                feed(&tour) { $0.section = .library }
                XCTAssertEqual(tour.phase, .step(step))
                XCTAssertTrue(tour.isAway)
                let away = try shown(tour)
                XCTAssertEqual(away.id, "setup-\(step.rawValue)-away")
                XCTAssertEqual(away.label, waiting.label)
                XCTAssertEqual(away.text, "Этот шаг — в разделе «Шлем»: шлем проверяется, только пока раздел открыт.")
                XCTAssertEqual(away.buttons, [.open(.headset)])
                XCTAssertEqual(away.buttons.map(away.title(of:)), ["Открыть «Шлем»"])
                XCTAssertEqual(away.primaryButton, .open(.headset))
                XCTAssertNil(SetupButton.open(.headset).event)
                XCTAssertNil(away.target)
                XCTAssertNil(away.help)
                // The user left on purpose: the strip does not pull back.
                XCTAssertNil(away.opensSection(afterShowing: waiting.id))
                // Another section, the same line.
                feed(&tour) { $0.section = .stream }
                XCTAssertEqual(try shown(tour), away)

                // Back on the page: the step as it was.
                feed(&tour) { $0.section = .headset }
                XCTAssertFalse(tour.isAway)
                XCTAssertEqual(try shown(tour), waiting)
            }
        }
    }

    func testOnlyAStepTheUserLeftSaysSo() throws {
        // A step done outside the app waits for nothing here: it stays as
        // it is, and is not opened again while it is the same step.
        var tour = try tour(noCable, resumeAt: .headsetAccount)
        let account = try shown(tour)
        feed(&tour) { $0.section = .library }
        var hint = try shown(tour)
        XCTAssertEqual(hint.id, account.id)
        XCTAssertEqual(hint.buttons, account.buttons)
        XCTAssertEqual(hint.section, .headset)
        XCTAssertNil(hint.opensSection(afterShowing: account.id))

        // A step newly shown asks for its page, waiting or not, wherever
        // the user is.
        tour.handle(.next)
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetCable))
        XCTAssertFalse(tour.isAway)
        hint = try shown(tour)
        XCTAssertEqual(hint.buttons, [.back, .help])
        XCTAssertEqual(hint.opensSection(afterShowing: account.id), .headset)

        // A step reached with "Back" waits for "Next", so it has nothing to
        // say about the page.
        var back = try self.tour(noCable, resumeAt: .headsetCable)
        feed(&back) { $0.section = .library }
        XCTAssertEqual(try shown(back).buttons, [.open(.headset)])
        feed(&back) { $0.section = .headset }
        back.handle(.back)
        feed(&back) { $0.section = .library }
        XCTAssertEqual(back.phase, .step(.headsetDeveloperMode))
        XCTAssertEqual(try shown(back).buttons, [.back, .confirm])

        // A review waits for nothing.
        var review = try self.tour(noCable, .review)
        while review.step != .headsetCable { review.handle(.next) }
        feed(&review) { $0.section = .library }
        XCTAssertFalse(review.isAway)
        XCTAssertEqual(try shown(review).buttons, [.back, .next])
    }

    // MARK: - Back, close and resume

    func testHeadsetBackNeverJumpsForward() throws {
        var tour = try tour(noCable, resumeAt: .headsetAccount)
        XCTAssertFalse(tour.hasPrevious)
        tour.handle(.next)
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetCable))

        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
        XCTAssertTrue(tour.isRevisit)
        XCTAssertEqual(try shown(tour).buttons, [.back, .confirm])
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.headsetAccount))
        XCTAssertEqual(try shown(tour).buttons, [.link(.metaDeveloperSignUp), .confirm])
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.headsetAccount))
        // Forward again: step by step, none skipped.
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetCable))

        // The headset is seen while a revisited step is shown: it stays
        // until "Done", and then the way goes on from the facts.
        tour.handle(.back)
        feed(&tour, LearningFixture.headset(.unauthorized))
        XCTAssertEqual(tour.phase, .step(.headsetDeveloperMode))
        XCTAssertEqual(try shown(tour).buttons, [.confirm])
        tour.handle(.next)
        XCTAssertEqual(tour.phase, .step(.headsetDebugging))
        XCTAssertFalse(tour.hasPrevious)
        tour.handle(.back)
        XCTAssertEqual(tour.phase, .step(.headsetDebugging))
    }

    func testHeadsetPausesAndResumes() throws {
        let stops: [(LearningFacts, Step)] = [
            (onPage.with { $0.headsetChecked = true }, .headsetTools),
            (noCable, .headsetAccount), (noCable, .headsetDeveloperMode), (noCable, .headsetCable),
            (onPage.with(LearningFixture.headset(.unauthorized)), .headsetDebugging),
            (onPage.with(LearningFixture.headset(.connected)), .headsetInstall),
            (onPage.with(LearningFixture.headsetReady), .headsetOpenALVR),
        ]
        for (facts, step) in stops {
            var tour = try tour(facts, resumeAt: step)
            XCTAssertEqual(tour.phase, .step(step))
            tour.handle(.close)
            XCTAssertEqual(tour.phase, .stopped)
            XCTAssertEqual(tour.pausedStep, step)
            XCTAssertFalse(tour.isCompleted)
            XCTAssertNil(tour.presentation)
            // A VR session stops it the same way.
            var session = try self.tour(facts, resumeAt: step)
            feed(&session) { $0.session = .starting }
            XCTAssertEqual(session.pausedStep, step)
        }

        // "Continue" goes by the facts of now, not by the step alone.
        XCTAssertEqual(try tour(onPage.with(LearningFixture.headset(.unauthorized)),
                                resumeAt: .headsetAccount).step, .headsetDebugging)
        XCTAssertEqual(try tour(noCable, resumeAt: .headsetDebugging).step, .headsetCable)
        XCTAssertEqual(try tour(noCable, resumeAt: .headsetInstall).step, .headsetCable)
        XCTAssertEqual(try tour(onPage.with { $0.headsetChecked = true }, resumeAt: .headsetCable).step,
                       .headsetTools)
        // Stopped on the last step after skipping the install: the last
        // step again, cable or no cable.
        for facts in [noCable, onPage.with(LearningFixture.headset(.connected)), onPage] {
            var last = try tour(facts, resumeAt: .headsetOpenALVR)
            XCTAssertEqual(last.phase, .step(.headsetOpenALVR))
            last.handle(.next)
            XCTAssertEqual(last.phase, .finished)
        }
        // A step of another chapter, or a name this version does not know:
        // from the start.
        for name in ["gameWait", "headsetSomethingNew"] {
            let tour = try XCTUnwrap(SetupTour(chapter: .headset, mode: .firstPass, facts: noCable,
                                               resumeAt: name))
            XCTAssertEqual(tour.phase, .step(.headsetIntro), name)
        }
        // Never during a VR session.
        let live = try tour(noCable.with { $0.session = .live })
        XCTAssertEqual(live.phase, .stopped)
        XCTAssertNil(live.presentation)
    }

    // MARK: - Review

    /// A player on Wi-Fi with no cable in: a review outlines only what is on
    /// the page now and says where the rest appears.
    func testAReviewOnAWiFiMacWithoutACable() throws {
        try russian {
            let facts = LearningFixture.returning.with(LearningFixture.headset(.none)).with {
                $0.connection = .wifi
                $0.section = .headset
            }
            XCTAssertTrue(facts.isDone(.headset))
            XCTAssertEqual(LearningProgram(facts).row(.headset)?.action, .review)
            var review = try tour(facts, .review)

            let cards: [(Step, String, SetupTarget?)] = [
                (.headsetIntro, intro, nil),
                (.headsetTools,
                 "Кнопка «Скачать Android Platform Tools…» появляется здесь, только когда инструментов нет.",
                 nil),
                (.headsetAccount,
                 "Нужен аккаунт разработчика Meta: от 18 лет, с организацией и подтверждением аккаунта. "
                    + "Это самый трудный шаг — можно попросить помощи.", nil),
                (.headsetDeveloperMode,
                 "В телефоне, в Meta Horizon: значок шлема на панели → ваш шлем вверху → "
                    + "«Headset Settings» (настройки шлема) → включите «Developer Mode» (режим разработчика).",
                 nil),
                (.headsetCable,
                 "Здесь видно, подключён ли шлем кабелем USB‑C. Для игры по Wi‑Fi кабель не нужен.",
                 .headsetStatus),
                (.headsetDebugging,
                 "В шлеме: «Allow USB debugging?» (разрешить отладку?). Отметьте «Always allow "
                    + "from this computer» (всегда с этого Mac), затем «Allow» (разрешить).", nil),
                (.headsetInstall,
                 "Кнопка «Установить на шлем…» появляется здесь, когда шлем подключён кабелем, "
                    + "а проверенного ALVR на нём нет.", nil),
                (.headsetOpenALVR, "В шлеме: кнопка Meta на правом контроллере → меню слева → "
                    + "«Unknown Sources» (неизвестные источники) → ALVR.", nil),
            ]
            for (index, (step, text, target)) in cards.enumerated() {
                XCTAssertEqual(review.phase, .step(step))
                let hint = try shown(review)
                XCTAssertEqual(hint.label, "Шлем · обзор, шаг \(index + 1) из 8")
                XCTAssertEqual(hint.text, text, "\(step)")
                XCTAssertEqual(hint.target, target, "\(step)")
                // No waiting, no "Done", no "Not working?" button.
                XCTAssertEqual(hint.buttons, index == 0 ? [.next] : [.back, .next], "\(step)")
                XCTAssertNil(hint.section)
                // No fact moves a review.
                for change in [LearningFixture.headset(.connected), LearningFixture.headsetReady,
                               LearningFixture.headsetScanFailed(otherError)] {
                    var moved = review
                    feed(&moved, change)
                    XCTAssertEqual(moved.phase, .step(step), "\(step)")
                }
                if step == .headsetAccount {
                    // Both places are taken, so the site is in the list.
                    XCTAssertEqual(hint.help?.title, "Не получается?")
                    XCTAssertEqual(hint.help?.options, [.link(.metaDeveloperSignUp)])
                    XCTAssertEqual(hint.title(of: .link(.metaDeveloperSignUp)), "Открыть сайт Meta")
                }
                review.handle(.next)
            }
            XCTAssertEqual(review.phase, .finished)
            XCTAssertTrue(review.isCompleted)
            XCTAssertNil(review.pausedStep)
            XCTAssertEqual(try shown(review).text, "Глава «Шлем» готова. Дальше — «Варианты запуска».")
        }
    }

    /// What is on the page now is outlined, and spoken of as it is.
    func testAReviewOutlinesWhatIsOnThePageNow() throws {
        try russian {
            func card(_ step: Step, _ change: (inout LearningFacts) -> Void) throws -> SetupPresentation {
                var review = try tour(LearningFixture.returning.with { $0.section = .headset }.with(change),
                                      .review)
                while review.step != step { review.handle(.next) }
                return try shown(review)
            }
            // The tools are missing: the button is there.
            var hint = try card(.headsetTools, LearningFixture.headsetScanFailed(LearningFixture.wrapperWithoutADB))
            XCTAssertEqual(hint.target, .headsetGetTools)
            XCTAssertEqual(hint.text, "Нажмите «Скачать Android Platform Tools…», затем «Принять и скачать».")
            // Not asked yet, or the question failed: no button, no outline.
            for change in [{ _ in }, LearningFixture.headsetScanFailed(otherError)]
                as [(inout LearningFacts) -> Void] {
                hint = try card(.headsetTools, change)
                XCTAssertNil(hint.target)
                XCTAssertTrue(hint.text.hasPrefix("Кнопка «Скачать Android Platform Tools…» появляется"))
            }
            // The request is unanswered: the card says so.
            XCTAssertEqual(try card(.headsetDebugging, LearningFixture.headset(.unauthorized)).target,
                           .headsetStatus)
            XCTAssertNil(try card(.headsetDebugging, LearningFixture.headset(.connected)).target)
            // Connected without the tested ALVR: the install button is there.
            hint = try card(.headsetInstall, LearningFixture.headset(.connected))
            XCTAssertEqual(hint.target, .headsetInstall)
            XCTAssertTrue(hint.text.hasPrefix("Нажмите «Установить на шлем…», затем «Скачать и установить»."))
            // With the tested ALVR it is not.
            hint = try card(.headsetInstall, LearningFixture.headsetReady)
            XCTAssertNil(hint.target)
            XCTAssertTrue(hint.text.hasPrefix("Кнопка «Установить на шлем…» появляется здесь"))
            // The status card is on the page in every state.
            for change in [LearningFixture.headset(.none), LearningFixture.headsetReady, { _ in }]
                as [(inout LearningFacts) -> Void] {
                XCTAssertEqual(try card(.headsetCable, change).target, .headsetStatus)
            }
        }
    }

    // MARK: - Words

    /// A hint names a control by the control's own text, and Meta's menus
    /// as Meta writes them, in every language.
    func testHeadsetHintsNameControlsByTheirOwnTextInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            func text(_ facts: LearningFacts, at step: Step) throws -> SetupPresentation {
                let tour = try tour(facts, resumeAt: step)
                XCTAssertEqual(tour.step, step, "\(language)")
                return try shown(tour)
            }
            func expect(_ text: String, names keys: L10nKey..., words: String...) {
                for word in keys.map({ L10n.string($0) }) + words {
                    XCTAssertTrue(text.contains(word), "\(language): \(word) in \(text)")
                }
            }
            let missing = onPage.with { $0.headsetChecked = true }
            let tools = try text(missing, at: .headsetTools)
            expect(tools.text, names: .headsetGetTools, .headsetAgreeDownload)
            expect(tools.help?.tips.joined() ?? "", names: .headsetGetTools, .commonDetails)
            expect(try text(onPage.with(LearningFixture.headsetScanFailed(otherError)), at: .headsetTools).text,
                   names: .commonError, .commonDetails)
            // With the opening sentence in front.
            let opening = try shown(try tour(missing))
            XCTAssertTrue(opening.text.hasPrefix(L10n.string(.learningHeadsetIntro)), "\(language)")
            expect(opening.text, names: .headsetGetTools, .headsetAgreeDownload)

            let account = try text(noCable, at: .headsetAccount)
            expect(account.text, words: "Meta", "18")
            expect(account.help?.tips.joined() ?? "", words: "Admin Verification")
            XCTAssertEqual(account.buttons.map(account.title(of:)),
                           [L10n.string(.learningHeadsetOpenMeta), L10n.string(.sheetDone)])
            let developer = try text(noCable, at: .headsetDeveloperMode)
            expect(developer.text, words: "Meta Horizon", "Headset Settings", "Developer Mode")
            expect(developer.help?.tips.joined() ?? "", words: "Developer Mode")
            let cable = try text(noCable, at: .headsetCable)
            expect(cable.text, words: "USB", "Mac")
            expect(cable.help?.tips.joined() ?? "", names: .sidebarHeadset, words: "Developer Mode")
            let debugging = try text(onPage.with(LearningFixture.headset(.unauthorized)), at: .headsetDebugging)
            expect(debugging.text, words: "Allow USB debugging?", "Always allow from this computer", "Allow")
            expect(debugging.help?.tips.joined() ?? "", names: .learningTipAwake,
                   words: "Don't show again", "USB Connection Dialog")

            let install = try text(onPage.with(LearningFixture.headset(.connected)), at: .headsetInstall)
            expect(install.text, names: .headsetInstall, .headsetDownloadInstall)
            XCTAssertFalse(install.text.contains(L10n.string(.headsetReplaceTitle)), "\(language)")
            expect(install.help?.tips.joined() ?? "",
                   names: .headsetInstall, .commonDetails, .headsetClientMissing)
            XCTAssertEqual(install.help?.options.map(install.title(of:)), [L10n.string(.learningSkipStep)])
            expect(try text(onPage.with(LearningFixture.headset(.connected, client: "20.11.0")),
                            at: .headsetInstall).text,
                   names: .headsetInstall, .headsetDownloadInstall, .headsetReplaceTitle, .headsetReplaceAction)
            let last = try text(onPage.with(LearningFixture.headsetReady), at: .headsetOpenALVR)
            expect(last.text, names: .headsetOpenClient, .sheetDone)
            XCTAssertEqual(last.buttons.map(last.title(of:)), [L10n.string(.sheetDone)])

            // Away from the page.
            var away = try tour(noCable, resumeAt: .headsetCable)
            feed(&away) { $0.section = .library }
            let line = try shown(away)
            expect(line.text, names: .sidebarHeadset)
            XCTAssertEqual(line.buttons.map(line.title(of:)),
                           [L10n.string(.learningOpenSection, L10n.string(.sidebarHeadset))])

            // The review's own lines.
            var review = try tour(LearningFixture.returning.with(LearningFixture.headset(.none)), .review)
            XCTAssertEqual(try shown(review).text, L10n.string(.learningHeadsetIntro))
            review.handle(.next)
            expect(try shown(review).text, names: .headsetGetTools)
            while review.step != .headsetInstall { review.handle(.next) }
            expect(try shown(review).text, names: .headsetInstall)
            review.handle(.next)
            XCTAssertEqual(try shown(review).text, L10n.string(.headsetOpenClient), "\(language)")
        }
    }

    /// The hints of the chapter, one by one, in Russian and English: none
    /// is longer than the strip holds. (Every state in all ten languages is
    /// walked in `SetupTourTests`.)
    func testRussianAndEnglishHeadsetHintsFitTheStrip() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        let keys: [L10nKey] = [
            .learningHeadsetIntro, .learningHeadsetToolsChecking, .learningHeadsetAccount,
            .learningHeadsetDeveloperMode, .learningHeadsetCable, .learningHeadsetDebugging,
            .learningHeadsetReviewCable,
        ]
        for language in [AppLanguage.ru, .en] {
            L10n.language = language
            var texts = keys.map { L10n.string($0) }
            let button = L10n.string(.headsetGetTools)
            let tools = L10n.string(.learningHeadsetTools, button, L10n.string(.headsetAgreeDownload))
            let failed = L10n.string(.learningHeadsetToolsFailed,
                                     L10n.string(.commonError), L10n.string(.commonDetails))
            let install = L10n.string(.headsetInstall)
            let download = L10n.string(.headsetDownloadInstall)
            texts += [
                tools, failed,
                L10n.string(.learningTwoSentences, L10n.string(.learningHeadsetIntro), tools),
                L10n.string(.learningTwoSentences, L10n.string(.learningHeadsetIntro), failed),
                L10n.string(.learningTwoSentences, L10n.string(.learningHeadsetIntro),
                            L10n.string(.learningHeadsetToolsChecking)),
                L10n.string(.learningHeadsetInstall, install, download),
                L10n.string(.learningHeadsetInstallReplace, install, download,
                            L10n.string(.headsetReplaceTitle), L10n.string(.headsetReplaceAction)),
                L10n.string(.learningHeadsetOpenALVR, L10n.string(.headsetOpenClient), L10n.string(.sheetDone)),
                L10n.string(.learningHeadsetAway, L10n.string(.sidebarHeadset)),
                L10n.string(.learningHeadsetReviewTools, button),
                L10n.string(.learningHeadsetReviewInstall, install),
            ]
            for text in texts {
                XCTAssertLessThanOrEqual(text.count, SetupTour.hintLimit, "\(language): \(text)")
                XCTAssertFalse(text.contains("%"), "\(language): \(text)")
            }
        }
    }
}
