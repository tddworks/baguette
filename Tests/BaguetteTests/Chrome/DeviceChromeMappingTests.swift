import Testing
import Foundation
@testable import Baguette

/// Pin the device-name → chrome-bundle mapping that drives every
/// rendered bezel.
///
/// Apple ships the lookup data in two places we can't change:
///   1. `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/<name>.simdevicetype/.../profile.plist`
///      — `chromeIdentifier` key tells us which DeviceKit bundle to use.
///   2. `/Library/Developer/DeviceKit/Chrome/<identifier>.devicechrome/.../chrome.json`
///      — geometry + button data for that bundle.
///
/// The actionable-bezel UI was originally tuned against the WRONG
/// chrome bundle for iPhone 17 Pro Max — we read `phone11` while the
/// real device routes to `phone12`. Visually similar bundles, but
/// different composite sizes (436×908 vs 474×990) and button
/// y-coordinates throw off per-pixel positioning.
///
/// Critically, sibling devices in the *same* generation route to
/// DIFFERENT bundles (iPhone 17 Pro → phone11 but iPhone 17 Pro Max
/// → phone12), so guessing from the device-name family is unsafe;
/// only the profile plist's `chromeIdentifier` is authoritative.
///
/// These tests fail loudly if:
///   - Apple changes which bundle a device routes to in a future
///     Xcode release (we'll know to re-tune any per-device tuning).
///   - Our `DeviceProfile` parser stops returning the bare bundle
///     identifier (e.g. starts returning the full reverse-DNS form
///     and silently breaks the chrome-bundle path resolver).
///   - The DeviceKit bundle for one of these devices ships
///     materially different composite geometry than we expect.
///
/// Skipped when the host machine doesn't have Xcode + DeviceKit
/// installed (matches the gate the existing chrome-integration
/// suite uses).
private let deviceKitAvailable: Bool =
    FileManager.default.fileExists(atPath: "/Library/Developer/DeviceKit/Chrome")
    && FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")

@Suite("DeviceChrome mapping (real DeviceKit assets)", .enabled(if: deviceKitAvailable))
struct DeviceChromeMappingTests {

    /// Each row asserts that a popular CoreSimulator device routes
    /// through the production `FileSystemChromeStore` to a specific
    /// chrome bundle identifier — and that the bundle, when loaded,
    /// produces a composite of the expected pixel size. Adding new
    /// device coverage is one row here; the table is the regression
    /// surface.
    ///
    /// Mappings verified against Xcode 26 (May 2026):
    ///   iPhone 17 Pro Max → phone12  (474×990, big "Pro Max" bezel)
    ///   iPhone 17 Pro     → phone11  (436×908, smaller Pro bezel)
    ///   iPhone 16 Pro Max → phone12  (same chassis as 17 Pro Max)
    ///   iPhone 17e        → phone13  (9-slice composition path)
    static let cases: [(deviceName: String, expectedBundle: String, compositeSize: Size)] = [
        ("iPhone 17 Pro Max", "phone12", Size(width: 474, height: 990)),
        ("iPhone 17 Pro",     "phone11", Size(width: 436, height: 908)),
        ("iPhone 16 Pro Max", "phone12", Size(width: 474, height: 990)),
    ]

    @Test(arguments: cases)
    func `device name resolves to expected chrome bundle and composite size`(
        _ row: (deviceName: String, expectedBundle: String, compositeSize: Size)
    ) throws {
        let store = FileSystemChromeStore()

        // 1. Profile plist → bare chrome identifier. If the specific
        //    simdevicetype isn't installed on this host, return
        //    quietly — different developers have different Xcode
        //    install sets, and we don't want one missing device to
        //    sink the whole regression check.
        let plist: Data
        do {
            plist = try store.profilePlistData(deviceName: row.deviceName)
        } catch {
            return
        }
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(
            profile.chromeIdentifier == row.expectedBundle,
            """
            \(row.deviceName) routed to chrome bundle '\(profile.chromeIdentifier)'
            but the front-end + per-button images are tuned for
            '\(row.expectedBundle)'. Either Apple changed the mapping in
            this Xcode release (update the table) or our DeviceProfile parser
            is dropping the bare-identifier transform.
            """
        )

        // 2. Bundle → composite size. End-to-end LiveChromes path
        //    parses chrome.json, rasterizes the composite PDF, and
        //    returns its size. If Apple re-rasterizes the PDF at
        //    different dimensions in a future release, the front-end
        //    percentage math drifts — catch that here too.
        let chromes = LiveChromes(store: store, rasterizer: CoreGraphicsPDFRasterizer())
        let assets = try #require(chromes.assets(forDeviceName: row.deviceName))
        #expect(
            assets.bareComposite.size == row.compositeSize,
            """
            \(row.deviceName) bare composite size is \(assets.bareComposite.size)
            but the front-end positioning math expects \(row.compositeSize).
            DeviceKit may have re-rasterized the composite PDF; re-check the
            bezel-buttons.js coordinate space.
            """
        )
    }
}
