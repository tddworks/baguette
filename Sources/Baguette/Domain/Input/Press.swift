import Foundation

/// Press-and-release of a hardware button.
struct Press: Gesture, Equatable {
    static let wireType = "button"
    static let allowed = "home | lock | power | volume-up | volume-down | action"

    let button: DeviceButton

    static func parse(_ dict: [String: Any]) throws -> Press {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        return Press(button: button)
    }

    func execute(on input: any Input) -> Bool {
        input.button(button)
    }
}
