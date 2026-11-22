import Foundation
import Mockable
import Testing
@testable import Baguette
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
        MacInput(display: DisplayEvents(bounds: Rect(origin: Point(x: 0, y: 0), size: size)), events: desktop.events)
    }

    @Test func `should land a tap on the Mac as a click`() {
        let desktop = Desktop()
        #expect(input(on: desktop).tap(at: Point(x: 5, y: 6), size: size, duration: 0, edge: nil))
        #expect(desktop.posted == [.mouseDown(Point(x: 5, y: 6)), .pause(0), .mouseUp(Point(x: 5, y: 6))])
    }

    @Test func `should report a tap unsent when the Mac refuses its events`() {
        #expect(!input(on: Desktop(accepts: false)).tap(at: Point(x: 5, y: 6), size: size, duration: 0, edge: nil))
    }

    @Test func `should send nothing for a second finger the Mac has no pointer for`() {
        let desktop = Desktop()
        let mac = input(on: desktop)
        #expect(!mac.touch2(phase: .down, first: Point(x: 1, y: 1), second: Point(x: 2, y: 2), size: size))
        #expect(!mac.twoFingerPath(start1: Point(x: 1, y: 1), end1: Point(x: 2, y: 2),
                                   start2: Point(x: 3, y: 3), end2: Point(x: 4, y: 4), size: size, duration: 0))
        #expect(desktop.posted.isEmpty)
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
        #expect(desktop.posted == [.scroll(deltaX: 0, deltaY: -10), .text("ok")])
    }
}
