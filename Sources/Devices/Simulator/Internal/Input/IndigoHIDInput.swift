import BaguetteDevice
import Foundation

/// Production `Input` — dispatches gestures into SimulatorKit's host-HID
/// pipeline using the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe
/// (Xcode 26 preview-kit, verified on iOS 26.4) for two fingers, real
/// `IOHIDEvent` digitizer touches for one, and button / HID-usage messages
/// for buttons and keys.
///
/// It decides; the `IndigoChannel` only builds and sends: which messages a
/// gesture becomes, in what order, with which waits between them, in which
/// coordinates (device points divided by size, clamped to the screen), and
/// what happens when one cannot be built or delivered — a contact that went
/// down is always lifted.
///
/// One instance per simulator. Warm-up runs lazily on first dispatch
/// (creates pointer + mouse services) and stays warm for the instance's
/// lifetime; deinit releases the services.
final class IndigoHIDInput: HID, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    /// Digitizer routing target for this input surface. Phone defaults
    /// to `IndigoHIDTouchTarget.phone`; CarPlay callers inject
    /// `IndigoHIDTouchTarget.carPlay`. Both are constants naming a
    /// service something created — never anything derived from a screen.
    let touchTarget: UInt32
    /// Which plane this input drives. Only used to decide whether the
    /// guest must be asked to build a digitizer first — see
    /// `warmServices`.
    private let plane: DisplayKind
    private let screenGuard: InputScreenGuard?
    private let channel: any IndigoChannel
    /// Sleeps for the given microseconds — `usleep` outside tests.
    private let wait: (UInt32) -> Void

    private var connected = false
    private let lock = NSLock()

    // Mouse-event wire constants — kept private; the user never sees these.
    private static let nsEventDown: UInt32 = 1
    private static let nsEventUp: UInt32 = 2
    private static let nsEventDragged: UInt32 = 6
    private static let dirDown: UInt32 = 1
    private static let dirMove: UInt32 = 0
    private static let dirUp: UInt32 = 2

    convenience init(
        udid: String, host: any DeviceHost,
        touchTarget: UInt32 = IndigoHIDTouchTarget.phone,
        plane: DisplayKind = .phone,
        screenGuard: InputScreenGuard? = nil
    ) {
        self.init(
            udid: udid, host: host, touchTarget: touchTarget, plane: plane, screenGuard: screenGuard,
            channel: SimulatorKitIndigoChannel(), wait: { usleep($0) })
    }

    init(
        udid: String, host: any DeviceHost,
        touchTarget: UInt32 = IndigoHIDTouchTarget.phone,
        plane: DisplayKind = .phone,
        screenGuard: InputScreenGuard? = nil,
        channel: any IndigoChannel, wait: @escaping (UInt32) -> Void
    ) {
        self.udid = udid
        self.host = host
        self.touchTarget = touchTarget
        self.plane = plane
        self.screenGuard = screenGuard
        self.channel = channel
        self.wait = wait
    }

    deinit {
        guard connected else { return }
        let teardown = InputTeardown.forPlane(plane)
        if teardown.releasesPointer {
            _ = channel.send(.removePointerService)
        }
        // The external digitizer stays registered — see `InputTeardown`.
        // An earlier version removed it here, reasoning that a digitizer
        // outliving its display leaves the next session a target
        // addressing nothing. It has the ownership backwards: the host
        // brought that display up and is still using it, so removing the
        // service left a CarPlay window on screen that nothing could
        // touch, and turned target 1 into the unregistered kind that
        // kills the guest.
        if teardown.releasesExternalDigitizer, plane.needsExternalDigitizer {
            _ = channel.send(.removeCarPlayService)
        }
    }

    // MARK: - Touch

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        guard ensureWarm() else { return false }
        // Built as an IOHIDEvent digitizer parent + finger child, run
        // through the trackpad-from-HIDEventRef wrapper, target + edge
        // slots patched. Bypasses the iOS 26 / Xcode 26 mouse-event
        // regression where 9-arg `IndigoHIDMessageForMouseNSEvent` taps
        // either get misinterpreted as Home gestures or silently drop.
        // See `IOHIDDigitizerDispatch` for the full recipe.
        let at = normalise(point, in: size)
        let edge = IOHIDDigitizerDispatch.Edge.from(edge)
        let id = nextTouchIdentifier()
        let pressed = touch(at, identifier: id, phase: .down, edge: edge)
        if pressed {
            wait(UInt32(max(0.02, duration > 0 ? duration : 0.05) * 1_000_000))
        }
        let released = touch(at, identifier: id, phase: .up, edge: edge)
        return pressed && released
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        guard ensureWarm() else { return false }
        let total = duration > 0 ? duration : 0.25
        let steps = 10
        let stepMs = UInt32((total * 1000) / Double(steps + 2))
        return stroke(
            from: normalise(start, in: size), to: normalise(end, in: size),
            steps: steps, stepMs: max(8, stepMs), dwellMs: 0, edge: .none)
    }

    func touch1(
        phase: GesturePhase, at point: Point, size: Size,
        edge: DeviceEdge?
    ) -> Bool {
        guard ensureWarm() else { return false }
        let dispatchPhase: IOHIDDigitizerDispatch.Phase
        switch phase {
        case .down: dispatchPhase = .down
        case .move: dispatchPhase = .move
        case .up: dispatchPhase = .up
        }
        // touch1 streaming uses a sticky identifier so iOS sees
        // one continuous touch sequence across the down/move/up
        // chain. The identifier is reset on `down` and reused
        // until `up`.
        if phase == .down { stickyTouchIdentifier = nextTouchIdentifier() }
        let id = stickyTouchIdentifier ?? nextTouchIdentifier()
        return touch(
            normalise(point, in: size), identifier: id, phase: dispatchPhase,
            edge: IOHIDDigitizerDispatch.Edge.from(edge))
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        // Two-finger streaming kept on the legacy mouse-event
        // signature for now — pinch/pan continue to work via the
        // existing path (they use coincident-finger streaming
        // which the digitizer recipe doesn't model yet).
        guard ensureWarm() else { return false }
        let (et, dir) = mouseEvent(for: phase)
        return sendMouse(p1: first, p2: second, eventType: et, direction: dir, size: size)
    }

    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool {
        guard ensureWarm() else { return false }
        let total = duration > 0 ? duration : 0.6
        let steps = 10
        let stepUs = UInt32((total / Double(steps + 2)) * 1_000_000)

        var ok = sendMouse(p1: start1, p2: start2, eventType: Self.nsEventDown, direction: Self.dirDown, size: size)
        var last1 = start1
        var last2 = start2
        if ok {
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                last1 = Point(x: start1.x + (end1.x - start1.x) * t, y: start1.y + (end1.y - start1.y) * t)
                last2 = Point(x: start2.x + (end2.x - start2.x) * t, y: start2.y + (end2.y - start2.y) * t)
                wait(stepUs)
                ok = sendMouse(
                    p1: last1, p2: last2, eventType: Self.nsEventDragged, direction: Self.dirMove, size: size)
                if !ok { break }
            }
        }
        let released = sendMouse(p1: last1, p2: last2, eventType: Self.nsEventUp, direction: Self.dirUp, size: size)
        return ok && released
    }

    /// Monotonic per-instance touch identifier. iOS uses the
    /// identifier to thread a touch sequence through the HID
    /// stack; reusing one across distinct touches confuses the
    /// recogniser. We reset to 1 on overflow rather than wrapping.
    private var touchIdentifierCounter: UInt32 = 0
    private var stickyTouchIdentifier: UInt32?
    private func nextTouchIdentifier() -> UInt32 {
        touchIdentifierCounter &+= 1
        if touchIdentifierCounter == 0 { touchIdentifierCounter = 1 }
        return touchIdentifierCounter
    }

    // MARK: - Press

    /// Every navigation and button.
    var available: Set<DeviceButton> { DeviceButton.onSimulator }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        guard ensureWarm() else { return false }
        let holdUs = holdMicroseconds(for: duration)
        switch button {
        case .hardware(let hardware):
            // A body button is its standard HID usage; lock (sleep/wake)
            // is a button message of its own.
            guard let usage = hardware.standardHIDUsage else {
                return pressLegacyButton(button, code: LegacyButton.lock, holdUs: holdUs)
            }
            return press(
                button.rawValue,
                down: .usage(usage, operation: 1, target: touchTarget),
                up: .usage(usage, operation: 2, target: touchTarget), holdUs: holdUs)
        case .navigation(let navigation):
            return navigate(navigation, holdUs: holdUs)
        }
    }

    /// A navigation, the way SpringBoard is reached for it: the home
    /// button's message, or an edge-flagged drag.
    private func navigate(_ navigation: Navigation, holdUs: UInt32) -> Bool {
        let button = DeviceButton.navigation(navigation)
        switch navigation {
        case .home:
            return pressLegacyButton(button, code: LegacyButton.home, holdUs: holdUs)
        case .softwareKeyboard:
            return pressLegacyButton(button, code: LegacyButton.softwareKeyboard, holdUs: holdUs)
        case .appSwitcher:
            // Two consecutive home-button presses ~150 ms apart.
            // SpringBoard listens to the home `IndigoHIDMessageForButton`
            // event source regardless of whether the device has a
            // physical home button, so this works on Face ID iPhones
            // (iPhone X+) too. Recipe matches idb's
            // FBSimulatorPurpleHID app-switcher path. Cleaner than
            // synthesising the slow swipe-and-hold gesture and
            // doesn't depend on the mouse-event signature.
            guard pressLegacyButton(button, code: LegacyButton.home, holdUs: holdUs) else { return false }
            wait(150_000)
            return pressLegacyButton(button, code: LegacyButton.home, holdUs: holdUs)
        case .swipeToAppSwitcher:
            // Slow edge-flagged drag from the home indicator with
            // a long dwell at the midpoint. iOS's home-indicator
            // gesture recognizer fires App Switcher when the
            // finger settles below ~y=0.6 for more than ~500 ms;
            // a fast flick goes Home instead. Empirical recipe
            // verified on iPhone 17 Pro Max / iOS 26.4: 30 steps
            // × 35 ms + 900 ms dwell at y=0.58 fires cards.
            // Kept as a wire-only fallback for callers that need
            // the gesture path rather than the home-press recipe.
            return stroke(
                from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.58),
                steps: 30, stepMs: 35, dwellMs: 900, edge: .bottom)
        case .swipeToHome:
            // Fast edge-flagged flick from the home indicator up
            // to ~mid screen. iOS's home-indicator recognizer
            // routes a quick swipe to Home (no dwell, ends below
            // halfway). Empirical: 12 steps × 16 ms reaching
            // y=0.30 lands on the home screen reliably.
            return stroke(
                from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.30),
                steps: 12, stepMs: 16, dwellMs: 0, edge: .bottom)
        case .pullDownToLockScreen:
            // Slow drag down from top-LEFT (above the dynamic
            // island, on the camera side) with edge=top flagged.
            // iOS's status-bar gesture recognizer routes a
            // top-left-origin pull to the lock-screen cover sheet.
            return stroke(
                from: CGPoint(x: 0.25, y: 0.002), to: CGPoint(x: 0.25, y: 0.55),
                steps: 24, stepMs: 25, dwellMs: 0, edge: .top)
        case .pullDownToNotificationCenter:
            // Slow drag down from top-RIGHT (above the dynamic
            // island, on the battery / time side) with edge=top
            // flagged. iOS routes a top-right-origin pull to
            // Notification Center.
            return stroke(
                from: CGPoint(x: 0.75, y: 0.002), to: CGPoint(x: 0.75, y: 0.55),
                steps: 24, stepMs: 25, dwellMs: 0, edge: .top)
        default:
            // Not one of a simulator's (`DeviceButton.onSimulator`): refused
            // by name before it gets here.
            return false
        }
    }

    /// `IndigoHIDMessageForButton`'s arg0 per button; the 3rd arg is a
    /// routing target on iOS 26.4 (0x33 = digitizer), not a timestamp
    /// despite a `UInt64` slot in some headers.
    private enum LegacyButton {
        static let home: UInt32 = 0x0
        static let lock: UInt32 = 0x1
        /// SimulatorHID maps button 1008 to the consumer Eject key.
        static let softwareKeyboard: UInt32 = 1008
        static let target: UInt32 = 0x33
    }

    private func pressLegacyButton(_ button: DeviceButton, code: UInt32, holdUs: UInt32) -> Bool {
        trace(
            "[hid] press \(button.rawValue) via legacy arg0=\(code) target=\(hex(LegacyButton.target)) hold=\(holdUs)us"
        )
        // Release — direction 2; 0 crashes backboardd on iOS 26.4.
        return press(
            button.rawValue,
            down: .button(code: code, direction: 1, target: LegacyButton.target),
            up: .button(code: code, direction: 2, target: LegacyButton.target), holdUs: holdUs)
    }

    /// Down, hold, up. A press that could not even be built is not
    /// released; one that was built is, whether or not it was delivered.
    private func press(_ name: String, down: IndigoMessage, up: IndigoMessage, holdUs: UInt32) -> Bool {
        let downSent = channel.send(down)
        guard downSent.built else {
            log("[hid] press \(name) — down message \(downSent == .unavailable ? "builder unresolved" : "build returned nil")")
            return false
        }
        let pressed = downSent == .delivered
        if pressed { wait(holdUs) }
        let upSent = channel.send(up)
        guard upSent.built else {
            log("[hid] press \(name) — up message build returned nil")
            return false
        }
        return pressed && upSent == .delivered
    }

    // MARK: - Key

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard ensureWarm() else { return false }
        let holdUs = holdMicroseconds(for: duration)
        let target = touchTarget
        // Sort modifiers so the down/up order is deterministic; iOS
        // doesn't care, but tests + logs become reproducible.
        let mods = modifiers.sorted { $0.rawValue < $1.rawValue }
        trace(
            "[hid] key page=\(key.hidUsage.page) usage=\(key.hidUsage.usage) modifiers=\(mods.map(\.rawValue)) hold=\(holdUs)us"
        )

        func press(_ usage: HIDUsage, while action: () -> Bool) -> Bool {
            let down = channel.send(.usage(usage, operation: 1, target: target))
            guard down.built else {
                if down == .unavailable { log("[hid] key — IndigoHIDMessageForHIDArbitrary unresolved") }
                return false
            }
            let performed = down == .delivered && action()
            // A failed send can have an unknown delivery outcome. Always release.
            let up = channel.send(.usage(usage, operation: 2, target: target))
            guard up.built else { return false }
            return performed && up == .delivered
        }
        func pressModifiers(_ remaining: ArraySlice<KeyModifier>) -> Bool {
            if let modifier = remaining.first {
                return press(modifier.hidUsage) { pressModifiers(remaining.dropFirst()) }
            }
            return press(key.hidUsage) {
                wait(holdUs)
                return true
            }
        }
        return pressModifiers(mods[...])
    }

    /// Default tap is 100 ms — long enough for iOS to register the press
    /// without crossing into "long press" territory. A non-zero duration
    /// (in seconds) overrides; we clamp the floor so a 0.001 s request
    /// doesn't underrun the simulator's HID dispatch.
    private func holdMicroseconds(for duration: Double) -> UInt32 {
        guard duration > 0 else { return 100_000 }
        let us = duration * 1_000_000
        return UInt32(min(max(us, 20_000), Double(UInt32.max)))
    }

    // MARK: - Scroll

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        guard screenGuard?.allows(.move) != false, ensureWarm() else { return false }
        return channel.send(.scroll(deltaX: deltaX, deltaY: deltaY, target: touchTarget)) == .delivered
    }

    // MARK: - one finger, on the digitizer

    /// One digitizer event, unless the screen changed under a contact
    /// that is going down or moving. A lift always goes through.
    private func touch(
        _ point: CGPoint, identifier: UInt32, phase: IOHIDDigitizerDispatch.Phase,
        edge: IOHIDDigitizerDispatch.Edge
    ) -> Bool {
        guard screenGuard?.allows(phase == .up ? .up : .move) != false else { return false }
        let message = IndigoMessage.touch(
            point, identifier: identifier, phase: phase, edge: edge, target: touchTarget)
        return channel.send(message) == .delivered
    }

    /// A continuous one-finger drag from `start` to `end` over `steps`
    /// interpolated moves. `dwellMs` holds the finger at the endpoint
    /// before lift — iOS uses dwell to discriminate Home from App
    /// Switcher when `edge == .bottom`. A failed move stops the drag; the
    /// finger still lifts where it reached.
    private func stroke(
        from start: CGPoint, to end: CGPoint,
        steps: Int, stepMs: UInt32, dwellMs: UInt32,
        edge: IOHIDDigitizerDispatch.Edge
    ) -> Bool {
        let id = nextTouchIdentifier()
        var ok = touch(start, identifier: id, phase: .down, edge: edge)
        var lastPoint = start
        if ok {
            for i in 1...steps {
                wait(stepMs * 1000)
                let t = Double(i) / Double(steps)
                lastPoint = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t)
                ok = touch(lastPoint, identifier: id, phase: .move, edge: edge)
                if !ok { break }
            }
        }
        if ok && dwellMs > 0 {
            let pulses = max(1, Int(dwellMs / 50))
            for _ in 0..<pulses {
                ok = touch(lastPoint, identifier: id, phase: .move, edge: edge)
                if !ok { break }
                wait(50_000)
            }
        }
        if ok { wait(stepMs * 1000) }
        let released = touch(lastPoint, identifier: id, phase: .up, edge: edge)
        return ok && released
    }

    // MARK: - two fingers, on the 9-arg mouse event

    private func mouseEvent(for phase: GesturePhase) -> (UInt32, UInt32) {
        switch phase {
        case .down: return (Self.nsEventDown, Self.dirDown)
        case .move: return (Self.nsEventDragged, Self.dirMove)
        case .up: return (Self.nsEventUp, Self.dirUp)
        }
    }

    /// Build + dispatch one mouse event. Retries on the 2-finger settle
    /// window — the builder returns nil for ~50ms after a 2-finger
    /// mouseDown, so the first one or two moves of a fresh 2-finger
    /// gesture transiently fail. 12 attempts × 5ms = 60ms covers the
    /// settle window without perceptible latency.
    private func sendMouse(
        p1: Point, p2: Point?,
        eventType: UInt32, direction: UInt32,
        size: Size
    ) -> Bool {
        guard screenGuard?.allows(eventType == Self.nsEventUp ? .up : .move) != false else { return false }
        let message = IndigoMessage.mouse(
            first: normalise(p1, in: size), second: p2.map { normalise($0, in: size) },
            target: touchTarget, eventType: eventType, direction: direction, size: size)
        for _ in 0..<(p2 != nil ? 12 : 3) {
            switch channel.send(message) {
            case .delivered: return true
            case .undelivered, .unavailable: return false
            case .unbuilt: wait(5_000)
            }
        }
        return false
    }

    /// Device points to fractions of the screen, clamped to it.
    private func normalise(_ point: Point, in size: Size) -> CGPoint {
        CGPoint(x: clamp01(point.x / size.width), y: clamp01(point.y / size.height))
    }

    private func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }

    // MARK: - warm-up

    /// Lazy connect + warm. Synchronised because gestures might come from
    /// multiple threads in a streaming session.
    private func ensureWarm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if connected { return true }
        guard let device = host.resolveDevice(udid: udid), channel.connect(to: device) else { return false }
        // Fail closed. If this plane needs a digitizer and the guest
        // could not be told to build one, every gesture that follows
        // would address a target no service registered — and
        // `SimHIDVirtualServiceManager` answers that by throwing, which
        // takes `backboardd` and SpringBoard with it. A dead pane beats
        // a dead simulator.
        guard warmServices() else { return false }
        connected = true
        return true
    }

    /// Returns false when this plane cannot be safely dispatched to.
    private func warmServices() -> Bool {
        // A service SimulatorKit cannot build is skipped; one it built
        // but could not deliver stops the warm-up.
        for service in [IndigoMessage.createPointerService, .createMouseService] {
            switch channel.send(service) {
            case .delivered: wait(20_000)
            case .undelivered: return false
            case .unbuilt, .unavailable: continue
            }
        }
        // An external plane's digitizer does not exist until the guest
        // is told to build one. Without this, `IndigoHIDTouchTarget.carPlay`
        // addresses nothing, and dispatching to it takes `backboardd`
        // down — SpringBoard and any CarPlay session with it.
        // Simulator.app creates the service before it ever sends a
        // touch; so do we.
        //
        // The phone is skipped: its digitizer is part of the device, and
        // asking for a second one is its own kind of wrong.
        guard plane.needsExternalDigitizer else { return true }
        // `true` = hasTouchScreen, read off Simulator.app's starkConfig
        // at its own call site. Nothing reaches here without wanting
        // touch, so a knob-only head unit is not a case we have.
        switch channel.send(.createCarPlayService(hasTouchScreen: true)) {
        case .unavailable:
            logErr(
                "[hid] CreateCarPlayService missing — refusing to dispatch to \(hex(touchTarget)); "
                    + "no service would be registered there and the guest throws on unknown targets")
            return false
        case .unbuilt:
            logErr("[hid] CreateCarPlayService returned no message — refusing to dispatch")
            return false
        case .undelivered:
            return false
        case .delivered:
            wait(20_000)
            trace("[hid] carplay digitizer registered at \(hex(touchTarget))")
            return true
        }
    }

    private func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16) }
}
