// SPDX-License-Identifier: MIT
import Foundation

/// A file of the app's that turned out not to be readable as what the app
/// writes is never replaced: it is renamed beside itself, to
/// `<name>.damaged-<UTC time>.<extension>`, and a new file is started.
/// `AppFootprint` lists these names, so removing the app removes them too.
public enum DamagedFile {
    static let infix = ".damaged-"

    /// Renames `file` and returns its new place. A rename within one folder:
    /// it works the same on an internal, external or network disk, and the
    /// file's bytes are not read or copied.
    @discardableResult
    public static func setAside(_ file: URL, now: Date = Date(),
                                fileManager: FileManager = .default) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stem = file.deletingPathExtension().lastPathComponent + infix + formatter.string(from: now)
        let folder = file.deletingLastPathComponent()
        for attempt in 1...100 {
            var name = attempt == 1 ? stem : "\(stem)-\(attempt)"
            if !file.pathExtension.isEmpty { name += "." + file.pathExtension }
            let destination = folder.appendingPathComponent(name)
            do {
                // Fails when the name is taken; never replaces another file.
                try fileManager.moveItem(at: file, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Whether `name` is what `setAside` calls a file named `original`.
    public static func isSetAside(_ name: String, of original: String) -> Bool {
        let file = URL(fileURLWithPath: original)
        let prefix = file.deletingPathExtension().lastPathComponent + infix
        let suffix = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        return name.hasPrefix(prefix) && name.hasSuffix(suffix)
            && name.count > prefix.count + suffix.count
    }
}
