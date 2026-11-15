import Foundation

/// The official OpenComposite download architectures, read from the PE/COFF header.
public enum OpenCompositeArchitecture: String, Sendable {
    case x64, x86

    public static func dllArchitecture(in data: Data) throws -> Self {
        let bytes = [UInt8](data)
        func invalid() -> BottleToolError {
            BottleToolError("Expected an x64 or x86 Windows PE DLL")
        }
        guard bytes.count >= 64, bytes[0] == 0x4d, bytes[1] == 0x5a else { throw invalid() }
        let offset = (0..<4).reduce(0) { $0 | (Int(bytes[0x3c + $1]) << (8 * $1)) }
        guard offset >= 64, offset <= bytes.count - 26,
              Array(bytes[offset..<(offset + 4)]) == [0x50, 0x45, 0, 0],
              bytes[offset + 23] & 0x20 != 0 else { throw invalid() }
        let machine = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
        let optionalSize = Int(bytes[offset + 20]) | Int(bytes[offset + 21]) << 8
        guard optionalSize >= 2, optionalSize <= bytes.count - offset - 24 else { throw invalid() }
        let magic = Int(bytes[offset + 24]) | Int(bytes[offset + 25]) << 8
        switch (machine, magic) {
        case (0x8664, 0x20b): return .x64
        case (0x14c, 0x10b): return .x86
        default: throw invalid()
        }
    }
}
