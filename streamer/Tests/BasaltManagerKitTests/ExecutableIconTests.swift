import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BasaltManagerKit

final class ExecutableIconTests: XCTestCase {
    private let iconType: UInt32 = 3
    private let groupType: UInt32 = 14
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    private let bitmap = Data([0x28, 0, 0, 0, 0x30, 0, 0, 0, 0x60, 0, 0, 0, 9, 9])

    func testReturnsTheLargestImageOfTheFirstGroupAsStoredPNG() {
        let exe = makeExecutable([
            groupType: [1: group([(32, 32, 1), (0, 32, 2), (48, 32, 3)])],
            iconType: [1: bitmap, 2: png, 3: bitmap],
        ])
        XCTAssertEqual(ExecutableIcon.imageData(fromExecutable: exe), png)
    }

    func testWrapsABitmapImageInAOneImageIconFile() throws {
        let exe = makeExecutable([
            groupType: [5: group([(48, 32, 7)])],
            iconType: [7: bitmap],
        ])
        let icon = try XCTUnwrap(ExecutableIcon.imageData(fromExecutable: exe))
        XCTAssertEqual(Array(icon.prefix(6)), [0, 0, 1, 0, 1, 0])
        XCTAssertEqual(icon[6], 48)
        XCTAssertEqual(icon[7], 48)
        XCTAssertEqual(Array(icon[12..<14]), [32, 0], "bit count")
        XCTAssertEqual(Array(icon[14..<18]), [UInt8(bitmap.count), 0, 0, 0], "image size")
        XCTAssertEqual(Array(icon[18..<22]), [22, 0, 0, 0], "image offset")
        XCTAssertEqual(icon.suffix(from: 22), bitmap)
    }

    func testPrefersDeeperColourAtTheSameSize() {
        let exe = makeExecutable([
            groupType: [1: group([(64, 8, 1), (64, 32, 2), (64, 24, 3)])],
            iconType: [1: bitmap, 2: png, 3: bitmap],
        ])
        XCTAssertEqual(ExecutableIcon.imageData(fromExecutable: exe), png)
    }

    func testUsesTheFirstGroupLikeWindows() {
        let exe = makeExecutable([
            groupType: [1: group([(16, 32, 10)]), 2: group([(0, 32, 20)])],
            iconType: [10: png, 20: bitmap],
        ])
        XCTAssertEqual(ExecutableIcon.imageData(fromExecutable: exe), png)
    }

    func testReadsThirtyTwoBitExecutables() {
        let exe = makeExecutable([
            groupType: [1: group([(32, 32, 1)])],
            iconType: [1: png],
        ], pe32Plus: false)
        XCTAssertEqual(ExecutableIcon.imageData(fromExecutable: exe), png)
    }

    func testFilesWithoutAUsableIconGiveNil() {
        let complete = makeExecutable([
            groupType: [1: group([(32, 32, 1)])],
            iconType: [1: png],
        ])
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: Data("not an executable".utf8)))
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: complete.prefix(0x150)),
                     "cut inside the section table")
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: complete.prefix(0x210)),
                     "cut inside the resource tree")
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: makeExecutable([iconType: [1: png]])),
                     "icons without a group")
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: makeExecutable([
            groupType: [1: group([(32, 32, 9)])],
            iconType: [1: png],
        ])), "a group naming a missing icon")
        XCTAssertNil(ExecutableIcon.imageData(fromExecutable: makeExecutable([
            groupType: [1: Data([0, 0, 1, 0, 0, 0])],
            iconType: [1: png],
        ])), "an empty group")
        XCTAssertNil(ExecutableIcon.imageData(
            fromExecutableAt: URL(fileURLWithPath: "/nonexistent/TrailBridge/game.exe")))
    }

    func testBackingAnswersTheIconsBrightness() throws {
        XCTAssertEqual(ExecutableIcon.backing(forImageData: try image(gray: 0, coverage: 0.5)), .light,
                       "a black logo on transparency needs a light plate")
        XCTAssertEqual(ExecutableIcon.backing(forImageData: try image(gray: 1, coverage: 0.5)), .dark,
                       "a white logo on transparency needs a dark plate")
        XCTAssertNil(ExecutableIcon.backing(forImageData: try image(gray: 0, coverage: 1)),
                     "an opaque icon brings its own background")
        XCTAssertNil(ExecutableIcon.backing(forImageData: try image(gray: 1, coverage: 0)),
                     "a transparent icon gives nothing to judge")
        XCTAssertNil(ExecutableIcon.backing(forImageData: Data("not an image".utf8)))
    }

    // MARK: - Fixtures

    /// A GRPICONDIR; a width of 0 stands for 256 pixels.
    private func group(_ entries: [(width: UInt8, bits: UInt16, id: UInt16)]) -> Data {
        var data = Data()
        data.append(u16: 0)
        data.append(u16: 1)
        data.append(u16: UInt16(entries.count))
        for entry in entries {
            data.append(contentsOf: [entry.width, entry.width, 0, 0])
            data.append(u16: 1)
            data.append(u16: entry.bits)
            data.append(u32: 0)
            data.append(u16: entry.id)
        }
        return data
    }

    /// A minimal PE file whose only section is a resource tree of the given
    /// types and IDs, one language each, laid out the way linkers write it.
    private func makeExecutable(_ resources: [UInt32: [UInt32: Data]], pe32Plus: Bool = true) -> Data {
        let sectionRVA: UInt32 = 0x1000
        let sectionFileOffset = 0x200
        let types = resources.keys.sorted()
        let leaves = types.flatMap { type in resources[type]!.keys.sorted().map { (type, $0) } }

        var cursor = 16 + 8 * types.count
        var typeDirectory = [UInt32: Int]()
        for type in types {
            typeDirectory[type] = cursor
            cursor += 16 + 8 * resources[type]!.count
        }
        var languageDirectory = [String: Int]()
        for (type, id) in leaves { languageDirectory["\(type)/\(id)"] = cursor; cursor += 24 }
        var dataEntry = [String: Int]()
        for (type, id) in leaves { dataEntry["\(type)/\(id)"] = cursor; cursor += 16 }
        var blob = [String: Int]()
        for (type, id) in leaves {
            cursor = (cursor + 3) & ~3
            blob["\(type)/\(id)"] = cursor
            cursor += resources[type]![id]!.count
        }

        var section = Data(count: cursor)
        section.put(u16: UInt16(types.count), at: 14)
        for (index, type) in types.enumerated() {
            section.put(u32: type, at: 16 + 8 * index)
            section.put(u32: 0x8000_0000 | UInt32(typeDirectory[type]!), at: 20 + 8 * index)
            let ids = resources[type]!.keys.sorted()
            let directory = typeDirectory[type]!
            section.put(u16: UInt16(ids.count), at: directory + 14)
            for (position, id) in ids.enumerated() {
                section.put(u32: id, at: directory + 16 + 8 * position)
                section.put(u32: 0x8000_0000 | UInt32(languageDirectory["\(type)/\(id)"]!),
                            at: directory + 20 + 8 * position)
            }
        }
        for (type, id) in leaves {
            let key = "\(type)/\(id)"
            let language = languageDirectory[key]!
            section.put(u16: 1, at: language + 14)
            section.put(u32: 0x409, at: language + 16)
            section.put(u32: UInt32(dataEntry[key]!), at: language + 20)
            let payload = resources[type]![id]!
            section.put(u32: sectionRVA + UInt32(blob[key]!), at: dataEntry[key]!)
            section.put(u32: UInt32(payload.count), at: dataEntry[key]! + 4)
            section.replaceSubrange(blob[key]!..<blob[key]! + payload.count, with: payload)
        }

        var file = Data(count: sectionFileOffset)
        file.put(u16: 0x5A4D, at: 0)
        file.put(u32: 0x40, at: 0x3C)
        file.put(u32: 0x0000_4550, at: 0x40)
        file.put(u16: 1, at: 0x46)
        let optionalSize = pe32Plus ? 240 : 224
        file.put(u16: UInt16(optionalSize), at: 0x54)
        let optional = 0x58
        file.put(u16: pe32Plus ? 0x20B : 0x10B, at: optional)
        let directories = optional + (pe32Plus ? 112 : 96)
        file.put(u32: 16, at: directories - 4)
        file.put(u32: sectionRVA, at: directories + 16)
        file.put(u32: UInt32(section.count), at: directories + 20)
        let header = optional + optionalSize
        file.replaceSubrange(header..<header + 5, with: Data(".rsrc".utf8))
        file.put(u32: UInt32(section.count), at: header + 8)
        file.put(u32: sectionRVA, at: header + 12)
        file.put(u32: UInt32(section.count), at: header + 16)
        file.put(u32: UInt32(sectionFileOffset), at: header + 20)
        return file + section
    }

    /// A 32-pixel PNG: a gray square covering `coverage` of the area, the
    /// rest transparent.
    private func image(gray: CGFloat, coverage: CGFloat) throws -> Data {
        let side = 32
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side) * coverage))
        let cgImage = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(u32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func put(u16 value: UInt16, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            replaceSubrange(offset..<offset + 2, with: $0)
        }
    }

    mutating func put(u32 value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            replaceSubrange(offset..<offset + 4, with: $0)
        }
    }
}
