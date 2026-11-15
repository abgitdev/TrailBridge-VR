import CoreGraphics
import Foundation
import ImageIO

/// What to put behind an icon with transparent parts so it stays visible.
public enum IconBacking: Equatable, Sendable {
    /// A dark icon, such as a black logo: show it on a light plate.
    case light
    /// A light icon, such as a white logo: show it on a dark plate.
    case dark
}

/// Reads the application icon embedded in a Windows executable, so a game
/// added from a folder gets a picture without Steam artwork or the network.
///
/// Windows shows the first icon group in an executable's resources as its
/// icon. This returns that group's largest image: PNG data as stored, or a
/// one-image ICO file around a bitmap entry, both of which ImageIO decodes.
/// Malformed or icon-less files return nil; nothing is written anywhere.
public enum ExecutableIcon {
    /// Icon data larger than this is ignored. Real 256-pixel icons are well
    /// under 300 KB.
    static let maximumImageBytes = 4 * 1024 * 1024
    static let maximumDirectoryEntries = 4096

    private static let resourceTypeIcon: UInt32 = 3
    private static let resourceTypeGroupIcon: UInt32 = 14
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func imageData(fromExecutableAt url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return imageData(fromExecutable: data)
    }

    public static func imageData(fromExecutable data: Data) -> Data? {
        let file = Bytes(data)
        guard let resources = ResourceSection(file) else { return nil }
        guard let group = resources.firstData(ofType: resourceTypeGroupIcon),
              let best = bestEntry(inGroup: group),
              let image = resources.data(ofType: resourceTypeIcon, id: UInt32(best.id)),
              !image.isEmpty, image.count <= maximumImageBytes else { return nil }
        if image.starts(with: pngSignature) { return image }
        return iconFile(entry: best, image: image)
    }

    /// The plate an icon needs, or nil when either works: the icon is mostly
    /// opaque (it brings its own background) or cannot be decoded. Judged
    /// by the alpha-weighted mean luminance of a 16-pixel thumbnail.
    public static func backing(forImageData data: Data) -> IconBacking? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return backing(premultipliedRGBA: pixels)
    }

    /// Pure part of `backing(forImageData:)`, over premultiplied RGBA bytes.
    static func backing(premultipliedRGBA pixels: [UInt8]) -> IconBacking? {
        var alpha = 0.0
        var luminance = 0.0
        for index in stride(from: 0, to: pixels.count - 3, by: 4) {
            luminance += (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])) / 255
            alpha += Double(pixels[index + 3]) / 255
        }
        let count = Double(pixels.count / 4)
        guard count > 0, alpha / count > 0.02, alpha / count < 0.9 else { return nil }
        return luminance / alpha < 0.5 ? .light : .dark
    }

    struct GroupEntry: Equatable {
        let width: UInt8
        let height: UInt8
        let colorCount: UInt8
        let planes: UInt16
        let bitCount: UInt16
        let id: UInt16

        /// A stored width of 0 means 256 pixels.
        var pixels: Int { width == 0 ? 256 : Int(width) }
    }

    /// The largest image of a GRPICONDIR, then the deepest colour.
    static func bestEntry(inGroup group: Data) -> GroupEntry? {
        let bytes = Bytes(group)
        guard bytes.u16(2) == 1, let count = bytes.u16(4), count > 0 else { return nil }
        var best: GroupEntry?
        for index in 0..<Int(count) {
            let base = 6 + index * 14
            guard let width = bytes.u8(base), let height = bytes.u8(base + 1),
                  let colors = bytes.u8(base + 2), let planes = bytes.u16(base + 4),
                  let bits = bytes.u16(base + 6), let id = bytes.u16(base + 12) else { break }
            let entry = GroupEntry(width: width, height: height, colorCount: colors,
                                   planes: planes, bitCount: bits, id: id)
            if let current = best,
               (current.pixels, current.bitCount) >= (entry.pixels, entry.bitCount) {
                continue
            }
            best = entry
        }
        return best
    }

    /// A one-image ICO file: ICONDIR, one ICONDIRENTRY, then the image.
    static func iconFile(entry: GroupEntry, image: Data) -> Data {
        var file = Data()
        file.appendLittleEndian(UInt16(0))
        file.appendLittleEndian(UInt16(1))
        file.appendLittleEndian(UInt16(1))
        file.append(contentsOf: [entry.width, entry.height, entry.colorCount, 0])
        file.appendLittleEndian(entry.planes)
        file.appendLittleEndian(entry.bitCount)
        file.appendLittleEndian(UInt32(image.count))
        file.appendLittleEndian(UInt32(22))
        file.append(image)
        return file
    }
}

/// The `.rsrc` tree of a PE file, read in place with bounds checks.
private struct ResourceSection {
    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawSize: UInt32
        let rawOffset: UInt32
    }

    private let file: Bytes
    private let sections: [Section]
    /// File offset of the resource directory root.
    private let root: Int

    init?(_ file: Bytes) {
        self.file = file
        guard file.u16(0) == 0x5A4D, let peOffset = file.u32(0x3C).map(Int.init),
              file.u32(peOffset) == 0x0000_4550,
              let sectionCount = file.u16(peOffset + 6),
              let optionalSize = file.u16(peOffset + 20).map(Int.init) else { return nil }
        let optional = peOffset + 24
        let directories: Int
        switch file.u16(optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        // The resource table is data directory 2.
        guard let directoryCount = file.u32(directories - 4), directoryCount > 2,
              let resourceRVA = file.u32(directories + 16), resourceRVA != 0 else { return nil }

        var sections = [Section]()
        let table = optional + optionalSize
        for index in 0..<Int(min(sectionCount, 96)) {
            let base = table + index * 40
            guard let virtualSize = file.u32(base + 8), let virtualAddress = file.u32(base + 12),
                  let rawSize = file.u32(base + 16), let rawOffset = file.u32(base + 20) else {
                return nil
            }
            sections.append(Section(virtualAddress: virtualAddress, virtualSize: virtualSize,
                                    rawSize: rawSize, rawOffset: rawOffset))
        }
        self.sections = sections
        guard let root = Self.fileOffset(rva: resourceRVA, in: sections) else { return nil }
        self.root = root
    }

    private static func fileOffset(rva: UInt32, in sections: [Section]) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress,
                  UInt64(rva) < UInt64(section.virtualAddress) + UInt64(span) else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.rawSize else { return nil }
            return Int(section.rawOffset) + Int(delta)
        }
        return nil
    }

    /// Entries of the directory at `offset` (relative to the root), in file
    /// order: named entries first, then IDs ascending, as Windows writes them.
    private func entries(at offset: Int) -> [(name: UInt32, target: UInt32)] {
        let base = root + offset
        guard let named = file.u16(base + 12), let ids = file.u16(base + 14) else { return [] }
        let count = min(Int(named) + Int(ids), ExecutableIcon.maximumDirectoryEntries)
        var result = [(name: UInt32, target: UInt32)]()
        for index in 0..<count {
            guard let name = file.u32(base + 16 + index * 8),
                  let target = file.u32(base + 20 + index * 8) else { break }
            result.append((name, target))
        }
        return result
    }

    private static let subdirectoryFlag: UInt32 = 0x8000_0000

    private func subdirectory(_ target: UInt32) -> Int? {
        target & Self.subdirectoryFlag != 0 ? Int(target & ~Self.subdirectoryFlag) : nil
    }

    /// The data under one name: its first language.
    private func leafData(nameTarget: UInt32) -> Data? {
        guard let languages = subdirectory(nameTarget),
              let first = entries(at: languages).first,
              first.target & Self.subdirectoryFlag == 0 else { return nil }
        let entry = root + Int(first.target)
        guard let rva = file.u32(entry), let size = file.u32(entry + 4),
              size > 0, Int(size) <= ExecutableIcon.maximumImageBytes,
              let offset = Self.fileOffset(rva: rva, in: sections) else { return nil }
        return file.slice(offset, Int(size))
    }

    private func names(ofType type: UInt32) -> [(name: UInt32, target: UInt32)] {
        guard let typeEntry = entries(at: 0).first(where: { $0.name == type }),
              let names = subdirectory(typeEntry.target) else { return [] }
        return entries(at: names)
    }

    func firstData(ofType type: UInt32) -> Data? {
        names(ofType: type).lazy.compactMap { leafData(nameTarget: $0.target) }.first
    }

    func data(ofType type: UInt32, id: UInt32) -> Data? {
        names(ofType: type).first { $0.name == id }.flatMap { leafData(nameTarget: $0.target) }
    }
}

/// Little-endian reads that return nil instead of trapping out of bounds.
private struct Bytes {
    let data: Data

    init(_ data: Data) { self.data = data }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard let low = u8(offset), let high = u8(offset + 1) else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    func slice(_ offset: Int, _ count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset <= data.count - count else { return nil }
        let start = data.startIndex + offset
        return Data(data[start..<start + count])
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
