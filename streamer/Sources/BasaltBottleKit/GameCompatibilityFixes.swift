import Foundation

/// Settings changes particular games need to show correctly through
/// TrailBridge. They run before every launch, because a game update or a
/// Steam file check puts the game's own files back. Before a fix changes a
/// file it keeps that file's current contents next to it as
/// `<name>.basalt-original`, as OpenVR support does for its DLL.
public enum GameCompatibilityFix: String, CaseIterable, Sendable {
    /// VTOL VR (Unity 2020.3) draws both eyes in one pass through OpenVR,
    /// and on Quest setups streamed by ALVR or Virtual Desktop the right eye
    /// stays black. Switching the game's own OpenVR setting to a separate
    /// pass per eye brings the right eye back, through TrailBridge as well.
    case vtolVRSeparateEyePasses

    /// Applies every fix that matches the game in `gameRoot` and returns the
    /// ones that changed a file. A fix whose setting is already right
    /// changes nothing and is not returned.
    public static func apply(inGameRoot gameRoot: URL,
                             fileManager: FileManager = .default) throws -> [GameCompatibilityFix] {
        try allCases.filter { try $0.apply(inGameRoot: gameRoot, fileManager: fileManager) }
    }

    static let originalSuffix = "basalt-original"

    private func apply(inGameRoot root: URL, fileManager: FileManager) throws -> Bool {
        switch self {
        case .vtolVRSeparateEyePasses:
            guard fileManager.fileExists(atPath: root.appendingPathComponent("VTOLVR.exe").path)
            else { return false }
            let settings = root.appendingPathComponent(
                "VTOLVR_Data/StreamingAssets/SteamVR/OpenVRSettings.asset")
            guard fileManager.fileExists(atPath: settings.path) else { return false }
            return try Self.setStereoRenderingModeToMultiPass(in: settings, fileManager: fileManager)
        }
    }

    /// Valve's Unity OpenVR plugin reads `StereoRenderingMode` from this
    /// file: 0 is a separate pass per eye, 1 single-pass instanced. Only the
    /// number on that one line changes; line endings and other lines stay.
    static func setStereoRenderingModeToMultiPass(in settings: URL,
                                                  fileManager: FileManager) throws -> Bool {
        let values = try settings.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw BottleToolError("\(settings.lastPathComponent) is not a regular file")
        }
        let original = try Data(contentsOf: settings)
        guard let text = String(data: original, encoding: .utf8) else { return false }
        let pattern = try NSRegularExpression(
            pattern: #"(?m)^(StereoRenderingMode:[ \t]*)([0-9]+)"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard matches.count == 1, let match = matches.first,
              let valueRange = Range(match.range(at: 2), in: text) else { return false }
        guard text[valueRange] != "0" else { return false }

        var changed = text
        changed.replaceSubrange(valueRange, with: "0")
        let backup = settings.appendingPathExtension(originalSuffix)
        try original.write(to: backup, options: .atomic)
        try Data(changed.utf8).write(to: settings, options: .atomic)
        return true
    }
}
