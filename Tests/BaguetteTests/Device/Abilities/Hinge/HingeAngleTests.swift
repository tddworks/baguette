import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A foldable's hinge angle, as `CoreMotionAngle` reports it from the
/// guest, and which panel that angle leaves lit.
///
/// The simulator runtime decides the swap itself (SpringBoard's pose
/// provider, fed by CoreMotion): closed lights the cover, and from the
/// partially-open region up the unfolded panel takes over. baguette only
/// needs the side of that boundary, because it is what decides which
/// framebuffer to bind and which digitizer to address.
@Suite("HingeAngle")
struct HingeAngleTests {

    // MARK: - parsing CoreMotionAngle

    /// The helper prints one line per valid sample.
    @Test func `should read the angle from a CoreMotionAngle sample line`() {
        #expect(HingeAngle.parse(coreMotionAngleLine: "angle 130") == HingeAngle(degrees: 130))
        #expect(HingeAngle.parse(coreMotionAngleLine: "angle 3.2") == HingeAngle(degrees: 3.2))
    }

    /// Diagnostics and anything else the helper prints are not samples.
    @Test func `should find no angle when a line is not a sample`() {
        for line in ["", "angle", "angle 130 extra", "angle open", "angle nan", "angle inf", "pid 42", "done 0", "Angle 130"] {
            #expect(HingeAngle.parse(coreMotionAngleLine: line) == nil, "\(line)")
        }
    }

    // MARK: - lit panel

    @Test func `should light the cover when closed`() {
        #expect(HingeAngle(degrees: 0).litPanel == .primary)
        #expect(HingeAngle(degrees: 3.2).litPanel == .primary)
        #expect(HingeAngle(degrees: 60).litPanel == .primary)
    }

    @Test func `should light the unfolded panel when open`() {
        #expect(HingeAngle(degrees: 180).litPanel == .secondary)
        #expect(HingeAngle(degrees: 130).litPanel == .secondary)
        #expect(HingeAngle(degrees: 90).litPanel == .secondary)
    }

    @Test func `should swap panels where SpringBoard's partially-open region begins`() {
        #expect(HingeAngle(degrees: HingeAngle.openBoundaryDegrees).litPanel == .secondary)
        #expect(HingeAngle(degrees: HingeAngle.openBoundaryDegrees - 1).litPanel == .primary)
    }
}
