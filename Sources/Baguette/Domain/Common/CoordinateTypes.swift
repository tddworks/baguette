import Foundation

/// A point in the simulator's screen-space, in points (top-left origin).
/// The infrastructure adapter clamps and normalizes to whatever the wire
/// requires; domain code stays in the user's units.
struct Point: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// Screen size in points. Carried with every gesture so the dispatch layer
/// can scale without knowing which device is target.
struct Size: Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Edge offsets in points (top/left/bottom/right). Used by `DeviceChrome`
/// for the bezel widths around the screen cutout.
struct Insets: Equatable, Sendable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
}

/// Origin + size, both in the same coordinate space. The chrome layout
/// returns one to describe where the screen sits inside a composite
/// image of a given pixel size.
struct Rect: Equatable, Sendable {
    let origin: Point
    let size: Size
}

/// Phase of a streaming touch gesture (`touch1` / `touch2`).
enum GesturePhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up
}

/// Hardware buttons routable via the host-HID path on iOS 26.4.
///
/// `home` / `lock` ride `IndigoHIDMessageForButton`. The four
/// chrome.json side-buttons (`power` / `volumeUp` / `volumeDown` /
/// `action`) ride `IndigoHIDMessageForHIDArbitrary` keyed by HID
/// usagePage / usage codes from each device's chrome.json. `siri`
/// remains rejected — it crashes backboardd through every known path.
enum DeviceButton: String, Sendable, Equatable, Hashable {
    case home, lock
    case power, action
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
}

extension DeviceButton {
    /// Standard HID (page, usage) for the arbitrary-HID buttons. Codes
    /// match the iPhone family's chrome.json declarations and Apple's
    /// HID consumer/telephony page assignments.
    private static let standardHIDUsage: [DeviceButton: HIDUsage] = [
        .power:      HIDUsage(page: 12, usage: 48),
        .volumeUp:   HIDUsage(page: 12, usage: 233),
        .volumeDown: HIDUsage(page: 12, usage: 234),
        .action:     HIDUsage(page: 11, usage: 45),
    ]

    /// Effective HID code for this button. `home`/`lock` always return
    /// `nil` — they ride a different SimulatorKit symbol entirely. For
    /// the four arbitrary-HID buttons, the chrome.json `override`
    /// (when non-nil) wins; otherwise the standard iPhone-family
    /// defaults apply.
    func hidUsage(override: HIDUsage?) -> HIDUsage? {
        switch self {
        case .home, .lock: return nil
        case .power, .volumeUp, .volumeDown, .action:
            return override ?? Self.standardHIDUsage[self]
        }
    }
}
