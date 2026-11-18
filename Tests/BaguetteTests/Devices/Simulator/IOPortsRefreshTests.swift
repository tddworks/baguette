import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Creating ports is only necessary when the device exposes none.
/// Calling updateIOPorts against an already-connected TVOut/CarPlay
/// resets guest display services and wedges the external surface.
@Suite("IOPortsRefresh")
struct IOPortsRefreshTests {
    @Test func `should not refresh IO ports when framebuffer displays already exist`() {
        #expect(IOPortsRefresh.shouldUpdate(hasFramebufferDisplayPorts: true) == false)
    }

    @Test func `should refresh IO ports when no framebuffer displays exist`() {
        #expect(IOPortsRefresh.shouldUpdate(hasFramebufferDisplayPorts: false) == true)
    }
}
