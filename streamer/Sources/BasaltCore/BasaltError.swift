import Foundation

public struct BasaltError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension BasaltError {
    /// A failed bind with the port named in `what`. "Address already in use"
    /// alone tells the user neither which port nor what to do about it.
    static func cannotBind(_ what: String, code: Int32) -> BasaltError {
        guard code == EADDRINUSE else {
            return BasaltError("Cannot bind \(what): \(String(cString: strerror(code)))")
        }
        return BasaltError("Cannot bind \(what): another program is using this port "
            + "(ALVR, MoltenVR or a second streamer?); quit it and try again")
    }
}
