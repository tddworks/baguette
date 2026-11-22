import BaguetteDevice
import Foundation

/// A Mac display's input, through the window server: a finger is the mouse,
/// two fingers moving together scroll as on a trackpad, keys and typing are
/// the Mac's keyboard, the wheel its scroll. What each gesture becomes is
/// `DisplayEvents`' — of the display where it is now, asked at each gesture:
/// making a display main moves every display on the desktop. This tells the
/// window server, and remembers where two fingers last were while they're down.
struct MacInput: Touch, Pointer, Scroll, Key, Typing {
    let display: @Sendable () -> DisplayEvents
    let events: any HostEvents
    private let fingers = TwoFingers()

    init(display: @escaping @Sendable () -> DisplayEvents, events: any HostEvents) {
        self.display = display
        self.events = events
    }

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        events.post(display().tap(at: point, size: size, duration: duration))
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        events.post(display().swipe(from: start, to: end, size: size, duration: duration))
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        events.post(display().touch1(phase: phase, at: point, size: size))
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        let last = fingers.swap(phase == .up ? nil : (first, second))
        guard phase == .move, let last else { return true }
        let scrolled = display().twoFingerScroll(from: last, to: (first, second), size: size)
        return scrolled.isEmpty || events.post(scrolled)
    }

    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        let scrolled = display().twoFingerScroll(from: (start1, start2), to: (end1, end2), size: size)
        return scrolled.isEmpty || events.post(scrolled)
    }

    func move(to point: Point, size: Size) -> Bool {
        events.post(display().hover(at: point, size: size))
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        events.post(display().scroll(deltaX: deltaX, deltaY: deltaY))
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let pressed = display().key(key, modifiers: modifiers, duration: duration) else { return false }
        return events.post(pressed)
    }

    func type(_ text: String) -> Bool {
        events.post(display().type(text))
    }
}

/// Where two fingers were at their last report, while they're down.
private final class TwoFingers: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (Point, Point)?

    /// Remember `now`; answer what was remembered before.
    func swap(_ now: (Point, Point)?) -> (Point, Point)? {
        lock.withLock { defer { last = now }; return last }
    }
}
