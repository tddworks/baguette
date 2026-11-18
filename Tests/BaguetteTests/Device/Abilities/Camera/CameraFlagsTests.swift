import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraFlags")
struct CameraFlagsTests {
    @Test func `should pack no flags as zero`() {
        #expect(CameraFlags().packed() == 0)
    }

    @Test func `should pack fill gravity into bit 0`() {
        #expect(CameraFlags(fillGravity: true, mirror: false).packed() == 0b01)
    }

    @Test func `should pack mirroring into bit 1`() {
        #expect(CameraFlags(fillGravity: false, mirror: true).packed() == 0b10)
    }

    @Test func `should pack fill gravity and mirroring together`() {
        #expect(CameraFlags(fillGravity: true, mirror: true).packed() == 0b11)
    }
}
