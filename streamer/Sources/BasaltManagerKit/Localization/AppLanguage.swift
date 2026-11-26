import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case en, ru, it, de, es, fr, uk, pl, ko, ja

    /// The language's own name, as its table spells it: "Deutsch", "日本語".
    public var nativeName: String { L10n.string(.languageNativeName, language: self) }

    public var isReviewed: Bool { self == .en || self == .ru }
    public var locale: Locale { Locale(identifier: rawValue) }

    /// Recognizes all declared languages, including those awaiting a table.
    /// Callers choosing a UI default filter identifiers by `available` first.
    public static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let language = AppLanguage(rawValue: code) { return language }
        }
        return .en
    }

    public static var available: [AppLanguage] {
        allCases.filter { LocalizationTables.isComplete($0) }
    }

    public var pluralCategories: Set<PluralCategory> {
        switch self {
        case .ru, .uk, .pl: return [.one, .few, .many]
        case .ko, .ja: return [.other]
        default: return [.one, .other]
        }
    }

    /// CLDR cardinal rules for the integer counts accepted by L10n.plural.
    public func pluralCategory(for count: Int) -> PluralCategory {
        let n = count.magnitude
        switch self {
        case .en, .de, .it, .es: return n == 1 ? .one : .other
        case .fr: return n == 0 || n == 1 ? .one : .other
        case .ru, .uk:
            if n % 10 == 1 && n % 100 != 11 { return .one }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return .few }
            return .many
        case .pl:
            if n == 1 { return .one }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return .few }
            return .many
        case .ko, .ja: return .other
        }
    }
}

public enum PluralCategory: String, CaseIterable, Sendable {
    case one, few, many, other
}
