import Foundation

/// One side's ICE username fragment and password (RFC 8445 §5.3): the browser
/// signs its connectivity checks with ours, and names both fragments in them.
public struct ICECredentials: Equatable, Sendable {
    public let ufrag: String
    public let password: String

    public init(ufrag: String, password: String) {
        self.ufrag = ufrag
        self.password = password
    }

    private static let iceChars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")

    /// New random credentials for a viewer: 8 and 24 ice-chars, above the
    /// spec's minimum of 4 and 22.
    public static func fresh() -> ICECredentials {
        var random = SystemRandomNumberGenerator()
        let pick = { (count: Int) in String((0..<count).map { _ in iceChars.randomElement(using: &random)! }) }
        return ICECredentials(ufrag: pick(8), password: pick(24))
    }
}
