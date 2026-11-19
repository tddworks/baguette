import Foundation
import Mockable

/// Fingers on a screen: a tap, a swipe, one or two fingers down, moved and
/// lifted. Every device that shows a screen has one. Coordinates are
/// device points, in the size each call carries.
@Mockable
public protocol Touch: Sendable {
    /// One-shot tap. `edge` flags the screen edge the finger lands on
    /// — the same hint `touch1` carries, and the only difference in
    /// the message a streamed touch and a `tap` build for one point.
    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool
    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool

    /// Two-finger interpolated path — both pinch and pan reduce to "each
    /// finger has a start and end; bridge interpolates."
    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool
}
