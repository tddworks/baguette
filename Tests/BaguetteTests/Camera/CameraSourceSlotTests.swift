import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// A staged camera source lands in a directory named after the
/// simulator it belongs to, and that udid arrives straight off the
/// request path — so the slot name is the boundary that keeps a crafted
/// udid from naming somewhere else on the filesystem.
@Suite("CameraSourceSlot")
struct CameraSourceSlotTests {

    @Test func `should give a real udid its own staging slot`() {
        let slot = CameraSourceSlot(udid: "A1B2C3D4-5E6F-7089-ABCD-EF0123456789")
        #expect(slot?.name == "A1B2C3D4-5E6F-7089-ABCD-EF0123456789")
    }

    @Test func `should give distinct udids distinct staging slots`() {
        #expect(CameraSourceSlot(udid: "sim-A") != CameraSourceSlot(udid: "sim-B"))
    }

    @Test func `should give no staging slot when the udid carries a path separator`() {
        #expect(CameraSourceSlot(udid: "../../etc") == nil)
        #expect(CameraSourceSlot(udid: "a/b") == nil)
        #expect(CameraSourceSlot(udid: "..") == nil)
    }

    /// `udidParam` percent-decodes, so `%2F` reaches us as a real slash
    /// and `.` / `..` as real dots — the traversal payloads have to die
    /// here rather than at the URL layer.
    @Test func `should give no staging slot when the udid decodes into a traversal`() {
        #expect(CameraSourceSlot(udid: "..%2F..%2Ftmp".removingPercentEncoding!) == nil)
    }

    @Test func `should give no staging slot when the udid is empty`() {
        #expect(CameraSourceSlot(udid: "") == nil)
    }

    @Test func `should give no staging slot when the udid has a null byte or whitespace`() {
        #expect(CameraSourceSlot(udid: "sim\0evil") == nil)
        #expect(CameraSourceSlot(udid: "sim evil") == nil)
    }

    @Test func `should give no staging slot when the udid is absurdly long`() {
        #expect(CameraSourceSlot(udid: String(repeating: "A", count: 300)) == nil)
    }
}
