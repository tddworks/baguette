import BaguetteDevice
import Foundation

/// Whether Xcode 27's Device Hub has attached its HID daemon to a
/// simulator — and with it, shadowed the legacy input surface baguette
/// drives.
///
/// Device Hub (the app that replaced Simulator.app in Xcode 27) runs a
/// per-device guest daemon, `dtuhidd`, which registers its own virtual
/// HID services inside backboardd and publishes one Darwin notify state,
/// `com.apple.coredevice.dtuhidd.active`. backboardd's `SimulatorHID`
/// watches that state and, the moment it flips to active, disconnects the
/// legacy Indigo services (`ScreenTouchService`, `MainScreenButtonsService`,
/// `ExternalKeyboardService`) baguette's `IndigoHIDInput` sends to. The
/// iOS 27 runtime then never manages to reconnect them — it re-adds a
/// dead `IOHIDServiceRef` on the first Indigo event and believes it
/// succeeded — so taps report `ok` and land nowhere, and hardware buttons
/// are gone for good. See `docs/features/device-hub/README.md` and issue #77.
///
/// The notify state is the whole detection: it is cheap to read from the
/// host (`simctl spawn <udid> notifyutil -g …`), and `1` means the surface
/// has been shadowed at least once in this backboardd's lifetime, which is
/// exactly the condition that needs healing. Per AGENTS.md's one-shot-fetch
/// split, the parse lives here; the spawn is `SimctlInputSurface`'s.
struct DeviceHubAttachment: Equatable, Sendable {
    /// The Darwin notify key `dtuhidd` sets to `1` on start. Spelling is the
    /// contract with Apple: a typo reads a key nothing sets, forever `0`.
    static let stateKey = "com.apple.coredevice.dtuhidd.active"

    /// Device Hub's HID daemon has claimed this simulator.
    var attached: Bool

    /// Interpret `notifyutil -g <stateKey>` output — `<key> <state>` on one
    /// line. Anything else (a runtime that never published the key, a
    /// failed spawn) reads as not attached: on Xcode 26 hosts there is no
    /// Device Hub, and reporting one would send users chasing a heal they
    /// don't need.
    static func parsing(_ notifyutilOutput: String?) -> DeviceHubAttachment {
        guard let notifyutilOutput else { return DeviceHubAttachment(attached: false) }
        for line in notifyutilOutput.split(whereSeparator: \.isNewline) {
            let words: [String] = line.split(separator: " ").map(String.init)
            if words == [stateKey, "1"] { return DeviceHubAttachment(attached: true) }
        }
        return DeviceHubAttachment(attached: false)
    }

    /// One line telling the user what is about to go wrong and the command
    /// that fixes it — an advisory that only describes the problem is
    /// noise.
    func advisory(udid: String) -> String? {
        guard attached else { return nil }
        return """
            Device Hub has attached to this simulator, which shadows the input surface \
            baguette drives — touches and buttons may be dropped while reporting ok. \
            Run `baguette heal --udid \(udid)` to reclaim it (this restarts SpringBoard).
            """
    }
}
