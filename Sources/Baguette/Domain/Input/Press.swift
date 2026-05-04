import Foundation

/// Press-and-release of a hardware button. `duration` is the hold time
/// in seconds; `0` defers to the infrastructure default (~100 ms tap).
/// Longer holds drive iOS gestures like the action button's
/// "Hold for Ring" prompt or power's Siri/SOS path. `hidUsage`
/// optionally overrides the (page, usage) used for arbitrary-HID
/// buttons (power / volume / action) — the browser sources it from
/// chrome.json so the dispatch layer doesn't need a back-channel.
struct Press: Gesture, Equatable {
    static let wireType = "button"
    static let allowed = "home | lock | power | volume-up | volume-down | action"

    let button: DeviceButton
    let duration: Double
    let hidUsage: HIDUsage?

    init(button: DeviceButton, duration: Double = 0, hidUsage: HIDUsage? = nil) {
        self.button = button
        self.duration = duration
        self.hidUsage = hidUsage
    }

    static func parse(_ dict: [String: Any]) throws -> Press {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        let duration = Field.optionalDouble(dict, "duration", default: 0)
        return Press(
            button: button,
            duration: duration,
            hidUsage: parseHIDUsage(dict)
        )
    }

    private static func parseHIDUsage(_ dict: [String: Any]) -> HIDUsage? {
        guard
            let page  = (dict["usagePage"] as? NSNumber)?.uint32Value,
            let usage = (dict["usage"]     as? NSNumber)?.uint32Value
        else { return nil }
        return HIDUsage(page: page, usage: usage)
    }

    func execute(on input: any Input) -> Bool {
        input.button(button, hidUsage: hidUsage, duration: duration)
    }
}
