import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A Mac display's input: a finger is the mouse, the keyboard is the Mac's,
/// and each gesture reaches the window server as the events it becomes.
@Suite("MacInput")
struct MacInputTests {
    let size = Size(width: 1920, height: 1080)

    /// The window server, remembering every event it is told.
    final class Desktop: @unchecked Sendable {
        let events = MockHostEvents()
        private let lock = NSLock()
        private var _posted: [HostEvent] = []
        var posted: [HostEvent] { lock.withLock { _posted } }

        init(accepts: Bool = true) {
            given(events).post(.any).willProduce { [self] batch in
                lock.withLock { _posted += batch }
                return accepts
            }
        }
    }

    func input(on desktop: Desktop) -> MacInput {
        MacInput(display: { [size] in DisplayEvents(bounds: Rect(origin: Point(x: 0, y: 0), size: size)) }, events: desktop.events)
    }

    @Test func `should land a tap on the Mac as a click`() {
        let desktop = Desktop()
        #expect(input(on: desktop).tap(at: Point(x: 5, y: 6), size: size, duration: 0, edge: nil))
        #expect(desktop.posted == [.mouseDown(Point(x: 5, y: 6)), .pause(0), .mouseUp(Point(x: 5, y: 6))])
    }

    @Test func `should drag the Mac's mouse as a finger lands, moves and lifts`() {
        let desktop = Desktop()
        let mac = input(on: desktop)
        #expect(mac.touch1(phase: .down, at: Point(x: 1, y: 2), size: size, edge: nil))
        #expect(mac.touch1(phase: .move, at: Point(x: 3, y: 4), size: size, edge: nil))
        #expect(mac.touch1(phase: .up, at: Point(x: 3, y: 4), size: size, edge: nil))
        #expect(desktop.posted == [.mouseDown(Point(x: 1, y: 2)), .mouseDragged(Point(x: 3, y: 4)), .mouseUp(Point(x: 3, y: 4))])
    }

    @Test func `should land a swipe on the Mac as a drag from start to end`() {
        let desktop = Desktop()
        #expect(input(on: desktop).swipe(from: Point(x: 0, y: 0), to: Point(x: 60, y: 0), size: size, duration: 0))
        #expect(desktop.posted.first == .mouseDown(Point(x: 0, y: 0)))
        #expect(desktop.posted.last == .mouseUp(Point(x: 60, y: 0)))
    }

    @Test func `should report a tap unsent when the Mac refuses its events`() {
        #expect(!input(on: Desktop(accepts: false)).tap(at: Point(x: 5, y: 6), size: size, duration: 0, edge: nil))
    }

    @Test func `should scroll the Mac as two fingers move together`() {
        let desktop = Desktop()
        let mac = input(on: desktop)
        #expect(mac.touch2(phase: .down, first: Point(x: 100, y: 500), second: Point(x: 300, y: 500), size: size))
        #expect(mac.touch2(phase: .move, first: Point(x: 100, y: 480), second: Point(x: 300, y: 480), size: size))
        #expect(mac.touch2(phase: .move, first: Point(x: 100, y: 470), second: Point(x: 300, y: 470), size: size))
        #expect(mac.touch2(phase: .up, first: Point(x: 100, y: 470), second: Point(x: 300, y: 470), size: size))
        #expect(desktop.posted == [.scroll(at: Point(x: 200, y: 480), deltaX: 0, deltaY: -20),
                                   .scroll(at: Point(x: 200, y: 470), deltaX: 0, deltaY: -10)])
    }

    @Test func `should start each two-finger scroll afresh after the fingers lift`() {
        let desktop = Desktop()
        let mac = input(on: desktop)
        _ = mac.touch2(phase: .down, first: Point(x: 0, y: 0), second: Point(x: 10, y: 0), size: size)
        _ = mac.touch2(phase: .up, first: Point(x: 0, y: 0), second: Point(x: 10, y: 0), size: size)
        // A quarter of the way down: a point the display's scale keeps exact.
        _ = mac.touch2(phase: .down, first: Point(x: 0, y: 0), second: Point(x: 10, y: 0), size: size)
        _ = mac.touch2(phase: .move, first: Point(x: 0, y: 270), second: Point(x: 10, y: 270), size: size)
        #expect(desktop.posted == [.scroll(at: Point(x: 5, y: 270), deltaX: 0, deltaY: 270)])
    }

    @Test func `should scroll the Mac along a two-finger path`() {
        let desktop = Desktop()
        #expect(input(on: desktop).twoFingerPath(
            start1: Point(x: 0, y: 100), end1: Point(x: 0, y: 40),
            start2: Point(x: 50, y: 100), end2: Point(x: 50, y: 40), size: size, duration: 0.2))
        #expect(desktop.posted == [.scroll(at: Point(x: 25, y: 40), deltaX: 0, deltaY: -60)])
    }

    @Test func `should move the Mac's pointer as it hovers`() {
        let desktop = Desktop()
        #expect(input(on: desktop).move(to: Point(x: 7, y: 8), size: size))
        #expect(desktop.posted == [.mouseMoved(Point(x: 7, y: 8))])
    }

    @Test func `should press a key on the Mac's keyboard`() {
        let desktop = Desktop()
        let a = KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0x04))
        #expect(input(on: desktop).key(a, modifiers: [], duration: 0))
        #expect(desktop.posted == [.key(code: 0, down: true, held: []), .pause(0), .key(code: 0, down: false, held: [])])
    }

    @Test func `should press nothing when the Mac has no such key`() {
        let desktop = Desktop()
        #expect(!input(on: desktop).key(KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0xE8)), modifiers: [], duration: 0))
        #expect(desktop.posted.isEmpty)
    }

    @Test func `should scroll and type on the Mac`() {
        let desktop = Desktop()
        let mac = input(on: desktop)
        #expect(mac.scroll(deltaX: 0, deltaY: 10))
        #expect(mac.type("ok"))
        #expect(desktop.posted == [.scroll(at: nil, deltaX: 0, deltaY: -10), .text("ok")])
    }
}
