import Foundation

/// Whether Wine's system video framework is installed, with the version when readable.
public enum GStreamerInstallation: Equatable, Sendable {
    case missing
    case installed(version: String?)

    public static let systemFramework = URL(
        fileURLWithPath: "/Library/Frameworks/GStreamer.framework", isDirectory: true)

    /// Checks for the framework and reads its version from the local bundle metadata.
    public static func detect(frameworkURL: URL = systemFramework,
                              fileManager: FileManager = .default) -> Self {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: frameworkURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .missing }

        // The versioned directory can be named "1.0" even for a newer release.
        // Read package metadata instead of inferring the version from that name.
        for path in ["Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"] {
            guard let data = fileManager.contents(atPath: frameworkURL.appendingPathComponent(path).path),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let version = (info as? [String: Any])?["CFBundleShortVersionString"] as? String
            else { continue }
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .installed(version: trimmed) }
        }
        return .installed(version: nil)
    }
}
