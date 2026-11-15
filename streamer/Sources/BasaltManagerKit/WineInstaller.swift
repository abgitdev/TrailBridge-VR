import Foundation
import BasaltBottleKit

/// The Wine the app downloads on request: the same build
/// runtime/scripts/test-dxmt.zsh pins for a source checkout.
public enum PinnedWine {
    public static let download = PinnedHeadsetDownload(
        version: "11.10",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/wine-devel-11.10-osx64.tar.xz")!,
        checksum: "6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b",
        digest: .sha256)
    /// The archive's exact size.
    public static let archiveBytes: Int64 = 188_035_604
    /// What it takes on disk once unpacked, roughly.
    public static let unpackedBytes: Int64 = 720_000_000
    /// The release the archive belongs to, for people to look at.
    public static let releasePage = URL(
        string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.10")!

    /// The archive's size as the app shows it, in the app's language.
    public static var archiveSizeText: String { sizeText(archiveBytes) }
    public static var unpackedSizeText: String { sizeText(unpackedBytes) }

    /// A size rounded to tens of megabytes: "about 190 MB".
    static func sizeText(_ bytes: Int64) -> String {
        let rounded = (bytes + 5_000_000) / 10_000_000 * 10_000_000
        return rounded.formatted(.byteCount(style: .file).locale(L10n.language.locale))
    }
}

public enum WineInstallError: LocalizedError, Equatable {
    /// The download did not finish.
    case downloadFailed
    /// The download ended somewhere other than the pinned source.
    case unexpectedSource
    /// The file is not the pinned one.
    case checksumMismatch
    /// The archive unpacked, and Wine's files are not in it.
    case incompleteArchive
    /// `tar` failed; its own words.
    case unpackFailed(String)
    case notEnoughSpace(needed: Int64, free: Int64)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed: return L10n.string(.wineErrorDownload)
        case .unexpectedSource: return L10n.string(.wineErrorSource)
        case .checksumMismatch: return L10n.string(.wineErrorChecksum)
        case .incompleteArchive: return L10n.string(.wineErrorArchive)
        case .unpackFailed(let detail): return L10n.string(.wineErrorUnpack, detail)
        case .notEnoughSpace(let needed, let free):
            let locale = L10n.language.locale
            return L10n.string(.wineErrorSpace,
                               needed.formatted(.byteCount(style: .file).locale(locale)),
                               free.formatted(.byteCount(style: .file).locale(locale)))
        }
    }
}

/// Downloads the pinned Wine into the data folder and unpacks it where
/// `BottleEngineDiscovery` finds it: `<data>/Tools/wine-11.10`.
///
/// The archive is in `<data>/Downloads` only while this runs, and the files
/// are unpacked into a hidden folder beside their final place. Both are
/// removed when this ends, however it ends. Nothing else is written, and
/// no attribute of the unpacked files is changed.
public struct WineInstaller: @unchecked Sendable {
    public enum Stage: Equatable, Sendable {
        /// Bytes received, and the total when the server says it.
        case downloading(received: Int64, total: Int64?)
        case verifying
        case unpacking
    }

    public enum Outcome: Equatable, Sendable {
        case installed
        /// A usable Wine was there already; nothing was downloaded.
        case alreadyInstalled
    }

    /// Fetches `url` into the file and returns the address the download
    /// ended at, reporting bytes received and the expected total.
    public typealias Fetch = @Sendable (
        _ url: URL, _ file: URL, _ progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL

    public let dataRoot: URL
    private let pin: PinnedHeadsetDownload
    private let requiredBytes: Int64
    private let freeBytes: @Sendable (URL) -> Int64?
    private let fileManager: FileManager

    /// `freeBytes` says how much room the folder's disk has; nil when it
    /// does not say, which is not a reason to refuse.
    public init(dataRoot: URL,
                pin: PinnedHeadsetDownload = PinnedWine.download,
                requiredBytes: Int64 = PinnedWine.archiveBytes + PinnedWine.unpackedBytes,
                freeBytes: @escaping @Sendable (URL) -> Int64? = { WineInstaller.freeBytes(in: $0) },
                fileManager: FileManager = .default) {
        self.dataRoot = dataRoot
        self.pin = pin
        self.requiredBytes = requiredBytes
        self.freeBytes = freeBytes
        self.fileManager = fileManager
    }

    /// `<data>/Tools/wine-11.10`.
    public var installFolder: URL {
        dataRoot.appendingPathComponent(BottleEngineDiscovery.downloadedWineFolder, isDirectory: true)
    }

    /// The folder the archive is unpacked into before it is moved in place.
    public var partialFolder: URL {
        installFolder.deletingLastPathComponent().appendingPathComponent(
            "." + installFolder.lastPathComponent + ".partial", isDirectory: true)
    }

    /// The archive while it is downloaded and unpacked.
    public var archiveFile: URL {
        dataRoot.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(pin.url.lastPathComponent)
    }

    public var isInstalled: Bool {
        BottleEngineDiscovery.isUsablePinnedWine(
            BottleEngineDiscovery.downloadedWineRoot(dataRoot: dataRoot), fileManager: fileManager)
    }

    /// Removes the archive and the partly unpacked files, if either is there.
    public func removeLeftovers() {
        for url in [archiveFile, partialFolder] where exists(url) {
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    public func install(fetch: Fetch? = nil,
                        progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> Outcome {
        if isInstalled { return .alreadyInstalled }
        let downloads = try HeadsetSetup.directory("Downloads", in: dataRoot)
        let tools = try HeadsetSetup.directory("Tools", in: dataRoot)
        // What an earlier run that was killed left behind.
        removeLeftovers()
        defer { removeLeftovers() }
        if let free = freeBytes(dataRoot), free < requiredBytes {
            throw WineInstallError.notEnoughSpace(needed: requiredBytes, free: free)
        }

        let archive = downloads.appendingPathComponent(pin.url.lastPathComponent)
        progress(.downloading(received: 0, total: nil))
        let finalURL: URL
        do {
            finalURL = try await (fetch ?? StreamedDownload.fetch)(pin.url, archive) { received, total in
                progress(.downloading(received: received, total: total))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A file that could not be written says why in the system's
            // words; anything the network did is one plain sentence.
            throw error is URLError ? WineInstallError.downloadFailed : error
        }
        try Task.checkCancellation()
        guard pin.isTrustedSource(finalURL) else { throw WineInstallError.unexpectedSource }
        progress(.verifying)
        guard !isSymbolicLink(archive), try pin.matches(fileAt: archive) else {
            throw WineInstallError.checksumMismatch
        }
        try Task.checkCancellation()

        progress(.unpacking)
        let partial = tools.appendingPathComponent(partialFolder.lastPathComponent, isDirectory: true)
        try ManagedFolder.create(partial, inside: dataRoot, outside: HeadsetSetup.outsideDataFolder,
                                 fileManager: fileManager)
        let result = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                        ["-xJf", archive.path, "-C", partial.path])
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw WineInstallError.unpackFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard BottleEngineDiscovery.isUsablePinnedWine(
            partial.appendingPathComponent(BottleEngineDiscovery.wineRootInBundle, isDirectory: true),
            fileManager: fileManager) else {
            throw WineInstallError.incompleteArchive
        }
        // Only an unusable folder can be in the way: a usable one ended
        // this at its first line.
        let target = tools.appendingPathComponent(installFolder.lastPathComponent, isDirectory: true)
        if exists(target) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: partial, to: target)
        return .installed
    }

    /// The room macOS can make on the folder's disk for something the
    /// person asked for.
    public static func freeBytes(in folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Runs a tool to its end; cancelling the task stops the tool.
    private static func run(_ executable: URL,
                            _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stop = ProcessStop(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try stop.start()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (
                        process.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }
        } onCancel: {
            stop.cancel()
        }
    }
}

/// Stops a process when its task is cancelled, also when the cancellation
/// comes before the process has started.
private final class ProcessStop: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var started = false
    private var cancelled = false

    init(_ process: Process) { self.process = process }

    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
            started = true
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started, process.isRunning { process.terminate() }
        }
    }
}

/// A download written to its file as it arrives, so that an archive of any
/// size is never held in memory. Nothing is cached, and no cookie or
/// credential is kept or sent.
final class StreamedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    // Touched only on the session's serial delegate queue.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var finalURL: URL?
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<URL, Error>?
    /// How the load ended; it may end before anyone waits for it.
    private var finished: Result<URL, Error>?

    init(file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.file = file
        self.progress = progress
    }

    /// Waits for the load's end and starts the load. A load cancelled
    /// before this ran has ended already and is never started: its end is
    /// what the waiter gets. On the delegate queue, like the end itself.
    func begin(_ continuation: CheckedContinuation<URL, Error>, start: () -> Void) {
        if let finished {
            continuation.resume(with: finished)
        } else {
            self.continuation = continuation
            start()
        }
    }

    /// The load's end, for whoever waits for it now or begins to later.
    /// A load ends once; the session cancelling it again changes nothing.
    func finish(error: Error?) {
        guard finished == nil else { return }
        try? handle?.close()
        handle = nil
        let result: Result<URL, Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let finalURL {
            progress(received, expected)
            result = .success(finalURL)
        } else {
            result = .failure(WineInstallError.downloadFailed)
        }
        finished = result
        continuation?.resume(with: result)
        continuation = nil
    }

    static let fetch: WineInstaller.Fetch = { url, file, progress in
        try await fetch(url, to: file, progress: progress)
    }

    /// `protocolClasses` lets a test answer in place of the network.
    static func fetch(_ url: URL, to file: URL,
                      progress: @escaping @Sendable (Int64, Int64?) -> Void,
                      protocolClasses: [AnyClass]? = nil) async throws -> URL {
        try Task.checkCancellation()
        let download = StreamedDownload(file: file, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    download.begin(continuation) { task.resume() }
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url else {
            failure = WineInstallError.downloadFailed
            completionHandler(.cancel)
            return
        }
        do {
            // Never through a link, and never over an older file.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
                || FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: file)
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        finalURL = url
        expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            // Often enough for a progress bar, and no more.
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 {
                lastReport = now
                progress(received, expected)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }
}

/// Rosetta 2, which runs the Intel code of Wine and of Windows games.
public enum Rosetta {
    /// What installs it, for the person to run in Terminal.
    public static let installCommand = "softwareupdate --install-rosetta --agree-to-license"

    /// Whether this Mac runs Intel code. macOS keeps Rosetta's files in
    /// different places in different versions, so the check runs a tiny
    /// Intel program, as `arch -x86_64` does in Terminal, instead of
    /// looking for a file.
    public static func isInstalled(runsIntelCode: () -> Bool = runsIntelCode) -> Bool {
        runsIntelCode()
    }

    /// `/usr/bin/arch -x86_64 /usr/bin/true`: without Rosetta it fails at
    /// once, with no window.
    public static func runsIntelCode() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
