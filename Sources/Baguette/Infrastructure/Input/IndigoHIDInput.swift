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
    private weak var host: CoreSimulators?

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

    init(udid: String, host: CoreSimulators) {
        self.udid = udid
        self.host = host
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
        guard sendMouse(client: c, p1: point, p2: nil, eventType: Self.nsEventDown, direction: Self.dirDown, size: size) else { return false }
        usleep(UInt32((duration > 0 ? duration : 0.05) * 1_000_000))
        return sendMouse(client: c, p1: point, p2: nil, eventType: Self.nsEventUp, direction: Self.dirUp, size: size)
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let total = duration > 0 ? duration : 0.25
        let steps = 10
        let stepUs = UInt32((total / Double(steps + 2)) * 1_000_000)

        guard sendMouse(client: c, p1: start, p2: nil, eventType: Self.nsEventDown, direction: Self.dirDown, size: size) else { return false }
        var ok = 0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = Point(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            usleep(stepUs)
            if sendMouse(client: c, p1: p, p2: nil, eventType: Self.nsEventDragged, direction: Self.dirMove, size: size) { ok += 1 }
        }
        _ = sendMouse(client: c, p1: end, p2: nil, eventType: Self.nsEventUp, direction: Self.dirUp, size: size)
        return ok >= steps / 2
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool {
        guard let c = ensureWarm() else { return false }
        let (et, dir) = mouseEvent(for: phase)
        return sendMouse(client: c, p1: point, p2: nil, eventType: et, direction: dir, size: size)
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        guard let c = ensureWarm() else { return false }
        let (et, dir) = mouseEvent(for: phase)
        return sendMouse(client: c, p1: first, p2: second, eventType: et, direction: dir, size: size)
    }

    func button(_ button: DeviceButton, hidUsage: HIDUsage?, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let holdUs = holdMicroseconds(for: duration)
        switch button {
        case .home, .lock:
            return pressLegacyButton(button, holdUs: holdUs, on: c)
        case .power, .volumeUp, .volumeDown, .action:
            guard let usage = button.hidUsage(override: hidUsage) else { return false }
            return pressArbitraryHID(button, usage: usage, holdUs: holdUs, on: c)
        }
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
        case .power, .volumeUp, .volumeDown, .action:
            // Caller routes these through pressArbitraryHID instead;
            // returning a sentinel keeps the switch total without
            // silently mis-dispatching.
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
        guard let device = host?.resolveDevice(udid: udid) else { return nil }
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
        mouseFn    = dlsym(handle, "IndigoHIDMessageForMouseNSEvent").map { unsafeBitCast($0, to: MouseFn.self) }
        buttonFn   = dlsym(handle, "IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFn.self) }
        hidArbFn   = dlsym(handle, "IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: HIDArbitraryFn.self) }
        scrollFn   = dlsym(handle, "IndigoHIDMessageForScrollEvent").map { unsafeBitCast($0, to: ScrollFn.self) }
        createPointerSvc = dlsym(handle, "IndigoHIDMessageToCreatePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
        createMouseSvc   = dlsym(handle, "IndigoHIDMessageToCreateMouseService").map { unsafeBitCast($0, to: ServiceFn.self) }
        removePointerSvc = dlsym(handle, "IndigoHIDMessageToRemovePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
        log("[hid] symbols resolved — mouse:\(mouseFn != nil) button:\(buttonFn != nil) hidArb:\(hidArbFn != nil) scroll:\(scrollFn != nil)")
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
