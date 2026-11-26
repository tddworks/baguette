import Foundation

/// A foldable's hinge angle in degrees — `0` closed, `180` open flat —
/// as the host reads it back from the device.
///
/// The angle is the simulator runtime's: Device Hub streams hinge
/// samples into the guest as HID reports, CoreMotion delivers them to
/// SpringBoard, and SpringBoard's pose provider decides which panel to
/// light. baguette does not decide the pose; it reads the angle and
/// follows it, because the framebuffer it binds and the digitizer it
/// addresses both depend on the lit panel.
public struct HingeAngle: Equatable, Sendable {
    public let degrees: Double

    /// Where SpringBoard hands the display over to the unfolded panel.
    ///
    /// Measured on iPhone Duo / iOS 27.1 with the runtime's own
    /// transition rules: sweeping to 60° left the cover lit, sweeping to
    /// 90° lit the unfolded panel, and the pose provider's regions
    /// (`closed` / `partiallyOpen` / `openFlat`) begin the partially-open
    /// band there. Device Hub's poses land well clear of it on either
    /// side (closed ≈ 3°, open ≈ 130–180°).
    public static let openBoundaryDegrees: Double = 90

    public var litPanel: IntegratedPanel {
        degrees >= Self.openBoundaryDegrees ? .secondary : .primary
    }

    /// One line of `CoreMotionAngle read-angle` / `watch-angle` output, a
    /// sample the guest's CoreMotion flagged valid:
    ///
    ///     angle 130
    ///
    /// The first sample carries the current angle and arrives before any
    /// motion, so one line is a reading.
    public static func parse(coreMotionAngleLine line: String) -> HingeAngle? {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2, words[0] == "angle",
              let degrees = Double(words[1]), degrees.isFinite
        else { return nil }
        return HingeAngle(degrees: degrees)
    }

    @available(*, deprecated, renamed: "parse(coreMotionAngleLine:)")
    public static func parse(hingeControlLine line: String) -> HingeAngle? {
        parse(coreMotionAngleLine: line)
    }

    public init(degrees: Double) {
        self.degrees = degrees
    }
}
