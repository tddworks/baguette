import Foundation
import Mockable

/// Inner port for `LiveChromes` — abstracts the filesystem so tests
/// drive the aggregate against in-memory bytes instead of poking at
/// `/Library/Developer/`. Production wiring is `FileSystemChromeStore`,
/// which appends standard paths and reads the file.
@Mockable
protocol ChromeStore: Sendable {
    /// Raw `profile.plist` for a simulator's device-type bundle.
    /// Throws when the bundle / file is missing — `LiveChromes`
    /// turns that into a `nil` asset for the caller.
    func profilePlistData(deviceName: String) throws -> Data

    /// Raw `capabilities.plist` from the same device-type bundle.
    /// Xcode 27 publishes screen dimensions here instead of on the
    /// profile; Xcode ≤26 has no such file, so throwing is the normal
    /// path there and `LiveChromes` falls back to the profile's own
    /// keys.
    func capabilitiesPlistData(deviceName: String) throws -> Data

    /// Raw `chrome.json` for a chrome bundle (bare identifier — no
    /// `com.apple.dt.devicekit.chrome.` prefix).
    func chromeJSONData(chromeIdentifier: String) throws -> Data

    /// Raw PDF bytes for one image inside a chrome bundle. `imageName`
    /// is the basename from `chrome.json` (e.g. `"PhoneComposite"`,
    /// `"Mute BTN"`); the store appends `.pdf`.
    func chromeAssetPDF(chromeIdentifier: String, imageName: String) throws -> Data

    /// Raw PDF bytes of a framebuffer mask, by the identifier a panel
    /// names in `capabilities.plist` (`framebufferMaskIdentifier`).
    /// Lives beside the chrome bundles under DeviceKit.
    func framebufferMaskPDF(identifier: String) throws -> Data
}
