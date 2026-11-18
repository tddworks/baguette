import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// One screen's input roles as mocks — and, forwarding each role to its
/// mock, a whole simulator HID, for what wraps one.
final class InputMocks: HID, @unchecked Sendable {
    let touch = MockTouch()
    let press = MockPress()
    let key = MockKey()
    let scroll = MockScroll()

    /// The abilities a gesture asks, every role registered.
    var abilities: Abilities { .input(of: "iPhone 17", all: self) }

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        touch.tap(at: point, size: size, duration: duration, edge: edge)
    }
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        touch.swipe(from: start, to: end, size: size, duration: duration)
    }
    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        touch.touch1(phase: phase, at: point, size: size, edge: edge)
    }
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        touch.touch2(phase: phase, first: first, second: second, size: size)
    }
    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        touch.twoFingerPath(start1: start1, end1: end1, start2: start2, end2: end2, size: size, duration: duration)
    }
    var available: Set<DeviceButton> { press.available }
    func button(_ button: DeviceButton, duration: Double) -> Bool { press.button(button, duration: duration) }
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        self.key.key(key, modifiers: modifiers, duration: duration)
    }
    func scroll(deltaX: Double, deltaY: Double) -> Bool { scroll.scroll(deltaX: deltaX, deltaY: deltaY) }
}
