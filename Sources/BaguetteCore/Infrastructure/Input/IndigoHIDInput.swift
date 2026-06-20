import Foundation
import ObjectiveC

/// Production `Input` — dispatches gestures into SimulatorKit's host-HID
/// pipeline using the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe
/// (Xcode 26 preview-kit, verified on iOS 26.4).
///
/// One instance per simulator. Warm-up runs lazily on first dispatch
/// (creates pointer + mouse services) and stays warm for the instance's
/// lifetime; deinit releases the services.
final class IndigoHIDInput: Input, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost

    private var client: AnyObject?
    private var warmed = false
    private let lock = NSLock()

    // IndigoHIDMessageForMouseNSEvent — 9-arg shape (Xcode 26 preview-kit).
    // Coords are NORMALIZED 0–1; target=0x32 routes to the touch digitizer.
    // direction: 1=down, 0=move, 2=up. nsEventType: 1=down, 2=up, 6=dragged.
    private typealias MouseFn = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
        UInt32, UInt32, UInt32,
        Double, Double,        // unused1, unused2 — pass 1.0
        Double, Double         // widthPoints, heightPoints
    ) -> UnsafeMutableRawPointer?
    /// `IndigoHIDMessageForMouseNSEvent` — *real* 7-arg shape derived
    /// from disassembling SimulatorKit on Xcode 26. Used only for
    /// system-edge gestures (swipe-to-home, app switcher) where the
    /// `edge` flag is what tells iOS to route the touch to the
    /// home-indicator gesture recognizer instead of the foreground
    /// app's pan handlers. Reading the prologue at `0x11270` shows
    /// `cmp x24, #0x4` — bounds-checking x4 against `IndigoHIDEdge`'s
    /// max value (4 = right). ARM64 ABI: ints in x0..x4, CGFloats in
    /// d0/d1, so the C signature is
    ///   (CGPoint*, CGPoint*, target, eventType, edge, NSSize.w, NSSize.h)
    /// Confirmed against `SimDigitizerInputView.TouchEvent.edge`'s
    /// public Swift surface, which carries this exact flag per touch.
    private typealias MouseEdgeFn = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
        UInt32, UInt32, UInt32,        // target, eventType, edge
        Double, Double                 // NSSize.width, NSSize.height
    ) -> UnsafeMutableRawPointer?
    private typealias ButtonFn = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    // IndigoHIDMessageForHIDArbitrary — routes any (page, usage) HID
    // event through the digitizer target. iOS 26 signature is
    //   (target, page, usage, operation)
    // — NOT (page, usage, op, timestamp) as some open-source bridges
    // assume. target=0x32 (the same digitizer constant the mouse path
    // uses); operation 1=down, 2=up. No timestamp.
    private typealias HIDArbitraryFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ScrollFn = @convention(c) (UInt32, Double, Double, Double) -> UnsafeMutableRawPointer?
    private typealias ServiceFn = @convention(c) () -> UnsafeMutableRawPointer?

    private var mouseFn: MouseFn?
    private var mouseEdgeFn: MouseEdgeFn?
    private var buttonFn: ButtonFn?
    private var hidArbFn: HIDArbitraryFn?
    private var scrollFn: ScrollFn?
    private var createPointerSvc: ServiceFn?
    private var createMouseSvc: ServiceFn?
    private var removePointerSvc: ServiceFn?

    // Wire constants — kept private; the user never sees these.
    private static let touchDigitizer: UInt32 = 0x32
    private static let nsEventDown:    UInt32 = 1
    private static let nsEventUp:      UInt32 = 2
    private static let nsEventDragged: UInt32 = 6
    private static let dirDown: UInt32 = 1
    private static let dirMove: UInt32 = 0
    private static let dirUp:   UInt32 = 2
    /// `IndigoHIDEdge` values — passed in x4 of the 7-arg
    /// `IndigoHIDMessageForMouseNSEvent`. Only `bottom` is used in
    /// production today (home-indicator swipe path); the others are
    /// kept here as documentation of the enum's full range so future
    /// edge gestures (control-centre top, notification-centre top
    /// for older devices, etc.) have a named landing spot.
    private static let edgeNone:   UInt32 = 0
    private static let edgeLeft:   UInt32 = 1
    private static let edgeTop:    UInt32 = 2
    private static let edgeBottom: UInt32 = 3
    private static let edgeRight:  UInt32 = 4

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    deinit {
        if warmed, let client {
            if let remove = removePointerSvc, let msg = remove() {
                send(message: msg, to: client)
            }
        }
    }

    // MARK: - Input protocol

    func tap(at point: Point, size: Size, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        // New path: build IOHIDEvent digitizer parent + finger
        // child, run through trackpad-from-HIDEventRef wrapper,
        // patch target + edge slots. Bypasses the iOS 26 / Xcode
        // 26 mouse-event regression where 9-arg
        // `IndigoHIDMessageForMouseNSEvent` taps either get
        // misinterpreted as Home gestures or silently drop. See
        // `IOHIDDigitizerDispatch` for the full recipe.
        let normalised = CGPoint(x: clamp01(point.x / size.width),
                                 y: clamp01(point.y / size.height))
        return IOHIDDigitizerDispatch.tap(
            point: normalised,
            holdSeconds: duration > 0 ? duration : 0.05,
            edge: .none, identifier: nextTouchIdentifier(),
            on: c
        )
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let total = duration > 0 ? duration : 0.25
        let steps = 10
        let stepMs = UInt32((total * 1000) / Double(steps + 2))
        let normStart = CGPoint(x: clamp01(start.x / size.width),
                                y: clamp01(start.y / size.height))
        let normEnd = CGPoint(x: clamp01(end.x / size.width),
                              y: clamp01(end.y / size.height))
        return IOHIDDigitizerDispatch.swipe(
            from: normStart, to: normEnd,
            steps: steps, stepMs: max(8, stepMs),
            edge: .none, identifier: nextTouchIdentifier(),
            on: c
        )
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size,
                edge: DeviceEdge?) -> Bool {
        guard let c = ensureWarm() else { return false }
        let dispatchPhase: IOHIDDigitizerDispatch.Phase
        switch phase {
        case .down: dispatchPhase = .down
        case .move: dispatchPhase = .move
        case .up:   dispatchPhase = .up
        }
        let normalised = CGPoint(x: clamp01(point.x / size.width),
                                 y: clamp01(point.y / size.height))
        // touch1 streaming uses a sticky identifier so iOS sees
        // one continuous touch sequence across the down/move/up
        // chain. The identifier is reset on `down` and reused
        // until `up`.
        if phase == .down { stickyTouchIdentifier = nextTouchIdentifier() }
        let id = stickyTouchIdentifier ?? nextTouchIdentifier()
        let dispatchEdge: IOHIDDigitizerDispatch.Edge
        switch edge {
        case .left:   dispatchEdge = .left
        case .top:    dispatchEdge = .top
        case .right:  dispatchEdge = .right
        case .bottom: dispatchEdge = .bottom
        case nil:     dispatchEdge = .none
        }
        return IOHIDDigitizerDispatch.send(
            point: normalised, identifier: id,
            phase: dispatchPhase, edge: dispatchEdge, on: c
        )
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        // Two-finger streaming kept on the legacy mouse-event
        // signature for now — pinch/pan continue to work via the
        // existing path (they use coincident-finger streaming
        // which the digitizer recipe doesn't model yet).
        guard let c = ensureWarm() else { return false }
        let (et, dir) = mouseEvent(for: phase)
        return sendMouse(client: c, p1: first, p2: second, eventType: et, direction: dir, size: size)
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

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let holdUs = holdMicroseconds(for: duration)
        switch button {
        case .home, .lock:
            return pressLegacyButton(button, holdUs: holdUs, on: c)
        case .power, .volumeUp, .volumeDown, .action,
             .digitalCrown, .sideButton, .leftSideButton:
            guard let usage = button.standardHIDUsage else { return false }
            return pressArbitraryHID(button, usage: usage, holdUs: holdUs, on: c)
        case .appSwitcher:
            // Two consecutive home-button presses ~150 ms apart.
            // SpringBoard listens to the home `IndigoHIDMessageForButton`
            // event source regardless of whether the device has a
            // physical home button, so this works on Face ID iPhones
            // (iPhone X+) too. Recipe matches idb's
            // FBSimulatorPurpleHID app-switcher path. Cleaner than
            // synthesising the slow swipe-and-hold gesture and
            // doesn't depend on the mouse-event signature.
            let downA = pressLegacyButton(.home, holdUs: holdUs, on: c)
            usleep(150_000)
            let downB = pressLegacyButton(.home, holdUs: holdUs, on: c)
            return downA && downB
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
            return IOHIDDigitizerDispatch.swipe(
                from: CGPoint(x: 0.5, y: 0.998),
                to:   CGPoint(x: 0.5, y: 0.58),
                steps: 30, stepMs: 35, dwellMs: 900,
                edge: .bottom, identifier: nextTouchIdentifier(),
                on: c
            ) ? true : false
        case .swipeToHome:
            // Fast edge-flagged flick from the home indicator up
            // to ~mid screen. iOS's home-indicator recognizer
            // routes a quick swipe to Home (no dwell, ends below
            // halfway). Empirical: 12 steps × 16 ms reaching
            // y=0.30 lands on the home screen reliably.
            return IOHIDDigitizerDispatch.swipe(
                from: CGPoint(x: 0.5, y: 0.998),
                to:   CGPoint(x: 0.5, y: 0.30),
                steps: 12, stepMs: 16, dwellMs: 0,
                edge: .bottom, identifier: nextTouchIdentifier(),
                on: c
            ) ? true : false
        case .pullDownToLockScreen:
            // Slow drag down from top-LEFT (above the dynamic
            // island, on the camera side) with edge=top flagged.
            // iOS's status-bar gesture recognizer routes a
            // top-left-origin pull to the lock-screen cover sheet.
            return IOHIDDigitizerDispatch.swipe(
                from: CGPoint(x: 0.25, y: 0.002),
                to:   CGPoint(x: 0.25, y: 0.55),
                steps: 24, stepMs: 25, dwellMs: 0,
                edge: .top, identifier: nextTouchIdentifier(),
                on: c
            ) ? true : false
        case .pullDownToNotificationCenter:
            // Slow drag down from top-RIGHT (above the dynamic
            // island, on the battery / time side) with edge=top
            // flagged. iOS routes a top-right-origin pull to
            // Notification Center.
            return IOHIDDigitizerDispatch.swipe(
                from: CGPoint(x: 0.75, y: 0.002),
                to:   CGPoint(x: 0.75, y: 0.55),
                steps: 24, stepMs: 25, dwellMs: 0,
                edge: .top, identifier: nextTouchIdentifier(),
                on: c
            ) ? true : false
        }
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let c = ensureWarm(), let kfn = hidArbFn else {
            log("[hid] key — IndigoHIDMessageForHIDArbitrary unresolved")
            return false
        }
        let holdUs = holdMicroseconds(for: duration)
        let target = Self.touchDigitizer
        // Sort modifiers so the down/up order is deterministic; iOS
        // doesn't care, but tests + logs become reproducible.
        let mods = modifiers.sorted { $0.rawValue < $1.rawValue }
        log("[hid] key page=\(key.hidUsage.page) usage=\(key.hidUsage.usage) modifiers=\(mods.map(\.rawValue)) hold=\(holdUs)us")

        // Modifier-down → key-down → hold → key-up → modifier-up.
        for m in mods {
            guard let down = kfn(target, m.hidUsage.page, m.hidUsage.usage, 1) else { return false }
            send(message: down, to: c)
        }
        guard let keyDown = kfn(target, key.hidUsage.page, key.hidUsage.usage, 1) else { return false }
        send(message: keyDown, to: c)
        usleep(holdUs)
        guard let keyUp = kfn(target, key.hidUsage.page, key.hidUsage.usage, 2) else { return false }
        send(message: keyUp, to: c)
        for m in mods.reversed() {
            guard let up = kfn(target, m.hidUsage.page, m.hidUsage.usage, 2) else { return false }
            send(message: up, to: c)
        }
        return true
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

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        guard let c = ensureWarm(), let sfn = scrollFn else { return false }
        guard let msg = sfn(Self.touchDigitizer, deltaX, deltaY, 0) else { return false }
        send(message: msg, to: c)
        return true
    }

    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool {
        guard let c = ensureWarm() else { return false }
        let total = duration > 0 ? duration : 0.6
        let steps = 10
        let stepUs = UInt32((total / Double(steps + 2)) * 1_000_000)

        let okDown = sendMouse(client: c, p1: start1, p2: start2, eventType: Self.nsEventDown, direction: Self.dirDown, size: size)
        var okMoves = 0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p1 = Point(x: start1.x + (end1.x - start1.x) * t, y: start1.y + (end1.y - start1.y) * t)
            let p2 = Point(x: start2.x + (end2.x - start2.x) * t, y: start2.y + (end2.y - start2.y) * t)
            usleep(stepUs)
            if sendMouse(client: c, p1: p1, p2: p2, eventType: Self.nsEventDragged, direction: Self.dirMove, size: size) {
                okMoves += 1
            }
        }
        _ = sendMouse(client: c, p1: end1, p2: end2, eventType: Self.nsEventUp, direction: Self.dirUp, size: size)
        return okDown && okMoves >= steps / 2
    }

    // MARK: - private

    private func mouseEvent(for phase: GesturePhase) -> (UInt32, UInt32) {
        switch phase {
        case .down: return (Self.nsEventDown, Self.dirDown)
        case .move: return (Self.nsEventDragged, Self.dirMove)
        case .up:   return (Self.nsEventUp, Self.dirUp)
        }
    }

    /// `IndigoHIDMessageForButton` arg0 + 3rd arg for the legacy
    /// home / lock path. The 3rd arg is a routing target on iOS 26.4
    /// (0x33 = digitizer); not a timestamp despite a `UInt64` slot in
    /// some headers.
    private func buttonCodes(for button: DeviceButton) -> (UInt32, UInt32) {
        switch button {
        case .home: return (0x0, 0x33)
        case .lock: return (0x1, 0x33)
        case .power, .volumeUp, .volumeDown, .action,
             .digitalCrown, .sideButton, .leftSideButton,
             .appSwitcher, .swipeToAppSwitcher, .swipeToHome,
             .pullDownToLockScreen, .pullDownToNotificationCenter:
            // Caller routes these through pressArbitraryHID or the
            // edge-gesture path instead; returning a sentinel keeps
            // the switch total without silently mis-dispatching.
            return (0, 0)
        }
    }

    private func pressLegacyButton(_ button: DeviceButton, holdUs: UInt32, on client: AnyObject) -> Bool {
        guard let bfn = buttonFn else {
            log("[hid] press \(button.rawValue) — buttonFn unresolved")
            return false
        }
        let (arg0, target) = buttonCodes(for: button)
        log("[hid] press \(button.rawValue) via legacy arg0=\(arg0) target=0x\(String(target, radix: 16)) hold=\(holdUs)us")
        guard let down = bfn(arg0, 1, target) else {
            log("[hid] press \(button.rawValue) — down message build returned nil")
            return false
        }
        send(message: down, to: client)
        usleep(holdUs)
        // Release — direction 2; 0 crashes backboardd on iOS 26.4.
        guard let up = bfn(arg0, 2, target) else {
            log("[hid] press \(button.rawValue) — up message build returned nil")
            return false
        }
        send(message: up, to: client)
        return true
    }

    /// Synthesise the Face ID home-indicator gesture: a single-finger
    /// swipe up from the bottom edge with `IndigoHIDEdge.bottom`
    /// flagged on every event. `hold = false` flicks fast (lift at
    /// `y ≈ 0.30`) and lands as Home; `hold = true` settles for
    /// ~400 ms at the midpoint, which iOS recognises as App Switcher.
    /// Coords are normalised; `IndigoHIDMessageForMouseNSEvent`
    /// scales by NSSize(1.0, 1.0) so the points are interpreted as
    /// unit fractions of the device screen.
    ///
    /// Move events use `nsEventType = 1` (LeftMouseDown), NOT 6
    /// (LeftMouseDragged) — the edge variant of the C function
    /// returns nil for any eventType ≠ {1, 2}, so passing 6 silently
    /// drops every interpolated step and iOS only ever sees a
    /// down + up at the same coordinate.
    private func swipeFromBottomEdge(on client: AnyObject, hold: Bool) -> Bool {
        guard mouseEdgeFn != nil else {
            log("[hid] swipe-from-bottom-edge — mouseEdgeFn unresolved")
            return false
        }
        let xN = 0.5
        let yStart = 0.95
        let yEnd: Double = hold ? 0.40 : 0.30
        let steps = 10
        let stepUs: UInt32 = 16_000   // ~16 ms per step

        guard sendMouseEdge(
            client: client, p1: CGPoint(x: xN, y: yStart), p2: nil,
            eventType: Self.nsEventDown, edge: Self.edgeBottom
        ) else { return false }
        usleep(stepUs)

        var ok = 0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let y = yStart + (yEnd - yStart) * t
            if sendMouseEdge(
                client: client, p1: CGPoint(x: xN, y: y), p2: nil,
                eventType: Self.nsEventDragged, edge: Self.edgeBottom
            ) { ok += 1 }
            usleep(stepUs)
        }

        if hold {
            // Linger at the midpoint so the gesture recogniser commits
            // to App Switcher rather than slingshotting back to Home.
            // Resending the same point keeps the touch state alive
            // through the recognition window even if a single move
            // event drops.
            for _ in 0..<5 {
                _ = sendMouseEdge(
                    client: client, p1: CGPoint(x: xN, y: yEnd), p2: nil,
                    eventType: Self.nsEventDragged, edge: Self.edgeBottom
                )
                usleep(80_000)
            }
        }

        _ = sendMouseEdge(
            client: client, p1: CGPoint(x: xN, y: yEnd), p2: nil,
            eventType: Self.nsEventUp, edge: Self.edgeBottom
        )
        return ok >= steps / 2
    }

    /// Build + dispatch one edge-flagged mouse event via the 7-arg
    /// signature. Uses the same retry-on-nil pattern as `sendMouse`
    /// but is intentionally separate so the legacy 9-arg path stays
    /// untouched — only edge gestures route here.
    private func sendMouseEdge(
        client: AnyObject,
        p1: CGPoint, p2: CGPoint?,
        eventType: UInt32, edge: UInt32
    ) -> Bool {
        guard let mfn = mouseEdgeFn else { return false }
        var pt1 = p1
        var msg: UnsafeMutableRawPointer?
        for _ in 0..<3 {
            if let p2 {
                var pt2 = p2
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    withUnsafePointer(to: &pt2) { p2Ref in
                        mfn(p1Ref, p2Ref, Self.touchDigitizer, eventType, edge, 1.0, 1.0)
                    }
                }
            } else {
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    mfn(p1Ref, nil, Self.touchDigitizer, eventType, edge, 1.0, 1.0)
                }
            }
            if msg != nil { break }
            usleep(5_000)
        }
        guard let msg else { return false }
        send(message: msg, to: client)
        return true
    }

    private func pressArbitraryHID(_ button: DeviceButton, usage: HIDUsage, holdUs: UInt32, on client: AnyObject) -> Bool {
        guard let kfn = hidArbFn else {
            log("[hid] press \(button.rawValue) — IndigoHIDMessageForHIDArbitrary unresolved")
            return false
        }
        let target = Self.touchDigitizer
        log("[hid] press \(button.rawValue) target=0x\(String(target, radix: 16)) page=\(usage.page) usage=\(usage.usage) hold=\(holdUs)us")
        guard let down = kfn(target, usage.page, usage.usage, 1) else {
            log("[hid] press \(button.rawValue) — down message build returned nil")
            return false
        }
        send(message: down, to: client)
        usleep(holdUs)
        guard let up = kfn(target, usage.page, usage.usage, 2) else {
            log("[hid] press \(button.rawValue) — up message build returned nil")
            return false
        }
        send(message: up, to: client)
        log("[hid] press \(button.rawValue) — sent down+up")
        return true
    }

    /// Build + dispatch one mouse event. Retries on the 2-finger settle
    /// window — the builder returns nil for ~50ms after a 2-finger
    /// mouseDown, so the first one or two moves of a fresh 2-finger
    /// gesture transiently fail. 12 attempts × 5ms = 60ms covers the
    /// settle window without perceptible latency.
    private func sendMouse(
        client: AnyObject,
        p1: Point, p2: Point?,
        eventType: UInt32, direction: UInt32,
        size: Size
    ) -> Bool {
        guard let mfn = mouseFn else { return false }
        let maxAttempts = (p2 != nil) ? 12 : 3
        var pt1 = CGPoint(
            x: clamp01(p1.x / size.width),
            y: clamp01(p1.y / size.height)
        )
        var msg: UnsafeMutableRawPointer?
        if let p2 {
            var pt2 = CGPoint(
                x: clamp01(p2.x / size.width),
                y: clamp01(p2.y / size.height)
            )
            for _ in 0..<maxAttempts {
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    withUnsafePointer(to: &pt2) { p2Ref in
                        mfn(p1Ref, p2Ref, Self.touchDigitizer, eventType, direction, 1.0, 1.0, size.width, size.height)
                    }
                }
                if msg != nil { break }
                usleep(5_000)
            }
        } else {
            for _ in 0..<maxAttempts {
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    mfn(p1Ref, nil, Self.touchDigitizer, eventType, direction, 1.0, 1.0, size.width, size.height)
                }
                if msg != nil { break }
                usleep(5_000)
            }
        }
        guard let msg else { return false }
        send(message: msg, to: client)
        return true
    }

    private func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }

    private func send(message: UnsafeMutableRawPointer, to client: AnyObject) {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, sel) else { return }
        typealias Fn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
    }

    /// Lazy resolve + warm. Synchronised because gestures might come from
    /// multiple threads in a streaming session.
    private func ensureWarm() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }

        resolveFunctions()
        guard let device = resolveDevice() else { return nil }
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            logErr("SimDeviceLegacyHIDClient class not found")
            return nil
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let imp = class_getMethodImplementation(cls, initSel) else { return nil }
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        let initFn = unsafeBitCast(imp, to: InitFn.self)
        guard let metaCls = object_getClass(cls) else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocImp = class_getMethodImplementation(metaCls, allocSel) else { return nil }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocFn = unsafeBitCast(allocImp, to: AllocFn.self)
        guard let allocated = allocFn(cls, allocSel) else { return nil }

        var err: NSError?
        guard let c = initFn(allocated, initSel, device, &err) else {
            if let err { logErr("SimDeviceLegacyHIDClient init failed: \(err)") }
            return nil
        }
        client = c
        warmServices(on: c)
        warmed = true
        return c
    }

    private func resolveFunctions() {
        guard mouseFn == nil else { return }
        let dev = CoreSimulators.developerDir()
        let path = (dev as NSString).appendingPathComponent(
            "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        )
        guard let handle = dlopen(path, RTLD_NOW) else {
            logErr("SimulatorKit dlopen failed: \(dlerrorString())")
            return
        }
        let mouseSym = dlsym(handle, "IndigoHIDMessageForMouseNSEvent")
        // Same C function, two Swift typedefs — `MouseFn` is the
        // legacy 9-arg shape used for taps/pans/pinches (verified in
        // production); `MouseEdgeFn` is the *real* 7-arg ABI used
        // for edge gestures where iOS reads x4 as `IndigoHIDEdge`.
        // Loading both lets the existing dispatcher stay untouched
        // while edge-aware paths get the right argument layout.
        mouseFn     = mouseSym.map { unsafeBitCast($0, to: MouseFn.self) }
        mouseEdgeFn = mouseSym.map { unsafeBitCast($0, to: MouseEdgeFn.self) }
        buttonFn   = dlsym(handle, "IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFn.self) }
        hidArbFn   = dlsym(handle, "IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: HIDArbitraryFn.self) }
        scrollFn   = dlsym(handle, "IndigoHIDMessageForScrollEvent").map { unsafeBitCast($0, to: ScrollFn.self) }
        createPointerSvc = dlsym(handle, "IndigoHIDMessageToCreatePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
        createMouseSvc   = dlsym(handle, "IndigoHIDMessageToCreateMouseService").map { unsafeBitCast($0, to: ServiceFn.self) }
        removePointerSvc = dlsym(handle, "IndigoHIDMessageToRemovePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
        log("[hid] symbols resolved — mouse:\(mouseFn != nil) mouseEdge:\(mouseEdgeFn != nil) button:\(buttonFn != nil) hidArb:\(hidArbFn != nil) scroll:\(scrollFn != nil)")
    }

    private func warmServices(on client: AnyObject) {
        if let create = createPointerSvc, let msg = create() {
            send(message: msg, to: client)
            usleep(20_000)
        }
        if let create = createMouseSvc, let msg = create() {
            send(message: msg, to: client)
            usleep(20_000)
        }
    }
}
