import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// iPhone Duo's page keeps one socket across a fold: the book draws both
/// panels, so nothing reconnects when the hinge lights the other one.
/// Its input follows the lit panel gesture by gesture, and a finger stays
/// on the digitizer it touched down on until it lifts.
@Suite("LitPanelInput")
struct LitPanelInputTests {

    /// The angle the mock hinge reports; tests fold it by setting `lit`.
    final class Fold: @unchecked Sendable {
        var lit: IntegratedPanel = .primary
    }

    private func make() -> (LitPanelInput, cover: InputMocks, unfolded: InputMocks, Fold) {
        let cover = InputMocks()
        let unfolded = InputMocks()
        for panel in [cover, unfolded] {
            given(panel.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
            given(panel.key).key(.any, modifiers: .any, duration: .any).willReturn(true)
            given(panel.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
            given(panel.touch).touch2(phase: .any, first: .any, second: .any, size: .any).willReturn(true)
            given(panel.touch).swipe(from: .any, to: .any, size: .any, duration: .any).willReturn(true)
            given(panel.press).button(.any, duration: .any).willReturn(true)
            given(panel.scroll).scroll(deltaX: .any, deltaY: .any).willReturn(true)
            given(panel.touch).twoFingerPath(
                start1: .any, end1: .any, start2: .any, end2: .any, size: .any, duration: .any
            ).willReturn(true)
        }
        let fold = Fold()
        let hinge = MockHinge()
        given(hinge).angle().willProduce { HingeAngle(degrees: fold.lit == .primary ? 0 : 130) }
        let input = LitPanelInput(cover: cover, unfolded: unfolded, hinge: hinge)
        return (input, cover, unfolded, fold)
    }

    private let size = Size(width: 466, height: 678)
    private let point = Point(x: 100, y: 200)

    @Test func `should land a tap on the cover when the device is folded`() {
        let (input, cover, unfolded, _) = make()
        #expect(input.tap(at: point, size: size, duration: 0.05, edge: nil))
        verify(cover.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(1)
        verify(unfolded.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }

    @Test func `should land a tap on the unfolded panel when the device is unfolded`() {
        let (input, cover, unfolded, hinge) = make()
        hinge.lit = .secondary
        #expect(input.tap(at: point, size: size, duration: 0.05, edge: nil))
        verify(unfolded.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(1)
        verify(cover.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }

    @Test func `should type into the cover when the device folds between keystrokes`() {
        let (input, cover, unfolded, hinge) = make()
        let a = KeyboardKey.from(wireCode: "KeyA")!
        hinge.lit = .secondary
        #expect(input.key(a, modifiers: [], duration: 0))
        hinge.lit = .primary
        #expect(input.key(a, modifiers: [], duration: 0))
        verify(unfolded.key).key(.any, modifiers: .any, duration: .any).called(1)
        verify(cover.key).key(.any, modifiers: .any, duration: .any).called(1)
    }

    @Test func `should send swipes, buttons, scrolls and two-finger paths to the unfolded panel when the device is unfolded`() {
        let (input, cover, unfolded, hinge) = make()
        hinge.lit = .secondary
        #expect(input.swipe(from: point, to: Point(x: 100, y: 500), size: size, duration: 0.3))
        #expect(input.button(.navigation(.home), duration: 0))
        #expect(input.scroll(deltaX: 0, deltaY: 40))
        #expect(input.twoFingerPath(
            start1: point, end1: point, start2: point, end2: point, size: size, duration: 0.3))
        verify(unfolded.touch).swipe(from: .any, to: .any, size: .any, duration: .any).called(1)
        verify(unfolded.press).button(.any, duration: .any).called(1)
        verify(unfolded.scroll).scroll(deltaX: .any, deltaY: .any).called(1)
        verify(unfolded.touch).twoFingerPath(
            start1: .any, end1: .any, start2: .any, end2: .any, size: .any, duration: .any
        ).called(1)
        verify(cover.touch).swipe(from: .any, to: .any, size: .any, duration: .any).called(0)
    }

    @Test func `should keep a drag on the panel it touched down on when the device folds mid-drag`() {
        let (input, cover, unfolded, hinge) = make()
        hinge.lit = .secondary
        #expect(input.touch1(phase: .down, at: point, size: size, edge: nil))
        hinge.lit = .primary
        #expect(input.touch1(phase: .move, at: point, size: size, edge: nil))
        #expect(input.touch1(phase: .up, at: point, size: size, edge: nil))
        verify(unfolded.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(3)
        verify(cover.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(0)
    }

    @Test func `should keep a pinch on the panel it touched down on when the device folds mid-pinch`() {
        let (input, cover, unfolded, hinge) = make()
        hinge.lit = .secondary
        #expect(input.touch2(phase: .down, first: point, second: point, size: size))
        hinge.lit = .primary
        #expect(input.touch2(phase: .up, first: point, second: point, size: size))
        verify(unfolded.touch).touch2(phase: .any, first: .any, second: .any, size: .any).called(2)
        verify(cover.touch).touch2(phase: .any, first: .any, second: .any, size: .any).called(0)
    }

    @Test func `should start the next drag on the newly lit panel when the finger has lifted`() {
        let (input, cover, unfolded, hinge) = make()
        hinge.lit = .secondary
        _ = input.touch1(phase: .down, at: point, size: size, edge: nil)
        _ = input.touch1(phase: .up, at: point, size: size, edge: nil)
        hinge.lit = .primary
        #expect(input.touch1(phase: .down, at: point, size: size, edge: nil))
        verify(unfolded.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(2)
        verify(cover.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(1)
    }

    @Test func `should keep a drag on its panel when a pinch ends during it and the device then folds`() {
        let (input, cover, unfolded, fold) = make()
        fold.lit = .secondary
        _ = input.touch1(phase: .down, at: point, size: size, edge: nil)
        _ = input.touch2(phase: .down, first: point, second: point, size: size)
        _ = input.touch2(phase: .up, first: point, second: point, size: size)
        fold.lit = .primary
        #expect(input.touch1(phase: .up, at: point, size: size, edge: nil))
        verify(unfolded.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(2)
        verify(cover.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).called(0)
    }
}
