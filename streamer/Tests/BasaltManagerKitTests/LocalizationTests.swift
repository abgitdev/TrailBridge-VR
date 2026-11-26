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
        // Another language puts the same version, button and page in its own sentence.
        L10n.language = .de
        XCTAssertEqual(L10n.string(.setupEngineDownload, PinnedWine.download.version), "Wine 11.10 laden…")
        XCTAssertEqual(
            L10n.string(.engineDownloadGuidance, L10n.string(.setupEngineDownload, "11.10"),
                        L10n.string(.sidebarSetup)),
            "Wine wurde noch nicht geladen. „Einrichtung“ öffnen und auf „Wine 11.10 laden…“ klicken.")
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
        for language in AppLanguage.allCases {
            // Each table spells its language as the system does: "Deutsch", "日本語".
            let own = language.locale.localizedString(forLanguageCode: language.rawValue)?
                .capitalized(with: language.locale)
            XCTAssertEqual(language.nativeName, own, language.rawValue)
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
        L10n.language = .de
        XCTAssertEqual(L10n.string(.aboutVersion, "0.2.0", "83"), "Version 0.2.0 (Build 83)")
        XCTAssertEqual(L10n.string(.sidebarLibrary), "Bibliothek")
        XCTAssertEqual(L10n.string(.sidebarMissingSteps, Int64(2)), "Fehlende Pflichtschritte: 2")
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
        // Russian and Ukrainian: 1 and 21 take the "one" form, 2 and 22 "few", 5 and 11 "many".
        let categories: [(Int, PluralCategory)] = [
            (1, .one), (2, .few), (5, .many), (11, .many), (21, .one), (22, .few)
        ]
        for language in [AppLanguage.ru, .uk] {
            L10n.language = language
            let forms = LocalizationTables.table(for: language)?.plurals[.libraryGameCount] ?? [:]
            XCTAssertEqual(Set([PluralCategory.one, .few, .many].compactMap { forms[$0] }).count, 3,
                           language.rawValue)
            for (count, category) in categories {
                XCTAssertEqual(L10n.plural(.libraryGameCount, count),
                               String(format: forms[category] ?? "", locale: language.locale, Int64(count)),
                               "\(language.rawValue) \(count)")
            }
        }
        L10n.language = .ru
        let hidden = LocalizationTables.table(for: .ru)?.plurals[.libraryHiddenGames]?[.few] ?? ""
        XCTAssertEqual(L10n.plural(.libraryHiddenGames, 22),
                       String(format: hidden, locale: AppLanguage.ru.locale, Int64(22)))
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
