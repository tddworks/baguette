import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Which of a simulator's panels the chrome, screen and tap space
/// describe. On a foldable that is the hinge's call; everything else
/// has one panel and never asks.
@Suite("Simulator lit panel")
struct LitPanelTests {

    private func duo(angle: HingeAngle?) -> (MockSimulator, MockChromes) {
        let sim = MockSimulator()
        let chromes = MockChromes()
        let hinge = MockHinge()
        given(sim).deviceTypeName.willReturn("iPhone Duo")
        given(sim).hinge().willReturn(hinge)
        given(hinge).angle().willReturn(angle)
        given(chromes).panels(forDeviceName: .value("iPhone Duo")).willReturn([.primary, .secondary])
        return (sim, chromes)
    }

    @Test func `should take a hinge with no reading as folded`() {
        let hinge = MockHinge()
        given(hinge).angle().willReturn(nil)
        #expect(hinge.litPanel == .primary)
    }

    @Test func `should light the unfolded panel when the hinge is open`() {
        let hinge = MockHinge()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        #expect(hinge.litPanel == .secondary)
    }

    /// The page's 3D socket stays open across a fold, so the input it
    /// is given follows the hinge rather than binding one panel.
    @Test func `should give a foldable an input that follows the fold`() {
        let displays = MockDisplays()
        let cover = MockDisplay(), unfolded = MockDisplay()
        let coverInput = InputMocks(), unfoldedInput = InputMocks()
        let hinge = MockHinge()
        given(displays).panel(.value(.primary)).willReturn(cover)
        given(displays).panel(.value(.secondary)).willReturn(unfolded)
        given(cover).input().willReturn(coverInput)
        given(unfolded).input().willReturn(unfoldedInput)
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(unfoldedInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)

        #expect(LitPanelInput(displays: displays, hinge: hinge).tap(
            at: Point(x: 1, y: 2), size: Size(width: 669, height: 951), duration: 0.05, edge: nil))
        verify(unfoldedInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(1)
        verify(coverInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }
}
