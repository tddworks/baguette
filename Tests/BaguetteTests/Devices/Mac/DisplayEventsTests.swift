import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What a gesture on one Mac display becomes: events in the desktop's global
/// points (the main display's top-left at 0,0), with the pauses between them.
@Suite("DisplayEvents")
struct DisplayEventsTests {
    /// A second display, right of a 1512-point-wide main one.
    let display = DisplayEvents(bounds: Rect(origin: Point(x: 1512, y: 0), size: Size(width: 1920, height: 1080)))
    let size = Size(width: 1920, height: 1080)

    @Test func `should land a tap on the display as a click held for its duration`() {
        #expect(display.tap(at: Point(x: 100, y: 200), size: size, duration: 0.1) == [
            .mouseDown(Point(x: 1612, y: 200)), .pause(0.1), .mouseUp(Point(x: 1612, y: 200)),
        ])
    }

    @Test func `should place a point by the size it was sent with when that differs from the display`() {
        let half = Size(width: 960, height: 540)
        #expect(display.tap(at: Point(x: 480, y: 270), size: half, duration: 0) == [
            .mouseDown(Point(x: 2472, y: 540)), .pause(0), .mouseUp(Point(x: 2472, y: 540)),
        ])
    }

    @Test func `should drag a swipe from start to end in steps across its duration`() {
        let events = display.swipe(from: Point(x: 0, y: 0), to: Point(x: 100, y: 0), size: size, duration: 0.05)
        #expect(events.first == .mouseDown(Point(x: 1512, y: 0)))
        #expect(events.last == .mouseUp(Point(x: 1612, y: 0)))
        #expect(events.dropLast().last == .mouseDragged(Point(x: 1612, y: 0)))
        #expect(events.filter { if case .mouseDragged = $0 { true } else { false } }.count == 3)
    }

    @Test func `should follow one finger as a press, a drag and a release`() {
        let at = Point(x: 10, y: 20)
        #expect(display.touch1(phase: .down, at: at, size: size) == [.mouseDown(Point(x: 1522, y: 20))])
        #expect(display.touch1(phase: .move, at: at, size: size) == [.mouseDragged(Point(x: 1522, y: 20))])
        #expect(display.touch1(phase: .up, at: at, size: size) == [.mouseUp(Point(x: 1522, y: 20))])
    }

    @Test func `should scroll the content the way the wheel turned`() {
        #expect(display.scroll(deltaX: 3, deltaY: 40) == [.scroll(deltaX: -3, deltaY: -40)])
    }

    @Test func `should press a key with its modifiers held around it, released in reverse`() {
        let a = KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0x04))
        #expect(display.key(a, modifiers: [.command], duration: 0) == [
            .key(code: 0x37, down: true, held: [.command]),
            .key(code: 0x00, down: true, held: [.command]),
            .pause(0),
            .key(code: 0x00, down: false, held: [.command]),
            .key(code: 0x37, down: false, held: []),
        ])
    }

    @Test func `should press nothing when the Mac has no such key`() {
        let unknown = KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0xE8))
        #expect(display.key(unknown, modifiers: [], duration: 0) == nil)
    }

    @Test func `should type any text, not only US-ASCII, in pieces the event can carry`() {
        let text = "héllo 👋🏽 " + String(repeating: "x", count: 20)
        let events = display.type(text)
        #expect(events.map { if case .text(let t) = $0 { t } else { "" } }.joined() == text)
        #expect(events.allSatisfy { if case .text(let t) = $0 { t.utf16.count <= 20 } else { false } })
    }
}
