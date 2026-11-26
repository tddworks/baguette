import Foundation
import Testing
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `devicectl device info displays` as an iPhone Duo on iOS 27.1 answers
/// it (measured 2026-11-26), cut to the fields the report reads.
@Suite("CoreDeviceDisplayReport")
struct CoreDeviceDisplayReportTests {
    private static func report(coverActive: Bool, unfoldedActive: Bool) -> Data {
        Data("""
        {"info":{"outcome":"success"},"result":{"backlightState":"on","displays":[
          {"name":"LCD","displayId":1,"type":{"integrated":{}},"primary":true,"active":\(coverActive),"nativeSize":[1398,2034]},
          {"name":"LCD-1","displayId":3,"type":{"integrated":{}},"primary":false,"active":\(unfoldedActive),"nativeSize":[2007,2853]},
          {"name":"TV-Out","displayId":2,"type":{"external":{}},"primary":false,"active":false}
        ]}}
        """.utf8)
    }

    @Test func `should name the cover when Core Device marks the primary display active`() {
        #expect(CoreDeviceDisplayReport.presentingPanel(in: Self.report(coverActive: true, unfoldedActive: false)) == .primary)
    }

    @Test func `should name the unfolded panel when Core Device marks the other built-in display active`() {
        #expect(CoreDeviceDisplayReport.presentingPanel(in: Self.report(coverActive: false, unfoldedActive: true)) == .secondary)
    }

    @Test func `should say nothing when Core Device marks no built-in display active`() {
        #expect(CoreDeviceDisplayReport.presentingPanel(in: Self.report(coverActive: false, unfoldedActive: false)) == nil)
    }

    @Test func `should say nothing of an answer it cannot read`() {
        #expect(CoreDeviceDisplayReport.presentingPanel(in: Data("devicectl: error".utf8)) == nil)
    }
}
