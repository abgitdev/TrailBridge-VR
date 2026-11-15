import XCTest
@testable import BasaltManagerKit

final class LocalizationTests: XCTestCase {
    func testAllLanguagesHaveEveryKey() throws {
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            XCTAssertEqual(Set(table.strings.keys), Set(L10nKey.allCases.filter { !$0.isPlural }), "\(language)")
            XCTAssertEqual(Set(table.plurals.keys), Set(L10nKey.allCases.filter(\.isPlural)), "\(language)")
            for key in L10nKey.allCases {
                if key.isPlural {
                    let forms = try XCTUnwrap(table.plurals[key], "\(language).\(key)")
                    XCTAssertFalse(forms.isEmpty)
                    for value in forms.values {
                        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    let value = try XCTUnwrap(table.strings[key], "\(language).\(key)")
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            XCTAssertTrue(LocalizationTables.isComplete(language))
        }
    }

    /// The Wine download and the Rosetta step: said in every language, with
    /// the product names left as they are and the size as a number.
    func testWineDownloadAndRosettaTextsInEveryLanguage() throws {
        let keys: [L10nKey] = [
            .setupEngineDownload, .setupEngineNotDownloaded, .setupRosetta, .setupRosettaHelp,
            .setupRosettaInstalled, .setupRosettaInstall, .setupRosettaCopy, .wineDownloadTitle,
            .wineDownloadExplanation, .wineDownloadSize, .wineDownloadRelease, .wineDownloadFolder,
            .wineDownloadOtherFolder, .wineDownloadProgress, .wineDownloadStarting,
            .wineDownloadVerifying, .wineDownloadUnpacking, .wineErrorDownload, .wineErrorSource,
            .wineErrorChecksum, .wineErrorArchive, .wineErrorUnpack, .wineErrorSpace,
            .engineDownloadGuidance, .learningMacFixHere, .learningInviteMacSetup,
        ]
        let english = try XCTUnwrap(LocalizationTables.table(for: .en))
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            for key in keys {
                let value = try XCTUnwrap(table.strings[key], "\(language).\(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Translated, except for a bare product name.
                if language != .en, key != .setupRosetta {
                    XCTAssertNotEqual(value, english.strings[key], "\(language).\(key)")
                }
            }
            XCTAssertEqual(table.strings[.setupRosetta], "Rosetta 2", "\(language)")
            XCTAssertTrue(try XCTUnwrap(table.strings[.setupRosettaInstall]).contains("Rosetta 2"), "\(language)")
            // Who makes the Wine build, and where it is published.
            let source = try XCTUnwrap(table.strings[.wineDownloadExplanation])
            for name in ["Wine for macOS builds", "Gcenx", "GitHub", "TrailBridge"] {
                XCTAssertTrue(source.contains(name), "\(language): \(name)")
            }
        }
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(L10n.string(.setupEngineDownload, PinnedWine.download.version), "Download Wine 11.10…")
        XCTAssertEqual(L10n.string(.wineDownloadSize, PinnedWine.archiveSizeText, PinnedWine.unpackedSizeText),
                       "Download: about 190 MB. On disk after unpacking: about 720 MB.")
        XCTAssertEqual(
            L10n.string(.engineDownloadGuidance, L10n.string(.setupEngineDownload, "11.10"),
                        L10n.string(.sidebarSetup)),
            "Wine has not been downloaded yet. Open “Setup” and click “Download Wine 11.10…”.")
        L10n.language = .ru
        XCTAssertEqual(L10n.string(.setupEngineDownload, PinnedWine.download.version), "Скачать Wine 11.10…")
        XCTAssertEqual(
            L10n.string(.engineDownloadGuidance, L10n.string(.setupEngineDownload, "11.10"),
                        L10n.string(.sidebarSetup)),
            "Wine ещё не скачан. Откройте «Подготовка» и нажмите «Скачать Wine 11.10…».")
    }

    /// No text of the Setup page sends a person to build what the app
    /// downloads itself.
    func testRequiredStepsFooterSaysTheAppDownloadsWine() throws {
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            XCTAssertTrue(try XCTUnwrap(table.strings[.setupRequiredHelp]).contains("Wine"), "\(language)")
        }
    }

    func testAvailableContainsOnlyCompleteTables() {
        XCTAssertEqual(AppLanguage.available, [.en, .ru, .it, .de, .es, .fr, .uk, .pl, .ko, .ja])
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.available.contains(language), LocalizationTables.isComplete(language))
        }
    }

    func testPlaceholdersMatchEnglishIncludingEveryPluralForm() throws {
        let english = try XCTUnwrap(LocalizationTables.table(for: .en))
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            for key in L10nKey.allCases {
                let reference = try XCTUnwrap(key.isPlural ? english.plurals[key]?[.other] : english.strings[key])
                let values = key.isPlural ? Array(table.plurals[key, default: [:]].values)
                    : [try XCTUnwrap(table.strings[key])]
                for value in values {
                    XCTAssertEqual(try placeholders(value), try placeholders(reference), "\(language).\(key)")
                    XCTAssertEqual(value.components(separatedBy: "%%").count,
                                   reference.components(separatedBy: "%%").count, "\(language).\(key)")
                }
            }
        }
    }

    private func placeholders(_ format: String) throws -> [String] {
        // Preserve the entire placeholder, including position, type, precision
        // and padding. Reject non-positional placeholders.
        let regex = try NSRegularExpression(pattern: #"%([1-9][0-9]*)\$[-+ #0]*[0-9]*(?:\.[0-9]+)?(lld|llu|ld|lu|d|u|f|g|@)"#)
        let value = format.replacingOccurrences(of: "%%", with: "")
        let text = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(matches.count, value.filter { $0 == "%" }.count, format)
        return matches.map { text.substring(with: $0.range) }.sorted()
    }

    func testPluralTablesHaveEveryRequiredCategory() throws {
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            for key in L10nKey.allCases where key.isPlural {
                let forms = try XCTUnwrap(table.plurals[key])
                XCTAssertTrue(language.pluralCategories.isSubset(of: Set(forms.keys)), "\(language).\(key)")
                // Reviewed tables predate the integer-only category set and
                // may retain extra forms. New translations must match exactly.
                if !language.isReviewed {
                    XCTAssertEqual(Set(forms.keys), language.pluralCategories, "\(language).\(key)")
                }
            }
        }
    }

    func testNewTranslationsPreserveEllipsesAndShortcuts() throws {
        let english = try XCTUnwrap(LocalizationTables.table(for: .en))
        for language in AppLanguage.allCases where !language.isReviewed {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            for key in L10nKey.allCases where !key.isPlural {
                let reference = try XCTUnwrap(english.strings[key])
                let value = try XCTUnwrap(table.strings[key])
                for token in ["…", "⌘R", "⇧⌘N", "⌘."] {
                    XCTAssertEqual(value.components(separatedBy: token).count,
                                   reference.components(separatedBy: token).count, "\(language).\(key): \(token)")
                }
            }
        }
    }

    func testEveryLanguageProvidesTwelveMonthNames() throws {
        for language in AppLanguage.allCases {
            let table = try XCTUnwrap(LocalizationTables.table(for: language))
            let months = try XCTUnwrap(table.strings[.streamHistoryMonths]).components(separatedBy: "|")
            XCTAssertEqual(months.count, 12, "\(language)")
            XCTAssertFalse(months.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }), "\(language)")
        }
    }

    func testRussianAndUkrainianCardinalRules() {
        let cases: [(Int, PluralCategory)] = [
            (1, .one), (2, .few), (5, .many), (11, .many), (12, .many),
            (14, .many), (21, .one), (22, .few), (25, .many), (111, .many)
        ]
        for language in [AppLanguage.ru, .uk] {
            for (count, category) in cases {
                XCTAssertEqual(language.pluralCategory(for: count), category, "\(language): \(count)")
            }
        }
    }

    func testPolishCardinalRules() {
        for (count, category): (Int, PluralCategory) in [
            (0, .many), (1, .one), (2, .few), (5, .many), (11, .many), (12, .many),
            (21, .many), (22, .few), (25, .many), (101, .many), (102, .few), (112, .many)
        ] {
            XCTAssertEqual(AppLanguage.pl.pluralCategory(for: count), category, "\(count)")
        }
    }

    func testEnglishGermanItalianAndSpanishCardinalRules() {
        for language in [AppLanguage.en, .de, .it, .es] {
            for (count, category): (Int, PluralCategory) in [(0, .other), (1, .one), (2, .other)] {
                XCTAssertEqual(language.pluralCategory(for: count), category, "\(language): \(count)")
            }
        }
    }

    func testFrenchCardinalRules() {
        XCTAssertEqual(AppLanguage.fr.pluralCategory(for: 0), .one)
        XCTAssertEqual(AppLanguage.fr.pluralCategory(for: 1), .one)
        XCTAssertEqual(AppLanguage.fr.pluralCategory(for: 2), .other)
    }

    func testJapaneseAndKoreanCardinalRules() {
        for language in [AppLanguage.ja, .ko] {
            for count in [1, 5] { XCTAssertEqual(language.pluralCategory(for: count), .other) }
        }
    }

    func testNegativeCountsAndMinimumIntDoNotOverflow() {
        XCTAssertEqual(AppLanguage.ru.pluralCategory(for: -22), .few)
        XCTAssertEqual(AppLanguage.en.pluralCategory(for: -1), .one)
        for language in AppLanguage.allCases {
            XCTAssertTrue(language.pluralCategories.contains(language.pluralCategory(for: Int.min)))
        }
    }

    func testPreferredLanguageIdentifiers() {
        XCTAssertEqual(AppLanguage.preferred(from: ["ru-RU"]), .ru)
        XCTAssertEqual(AppLanguage.preferred(from: ["uk"]), .uk)
        XCTAssertEqual(AppLanguage.preferred(from: ["uk-UA"]), .uk)
        XCTAssertEqual(AppLanguage.preferred(from: ["pt-BR"]), .en)
        XCTAssertEqual(AppLanguage.preferred(from: []), .en)
        XCTAssertEqual(AppLanguage.preferred(from: ["de-AT", "ru"]), .de)
        XCTAssertEqual(AppLanguage.preferred(from: ["pt-BR", "ru_RU"]), .ru)
        XCTAssertEqual(AppLanguage.preferred(from: [""]), .en)
    }

    func testLanguageMetadata() {
        XCTAssertEqual(AppLanguage.allCases.map(\.nativeName), [
            "English", "Русский", "Italiano", "Deutsch", "Español", "Français", "Українська", "Polski", "한국어", "日本語"
        ])
        for language in AppLanguage.allCases {
            XCTAssertEqual(language.isReviewed, language == .en || language == .ru)
            XCTAssertEqual(language.locale.language.languageCode?.identifier, language.rawValue)
        }
    }

    func testStringFormattingSwitchesImmediately() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(L10n.string(.aboutVersion, "0.2.0", "83"), "Version 0.2.0 (build 83)")
        XCTAssertEqual(L10n.string(.librarySearchEmpty, "100%"), "No results for “100%”")
        L10n.language = .ru
        XCTAssertEqual(L10n.string(.aboutVersion, "0.2.0", "83"), "Версия 0.2.0 (сборка 83)")
        XCTAssertEqual(L10n.string(.sidebarLibrary), "Библиотека")
        XCTAssertEqual(L10n.string(.sidebarMissingSteps, Int64(2)), "Не хватает обязательных пунктов: 2")
        L10n.language = .ko
        XCTAssertEqual(L10n.string(.setupProgress, Int64(2), Int64(5)), "5개 중 2개 준비됨")
        L10n.language = .ja
        XCTAssertEqual(L10n.string(.setupProgress, Int64(2), Int64(5)), "5項目中2項目完了")
    }

    func testPluralLookupAndCountSubstitution() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(L10n.plural(.libraryGameCount, 0), "0 games")
        XCTAssertEqual(L10n.plural(.libraryGameCount, 1), "1 game")
        XCTAssertEqual(L10n.plural(.libraryGameCount, 2), "2 games")
        L10n.language = .ru
        for (count, noun) in [(1, "игра"), (2, "игры"), (5, "игр"), (11, "игр"), (21, "игра"), (22, "игры")] {
            XCTAssertEqual(L10n.plural(.libraryGameCount, count), "\(count) \(noun)")
        }
        XCTAssertEqual(L10n.plural(.libraryHiddenGames, 22), "22 игры Steam скрыты фильтром «Только VR-игры»")
        L10n.language = .uk
        for (count, noun) in [(1, "гра"), (2, "гри"), (5, "ігор"), (11, "ігор"), (21, "гра"), (22, "гри")] {
            XCTAssertEqual(L10n.plural(.libraryGameCount, count), "\(count) \(noun)")
        }
        L10n.language = .pl
        for (count, noun) in [(1, "gra"), (2, "gry"), (5, "gier"), (11, "gier"), (21, "gier"), (22, "gry")] {
            XCTAssertEqual(L10n.plural(.libraryGameCount, count), "\(count) \(noun)")
        }
        L10n.language = .ko
        XCTAssertEqual(L10n.plural(.libraryGameCount, 22), "게임 22개")
        L10n.language = .ja
        XCTAssertEqual(L10n.plural(.libraryGameCount, 22), "22本のゲーム")
    }
}
