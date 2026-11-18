import Testing
import Foundation
import Mockable
@testable import Baguette

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

    @Test func `should light the cover when folded`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 3))
        #expect(sim.litPanel(in: chromes) == .primary)
    }

    @Test func `should light the unfolded panel when open`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 130))
        #expect(sim.litPanel(in: chromes) == .secondary)
    }

    /// No reading means as booted: folded.
    @Test func `should light the cover when there is no hinge reading`() {
        let (sim, chromes) = duo(angle: nil)
        #expect(sim.litPanel(in: chromes) == .primary)
    }

    /// The hinge read is a guest round-trip; a phone must not pay it.
    @Test func `should never ask the hinge of a single-panel device`() {
        let sim = MockSimulator()
        let chromes = MockChromes()
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        #expect(sim.litPanel(in: chromes) == .primary)
        verify(sim).hinge().called(0)
    }

    @Test func `should show the lit panel's chrome`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 130))
        let unfolded = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone14",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [],
                compositeImageName: "X"
            ),
            composite: ChromeImage(data: Data(), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone Duo"), panel: .value(.secondary))
            .willReturn(unfolded)
        #expect(sim.chrome(in: chromes)?.chrome.identifier == "phone14")
    }

    /// The hinge's own answer, for callers that already know the device
    /// folds: no reading means as booted, folded.
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
        let sim = MockSimulator()
        let displays = MockDisplays()
        let cover = MockDisplay(), unfolded = MockDisplay()
        let coverInput = InputMocks(), unfoldedInput = InputMocks()
        let hinge = MockHinge()
        given(sim).displays().willReturn(displays)
        given(sim).hinge().willReturn(hinge)
        given(displays).panel(.value(.primary)).willReturn(cover)
        given(displays).panel(.value(.secondary)).willReturn(unfolded)
        given(cover).input().willReturn(coverInput)
        given(unfolded).input().willReturn(unfoldedInput)
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(unfoldedInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)

        #expect(sim.litPanelInput().tap(
            at: Point(x: 1, y: 2), size: Size(width: 669, height: 951), duration: 0.05, edge: nil))
        verify(unfoldedInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(1)
        verify(coverInput.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }
}
