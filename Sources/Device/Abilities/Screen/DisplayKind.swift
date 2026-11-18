import Foundation

/// Which framebuffer plane the caller wants. Parsed at App/CLI only.
/// Wire strings: "phone" | "carplay" (case-insensitive). Unknown → nil.
public enum DisplayKind: String, Sendable, Equatable {
    case phone
    case carPlay

    /// Whether the guest must be told to build this plane's digitizer
    /// before it can be touched.
    ///
    /// The phone's is part of the device and always present. An external
    /// plane's has to be created — see `ExternalDigitizer`.
    public var needsExternalDigitizer: Bool {
        switch self {
        case .phone:   return false
        case .carPlay: return true
        }
    }

    public static func parse(query: String?) -> DisplayKind? {
        parse(token: query)
    }

    public static func parse(cliFlag: String?) -> DisplayKind? {
        parse(token: cliFlag)
    }

    private static func parse(token: String?) -> DisplayKind? {
        guard let token, !token.isEmpty else { return nil }
        switch token.lowercased() {
        case "phone": return .phone
        case "carplay": return .carPlay
        default: return nil
        }
    }
}
