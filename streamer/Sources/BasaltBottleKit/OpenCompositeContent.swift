import Foundation

public enum OpenCompositeContent {
    /// Both ASCII markers occur in the official OpenXR x64 artifact and neither
    /// occurs in the saved Steam original. Require a valid PE DLL as well.
    public static func isOpenComposite(_ data: Data) -> Bool {
        (try? OpenCompositeArchitecture.dllArchitecture(in: data)) != nil
            && data.range(of: Data("OCOVR".utf8)) != nil
            && data.range(of: Data("OpenComposite".utf8)) != nil
    }
}
