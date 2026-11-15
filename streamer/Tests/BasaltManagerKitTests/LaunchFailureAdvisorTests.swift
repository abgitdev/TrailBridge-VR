import XCTest
import BasaltCore
@testable import BasaltManagerKit

final class LaunchFailureAdvisorTests: XCTestCase {
    private static let streamerTexts: [(String, LaunchFailureCause)] = [
        (AlvrWiredFailure.adbMissing, .adbMissing),
        (AlvrWiredFailure.debuggingUnauthorized, .debuggingUnauthorized),
        (AlvrWiredFailure.noAuthorizedQuest, .noAuthorizedQuest),
        (AlvrWiredFailure.clientMissing, .clientMissing),
        (AlvrWiredFailure.pausedBehindLockScreen, .pausedBehindLockScreen),
    ]
    private static let appKeys: [(L10nKey, LaunchFailureCause)] = [
        (.modelWaitingHeadset, .waitingForHeadset),
        (.modelSteamNotSignedIn, .steamNotSignedIn),
    ]
    /// A launch over Wi-Fi of a game on the shared stream settings.
    private static let wifi = LaunchFailureContext(connection: .wifi)
    private static let contexts = [
        wifi, LaunchFailureContext(connection: .wired),
        LaunchFailureContext(connection: .wifi, gameWithOwnSettings: "Blood Trail"),
        LaunchFailureContext(connection: .wired, gameWithOwnSettings: "Blood Trail"),
    ]

    func testTheSevenCausesAreExactlyTheKnownOnes() {
        XCTAssertEqual(Set(LaunchFailureCause.allCases),
                       Set(Self.streamerTexts.map(\.1) + Self.appKeys.map(\.1)))
        XCTAssertEqual(LaunchFailureCause.allCases.count, 7)
    }

    func testRecognisesTheStreamerTextsFromTheBasaltCoreConstants() {
        for (text, cause) in Self.streamerTexts {
            XCTAssertEqual(LaunchFailureAdvisor.cause(for: text), cause)
            // The way the app receives it: the streamer wraps the setup error,
            // and the app reads it from the streamer's last "error:" line.
            let line = "Could not start wired ALVR session: \(text)"
            XCTAssertEqual(LaunchFailureAdvisor.cause(for: line), cause)
            let fromLog = StreamerLogFailure.message(in: "Starting…\nerror: \(line)\n")
            XCTAssertEqual(fromLog.flatMap(LaunchFailureAdvisor.cause(for:)), cause)
            for context in Self.contexts {
                let advice = LaunchFailureAdvisor.advice(for: "  \(line)\n", context: context)
                XCTAssertEqual(advice?.cause, cause)
                XCTAssertEqual(advice?.context, context)
            }
        }
    }

    /// The app's own messages are localized when thrown. Whatever language
    /// they were thrown in, and whatever language is shown now, they are found.
    func testRecognisesTheAppTextsInEveryLanguage() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for (key, cause) in Self.appKeys {
            for thrownIn in AppLanguage.allCases {
                L10n.language = thrownIn
                let message = L10n.string(key)
                XCTAssertFalse(message.isEmpty)
                for shownIn in AppLanguage.allCases {
                    L10n.language = shownIn
                    XCTAssertEqual(LaunchFailureAdvisor.cause(for: message), cause,
                                   "\(key) thrown in \(thrownIn), shown in \(shownIn)")
                }
            }
        }
    }

    func testEveryCauseIsRecognisedWhateverTheInterfaceLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in AppLanguage.allCases {
            L10n.language = language
            for (text, cause) in Self.streamerTexts {
                XCTAssertEqual(LaunchFailureAdvisor.cause(for: text), cause, "\(language)")
            }
        }
    }

    func testOtherMessagesGetNoAdvice() {
        let previous = L10n.language
        defer { L10n.language = previous }
        var others = [
            "", "   \n", "error:", "The streamer exited with code 9",
            "adb devices: device offline", "Android tools folder resolves outside the data folder",
            "Could not start wired ALVR session: adb forward: more than one device",
            "Steam", "ALVR", "Quest",
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            others += [
                L10n.string(.modelStreamerExit, "1"),
                L10n.string(.modelStreamerExitedBeforeReady, "1"),
                L10n.string(.modelSteamLogMissing),
                L10n.string(.modelSteamSignInFailure),
                L10n.string(.modelWaitForSessionStop),
                L10n.string(.folderImportPlayBlocked),
                L10n.string(.sessionFailed),
            ]
        }
        for message in others {
            XCTAssertNil(LaunchFailureAdvisor.cause(for: message), message)
            XCTAssertNil(LaunchFailureAdvisor.advice(for: message, context: Self.wifi), message)
        }
    }

    func testEachCauseHasOneAction() {
        let expected: [LaunchFailureCause: LaunchFailureAction] = [
            .waitingForHeadset: .restartQuickPath,
            .adbMissing: .open(.headset),
            .debuggingUnauthorized: .open(.headset),
            .noAuthorizedQuest: .open(.headset),
            .clientMissing: .open(.headset),
            .pausedBehindLockScreen: .restartQuickPath,
            .steamNotSignedIn: .open(.steam),
        ]
        for cause in LaunchFailureCause.allCases {
            for context in Self.contexts {
                let advice = LaunchFailureAdvice(cause: cause, context: context)
                XCTAssertEqual(advice.action, expected[cause], "\(cause)")
                XCTAssertEqual(advice.availableAction(pageSheetOpen: false), expected[cause])
                // Leaving the section would close the open sheet: text only.
                XCTAssertNil(advice.availableAction(pageSheetOpen: true))
            }
        }
    }

    func testRussianAdvice() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        func advice(
            _ cause: LaunchFailureCause, _ connection: StreamConnectionMode = .wifi, ownSettings game: String? = nil
        ) -> LaunchFailureAdvice {
            LaunchFailureAdvice(cause: cause, context: LaunchFailureContext(
                connection: connection, gameWithOwnSettings: game))
        }
        let wifi = L10n.string(.connectionWiFi)

        // The streamer still waits for the headset: by the launch's connection.
        XCTAssertEqual(advice(.waitingForHeadset).title, "Шлем не подключился")
        XCTAssertEqual(advice(.waitingForHeadset, .wifi).text, "Откройте ALVR в шлеме, затем нажмите «Играть».")
        XCTAssertEqual(advice(.waitingForHeadset, .wired).text,
                       "Наденьте шлем и проверьте, что он разблокирован. Затем нажмите «Играть».")
        XCTAssertEqual(advice(.waitingForHeadset, .wired).title, "Шлем не подключился")
        XCTAssertEqual(advice(.waitingForHeadset, .wired, ownSettings: "Blood Trail").text,
                       advice(.waitingForHeadset, .wired).text)

        // No adb: the way to Wi-Fi goes through the settings the game uses.
        XCTAssertEqual(advice(.adbMissing).title, "Нет инструментов USB")
        XCTAssertEqual(advice(.adbMissing, .wired).text,
                       "Откройте раздел «Шлем» и нажмите «Скачать Android Platform Tools…». "
                        + "Или играйте без кабеля: «Настройки» → «Подключение» → «\(wifi)».")
        XCTAssertEqual(advice(.adbMissing, .wired, ownSettings: "Blood Trail").text,
                       "Откройте раздел «Шлем» и нажмите «Скачать Android Platform Tools…». "
                        + "Или играйте без кабеля: «Трансляция» → «Изменить…» → "
                        + "«Настройки трансляции для Blood Trail…» → «Подключение» → «\(wifi)».")
        XCTAssertFalse(advice(.adbMissing, .wired, ownSettings: "Blood Trail").text.contains("«Настройки»"))
        XCTAssertEqual(advice(.debuggingUnauthorized).title, "Отладка по USB не разрешена")
        XCTAssertEqual(advice(.debuggingUnauthorized).text,
                       "Наденьте шлем и разрешите отладку по USB. Если это ваш Mac, отметьте "
                        + "«Всегда разрешать с этого компьютера». Если запроса нет, выньте кабель и вставьте снова.")
        XCTAssertEqual(advice(.noAuthorizedQuest).title, "Шлем по USB не найден")
        XCTAssertEqual(advice(.noAuthorizedQuest).text,
                       "Подключите шлем к этому Mac кабелем USB‑C с передачей данных (не только для зарядки) "
                        + "и включите шлем. Проверьте, что в приложении Meta Horizon на телефоне "
                        + "включён режим разработчика.")
        XCTAssertEqual(advice(.clientMissing).title, "На шлеме нет ALVR")
        XCTAssertEqual(advice(.clientMissing).text, "Откройте раздел «Шлем» и нажмите «Установить на шлем…».")
        XCTAssertEqual(advice(.pausedBehindLockScreen).title, "Шлем заблокирован")
        XCTAssertEqual(advice(.pausedBehindLockScreen).text,
                       "Наденьте шлем и разблокируйте его. Затем нажмите «Играть».")
        XCTAssertEqual(advice(.steamNotSignedIn).title, "Вход в Steam не выполнен")
        XCTAssertEqual(advice(.steamNotSignedIn).text,
                       "Откройте раздел «Steam» и нажмите «Открыть Steam и войти». Войдите в Steam. "
                        + "Затем нажмите «Закрыть Steam». После этого — «Играть».")

        XCTAssertEqual(LaunchFailureAction.open(.headset).title, "Открыть «Шлем»")
        XCTAssertEqual(LaunchFailureAction.open(.steam).title, "Открыть «Steam»")
        XCTAssertEqual(LaunchFailureAction.restartQuickPath.title, "Запустить VR по шагам")
        XCTAssertEqual(L10n.string(.learningHowToFix), "Как исправить")
    }

    /// Advice names a control by the control's own text, in every language.
    func testAdviceNamesControlsWithTheirOwnTextInEveryLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let named: [LaunchFailureCause: [L10nKey]] = [
            .waitingForHeadset: [.libraryPlay],
            .adbMissing: [.sidebarHeadset, .headsetGetTools, .streamConnection, .connectionWiFi],
            .debuggingUnauthorized: [],
            .noAuthorizedQuest: [],
            .clientMissing: [.sidebarHeadset, .headsetInstall],
            .pausedBehindLockScreen: [.libraryPlay],
            .steamNotSignedIn: [.commonSteam, .steamOpenSignIn, .steamClose, .libraryPlay],
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for cause in LaunchFailureCause.allCases {
                for context in Self.contexts {
                    let advice = LaunchFailureAdvice(cause: cause, context: context)
                    XCTAssertFalse(advice.title.isEmpty)
                    XCTAssertFalse(advice.text.contains("%"), "\(language).\(cause)")
                    for key in named[cause] ?? [] {
                        XCTAssertTrue(advice.text.contains(L10n.string(key)), "\(language).\(cause): \(key)")
                    }
                    XCTAssertFalse(advice.action.title.isEmpty)
                }
            }
            XCTAssertEqual(Set(LaunchFailureCause.allCases.map {
                LaunchFailureAdvice(cause: $0, context: Self.wifi).title
            }).count, 7)

            // No adb: the shared settings are reached through "Settings"; a
            // game's own through the Stream page's menu, named as it names itself.
            let shared = LaunchFailureAdvice(cause: .adbMissing, context: LaunchFailureContext(connection: .wired))
            XCTAssertTrue(shared.text.contains(L10n.string(.sidebarSettings)), "\(language)")
            XCTAssertFalse(shared.text.contains(L10n.string(.streamAdjust)), "\(language)")
            let own = LaunchFailureAdvice(cause: .adbMissing, context: LaunchFailureContext(
                connection: .wired, gameWithOwnSettings: "Blood Trail"))
            for name in [L10n.string(.sidebarStream), L10n.string(.streamAdjust),
                         L10n.string(.streamProfileSettings, "Blood Trail")] {
                XCTAssertTrue(own.text.contains(name), "\(language): \(name)")
            }
            XCTAssertNotEqual(own.text, shared.text, "\(language)")

            // Still waiting for the headset: one text per connection.
            XCTAssertNotEqual(
                LaunchFailureAdvice(cause: .waitingForHeadset, context: Self.wifi).text,
                LaunchFailureAdvice(cause: .waitingForHeadset,
                                    context: LaunchFailureContext(connection: .wired)).text, "\(language)")
        }
    }

    func testDestinationsUseTheSidebarNames() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .ru
        XCTAssertEqual(LearningDestination.allCases.map(\.title),
                       ["Подготовка", "Библиотека", "Трансляция", "Steam", "Шлем", "Настройки", "Обучение"])
    }
}
