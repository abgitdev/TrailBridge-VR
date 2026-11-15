import Foundation

/// A section of the app that Learning can send the user to, or that a step
/// lives in. The app maps it to its own sidebar section.
public enum LearningDestination: String, CaseIterable, Sendable {
    case setup, library, stream, steam, headset, settings, learning

    /// The section's name, from the same key as its sidebar row.
    public var title: String {
        switch self {
        case .setup: return L10n.string(.sidebarSetup)
        case .library: return L10n.string(.sidebarLibrary)
        case .stream: return L10n.string(.sidebarStream)
        case .steam: return L10n.string(.commonSteam)
        case .headset: return L10n.string(.sidebarHeadset)
        case .settings: return L10n.string(.sidebarSettings)
        case .learning: return L10n.string(.learningTitle)
        }
    }
}

/// The app's session state, as far as Learning needs it.
public enum LearningSessionPhase: Equatable, Sendable {
    /// Nothing runs.
    case idle
    /// A VR launch is in progress.
    case starting
    /// The game runs and the stream is live.
    case live
    /// A Windows program (Steam, an installer) holds the session.
    case windowsApp
    case failed(String)

    var isVRSession: Bool { self == .starting || self == .live }
}
