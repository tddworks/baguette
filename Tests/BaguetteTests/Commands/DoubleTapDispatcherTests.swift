import Foundation
import Testing
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// The single behaviour `baguette double-tap` adds on top of the existing
/// `Touch1` phased gestures: at one coordinate, send `down → up → down → up`
/// in **one process**, separated by `duration` (per-tap hold) and `interval`
/// (tap-1-up → tap-2-down gap). The CLI itself only wires argv onto these
/// parameters; the four-call timing recipe is what the iOS recognizer cares
/// about, so that's what we pin down here with a `InputMocks` and an
/// injectable sleep.
@Suite("DoubleTapDispatcher")
struct DoubleTapDispatcherTests {

    @Test func `should land a double tap as down, up, down, up at one point`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)

        _ = DoubleTapCommand.dispatch(
            at: Point(x: 220, y: 480),
            size: Size(width: 402, height: 874),
            interval: 0.05, duration: 0.08,
            on: input,
            sleep: { _ in }
        )

        verify(input.touch).touch1(
            phase: .value(.down),
            at:    .value(Point(x: 220, y: 480)),
            size:  .value(Size(width: 402, height: 874)),
            edge:  .value(nil)
        ).called(2)
        verify(input.touch).touch1(
            phase: .value(.up),
            at:    .value(Point(x: 220, y: 480)),
            size:  .value(Size(width: 402, height: 874)),
            edge:  .value(nil)
        ).called(2)
    }

    @Test func `should hold for duration, wait interval, then hold for duration between the four touches`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        var sleeps: [TimeInterval] = []

        _ = DoubleTapCommand.dispatch(
            at: Point(x: 1, y: 2),
            size: Size(width: 100, height: 200),
            interval: 0.05, duration: 0.08,
            on: input,
            sleep: { sleeps.append($0) }
        )

        #expect(sleeps == [0.08, 0.05, 0.08])
    }

    @Test func `should stop the double tap when the first touch down is refused`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).willReturn(false)
        given(input.touch).touch1(phase: .value(.up), at: .any, size: .any, edge: .any).willReturn(true)

        let ok = DoubleTapCommand.dispatch(
            at: Point(x: 1, y: 2),
            size: Size(width: 1, height: 1),
            interval: 0.05, duration: 0.08,
            on: input,
            sleep: { _ in }
        )

        #expect(!ok)
        verify(input.touch).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).called(1)
        verify(input.touch).touch1(phase: .value(.up), at: .any, size: .any, edge: .any).called(0)
    }

    @Test func `should report the double tap landed when the final lift succeeds`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).willReturn(true)
        given(input.touch).touch1(phase: .value(.up), at: .any, size: .any, edge: .any).willReturn(true)

        let ok = DoubleTapCommand.dispatch(
            at: Point(x: 1, y: 2),
            size: Size(width: 1, height: 1),
            interval: 0.05, duration: 0.08,
            on: input,
            sleep: { _ in }
        )

        #expect(ok)
    }
}
