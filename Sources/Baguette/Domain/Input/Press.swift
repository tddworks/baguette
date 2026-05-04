import Foundation

/// Press-and-release of a hardware button. `duration` is the hold time
/// in seconds; `0` defers to the infrastructure default (~100 ms tap).
/// Longer holds drive iOS gestures like the action button's
/// "Hold for Ring" prompt or power's Siri/SOS path.
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
        let duration = Field.optionalDouble(dict, "duration", default: 0)
        return Press(button: button, duration: duration)
    }

    func execute(on input: any Input) -> Bool {
        input.button(button, duration: duration)
    }
}
