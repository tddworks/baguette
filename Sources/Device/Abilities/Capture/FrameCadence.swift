import Foundation

/// Decides which of the simulator's frames become frames of the
/// recording.
///
/// SimulatorKit delivers a surface whenever the screen *changes* — up to
/// 60 times a second while something is animating, and not at all while
/// the screen is still. A recording asked for 30 fps therefore can't
/// just take every surface: it keeps the first, then the next one that
/// arrives at least one frame-interval later, measured **from the frame
/// it actually kept** rather than from an absolute grid (a late frame
/// shouldn't drag every following slot early to "catch up").
///
/// Nothing is invented to fill a gap. A still screen produces no
/// surfaces, so the last kept frame simply stays on screen until the
/// next one arrives — which is exactly what the user saw.
public struct FrameCadence: Equatable, Sendable {
    public let fps: Int
    private var lastAccepted: Double?

    public init(fps: Int) {
        self.fps = fps
    }

    /// Seconds between kept frames. A non-positive rate means "keep
    /// everything" rather than dividing by zero.
    public var interval: Double {
        fps > 0 ? 1.0 / Double(fps) : 0
    }

    /// True when this arrival should become a frame of the recording.
    /// Mutating: accepting advances the cadence.
    public mutating func accepts(_ time: Double) -> Bool {
        guard let lastAccepted else {
            self.lastAccepted = time
            return true
        }
        // Wall-clock readings never land exactly on the interval, so a
        // hair early still counts — otherwise a 60 fps source recorded
        // at 60 fps drops every other frame to 30.
        let tolerance = interval * 0.05
        guard time - lastAccepted >= interval - tolerance else { return false }
        self.lastAccepted = time
        return true
    }
}
