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

/// HID (page, usage) pair — the wire-level code SimulatorKit needs
/// to identify an arbitrary-HID button press. iPhone side buttons
/// live on consumer (page 12) and telephony (page 11) HID pages.
struct HIDUsage: Equatable, Hashable, Sendable {
    let page: UInt32
    let usage: UInt32
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
    /// Standard HID (page, usage) for the arbitrary-HID side buttons.
    /// `home`/`lock` return `nil` — they ride a different SimulatorKit
    /// symbol (`IndigoHIDMessageForButton`) and don't go through the
    /// arbitrary-HID path. Codes match Apple's HID consumer (page 12)
    /// and telephony (page 11) page assignments and agree with every
    /// shipping iPhone's chrome.json.
    var standardHIDUsage: HIDUsage? {
        switch self {
        case .home, .lock: return nil
        case .power:      return HIDUsage(page: 12, usage: 48)
        case .volumeUp:   return HIDUsage(page: 12, usage: 233)
        case .volumeDown: return HIDUsage(page: 12, usage: 234)
        case .action:     return HIDUsage(page: 11, usage: 45)
        }
    }

    /// Press-and-release this button on the given input. `duration` is
    /// the hold time in seconds; `0` defers to the infrastructure
    /// default (~100 ms tap). Encapsulates the HID-vs-legacy split:
    /// the input adapter routes by case while the caller just says
    /// "this button, this long."
    @discardableResult
    func press(duration: Double = 0, on input: any Input) -> Bool {
        input.button(self, duration: duration)
    }
}
