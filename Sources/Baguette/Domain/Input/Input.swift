import Foundation
import Mockable

/// The simulator's input surface. Each gesture's `execute(on:)` calls
/// exactly one method here. The infrastructure adapter translates these
/// into private SimulatorKit calls; tests substitute `MockInput`.
@Mockable
protocol Input: Sendable {
    func tap(at point: Point, size: Size, duration: Double) -> Bool
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool
    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool
    func button(_ button: DeviceButton) -> Bool
    func scroll(deltaX: Double, deltaY: Double) -> Bool

    /// Two-finger interpolated path — both pinch and pan reduce to "each
    /// finger has a start and end; bridge interpolates." Coordinates are
    /// point-space (not normalized).
    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool
}
