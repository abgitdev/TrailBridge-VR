// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import BasaltBottleKit
@testable import BasaltCore
@testable import BasaltManagerKit

/// A data folder that was there and is not any more (its disk left) is
/// never created again, and nothing is created inside a data folder that is
/// not there. With a real disk that is detached, see `DataFolderDiskGoneTests`.
final class DataFolderGuardTests: XCTestCase {
    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Every `refresh()` prepares the data folder; that used to build an
    /// empty one wherever the path pointed after the disk had left.
    func testADataFolderThatWasThereIsNeverCreatedAgain() throws {
        let scratch = try dataFolderScratch()
        let root = scratch.appendingPathComponent("mount/TrailBridge Data", isDirectory: true)
        let manager = BottleManager(root: root, repoRoot: scratch)
        XCTAssertNil(manager.openedDataFolder)
        // A first start: the folder is made, with its two folders.
        try manager.prepare()
        XCTAssertEqual(contents(root), ["Bottles", "Profiles"])
        XCTAssertEqual(manager.openedDataFolder?.isStillThere, true)
        try manager.prepare()

        // The disk leaves: the mount folder stays, empty.
        try FileManager.default.removeItem(at: root)
        for operation in [{ try manager.prepare() },
                          { try manager.saveProfile(LaunchProfile(name: "game", bottleName: "env", source: .direct, executable: "a.exe")) },
                          { _ = try manager.createBottle(name: "env", engineID: "any") }] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? DataFolderUnavailable, DataFolderUnavailable(folder: root))
            }
        }
        XCTAssertEqual(contents(root.deletingLastPathComponent()), [], "nothing was built where the disk was")
        XCTAssertEqual(manager.openedDataFolder?.isStillThere, false)

        // Only the two folders inside are ever made again.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.prepare()
        XCTAssertEqual(contents(root), ["Bottles", "Profiles"])
    }

    /// The app passes this for every folder it found in place: a chosen
    /// one, a saved one. Only the default folder is made at a first start.
    func testAManagerForAFolderFoundInPlaceNeverCreatesIt() throws {
        let scratch = try dataFolderScratch()
        let root = scratch.appendingPathComponent("mount/TrailBridge Data", isDirectory: true)
        let manager = BottleManager(root: root, repoRoot: scratch, createsDataFolder: false)
        XCTAssertThrowsError(try manager.prepare()) { XCTAssertTrue($0 is DataFolderUnavailable) }
        XCTAssertEqual(contents(scratch), [])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.prepare()
        XCTAssertEqual(contents(root), ["Bottles", "Profiles"])
    }

    func testFoldersInsideTheDataFolderAreNeverMadeWithoutIt() throws {
        let scratch = try dataFolderScratch()
        let root = scratch.appendingPathComponent("mount/TrailBridge Data", isDirectory: true)
        for relative in ["Tools/Android", "Downloads", "Tools"] {
            XCTAssertThrowsError(try HeadsetSetup.directory(relative, in: root), relative) { error in
                XCTAssertEqual(error as? DataFolderUnavailable, DataFolderUnavailable(folder: root))
            }
        }
        XCTAssertEqual(contents(scratch), [])

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(try HeadsetSetup.directory("Tools/Android", in: root).path,
                       root.appendingPathComponent("Tools/Android").path)
        XCTAssertEqual(try HeadsetSetup.directory("Tools/Android", in: root).path,
                       root.appendingPathComponent("Tools/Android").path, "and again, when it is there")
        XCTAssertEqual(contents(root.appendingPathComponent("Tools")), ["Android"])
        XCTAssertThrowsError(try HeadsetSetup.directory("../beside", in: root))
        XCTAssertEqual(contents(scratch.appendingPathComponent("mount")), ["TrailBridge Data"])
    }

    func testVolumesAreToldApart() throws {
        let scratch = try dataFolderScratch()
        let here = try XCTUnwrap(VolumeIdentity.of(scratch))
        // devfs is another volume on every Mac.
        let other = try XCTUnwrap(VolumeIdentity.of(URL(fileURLWithPath: "/dev")))
        XCTAssertTrue(here.isSameVolume(as: try XCTUnwrap(VolumeIdentity.of(scratch.deletingLastPathComponent()))))
        XCTAssertFalse(here.isSameVolume(as: other))
        let missing = scratch.appendingPathComponent("a/b/c")
        XCTAssertNil(VolumeIdentity.of(missing))
        XCTAssertEqual(VolumeIdentity.ofNearestExisting(missing), here)
        // The same disk mounted again has another device number and the same UUID.
        XCTAssertTrue(VolumeIdentity(device: 1, uuid: "A").isSameVolume(as: VolumeIdentity(device: 2, uuid: "A")))
        XCTAssertFalse(VolumeIdentity(device: 1, uuid: "A").isSameVolume(as: VolumeIdentity(device: 1, uuid: "B")))
        XCTAssertTrue(VolumeIdentity(device: 1, uuid: nil).isSameVolume(as: VolumeIdentity(device: 1, uuid: "B")))
        XCTAssertFalse(VolumeIdentity(device: 1, uuid: nil).isSameVolume(as: VolumeIdentity(device: 2, uuid: nil)))

        let folder = scratch.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let opened = OpenedDataFolder(folder: folder, volume: here)
        XCTAssertTrue(opened.isStillThere)
        XCTAssertTrue(opened.diskIsConnected)
        // Removed by hand, on the same disk: gone, but its disk is there.
        try FileManager.default.removeItem(at: folder)
        XCTAssertFalse(opened.isStillThere)
        XCTAssertTrue(opened.diskIsConnected)
    }

    /// Choosing again the folder the app has open, after its disk left:
    /// the check used to create it anew unless it was under `/Volumes`.
    func testTheOpenedFolderIsNotMadeAnewOnAnotherDisk() throws {
        let scratch = try dataFolderScratch()
        let folder = scratch.appendingPathComponent("mount/TrailBridge Data", isDirectory: true)
        let elsewhere = try XCTUnwrap(VolumeIdentity.of(URL(fileURLWithPath: "/dev")))
        // Opened on another disk than the one now at its path.
        let opened = OpenedDataFolder(folder: folder, volume: elsewhere)
        XCTAssertFalse(opened.diskIsConnected)
        XCTAssertEqual(DataFolderCheck().check(folder, opened: opened), .failure(.missing))
        XCTAssertEqual(contents(scratch), [])

        // A folder that something else made at that path is not the data folder either.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(DataFolderCheck().checkExisting(folder, opened: opened), .failure(.missing))
        XCTAssertEqual(DataFolderCheck().check(folder, opened: opened), .failure(.missing))
        XCTAssertEqual(contents(folder), [])

        // Another folder is not held to it, and the same disk passes.
        let another = scratch.appendingPathComponent("another", isDirectory: true)
        guard case .success = DataFolderCheck().check(another, opened: opened) else { return XCTFail() }
        let here = OpenedDataFolder(folder: folder, volume: try XCTUnwrap(VolumeIdentity.of(folder)))
        guard case .success = DataFolderCheck().checkExisting(folder, opened: here),
              case .success = DataFolderCheck().check(folder, opened: here) else { return XCTFail() }
    }
}
