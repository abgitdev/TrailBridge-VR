// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Which disk a path is on. A data folder may be on an external or network
/// disk; when that disk leaves, a folder can stay at its mount path (a share
/// or image mounted at a folder of the user's own), and anything created
/// "in the data folder" would then land on the disk underneath, where the
/// returning disk hides it. Comparing this with what was there when the
/// folder was opened tells the two apart.
public struct VolumeIdentity: Equatable, Sendable {
    /// `st_dev`: changes when the same disk is mounted again.
    public let device: Int32
    /// The volume's UUID where the file system has one: the same after the
    /// disk was unplugged and plugged in again.
    public let uuid: String?

    /// The volume of the folder or file at `url`, following links; nil when
    /// nothing is there.
    public static func of(_ url: URL) -> VolumeIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        // A new URL each time: URL keeps the values it has read.
        let uuid = (try? URL(fileURLWithPath: url.path).resourceValues(
            forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return VolumeIdentity(device: info.st_dev, uuid: uuid)
    }

    /// The volume of `url`, or of the nearest folder above it that exists:
    /// where `url` would be created.
    public static func ofNearestExisting(_ url: URL) -> VolumeIdentity? {
        var current = url.standardizedFileURL
        while true {
            if let identity = of(current) { return identity }
            guard current.path != "/" else { return nil }
            current.deleteLastPathComponent()
        }
    }

    public func isSameVolume(as other: VolumeIdentity) -> Bool {
        if let uuid, let otherUUID = other.uuid { return uuid == otherUUID }
        return device == other.device
    }
}

/// A data folder and the disk it was on when the app first saw it there.
public struct OpenedDataFolder: Equatable, Sendable {
    public let folder: URL
    public let volume: VolumeIdentity

    public init(folder: URL, volume: VolumeIdentity) {
        self.folder = folder.standardizedFileURL
        self.volume = volume
    }

    /// The folder is there, on the disk it was opened on.
    public var isStillThere: Bool {
        VolumeIdentity.of(folder).map(volume.isSameVolume(as:)) ?? false
    }

    /// The folder, or the place where it would be created, is on the disk
    /// it was opened on. False once that disk has left, also when a folder
    /// stays at its mount path.
    public var diskIsConnected: Bool {
        VolumeIdentity.ofNearestExisting(folder).map(volume.isSameVolume(as:)) ?? false
    }
}

/// The data folder is not where it was when the app opened it: its disk is
/// not connected, or another disk is at its path. Nothing is created in its
/// place.
public struct DataFolderUnavailable: LocalizedError, Equatable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public var errorDescription: String? {
        "The disk with the data folder is not connected: \(folder.path)"
    }
}

/// Folders the app makes inside its data folder.
public enum ManagedFolder {
    /// Creates `folder` and the folders between it and `root`, one at a time
    /// and never `root` itself: when the data folder's disk has left, this
    /// throws `DataFolderUnavailable` instead of building the path again on
    /// another disk. Each folder is created only after its parent, which
    /// then exists, is seen to resolve inside `root`, so a link on the way
    /// (the data folder may itself be reached through one) is followed
    /// correctly and a link that points out of the data folder is refused
    /// before anything is created behind it. Throws `BottleToolError(outside)`
    /// for a folder that is not inside `root`.
    ///
    /// `folder` must be spelled from the same `root` (as every caller builds
    /// it): the two are compared as written, since `standardizedFileURL`
    /// spells a path under `/private/tmp` or `/private/var` differently
    /// depending on whether it exists yet.
    public static func create(_ folder: URL, inside root: URL, outside: String,
                              fileManager: FileManager = .default) throws {
        let rootParts = components(of: root)
        let parts = components(of: folder)
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            throw BottleToolError(outside)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DataFolderUnavailable(folder: root)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().path
        func isInside(_ url: URL, orIsRoot: Bool) -> Bool {
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(resolvedRoot + "/") || (orIsRoot && path == resolvedRoot)
        }
        var current = URL(fileURLWithPath: "/" + rootParts.joined(separator: "/"), isDirectory: true)
        for part in parts.dropFirst(rootParts.count) {
            guard isInside(current, orIsRoot: true) else { throw BottleToolError(outside) }
            current.appendPathComponent(part, isDirectory: true)
            if fileManager.fileExists(atPath: current.path) { continue }
            do {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                // Made by someone else in the meantime.
            } catch CocoaError.fileNoSuchFile {
                // The parent went away: the disk left between the look and now.
                throw DataFolderUnavailable(folder: root)
            }
        }
        guard isInside(current, orIsRoot: false) else { throw BottleToolError(outside) }
    }

    /// The path's components with `.` and `..` worked out, by the text
    /// alone: the file system is not asked.
    static func components(of url: URL) -> [String] {
        var parts = [String]()
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(String(part))
            }
        }
        return parts
    }
}
