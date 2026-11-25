import Foundation

/// One table file per language; register it in `LocalizationTables.table(for:)`.
protocol LocalizationTable: AnyObject {
    static var strings: [L10nKey: String] { get }
    static var plurals: [L10nKey: [PluralCategory: String]] { get }
}

enum LocalizationTables {
    static func table(for language: AppLanguage) -> LocalizationTable.Type? {
        switch language {
        case .en: return StringsEN.self
        case .ru: return StringsRU.self
        case .it: return StringsIT.self
        case .de: return StringsDE.self
        case .es: return StringsES.self
        case .fr: return StringsFR.self
        case .uk: return StringsUK.self
        case .pl: return StringsPL.self
        case .ko: return StringsKO.self
        case .ja: return StringsJA.self
        }
    }

    static func isComplete(_ language: AppLanguage) -> Bool {
        guard let table = table(for: language) else { return false }
        return L10nKey.allCases.allSatisfy { key in
            if key.isPlural {
                return language.pluralCategories.allSatisfy {
                    !(table.plurals[key]?[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
            return !(table.strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

public enum L10n {
    // Views and AppKit set this on the main actor. Locked access also makes
    // formatting safe for callers outside SwiftUI, with one snapshot per lookup.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage.en
    }
    private static let state = State()

    public static var language: AppLanguage {
        get { state.lock.withLock { state.language } }
        set { state.lock.withLock { state.language = newValue } }
    }

    public static func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        string(key, arguments: args)
    }

    /// Array overload for forwarding arguments from an app's short helper.
    public static func string(_ key: L10nKey, arguments: [CVarArg]) -> String {
        string(key, language: language, arguments: arguments)
    }

    static func string(_ key: L10nKey, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        let value = LocalizationTables.table(for: language)?.strings[key]
        #if DEBUG
        if value == nil { assertionFailure("Missing localization: \(language.rawValue).\(key.rawValue)") }
        #endif
        let format = value ?? StringsEN.strings[key] ?? key.rawValue
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    public static func plural(_ key: L10nKey, _ count: Int) -> String {
        let language = language
        let value = LocalizationTables.table(for: language)?.plurals[key]?[language.pluralCategory(for: count)]
        #if DEBUG
        if value == nil { assertionFailure("Missing plural: \(language.rawValue).\(key.rawValue)") }
        #endif
        let format = value ?? StringsEN.plurals[key]?[AppLanguage.en.pluralCategory(for: count)] ?? key.rawValue
        return String(format: format, locale: language.locale, arguments: [Int64(count)])
    }
}
