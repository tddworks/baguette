import Foundation
import Mockable

/// What a device presses: its navigations (home, back, the app switcher)
/// and the buttons on its body (power, volume, action). A device with
/// neither has no `Press` at all.
@Mockable
protocol Press: Sendable {
    /// The navigations and buttons this device has; a press of any other
    /// is refused by name before it reaches the device.
    var available: Set<DeviceButton> { get }

    /// Press-and-hold `button`. `duration` is the hold in seconds; `0`
    /// is a default short tap. Prefer `button.press(duration:on:)`.
    func button(_ button: DeviceButton, duration: Double) -> Bool
}
