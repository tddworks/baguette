import Foundation

/// Press-and-release of a hardware button. Today: home, lock.
struct Press: Gesture, Equatable {
    static let wireType = "button"

    let button: DeviceButton

    static func parse(_ dict: [String: Any]) throws -> Press {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: "home | lock")
        }
        return Press(button: button)
    }

    func execute(on input: any Input) -> Bool {
        input.button(button)
    }
}
