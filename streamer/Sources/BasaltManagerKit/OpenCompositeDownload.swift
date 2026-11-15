import Foundation
import CryptoKit
import BasaltBottleKit

public struct OpenCompositeArtifact: Equatable, Sendable {
    public let file: URL
    public let size: Int
    public let sha256: String

    public init(file: URL, data: Data) {
        self.file = file
        size = data.count
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum OpenCompositeDownload {
    public static func officialURL(for architecture: OpenCompositeArchitecture) -> URL {
        URL(string: "https://znix.xyz/OpenComposite/download.php?arch=\(architecture.rawValue)&branch=openxr")!
    }

    /// The builds TrailBridge was checked with: branch openxr, commit
    /// a27e7e6a64bd (30 May 2025). The site serves only its newest build, so
    /// any other file is a new release nobody has run in a headset yet.
    public static let testedSHA256: [OpenCompositeArchitecture: String] = [
        .x64: "827ad85f3606a4dc4a8f5561a8ca69e4c6c1b5d2b9cd3315a461b9270b08242c",
        .x86: "096095dc592d606d7e085cc5780fac342d4a84174acb0d55a56f40b70e080a18",
    ]

    public static func isTested(_ data: Data, architecture: OpenCompositeArchitecture) -> Bool {
        OpenCompositeArtifact(file: URL(fileURLWithPath: "/"), data: data).sha256
            == testedSHA256[architecture]
    }

    public static func cacheFile(architecture: OpenCompositeArchitecture, dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL
            .appendingPathComponent("Downloads/OpenComposite/\(architecture.rawValue)/openvr_api.dll")
    }

    /// Call only after the user accepts the separate-project download sheet.
    /// A cached copy of the tested build is used without going online. An
    /// ephemeral session avoids URL caches outside the selected data root.
    public static func download(architecture: OpenCompositeArchitecture,
                                dataRoot: URL) async throws -> OpenCompositeArtifact {
        let cached = cacheFile(architecture: architecture, dataRoot: dataRoot)
        if let data = try? Data(contentsOf: cached), isTested(data, architecture: architecture) {
            return OpenCompositeArtifact(file: cached, data: data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: officialURL(for: architecture))
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), response.url?.scheme == "https" else {
            throw BottleToolError("The official OpenComposite download failed")
        }
        guard try OpenCompositeArchitecture.dllArchitecture(in: data) == architecture else {
            throw BottleToolError("The downloaded OpenComposite DLL has the wrong architecture")
        }
        // The file below is the shared cache. A DLL that installation would
        // reject must not replace a good cached copy.
        guard OpenCompositeContent.isOpenComposite(data) else {
            throw BottleToolError("The downloaded file is not an OpenComposite DLL")
        }
        // Pinned: a newer upstream build must not reach working games unseen.
        guard isTested(data, architecture: architecture) else {
            let hash = OpenCompositeArtifact(file: URL(fileURLWithPath: "/"), data: data).sha256
            throw BottleToolError(L10n.string(.openVRUntestedBuild, String(hash.prefix(12)),
                                              L10n.string(.openVRChooseFile)))
        }
        let root = dataRoot.standardizedFileURL
        let file = cacheFile(architecture: architecture, dataRoot: dataRoot)
        let directory = file.deletingLastPathComponent()
        // Only components we create below the data root are checked; the root
        // itself may legitimately sit behind a system link such as /var.
        var component = file
        while component.path.hasPrefix(root.path + "/") {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw BottleToolError("OpenComposite download paths must not contain symbolic links")
            }
            component.deleteLastPathComponent()
        }
        // Inside the data folder only: one whose disk left while the file
        // was downloading is not built again on another disk.
        try ManagedFolder.create(
            directory, inside: root,
            outside: "OpenComposite download paths must not contain symbolic links")
        try data.write(to: file, options: .atomic)
        return OpenCompositeArtifact(file: file, data: data)
    }
}
