import Foundation
import Testing
import Mockable
@testable import Baguette

@Suite("Input abilities")
struct InputAbilitiesTests {

    @Test func `should refuse a key for a device without one, naming it`() {
        let touch = MockTouch()
        let dispatcher = GestureDispatcher(input: .input(of: "han's iPhone", touch: touch))

        let ack = dispatcher.dispatch(line: #"{"type":"key","code":"KeyA"}"#)

        #expect(ack == #"{"ok":false,"error":"han's iPhone can't do key"}"#)
    }

    @Test func `should refuse a button for a device without one, naming it`() {
        let dispatcher = GestureDispatcher(input: .input(of: "han's iPhone", touch: MockTouch()))

        let ack = dispatcher.dispatch(line: #"{"type":"button","button":"home"}"#)

        #expect(ack == #"{"ok":false,"error":"han's iPhone can't do press"}"#)
    }

    @Test func `should list only the input a device has`() {
        let phone = Abilities.input(of: "han's iPhone", touch: MockTouch())
        let sim = Abilities.input(of: "iPhone 17", all: AllInput())

        #expect(phone.names == ["touch"])
        #expect(sim.names == ["touch", "press", "key", "scroll"])
    }

    @Test func `should make a screen's input once, so a finger stays on the touch it went down on`() throws {
        let made = Counter()
        var table = Abilities(device: "iPhone Duo")
        table.register(.touch) { made.increment(); return MockTouch() as any Touch }

        let screen = table.resolvingInputOnce()
        _ = try screen.require(.touch)
        _ = try screen.require(.touch)

        #expect(made.count == 1)
    }

    @Test func `should land a keystroke on the device's keys`() {
        let input = InputMocks()
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let landed = Keystroke(key: KeyboardKey.from(wireCode: "KeyA")!, modifiers: [.shift]).execute(on: input.key)

        #expect(landed)
        verify(input.key).key(.any, modifiers: .value([.shift]), duration: .any).called(1)
    }

    @Test func `should land a button press on the device's buttons`() {
        let input = InputMocks()
        given(input.press).button(.any, duration: .any).willReturn(true)

        #expect(ButtonPress(button: .navigation(.home)).execute(on: input.press))
        verify(input.press).button(.value(.navigation(.home)), duration: .value(0)).called(1)
    }

    @Test func `should land a wheel event on the device's scroll`() {
        let input = InputMocks()
        given(input.scroll).scroll(deltaX: .any, deltaY: .any).willReturn(true)

        #expect(WheelEvent(deltaX: 0, deltaY: -40).execute(on: input.scroll))
        verify(input.scroll).scroll(deltaX: .value(0), deltaY: .value(-40)).called(1)
    }
}

private final class Counter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A surface that plays every input role, as a simulator's HID does.
private struct AllInput: Touch, Press, Key, Scroll {
    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool { true }
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool { true }
    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool { true }
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool { true }
    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool { true }
    var available: Set<DeviceButton> { DeviceButton.onSimulator }
    func button(_ button: DeviceButton, duration: Double) -> Bool { true }
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool { true }
    func scroll(deltaX: Double, deltaY: Double) -> Bool { true }
}
