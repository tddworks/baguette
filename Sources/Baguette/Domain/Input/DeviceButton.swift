import Foundation

/// What `press` presses: a navigation the system performs, or a button on
/// the device's body. The wire names one flat list (`"button": "home"`);
/// the two kinds are what a device offers, and each device says which of
/// them it has (`Press.available`).
enum DeviceButton: Hashable, Sendable {
    case navigation(Navigation)
    case hardware(HardwareButton)
}

/// Where the system takes the user, named for where it goes; how it gets
/// there is the device's business. A simulator reaches Home with the home
/// button's message and the app switcher with two of them ~150 ms apart
/// (SpringBoard's own recipe, so a Face ID phone gets there too); the
/// `swipe-` and `pull-down-` variants are edge-flagged drags the system
/// gesture recognizer routes (the app in front never sees them).
/// `software-keyboard` shows or hides the on-screen keyboard. Android's
/// `back` joins these when an Android device can press it.
enum Navigation: String, Sendable, CaseIterable {
    case home
    case appSwitcher = "app-switcher"
    case swipeToAppSwitcher = "swipe-to-app-switcher"
    case swipeToHome = "swipe-to-home"
    case pullDownToLockScreen = "pull-down-to-lock-screen"
    case pullDownToNotificationCenter = "pull-down-to-notification-center"
    case softwareKeyboard = "software-keyboard"
}

/// A button on the device's body. `lock` is the sleep/wake button; the
/// watch's `digital-crown`, `side-button` and `left-side-button` are a
/// watch's own. `siri` is not one: it crashes backboardd through every
/// known path.
enum HardwareButton: String, Sendable, CaseIterable {
    case lock, power, action
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case digitalCrown = "digital-crown"
    case sideButton = "side-button"
    case leftSideButton = "left-side-button"
}

extension DeviceButton: RawRepresentable, CaseIterable {
    /// The wire name: the navigation's or the button's own.
    init?(rawValue: String) {
        if let navigation = Navigation(rawValue: rawValue) {
            self = .navigation(navigation)
        } else if let button = HardwareButton(rawValue: rawValue) {
            self = .hardware(button)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .navigation(let navigation): return navigation.rawValue
        case .hardware(let button): return button.rawValue
        }
    }

    static var allCases: [DeviceButton] {
        Navigation.allCases.map(Self.navigation) + HardwareButton.allCases.map(Self.hardware)
    }

    /// What an iOS simulator offers: every navigation and button.
    static var onSimulator: Set<DeviceButton> { Set(allCases) }

    /// Press-and-release on the device's buttons. `duration` is the hold
    /// in seconds; `0` defers to the device's default short tap.
    @discardableResult
    func press(duration: Double = 0, on buttons: any Press) -> Bool {
        buttons.button(self, duration: duration)
    }
}

extension HardwareButton {
    /// The button's standard HID (page, usage), or nil for `lock`, which a
    /// simulator presses as a button message rather than a HID usage.
    /// Consumer page 12 and telephony page 11, as every shipping iPhone's
    /// chrome.json has them; the watch's from watch4's chrome.json, its
    /// left side button on Apple's vendor page 0xFF01.
    var standardHIDUsage: HIDUsage? {
        switch self {
        case .lock:           return nil
        case .power:          return HIDUsage(page: 12, usage: 48)
        case .volumeUp:       return HIDUsage(page: 12, usage: 233)
        case .volumeDown:     return HIDUsage(page: 12, usage: 234)
        case .action:         return HIDUsage(page: 11, usage: 45)
        case .digitalCrown:   return HIDUsage(page: 12, usage: 64)
        case .sideButton:     return HIDUsage(page: 12, usage: 149)
        case .leftSideButton: return HIDUsage(page: 65281, usage: 512)
        }
    }
}
