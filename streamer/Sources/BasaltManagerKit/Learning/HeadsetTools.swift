import Foundation
import BasaltCore

/// Whether this Mac has USB tools the headset can be asked through. One
/// rule for the Headset page, the "Headset" chapter and the Setup check.
public enum HeadsetTools: Equatable, Sendable {
    /// The Headset page has not asked yet: nothing is known.
    case checking
    /// No adb that can run. "Get Android Platform Tools…" is the fix.
    case missing
    /// adb is there, and the question failed for another reason. A download
    /// would not help: the page shows the error instead.
    case failed
    /// adb answered.
    case ready

    /// From what the Headset page's polling last saw: whether it has had an
    /// answer at all, the status it holds, and the error of its last
    /// question.
    public init(checked: Bool, connection: HeadsetStatus.Connection, scanError: String?) {
        if !checked {
            self = .checking
        } else if let scanError {
            // The developer wrapper is an adb that is always found; with no
            // real adb behind it, it fails with this sentence.
            self = scanError.contains(AlvrWiredFailure.adbMissing) ? .missing : .failed
        } else {
            self = connection == .noTools ? .missing : .ready
        }
    }

    /// The adb the app would really run; nil when there is none.
    ///
    /// Under the developer script the adb found first is the wrapper
    /// `scripts/tools/adb`, which is there even when it has nothing to run.
    /// It is then looked through. An adb found anywhere else counts as it is.
    public static func runnableADB(
        repoRoot: URL, dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = AlvrADBExecutableLocator.standardFallbackDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let found = AlvrADBExecutableLocator.find(
            environment: environment, fallbackDirectories: fallbackDirectories,
            dataRoot: dataRoot, fileManager: fileManager) else { return nil }
        let wrapper = repoRoot.appendingPathComponent("scripts/tools/adb")
        guard found.resolvingSymlinksInPath().path == wrapper.resolvingSymlinksInPath().path else {
            return found
        }
        // This mirrors scripts/tools/adb. Its first branch: the developer
        // copy, which it runs only with this Mac's existing adb key.
        let developer = repoRoot.appendingPathComponent(".local/tools/platform-tools/adb")
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        var isDirectory: ObjCBool = false
        if fileManager.isExecutableFile(atPath: developer.path),
           fileManager.fileExists(atPath: home.appendingPathComponent(".android/adbkey").path,
                                  isDirectory: &isDirectory), !isDirectory.boolValue {
            return developer
        }
        // Its second branch: the copy the Headset page downloads.
        let managed = dataRoot.appendingPathComponent("Tools/platform-tools/adb")
        return fileManager.isExecutableFile(atPath: managed.path) ? managed : nil
    }
}
