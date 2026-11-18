import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Xcode 27 stopped publishing screen dimensions in `profile.plist`.
/// The `mainScreenWidth` / `mainScreenHeight` / `mainScreenScale` keys
/// that every Xcode ≤26 device type carried are gone — 124 of 124
/// profiles have them on Xcode 26, 0 of 124 on Xcode 27 — and the
/// numbers moved to a sibling `capabilities.plist` under a `displays`
/// list.
///
/// Only the 9-slice chrome path reads a screen size (the composite path
/// returns its baked PDF first), so the visible symptom is that every
/// 9-slice device loses its bezel while composite devices keep theirs.
///
/// Each device lists several displays — `tvOut` and `carPlay` at
/// 720×480, and a `scene` entry at 7680×4320. Only the `integrated`
/// one describes the device's own screen, so selecting on
/// `displayType` is what keeps a bezel from being sized off a
/// resizable-scene canvas.
@Suite("DeviceProfile screen size across Xcode versions")
struct DeviceProfileCapabilitiesTests {

    /// Xcode ≤26 shape: dimensions inline on the profile.
    private func legacyProfile() -> Data {
        let plist: [String: Any] = [
            "chromeIdentifier": "com.apple.dt.devicekit.chrome.tablet5",
            "mainScreenWidth": 1668,
            "mainScreenHeight": 2420,
            "mainScreenScale": 2,
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }

    /// Xcode 27 shape: profile keeps the chrome id, drops the screen.
    private func modernProfile() -> Data {
        let plist: [String: Any] = [
            "chromeIdentifier": "com.apple.dt.devicekit.chrome.tablet5"
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }

    /// Mirrors the real iPad Pro 11-inch (M4) capabilities: the
    /// integrated panel plus the decoys that must not be picked.
    private func capabilities() -> Data {
        let plist: [String: Any] = [
            "capabilities": [
                "displays": [
                    [
                        "displayType": "integrated",
                        "displayName": "LCD",
                        "width": 1668, "height": 2420, "scale": 2,
                    ],
                    [
                        "displayType": "tvOut",
                        "displayName": "TVOut",
                        "width": 720, "height": 480, "scale": 1,
                    ],
                    [
                        "displayType": "scene",
                        "displayName": "Resizable",
                        "width": 7680, "height": 4320, "scale": 3,
                    ],
                ]
            ]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }

    /// Mirrors iPhone Duo (iOS 27.1): two `integrated` panels. The
    /// cover is `primary`; the larger unfolded one is `primary-1`, and
    /// listed second here as it is on disk — but ordering is not the
    /// rule, the name is, so the fixture also tries it first.
    private func foldableCapabilities(unfoldedFirst: Bool) -> Data {
        let cover: [String: Any] = [
            "displayType": "integrated", "deviceName": "primary",
            "displayName": "LCD",
            "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone15",
            "framebufferMaskIdentifier": "1C896A2B-F0D7-405C-8D0F-66E4B80AD044",
            "width": 1398, "height": 2034, "scale": 3,
        ]
        let unfolded: [String: Any] = [
            "displayType": "integrated", "deviceName": "primary-1",
            "displayName": "LCD-1",
            "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone14",
            "framebufferMaskIdentifier": "BF0DC480-5EE2-4EC1-B02B-C75E94759832",
            "width": 2007, "height": 2853, "scale": 3,
        ]
        let plist: [String: Any] = [
            "capabilities": [
                "displays": unfoldedFirst ? [unfolded, cover] : [cover, unfolded]
            ]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }

    @Test func `should size a foldable's screen to its primary panel whatever the listing order`() throws {
        for unfoldedFirst in [false, true] {
            let profile = try DeviceProfile.parsing(
                plistData: modernProfile(),
                capabilitiesData: foldableCapabilities(unfoldedFirst: unfoldedFirst)
            )
            // 1398x2034 @3 — the cover, which is what the guest lights.
            #expect(profile.screenSize == Size(width: 466, height: 678))
        }
    }

    /// Each panel has its own DeviceKit chrome and its own size; the
    /// unfolded panel is what the bezel and the tap space become once
    /// the hinge opens.
    @Test func `should give a foldable's unfolded panel its own chrome, size and mask`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(),
            capabilitiesData: foldableCapabilities(unfoldedFirst: false)
        )
        let unfolded = try #require(profile.panel(.secondary))
        #expect(unfolded.chromeIdentifier == "phone14")
        #expect(unfolded.screenSize == Size(width: 669, height: 951))
        let cover = try #require(profile.panel(.primary))
        #expect(cover.chromeIdentifier == "tablet5")   // the profile's own id wins for the primary
        #expect(cover.screenSize == Size(width: 466, height: 678))
        #expect(profile.panels == [.primary, .secondary])
        // The shape CoreSimulator masks each framebuffer with: the
        // cover's hinge-side corners are nearly square, the unfolded
        // panel's four are even. `chrome.json`'s one radius cannot say
        // that; the mask can.
        #expect(unfolded.framebufferMaskIdentifier == "BF0DC480-5EE2-4EC1-B02B-C75E94759832")
        #expect(cover.framebufferMaskIdentifier == "1C896A2B-F0D7-405C-8D0F-66E4B80AD044")
    }

    @Test func `should leave a panel's mask unset when the device lists none`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: capabilities()
        )
        #expect(profile.panel(.primary)?.framebufferMaskIdentifier == nil)
    }

    @Test func `should offer only the primary panel on a single-panel device`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: capabilities()
        )
        #expect(profile.panel(.secondary) == nil)
        #expect(profile.panels == [.primary])
        #expect(profile.panel(.primary)?.screenSize == Size(width: 834, height: 1210))
    }

    @Test func `should read the screen size from the profile on Xcode 26`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: legacyProfile(), capabilitiesData: nil
        )

        #expect(profile.screenSize == Size(width: 834, height: 1210))
    }

    @Test func `should read the screen size from capabilities on Xcode 27`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: capabilities()
        )

        // 1668x2420 @2 — the same points the Xcode 26 profile gave.
        #expect(profile.screenSize == Size(width: 834, height: 1210))
    }

    @Test func `should ignore non-integrated displays when reading capabilities`() throws {
        // The scene display is 7680x4320 and listed last; picking it
        // would size a bezel off a resizable canvas rather than the
        // device panel.
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: capabilities()
        )

        #expect(profile.screenSize?.width == 834)
        #expect(profile.screenSize != Size(width: 2560, height: 1440))
    }

    @Test func `should prefer the profile's own screen size when both shapes are present`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: legacyProfile(), capabilitiesData: capabilities()
        )

        #expect(profile.screenSize == Size(width: 834, height: 1210))
    }

    @Test func `should leave the screen size unknown when neither shape carries one`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: nil
        )

        #expect(profile.screenSize == nil)
    }

    @Test func `should still read the chrome identifier on Xcode 27`() throws {
        let profile = try DeviceProfile.parsing(
            plistData: modernProfile(), capabilitiesData: capabilities()
        )

        #expect(profile.chromeIdentifier == "tablet5")
    }
}
