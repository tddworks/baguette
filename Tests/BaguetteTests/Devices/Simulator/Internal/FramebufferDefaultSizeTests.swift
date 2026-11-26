import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Framebuffer port default size is read only from accessors the port
/// actually exposes — missing KVC keys must return nil, not trap.
@Suite("FramebufferDefaultSize")
struct FramebufferDefaultSizeTests {
    @Test func `should find no default size when the framebuffer port exposes none`() {
        #expect(FramebufferDefaultSize.read(from: NSObject()) == nil)
    }

    @Test func `should read the default width and height when the port has them`() {
        final class FakePort: NSObject {
            @objc var defaultWidth: NSNumber = 800
            @objc var defaultHeight: NSNumber = 480
        }
        #expect(FramebufferDefaultSize.read(from: FakePort()) == Size(width: 800, height: 480))
    }

    @Test func `should fall back to plain width and height when the port has no default size`() {
        final class FakePort: NSObject {
            @objc var width: NSNumber = 390
            @objc var height: NSNumber = 844
        }
        #expect(FramebufferDefaultSize.read(from: FakePort()) == Size(width: 390, height: 844))
    }
}
