import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Creating ports is only necessary when the device exposes none.
/// Calling updateIOPorts against an already-connected TVOut/CarPlay
/// resets guest display services and wedges the external surface.
@Suite("FramebufferRefresh")
struct FramebufferRefreshTests {
    @Test func `should not refresh IO ports when framebuffer displays already exist`() {
        #expect(FramebufferRefresh.shouldUpdate(hasFramebuffers: true) == false)
    }

    @Test func `should refresh IO ports when no framebuffer displays exist`() {
        #expect(FramebufferRefresh.shouldUpdate(hasFramebuffers: false) == true)
    }
}
