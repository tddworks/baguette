import Testing
import Foundation
@testable import BaguetteCore

@Suite("CameraFlags")
struct CameraFlagsTests {
    @Test func `default flags pack to zero`() {
        #expect(CameraFlags().packed() == 0)
    }

    @Test func `fillGravity sets bit 0`() {
        #expect(CameraFlags(fillGravity: true, mirror: false).packed() == 0b01)
    }

    @Test func `mirror sets bit 1`() {
        #expect(CameraFlags(fillGravity: false, mirror: true).packed() == 0b10)
    }

    @Test func `both flags OR together`() {
        #expect(CameraFlags(fillGravity: true, mirror: true).packed() == 0b11)
    }
}
