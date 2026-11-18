import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// End-to-end smoke against real DeviceKit assets. Skipped when the
/// host machine doesn't have DeviceKit installed (e.g. CI without
/// Xcode), so this stays useful locally without breaking the build
/// elsewhere.
private let deviceKitAvailable: Bool =
    FileManager.default.fileExists(atPath: "/Library/Developer/DeviceKit/Chrome")

@Suite("Chrome integration", .enabled(if: deviceKitAvailable))
struct ChromeIntegrationTests {

    @Test func `should load the iPhone 17 Pro bezel from its baked composite`() throws {
        // phone11 ships with iPhone 17 Pro on Xcode 26. The composite
        // path (vs. the 9-slice path covered below) — same chain, just
        // a different branch through LiveChromes.loadComposite.
        try expectLoadable(deviceName: "iPhone 17 Pro", chromeID: "phone11")
    }

    // 9-slice bundles — every iPad bundle ships only the corner / edge
    // pieces, no baked composite. One device per identifier exercises
    // every slice the LiveChromes path can take. iPhone 17e (phone13)
    // is the iPhone-shaped 9-slice case.

    @Test func `should compose the iPad Pro M4 bezel from nine slices`() throws {
        try expectLoadable(deviceName: "iPad Pro 11-inch (M4)", chromeID: "tablet5")
    }

    @Test func `should compose the iPad Air M2 bezel from nine slices`() throws {
        try expectLoadable(deviceName: "iPad Air 11-inch (M2)", chromeID: "tablet4")
    }

    @Test func `should compose the iPad mini A17 Pro bezel from nine slices`() throws {
        try expectLoadable(deviceName: "iPad mini (A17 Pro)", chromeID: "tablet3")
    }

    @Test func `should compose the iPad Pro 11 bezel from nine slices`() throws {
        try expectLoadable(
            deviceName: "iPad Pro (11-inch) (4th generation)",
            chromeID: "tablet2"
        )
    }

    @Test func `should compose the classic iPad bezel from nine slices`() throws {
        try expectLoadable(deviceName: "iPad (9th generation)", chromeID: "tablet")
    }

    @Test func `should compose the iPhone 17e bezel from nine slices`() throws {
        try expectLoadable(deviceName: "iPhone 17e", chromeID: "phone13")
    }

    /// Drive the real chain end-to-end: simulator name → profile.plist
    /// → DeviceKit bundle → composed PNG. Asserts the parsed identifier
    /// matches the expected bundle, the rasterized image has positive
    /// pixel dimensions and PNG magic, and the layout JSON publishes a
    /// non-zero screen rect inside the merged composite. Returns early
    /// when the specific simdevicetype isn't installed on the host
    /// (e.g. CI with a trimmed Xcode that ships fewer device types) —
    /// the test passes vacuously rather than failing on missing input.
    private func expectLoadable(deviceName: String, chromeID: String) throws {
        let typePath = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/\(deviceName).simdevicetype"
        guard FileManager.default.fileExists(atPath: typePath) else {
            return
        }

        let chromes = LiveChromes(
            store: FileSystemChromeStore(),
            rasterizer: CoreGraphicsPDFRasterizer()
        )
        let assets = try #require(chromes.assets(forDeviceName: deviceName))
        #expect(assets.chrome.identifier == chromeID)
        #expect(assets.composite.size.width > 0)
        #expect(assets.composite.size.height > 0)
        #expect(assets.composite.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let layout = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]
        let screen = try #require(layout?["screen"] as? [String: Any])
        #expect((screen["width"] as? Double ?? 0) > 0)
        #expect((screen["height"] as? Double ?? 0) > 0)
    }
}
