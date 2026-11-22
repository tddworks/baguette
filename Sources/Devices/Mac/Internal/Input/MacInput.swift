import BaguetteDevice
import Foundation

/// A Mac display's input, through the window server: a finger is the mouse
/// (one pointer — a second finger sends nothing), keys and typing are the
/// Mac's keyboard, the wheel its scroll. What each gesture becomes is
/// `DisplayEvents`'; this only tells the window server.
struct MacInput: Touch, Scroll, Key, Typing {
    let display: DisplayEvents
    let events: any HostEvents

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        events.post(display.tap(at: point, size: size, duration: duration))
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        events.post(display.swipe(from: start, to: end, size: size, duration: duration))
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        events.post(display.touch1(phase: phase, at: point, size: size))
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool { false }

    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        false
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        events.post(display.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let pressed = display.key(key, modifiers: modifiers, duration: duration) else { return false }
        return events.post(pressed)
    }

    func type(_ text: String) -> Bool {
        events.post(display.type(text))
    }
}
