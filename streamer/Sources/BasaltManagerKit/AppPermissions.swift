// SPDX-License-Identifier: MIT
import Foundation

/// The privacy permissions macOS keeps for the app: system audio recording,
/// the microphone (BlackHole), removable and network disks, and the like.
/// Removing the app resets them with `tccutil`, which finds an app by its
/// bundle identifier only while the app is still on disk, so this runs
/// before the app moves itself to the Trash. The Local Network permission
/// is not among them: macOS gives an app no way to withdraw it.
public enum AppPermissions {
    static let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")

    /// The arguments for resetting every permission of `bundleIdentifier`;
    /// nil for a value that is not a plain bundle identifier.
    static func resetArguments(bundleIdentifier: String) -> [String]? {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              !bundleIdentifier.hasPrefix("-"), !bundleIdentifier.hasPrefix("."),
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return ["reset", "All", bundleIdentifier]
    }

    /// Whether `tccutil` reported success within `timeout`. A failure does
    /// not stop the removal: the files are gone by then either way.
    @discardableResult
    public static func reset(bundleIdentifier: String, timeout: TimeInterval = 5) -> Bool {
        guard let arguments = resetArguments(bundleIdentifier: bundleIdentifier) else { return false }
        let process = Process()
        process.executableURL = tccutil
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        guard !process.isRunning else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
