import Testing
import Foundation
@testable import Baguette

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test func `parsing returns the bare chromeIdentifier`() throws {
        let plist = Self.makePlist(chromeIdentifier: "com.apple.dt.devicekit.chrome.phone11")
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.chromeIdentifier == "phone11")
    }

    @Test func `parsing leaves an already-bare identifier alone`() throws {
        let plist = Self.makePlist(chromeIdentifier: "phone11")
        let profile = try DeviceProfile.parsing(plistData: plist)
        #expect(profile.chromeIdentifier == "phone11")
    }

    @Test func `parsing throws on missing chromeIdentifier`() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["mainScreenWidth": 1320] as [String: Any],
            format: .xml, options: 0
        )
        #expect(throws: DeviceProfileParseError.missingChromeIdentifier) {
            _ = try DeviceProfile.parsing(plistData: plist)
        }
    }

    @Test func `parsing throws on malformed plist`() {
        #expect(throws: DeviceProfileParseError.self) {
            _ = try DeviceProfile.parsing(plistData: Data("not-a-plist".utf8))
        }
    }

    // PropertyListSerialization rejects empty data outright (vs. parsing
    // it as a string) — exercises the catch arm of the do/catch instead
    // of the "parsed but wrong shape" arm.
    @Test func `parsing throws malformedPlist when PropertyListSerialization rejects the bytes`() {
        #expect(throws: DeviceProfileParseError.malformedPlist) {
            _ = try DeviceProfile.parsing(plistData: Data())
        }
    }

    // A plist whose top level is an array (not a dict) — parser exits
    // through the `guard let dict` arm and reports malformedPlist.
    @Test func `parsing throws malformedPlist when the top level is not a dict`() throws {
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
