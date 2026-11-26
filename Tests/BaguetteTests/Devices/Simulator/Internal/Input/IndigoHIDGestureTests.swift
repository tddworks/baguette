import Foundation
import Mockable
import Testing

@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// What the simulator's input decides, with SimulatorKit's Indigo channel
/// mocked: which messages a gesture becomes, in what order, with which
/// waits between them, in which coordinates — and what it does when a
/// message cannot be built or delivered. Every assertion is the sequence
/// that reached the simulator.
@Suite("IndigoHIDInput — gestures")
struct IndigoHIDGestureTests {

    private let screen = Size(width: 400, height: 800)
    private let phone = IndigoHIDTouchTarget.phone
    private let warmUp: [Step] = [
        .message(.createPointerService), .wait(20_000),
        .message(.createMouseService), .wait(20_000),
    ]

    private func touch(
        _ x: Double, _ y: Double, _ phase: IOHIDDigitizerDispatch.Phase,
        id: UInt32 = 1, edge: IOHIDDigitizerDispatch.Edge = .none
    ) -> Step {
        .message(.touch(CGPoint(x: x, y: y), identifier: id, phase: phase, edge: edge, target: phone))
    }

    private func mouse(_ first: CGPoint, _ second: CGPoint?, _ phase: GesturePhase) -> Step {
        let (event, direction): (UInt32, UInt32) =
            switch phase {
            case .down: (1, 1)
            case .move: (6, 0)
            case .up: (2, 2)
            }
        return .message(
            .mouse(first: first, second: second, target: phone, eventType: event, direction: direction, size: screen))
    }

    // MARK: - reaching the simulator

    @Test func `should register the pointer and mouse services once before the first gesture`() {
        let (input, log) = Rig.make()

        _ = input.scroll(deltaX: 1, deltaY: 2)
        _ = input.scroll(deltaX: 3, deltaY: 4)

        #expect(
            log.steps == warmUp + [
                .message(.scroll(deltaX: 1, deltaY: 2, target: phone)),
                .message(.scroll(deltaX: 3, deltaY: 4, target: phone)),
            ])
    }

    @Test func `should touch nothing when the simulator's HID client cannot be opened`() {
        let (input, log) = Rig.make(connects: false)

        #expect(!input.tap(at: Point(x: 1, y: 1), size: screen, duration: 0, edge: nil))
        #expect(log.steps.isEmpty)
    }

    @Test func `should carry on without a service SimulatorKit cannot build`() {
        let (input, log) = Rig.make { message, _ in
            message == .createPointerService ? .unbuilt : message == .createMouseService ? .unavailable : .delivered
        }

        #expect(input.scroll(deltaX: 1, deltaY: 0))
        #expect(
            log.steps == [
                .message(.createPointerService), .message(.createMouseService),
                .message(.scroll(deltaX: 1, deltaY: 0, target: phone)),
            ])
    }

    @Test func `should refuse to touch when a service is not delivered and try again next gesture`() {
        let (input, log) = Rig.make { _, index in index == 0 ? .undelivered : .delivered }

        #expect(!input.scroll(deltaX: 1, deltaY: 0))
        #expect(input.scroll(deltaX: 1, deltaY: 0))
        #expect(log.steps == [.message(.createPointerService)] + warmUp + [
            .message(.scroll(deltaX: 1, deltaY: 0, target: phone))
        ])
    }

    @Test func `should build a CarPlay digitizer before touching a CarPlay screen`() {
        let (input, log) = Rig.make(plane: .carPlay)

        #expect(input.scroll(deltaX: 0, deltaY: 1))
        #expect(
            log.steps == warmUp + [
                .message(.createCarPlayService(hasTouchScreen: true)), .wait(20_000),
                .message(.scroll(deltaX: 0, deltaY: 1, target: phone)),
            ])
    }

    @Test(arguments: [IndigoDelivery.unavailable, .unbuilt, .undelivered])
    func `should refuse to touch a CarPlay screen when its digitizer cannot be built`(answer: IndigoDelivery) {
        let (input, log) = Rig.make(plane: .carPlay) { message, _ in
            message == .createCarPlayService(hasTouchScreen: true) ? answer : .delivered
        }

        #expect(!input.scroll(deltaX: 0, deltaY: 1))
        #expect(log.steps == warmUp + [.message(.createCarPlayService(hasTouchScreen: true))])
    }

    @Test func `should hand the pointer service back when the input goes away`() {
        let log: Log
        do {
            let (input, rigLog) = Rig.make(plane: .carPlay)
            log = rigLog
            _ = input.scroll(deltaX: 0, deltaY: 1)
        }
        #expect(log.steps.last == .message(.removePointerService))
        #expect(!log.steps.contains(.message(.removeCarPlayService)))
    }

    @Test func `should hand nothing back when the input never reached the simulator`() {
        let log: Log
        do {
            let (_, rigLog) = Rig.make()
            log = rigLog
        }
        #expect(log.steps.isEmpty)
    }

    // MARK: - touches

    @Test func `should land a tap on the simulator as a finger down, hold and up`() {
        let (input, log) = Rig.make()

        #expect(input.tap(at: Point(x: 100, y: 200), size: screen, duration: 0.5, edge: .top))
        #expect(
            log.steps == warmUp + [
                touch(0.25, 0.25, .down, edge: .top), .wait(500_000), touch(0.25, 0.25, .up, edge: .top),
            ])
    }

    @Test func `should hold a tap for a twentieth of a second when no duration is given`() {
        let (input, log) = Rig.make()

        _ = input.tap(at: Point(x: 0, y: 0), size: screen, duration: 0, edge: nil)

        #expect(log.steps.dropFirst(warmUp.count).dropFirst().first == .wait(50_000))
    }

    @Test func `should clamp a point off the screen to its edge`() {
        let (input, log) = Rig.make()

        _ = input.tap(at: Point(x: -40, y: 1600), size: screen, duration: 0.05, edge: nil)

        #expect(log.steps.dropFirst(warmUp.count).first == touch(0, 1, .down))
    }

    @Test(arguments: [0, 1])
    func `should still lift a tap and fail it when either half is not delivered`(failing: Int) {
        let (input, log) = Rig.make { message, index in index == 2 + failing ? .undelivered : .delivered }

        #expect(!input.tap(at: Point(x: 100, y: 200), size: screen, duration: 0.05, edge: nil))
        #expect(log.steps.last == touch(0.25, 0.25, .up))
        #expect(log.steps.contains(.wait(50_000)) == (failing == 1))
    }

    @Test func `should not touch the screen once it has changed under the gesture, yet still lift`() throws {
        let expected = try ExpectedScreen(json: ExpectedScreenTests.json)
        let screenGuard = InputScreenGuard(expected: expected) { throw ObservedScreenError.unavailable }
        let (input, log) = Rig.make(screenGuard: screenGuard)

        #expect(!input.tap(at: Point(x: 100, y: 200), size: screen, duration: 0.05, edge: nil))
        #expect(!input.scroll(deltaX: 1, deltaY: 1))
        #expect(log.steps == warmUp + [touch(0.25, 0.25, .up)])
    }

    @Test func `should drag a swipe through even steps and lift where it ended`() {
        let (input, log) = Rig.make()

        #expect(input.swipe(from: Point(x: 0, y: 0), to: Point(x: 0, y: 100), size: screen, duration: 0.12))

        let moves = (1...15).flatMap { i -> [Step] in
            [.wait(8_000), touch(0, Double(i) / 15 * 0.125, .move)]
        }
        #expect(log.steps == warmUp + [touch(0, 0, .down)] + moves + [.wait(8_000), touch(0, 0.125, .up)])
    }

    @Test func `should drag a long swipe in moves no more than ten points apart`() {
        let (input, log) = Rig.make()

        _ = input.swipe(from: Point(x: 201, y: 150), to: Point(x: 201, y: 650), size: screen, duration: 0.64)

        let ys = log.steps.compactMap { step -> Double? in
            if case .message(.touch(let point, _, _, _, _)) = step { return point.y * screen.height }
            return nil
        }
        let strides = zip(ys, ys.dropFirst()).map { $1 - $0 }
        #expect(strides.allSatisfy { $0 <= 10.000001 })
    }

    @Test func `should never step a swipe faster than 8 ms`() {
        let (input, log) = Rig.make()

        _ = input.swipe(from: Point(x: 0, y: 0), to: Point(x: 4, y: 8), size: screen, duration: 0.001)

        #expect(log.steps.dropFirst(warmUp.count + 1).first == .wait(8_000))
    }

    @Test func `should stop a swipe's movement after a delivery failure and still lift where it reached`() {
        // warm-up (2) + down, then the second move fails.
        let (input, log) = Rig.make { _, index in index == 4 ? .undelivered : .delivered }

        #expect(!input.swipe(from: Point(x: 0, y: 0), to: Point(x: 400, y: 0), size: screen, duration: 0.25))
        #expect(log.messages.count == 2 + 3 + 1)
        #expect(log.steps.last == touch(0.05, 0, .up))
    }

    @Test func `should keep one finger identity from down to up of a streamed touch`() {
        let (input, log) = Rig.make()

        _ = input.tap(at: Point(x: 0, y: 0), size: screen, duration: 0.05, edge: nil)
        _ = input.touch1(phase: .down, at: Point(x: 0, y: 0), size: screen, edge: .bottom)
        _ = input.touch1(phase: .move, at: Point(x: 200, y: 400), size: screen, edge: .bottom)
        _ = input.touch1(phase: .up, at: Point(x: 200, y: 400), size: screen, edge: .bottom)
        _ = input.touch1(phase: .down, at: Point(x: 0, y: 0), size: screen, edge: nil)

        #expect(
            Array(log.steps.suffix(4)) == [
                touch(0, 0, .down, id: 2, edge: .bottom),
                touch(0.5, 0.5, .move, id: 2, edge: .bottom),
                touch(0.5, 0.5, .up, id: 2, edge: .bottom),
                touch(0, 0, .down, id: 3),
            ])
    }

    @Test func `should give a streamed touch that never went down its own finger`() {
        let (input, log) = Rig.make()

        _ = input.touch1(phase: .move, at: Point(x: 0, y: 0), size: screen, edge: nil)
        _ = input.touch1(phase: .move, at: Point(x: 0, y: 0), size: screen, edge: nil)

        #expect(Array(log.steps.suffix(2)) == [touch(0, 0, .move, id: 1), touch(0, 0, .move, id: 2)])
    }

    // MARK: - two fingers, on the 9-arg mouse event

    @Test func `should stream two fingers as mouse events in fractions of the screen`() {
        let (input, log) = Rig.make()

        for phase in GesturePhase.allCases {
            #expect(input.touch2(phase: phase, first: Point(x: 100, y: 200), second: Point(x: 300, y: 600), size: screen))
        }

        let first = CGPoint(x: 0.25, y: 0.25)
        let second = CGPoint(x: 0.75, y: 0.75)
        #expect(
            log.steps == warmUp + GesturePhase.allCases.map { mouse(first, second, $0) })
    }

    @Test func `should retry building a two-finger move while the fingers settle`() {
        let (input, log) = Rig.make { _, index in index < 4 ? (index < 2 ? .delivered : .unbuilt) : .delivered }

        #expect(input.touch2(phase: .move, first: Point(x: 0, y: 0), second: Point(x: 0, y: 0), size: screen))
        #expect(log.steps.dropFirst(warmUp.count).filter { $0 == .wait(5_000) }.count == 2)
        #expect(log.messages.count == 2 + 3)
    }

    @Test func `should give up on a two-finger event after twelve failed builds`() {
        let (input, log) = Rig.make { _, index in index < 2 ? .delivered : .unbuilt }

        #expect(!input.touch2(phase: .down, first: Point(x: 0, y: 0), second: Point(x: 0, y: 0), size: screen))
        #expect(log.messages.count == 2 + 12)
    }

    @Test(arguments: [IndigoDelivery.unavailable, .undelivered])
    func `should not retry a two-finger event SimulatorKit cannot take`(answer: IndigoDelivery) {
        let (input, log) = Rig.make { _, index in index < 2 ? .delivered : answer }

        #expect(!input.touch2(phase: .down, first: Point(x: 0, y: 0), second: Point(x: 0, y: 0), size: screen))
        #expect(log.messages.count == 2 + 1)
    }

    @Test func `should pinch two fingers along their paths and lift them where they stopped`() {
        let (input, log) = Rig.make()

        #expect(
            input.twoFingerPath(
                start1: Point(x: 0, y: 0), end1: Point(x: 400, y: 0),
                start2: Point(x: 0, y: 800), end2: Point(x: 400, y: 800),
                size: screen, duration: 1.5))

        let moves = (1...10).flatMap { i -> [Step] in
            let t = Double(i) / 10
            return [.wait(125_000), mouse(CGPoint(x: t, y: 0), CGPoint(x: t, y: 1), .move)]
        }
        #expect(
            log.steps == warmUp + [mouse(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), .down)] + moves + [
                mouse(CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), .up)
            ])
    }

    @Test func `should lift a pinch where it stopped when a move is not delivered`() {
        let (input, log) = Rig.make { _, index in index == 4 ? .undelivered : .delivered }

        #expect(
            !input.twoFingerPath(
                start1: Point(x: 0, y: 0), end1: Point(x: 400, y: 0),
                start2: Point(x: 0, y: 800), end2: Point(x: 400, y: 800),
                size: screen, duration: 1.5))
        #expect(log.messages.count == 2 + 3 + 1)
        #expect(log.steps.last == mouse(CGPoint(x: 0.2, y: 0), CGPoint(x: 0.2, y: 1), .up))
        #expect(log.steps.contains(.wait(125_000)))
    }

    // MARK: - buttons

    private func legacy(_ code: UInt32, _ direction: UInt32) -> Step {
        .message(.button(code: code, direction: direction, target: 0x33))
    }

    @Test func `should press home as the home button's down, hold and up`() {
        let (input, log) = Rig.make()

        #expect(input.button(.navigation(.home), duration: 0))
        #expect(log.steps == warmUp + [legacy(0, 1), .wait(100_000), legacy(0, 2)])
    }

    @Test func `should press lock and the software keyboard as buttons of their own`() {
        let (input, log) = Rig.make()

        _ = input.button(.hardware(.lock), duration: 0.5)
        _ = input.button(.navigation(.softwareKeyboard), duration: 0.001)

        #expect(
            log.steps == warmUp + [
                legacy(1, 1), .wait(500_000), legacy(1, 2),
                legacy(1008, 1), .wait(20_000), legacy(1008, 2),
            ])
    }

    @Test func `should press a body button as its HID usage on the touch target`() {
        let (input, log) = Rig.make()
        let volumeUp = HIDUsage(page: 12, usage: 233)

        #expect(input.button(.hardware(.volumeUp), duration: 0))
        #expect(
            log.steps == warmUp + [
                .message(.usage(volumeUp, operation: 1, target: phone)), .wait(100_000),
                .message(.usage(volumeUp, operation: 2, target: phone)),
            ])
    }

    @Test func `should open the app switcher with two home presses 150 ms apart`() {
        let (input, log) = Rig.make()

        #expect(input.button(.navigation(.appSwitcher), duration: 0))
        #expect(
            log.steps == warmUp + [
                legacy(0, 1), .wait(100_000), legacy(0, 2), .wait(150_000),
                legacy(0, 1), .wait(100_000), legacy(0, 2),
            ])
    }

    @Test func `should not press home a second time when the first press fails`() {
        let (input, log) = Rig.make { _, index in index == 2 ? .undelivered : .delivered }

        #expect(!input.button(.navigation(.appSwitcher), duration: 0))
        #expect(log.steps == warmUp + [legacy(0, 1), legacy(0, 2)])
    }

    @Test(arguments: [IndigoDelivery.unavailable, .unbuilt])
    func `should not lift a button whose press could not be built`(answer: IndigoDelivery) {
        let (input, log) = Rig.make { _, index in index == 2 ? answer : .delivered }

        #expect(!input.button(.hardware(.power), duration: 0))
        #expect(log.messages.count == 2 + 1)
    }

    @Test func `should fail a button whose release could not be built`() {
        let (input, _) = Rig.make { _, index in index == 3 ? .unbuilt : .delivered }

        #expect(!input.button(.navigation(.home), duration: 0))
    }

    struct SystemGesture: Sendable {
        let navigation: Navigation
        let from, to: CGPoint
        let steps: Int
        let stepUs: UInt32
        let edge: IOHIDDigitizerDispatch.Edge
        let dwellPulses: Int
    }

    @Test(arguments: [
        SystemGesture(
            navigation: .swipeToHome, from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.30),
            steps: 12, stepUs: 16_000, edge: .bottom, dwellPulses: 0),
        SystemGesture(
            navigation: .swipeToAppSwitcher, from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.58),
            steps: 30, stepUs: 35_000, edge: .bottom, dwellPulses: 18),
        SystemGesture(
            navigation: .pullDownToLockScreen, from: CGPoint(x: 0.25, y: 0.002), to: CGPoint(x: 0.25, y: 0.55),
            steps: 24, stepUs: 25_000, edge: .top, dwellPulses: 0),
        SystemGesture(
            navigation: .pullDownToNotificationCenter, from: CGPoint(x: 0.75, y: 0.002),
            to: CGPoint(x: 0.75, y: 0.55), steps: 24, stepUs: 25_000, edge: .top, dwellPulses: 0),
    ])
    func `should reach a system gesture as an edge-flagged drag from its edge`(gesture system: SystemGesture) {
        let (navigation, from, to, steps) = (system.navigation, system.from, system.to, system.steps)
        let (stepUs, edge, dwellPulses) = (system.stepUs, system.edge, system.dwellPulses)
        let (input, log) = Rig.make()

        #expect(input.button(.navigation(navigation), duration: 0))

        let gesture = Array(log.steps.dropFirst(warmUp.count))
        let touches = gesture.compactMap { step -> IndigoMessage? in
            if case .message(let message) = step { return message }
            return nil
        }
        #expect(touches.first == .touch(from, identifier: 1, phase: .down, edge: edge, target: phone))
        guard case .touch(let lift, 1, .up, edge, phone)? = touches.last else {
            Issue.record("the drag never lifted")
            return
        }
        #expect(abs(lift.x - to.x) < 1e-9 && abs(lift.y - to.y) < 1e-9)
        #expect(touches.count == 1 + steps + dwellPulses + 1)
        #expect(gesture.filter { $0 == .wait(stepUs) }.count == steps + 1)
        #expect(gesture.filter { $0 == .wait(50_000) }.count == dwellPulses)
    }

    @Test func `should offer every navigation and button`() {
        let (input, _) = Rig.make()
        #expect(input.available == DeviceButton.onSimulator)
    }

    // MARK: - keys

    private func usage(_ usage: HIDUsage, _ operation: UInt32) -> Step {
        .message(.usage(usage, operation: operation, target: phone))
    }

    @Test func `should wrap a key in its modifiers, pressed in order and released in reverse`() throws {
        let (input, log) = Rig.make()
        let a = try #require(KeyboardKey.from(wireCode: "KeyA"))

        #expect(input.key(a, modifiers: [.shift, .command], duration: 0.03))
        #expect(
            log.steps == warmUp + [
                usage(KeyModifier.command.hidUsage, 1), usage(KeyModifier.shift.hidUsage, 1),
                usage(a.hidUsage, 1), .wait(30_000), usage(a.hidUsage, 2),
                usage(KeyModifier.shift.hidUsage, 2), usage(KeyModifier.command.hidUsage, 2),
            ])
    }

    @Test func `should still release the modifiers when the key press is not delivered`() throws {
        let (input, log) = Rig.make { _, index in index == 3 ? .undelivered : .delivered }
        let a = try #require(KeyboardKey.from(wireCode: "KeyA"))

        #expect(!input.key(a, modifiers: [.shift], duration: 0))
        #expect(
            log.steps == warmUp + [
                usage(KeyModifier.shift.hidUsage, 1), usage(a.hidUsage, 1), usage(a.hidUsage, 2),
                usage(KeyModifier.shift.hidUsage, 2),
            ])
    }

    @Test(arguments: [IndigoDelivery.unavailable, .unbuilt])
    func `should fail a key SimulatorKit cannot build a message for`(answer: IndigoDelivery) throws {
        let (input, log) = Rig.make { _, index in index >= 2 ? answer : .delivered }
        let a = try #require(KeyboardKey.from(wireCode: "KeyA"))

        #expect(!input.key(a, modifiers: [], duration: 0))
        #expect(log.messages.count == 2 + 1)
    }

    @Test func `should fail a key whose release could not be built`() throws {
        let (input, _) = Rig.make { _, index in index == 3 ? .unbuilt : .delivered }
        let a = try #require(KeyboardKey.from(wireCode: "KeyA"))

        #expect(!input.key(a, modifiers: [], duration: 0))
    }

    // MARK: - scroll

    @Test(arguments: [IndigoDelivery.unavailable, .unbuilt, .undelivered])
    func `should fail a scroll the simulator does not take`(answer: IndigoDelivery) {
        let (input, _) = Rig.make { _, index in index >= 2 ? answer : .delivered }

        #expect(!input.scroll(deltaX: 1, deltaY: 1))
    }
}

/// One thing that reached the simulator, or a wait between two of them.
enum Step: Equatable {
    case message(IndigoMessage)
    case wait(UInt32)
}

/// Everything the input did, in order.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Step] = []

    var steps: [Step] { lock.withLock { recorded } }
    var messages: [IndigoMessage] {
        steps.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }

    /// Records the message and answers its 0-based index among messages.
    func record(_ message: IndigoMessage) -> Int {
        lock.withLock {
            recorded.append(.message(message))
            return recorded.filter { if case .message = $0 { true } else { false } }.count - 1
        }
    }

    func wait(_ microseconds: UInt32) { lock.withLock { recorded.append(.wait(microseconds)) } }
}

private enum Rig {
    /// An input on a mocked channel that opens (or not) and answers each
    /// message with `answer(message, index)`; its waits are recorded, not
    /// slept.
    static func make(
        plane: DisplayKind = .phone, screenGuard: InputScreenGuard? = nil, connects: Bool = true,
        answer: @escaping @Sendable (IndigoMessage, Int) -> IndigoDelivery = { _, _ in .delivered }
    ) -> (IndigoHIDInput, Log) {
        let log = Log()
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(NSObject())
        let channel = MockIndigoChannel()
        given(channel).connect(to: .any).willReturn(connects)
        given(channel).send(.any).willProduce { message in answer(message, log.record(message)) }
        let input = IndigoHIDInput(
            udid: "sim", host: host, plane: plane, screenGuard: screenGuard,
            channel: channel, wait: { log.wait($0) })
        return (input, log)
    }
}
