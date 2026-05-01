import Testing
import Foundation
@testable import Baguette

/// End-to-end smoke against real DeviceKit assets. Skipped when the
/// host machine doesn't have DeviceKit installed (e.g. CI without
/// Xcode), so this stays useful locally without breaking the build
/// elsewhere.
private let deviceKitAvailable: Bool =
    FileManager.default.fileExists(atPath: "/Library/Developer/DeviceKit/Chrome")

@Suite("Chrome integration", .enabled(if: deviceKitAvailable))
struct ChromeIntegrationTests {

    @Test func `loads phone11 chrome from disk and rasterizes the composite`() throws {
        // phone11 ships with iPhone 17 Pro on Xcode 26. If a future
        // Xcode renames the family, switch the device name; the chain
        // itself is what we're verifying.
        let store = FileSystemChromeStore()
        let rasterizer = CoreGraphicsPDFRasterizer()
        let chromes = LiveChromes(store: store, rasterizer: rasterizer)

        let assets = try #require(chromes.assets(forDeviceName: "iPhone 17 Pro"))
        #expect(assets.chrome.identifier == "phone11")
        #expect(assets.composite.size.width > 0)
        #expect(assets.composite.size.height > 0)
        // PNG magic.
        #expect(assets.composite.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        // Sanity: layout JSON parses and reports the screen rect we
        // expect from a real bezel (insets > 0).
        let layout = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]
        let screen = layout?["screen"] as? [String: Any]
        #expect((screen?["x"] as? Double ?? 0) > 0)
    }
}
