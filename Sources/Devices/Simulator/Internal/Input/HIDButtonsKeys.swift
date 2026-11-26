import BaguetteDevice
import Foundation

/// `DeviceKeys` on a HID buttons service: the `HIDButtons` program, kept
/// serving in the guest, presses each key as Device Hub's buttons do (`button
/// <page> <usage> <ms> [<page> <usage>]…`, modifiers as trailing pairs; see
/// `Injected/HIDButtons/Sources/main.m`). iPhone Duo takes its hardware
/// buttons and its keyboard keys only from there.
final class HIDButtonsKeys: DeviceKeys, @unchecked Sendable {
    private let session: SimctlSpawnSession

    init(session: SimctlSpawnSession) {
        self.session = session
    }

    /// One per device, however many displays and inputs ask for it.
    static func forDevice(_ udid: String, deviceSetPath: String? = nil, path: @escaping () -> String?) -> HIDButtonsKeys {
        HIDButtonsKeys(session: .forDevice(udid, deviceSetPath: deviceSetPath, program: "HIDButtons", path: path))
    }

    func press(_ usage: HIDUsage, holding modifiers: [HIDUsage], hold: TimeInterval) throws {
        let held = modifiers.map { " \($0.page) \($0.usage)" }.joined()
        try session.send("button \(usage.page) \(usage.usage) \(SimctlSpawnSession.number(hold * 1000))\(held)", playing: hold)
    }
}
