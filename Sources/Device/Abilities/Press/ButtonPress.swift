import Foundation

/// One press of a navigation or a hardware button — an act of `Press`.
/// Parsing and delegating only: the press itself is
/// `DeviceButton.press(duration:on:)`. Longer holds drive iOS gestures
/// like the action button's "Hold for Ring" prompt or power's Siri/SOS
/// path. A button the device doesn't offer is refused by name.
public struct ButtonPress: Gesture, Equatable {
    public static let wireType = "button"
    public static let allowed = DeviceButton.allCases.map(\.rawValue).joined(separator: " | ")

    public let button: DeviceButton
    public let duration: Double

    public init(button: DeviceButton, duration: Double = 0) {
        self.button = button
        self.duration = duration
    }

    public static func parse(_ dict: [String: Any]) throws -> ButtonPress {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        return ButtonPress(
            button: button,
            duration: Field.optionalDouble(dict, "duration", default: 0)
        )
    }

    public static var ability: Ability<any Press> { .press }

    public func missing(from press: any Press) -> String? {
        press.available.contains(button) ? nil : button.rawValue
    }

    public func execute(on press: any Press) -> Bool {
        button.press(duration: duration, on: press)
    }
}
