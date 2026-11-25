import Foundation

/// How a dragged finger reports: a real one reports at 120 Hz and never
/// jumps more than a few points between reports. A drag sent in a fixed
/// handful of moves jumps tens of points at a time over a long distance,
/// and UIKit's interactive transitions (a zoom transition's dismiss)
/// don't track it (#158).
public enum FingerPace {
    /// A finger's report rate on a ProMotion screen.
    public static let reportsPerSecond = 120.0
    /// The farthest a finger moves between two reports, in points.
    public static let longestStride = 10.0

    /// The moves a finger reports dragging from `start` to `end` over
    /// `duration` seconds: enough to keep each under `longestStride`
    /// and to report as often as a finger would, at least one.
    public static func moves(from start: Point, to end: Point, duration: Double) -> Int {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let byDistance = (distance / longestStride).rounded(.up)
        let byTime = (max(duration, 0) * reportsPerSecond).rounded(.up)
        return max(1, Int(max(byDistance, byTime)))
    }
}
