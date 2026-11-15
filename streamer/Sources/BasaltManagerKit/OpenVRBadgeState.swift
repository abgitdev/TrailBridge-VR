import Foundation
import BasaltBottleKit

public enum OpenVRBadgeState: Equatable, Sendable {
    case installed, needsSetup, none

    public static func inspect(profileName: String, manager: BottleManager) throws -> Self {
        // No game folder means no place to look for OpenVR DLLs. Asking the
        // user to set up OpenVR there would be a false prompt.
        guard try manager.loadProfile(profileName).gameRoot != nil else { return .none }
        let targets = try manager.openVRTargets(profileName: profileName)
        var installed = false
        for target in targets {
            if try manager.isOpenComposite(at: target) { installed = true }
        }
        if installed { return .installed }
        return targets.isEmpty ? .none : .needsSetup
    }
}

public struct OpenVRStatusChip: Equatable, Sendable {
    public enum Tint: Equatable, Sendable { case green, orange }

    public let text: String
    public let tint: Tint
    public let showsCheckmark: Bool
    public let help: String?

    public static func presentation(for state: OpenVRBadgeState?) -> Self {
        switch state {
        case .installed:
            return Self(text: "READY · OPENVR", tint: .green, showsCheckmark: true,
                        help: "OpenVR support is on (OpenComposite installed in the game folder)")
        case .needsSetup:
            return Self(text: "SET UP OPENVR", tint: .orange, showsCheckmark: false,
                        help: "This game uses OpenVR. Click to install OpenVR support.")
        case .some(.none), nil:
            return Self(text: "READY", tint: .green, showsCheckmark: true, help: nil)
        }
    }
}
