import Foundation

/// Wire DTO for a hardware-button press. The Gesture protocol's role
/// is parsing + delegating: actual press behaviour lives on
/// `DeviceButton.press(duration:on:)`. Longer holds drive iOS gestures
/// like the action button's "Hold for Ring" prompt or power's
/// Siri/SOS path.
struct Press: Gesture, Equatable {
    static let wireType = "button"
    static let allowed = "home | lock | power | volume-up | volume-down | action"

    let button: DeviceButton
    let duration: Double

    init(button: DeviceButton, duration: Double = 0) {
        self.button = button
        self.duration = duration
    }

    static func parse(_ dict: [String: Any]) throws -> Press {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        return Press(
            button: button,
            duration: Field.optionalDouble(dict, "duration", default: 0)
        )
    }

    func execute(on input: any Input) -> Bool {
        button.press(duration: duration, on: input)
    }
}
