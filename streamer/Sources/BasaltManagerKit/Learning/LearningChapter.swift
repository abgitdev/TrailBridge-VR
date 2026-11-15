import Foundation

/// A chapter of the Learning program, in the recommended order.
public enum LearningChapter: String, CaseIterable, Codable, Sendable {
    case mac, headset, game, firstLaunch, launchOptions

    public var title: String {
        switch self {
        case .mac: return L10n.string(.learningRowMac)
        case .headset: return L10n.string(.sidebarHeadset)
        case .game: return L10n.string(.streamGame)
        case .firstLaunch: return L10n.string(.learningChapterFirstLaunch)
        case .launchOptions: return L10n.string(.learningChapterOptions)
        }
    }

    /// One phrase: what the chapter is for.
    public var purpose: String {
        switch self {
        case .mac: return L10n.string(.learningWhyMac)
        case .headset: return L10n.string(.learningWhyHeadset)
        case .game: return L10n.string(.learningWhyGame)
        case .firstLaunch: return L10n.string(.learningWhyFirstLaunch)
        case .launchOptions: return L10n.string(.learningWhyOptions, L10n.string(.libraryPlay))
        }
    }
}
