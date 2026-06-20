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

/// Screen-edge gesture region a streaming touch belongs to. When
/// set on a `touch1-*` envelope, the Infrastructure adapter
/// patches the `IndigoHIDEdge` byte slot in the message so iOS's
/// system gesture recognizers (home indicator, control centre,
/// notification centre) see the touch as an edge gesture rather
/// than an interior pan. Empirical bitmask values verified against
/// `IndigoHIDMessageForMouseNSEvent`'s 7-arg signature.
public enum DeviceEdge: String, Sendable, Equatable, Hashable, CaseIterable {
    case left, top, right, bottom
}

/// Hardware buttons routable via the host-HID path on iOS 26.4.
///
/// `home` / `lock` ride `IndigoHIDMessageForButton`. The iPhone-family
/// side-buttons (`power` / `volumeUp` / `volumeDown` / `action`) and
/// the Apple-Watch-family buttons (`digitalCrown` / `sideButton` /
/// `leftSideButton`) ride `IndigoHIDMessageForHIDArbitrary` keyed by
/// HID usagePage / usage codes copied verbatim from each device's
/// chrome.json. `siri` remains rejected — it crashes backboardd
/// through every known path.
///
/// `appSwitcher`, `swipeToAppSwitcher`, `swipeToHome`,
/// `pullDownToLockScreen`, and `pullDownToNotificationCenter` are
/// *virtual* buttons — they have no physical counterpart on any
/// iPhone, but the wire surface keeps the API uniform with the real
/// ones. `appSwitcher` decomposes into two consecutive home
/// `IndigoHIDMessageForButton` presses ~150 ms apart (SpringBoard's
/// own recipe; works on Face ID devices that have no home button
/// hardware — cleaner and more reliable than synthesising the slow
/// swipe-and-hold gesture). The four swipe / pull variants all ride
/// `IOHIDDigitizerDispatch` with an `IndigoHIDEdge` flag set, which
/// is what tells the iOS HID stack to route the touches to the
/// system-gesture recognizer rather than to whatever app is foreground:
///   - `swipeToAppSwitcher` — slow drag-and-hold from the bottom edge
///   - `swipeToHome` — fast flick from the device's bottom edge
///   - `pullDownToLockScreen` — slow drag from top-left
///   - `pullDownToNotificationCenter` — slow drag from top-right
enum DeviceButton: String, Sendable, Equatable, Hashable {
    case home, lock
    case power, action
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case digitalCrown = "digital-crown"
    case sideButton = "side-button"
    case leftSideButton = "left-side-button"
    case appSwitcher = "app-switcher"
    case swipeToAppSwitcher = "swipe-to-app-switcher"
    case swipeToHome = "swipe-to-home"
    case pullDownToLockScreen = "pull-down-to-lock-screen"
    case pullDownToNotificationCenter = "pull-down-to-notification-center"
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
        case .home, .lock, .appSwitcher, .swipeToAppSwitcher, .swipeToHome,
             .pullDownToLockScreen, .pullDownToNotificationCenter: return nil
        case .power:      return HIDUsage(page: 12, usage: 48)
        case .volumeUp:   return HIDUsage(page: 12, usage: 233)
        case .volumeDown: return HIDUsage(page: 12, usage: 234)
        case .action:     return HIDUsage(page: 11, usage: 45)
        // Apple Watch family. Codes match watch4.devicechrome's
        // chrome.json verbatim (`usagePage` / `usage` per input).
        // `leftSideButton` rides Apple's vendor-defined consumer
        // page 0xFF01 — accepted as a raw (page, usage) pair by
        // IndigoHIDMessageForHIDArbitrary like any other consumer
        // code; the iOS-side handler is what gives it watch-specific
        // semantics.
        case .digitalCrown:   return HIDUsage(page: 12, usage: 64)
        case .sideButton:     return HIDUsage(page: 12, usage: 149)
        case .leftSideButton: return HIDUsage(page: 65281, usage: 512)
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
