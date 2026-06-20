import Foundation

/// A booted simulator's interface orientation. The four cases mirror
/// `UIDeviceOrientation` and use the same raw values on the wire — the
/// 4-byte payload of a `GSEventTypeDeviceOrientationChanged` mach
/// message at offset 0x4C is exactly this number.
public enum DeviceOrientation: UInt32, Sendable, CaseIterable, Equatable {
    case portrait              = 1
    case portraitUpsideDown    = 2
    case landscapeRight        = 3   // Home button on the right (rotated 90° CW)
    case landscapeLeft         = 4   // Home button on the left  (rotated 90° CCW)

    /// Kebab-case spellings the CLI and the HTTP route surface — the
    /// single source of truth so App's `ExpressibleByArgument`
    /// extension and Infrastructure's `Server.applyOrientation` agree
    /// without crossing layers.
    public init?(wireName: String) {
        switch wireName {
        case "portrait":             self = .portrait
        case "portrait-upside-down": self = .portraitUpsideDown
        case "landscape-left":       self = .landscapeLeft
        case "landscape-right":      self = .landscapeRight
        default: return nil
        }
    }

    /// Reverse of `init(wireName:)`. Used to echo the chosen value
    /// back in CLI output and HTTP responses.
    public var wireName: String {
        switch self {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft:      return "landscape-left"
        case .landscapeRight:     return "landscape-right"
        }
    }
}
