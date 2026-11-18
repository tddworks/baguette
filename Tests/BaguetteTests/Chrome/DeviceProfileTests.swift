import Testing
import Foundation
@testable import Baguette

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test func `should strip the reverse-DNS prefix from a device's chrome identifier`() throws {
        let plist = Self.makePlist(chromeIdentifier: "com.apple.dt.devicekit.chrome.phone11")
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.chromeIdentifier == "phone11")
    }

    @Test func `should leave a chrome identifier alone when it is already bare`() throws {
        let plist = Self.makePlist(chromeIdentifier: "phone11")
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.chromeIdentifier == "phone11")
    }

    // mainScreenWidth/Height are in pixels; mainScreenScale converts to
    // 1x points. iPhone 17 Pro Max plist values: 1320×2868 @3x → 440×956
    // points. The 9-slice composer needs this to size the inner area
    // since `Screen.pdf` is just a 1×1 marker.
    @Test func `should size the screen in points from the profile's pixels and scale`() throws {
        let plist = Self.makePlist(chromeIdentifier: "phone12")
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.screenSize == Size(width: 440, height: 956))
    }

    @Test func `should leave the screen size unknown when any main screen key is missing`() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["chromeIdentifier": "phone12"] as [String: Any],
            format: .xml, options: 0
        )
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.screenSize == nil)
    }

    @Test func `should reject a device profile without a chrome identifier`() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["mainScreenWidth": 1320] as [String: Any],
            format: .xml, options: 0
        )
        #expect(throws: DeviceProfileParseError.missingChromeIdentifier) {
            _ = try DeviceProfile.parsing(plistData: plist)
        }
    }

    @Test func `should reject a device profile that isn't a plist`() {
        #expect(throws: DeviceProfileParseError.self) {
            _ = try DeviceProfile.parsing(plistData: Data("not-a-plist".utf8))
        }
    }

    // PropertyListSerialization rejects empty data outright (vs. parsing
    // it as a string) — exercises the catch arm of the do/catch instead
    // of the "parsed but wrong shape" arm.
    @Test func `should reject an empty device profile as malformed`() {
        #expect(throws: DeviceProfileParseError.malformedPlist) {
            _ = try DeviceProfile.parsing(plistData: Data())
        }
    }

    // A plist whose top level is an array (not a dict) — parser exits
    // through the `guard let dict` arm and reports malformedPlist.
    @Test func `should reject a device profile as malformed when its top level is not a dictionary`() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["a", "b"] as [String],
            format: .xml, options: 0
        )
        #expect(throws: DeviceProfileParseError.malformedPlist) {
            _ = try DeviceProfile.parsing(plistData: plist)
        }
    }
}

private extension DeviceProfileTests {
    static func makePlist(chromeIdentifier: String) -> Data {
        let dict: [String: Any] = [
            "chromeIdentifier": chromeIdentifier,
            "mainScreenWidth": 1320,
            "mainScreenHeight": 2868,
            "mainScreenScale": 3,
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
    }
}
