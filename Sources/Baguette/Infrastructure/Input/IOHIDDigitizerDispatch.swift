import Foundation

/// Production digitizer-event dispatch — the path we cracked while
/// debugging the iOS 26.4 / Xcode 26 mouse-event regression.
///
/// Xcode 26 it produces messages iOS
/// either ignores or interprets as the Home gesture. The fix is to
/// build a real `IOHIDEvent` digitizer parent + finger child, run
/// it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef`
/// (the only `*FromHIDEventRef` wrapper that doesn't reject
/// digitizer events), then *patch two byte slots* the wrapper
/// leaves uninitialised:
///
///   • offset 0x6c + 0x10c → `0x32` (`IndigoHIDTouchTarget`),
///     the routing tag iOS reads to send the touch to the
///     digitizer subsystem;
///   • offset 0x3a/0x3b + 0xda/0xdb → edge bitmask
///     (`0x04 0x01` for bottom = home indicator; `0x00 0x00`
///     for interior touches), so iOS's home-indicator gesture
///     recognizer sees touches that started on the safe area.
///
/// All non-edge interior touches use `edge: .none`. Real edge
/// gestures (swipe-to-home, app switcher) use `edge: .bottom` —
/// iOS itself then discriminates Home vs App Switcher from
/// velocity and dwell, exactly as Simulator.app does.
///
/// Empirical recipe verified against booted iPhone 17 Pro Max /
/// iOS 26.4 / Xcode 26: tap → app launches, swipe-to-home →
/// returns to home, slow drag with dwell → app switcher cards.
enum IOHIDDigitizerDispatch {
    /// Screen-edge bitmask written at byte 0x3b/0xdb of the Indigo
    /// message. Empirically derived by sweeping `edge=0..4` through
    /// `IndigoHIDMessageForMouseNSEvent`'s 7-arg shape and diffing
    /// the produced bytes.
    enum Edge {
        case none, left, top, right, bottom

        /// The wire's `DeviceEdge` in this vocabulary; `nil` is an
        /// interior touch. One translation for every caller, so a
        /// `tap` and a `touch1` at the same point cannot disagree.
        static func from(_ edge: DeviceEdge?) -> Edge {
            switch edge {
            case .left: return .left
            case .top: return .top
            case .right: return .right
            case .bottom: return .bottom
            case nil: return .none
            }
        }

        var bit: UInt8 {
            switch self {
            case .none: return 0x00
            case .left: return 0x02
            case .top: return 0x08
            case .right: return 0x04
            case .bottom: return 0x01
            }
        }
    }

    /// Phase of a touch sequence. `down` is the initial press,
    /// `move` is a sustained-touch position update, `up` is the
    /// finger lift. Each maps to a different `IOHIDDigitizerEventMask`
    /// + range/touch flag combination.
    enum Phase {
        case down, move, up

        /// `IOHIDDigitizerEventMask` bits for this phase. Sustained
        /// touch (down + move) carries Range | Touch | Position;
        /// lift carries Touch | Position so iOS sees the
        /// touch-state change; pure interior position moves keep
        /// Range + Touch on so iOS doesn't treat the move as a
        /// new touch sequence.
        var eventMask: UInt32 {
            switch self {
            case .down: return 0x07  // Range | Touch | Position
            case .move: return 0x07  // sustained
            case .up: return 0x06  // Touch | Position (lift)
            }
        }
        var range: Bool { self != .up }
        var touch: Bool { self != .up }
    }

    // MARK: - one-shot helpers

    /// Single-finger tap at `point` (normalised 0..1). Convenience
    /// wrapper around `down` → hold → `up` for the common case.
    static func tap(
        point: CGPoint, holdSeconds: Double,
        edge: Edge = .none, identifier: UInt32,
        target: UInt32 = IndigoHIDTouchTarget.phone,
        screenGuard: InputScreenGuard? = nil,
        on client: AnyObject
    ) -> Bool {
        let pressed = send(
            point: point, identifier: identifier, phase: .down,
            edge: edge, target: target, screenGuard: screenGuard, on: client)
        if pressed {
            let holdUs = UInt32(max(0.02, holdSeconds) * 1_000_000)
            usleep(holdUs)
        }
        let released = send(
            point: point, identifier: identifier, phase: .up,
            edge: edge, target: target, screenGuard: screenGuard, on: client)
        return pressed && released
    }

    /// Continuous swipe from `start` to `end` over `steps`
    /// interpolated moves. Optional `dwellMs` holds the finger at
    /// the endpoint before lift — iOS uses dwell to discriminate
    /// Home from App Switcher when `edge == .bottom`.
    static func swipe(
        from start: CGPoint, to end: CGPoint,
        steps: Int = 10, stepMs: UInt32 = 16,
        dwellMs: UInt32 = 0,
        edge: Edge = .none, identifier: UInt32,
        target: UInt32 = IndigoHIDTouchTarget.phone,
        screenGuard: InputScreenGuard? = nil,
        on client: AnyObject
    ) -> Bool {
        var ok = send(
            point: start, identifier: identifier, phase: .down,
            edge: edge, target: target, screenGuard: screenGuard, on: client)
        var lastPoint = start
        if ok {
            for i in 1...steps {
                usleep(stepMs * 1000)
                let t = Double(i) / Double(steps)
                lastPoint = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t)
                ok = send(
                    point: lastPoint, identifier: identifier, phase: .move,
                    edge: edge, target: target, screenGuard: screenGuard, on: client)
                if !ok { break }
            }
        }
        if ok && dwellMs > 0 {
            let pulses = max(1, Int(dwellMs / 50))
            for _ in 0..<pulses {
                ok = send(
                    point: lastPoint, identifier: identifier, phase: .move,
                    edge: edge, target: target, screenGuard: screenGuard, on: client)
                if !ok { break }
                usleep(50_000)
            }
        }
        if ok { usleep(stepMs * 1000) }
        let released = send(
            point: lastPoint, identifier: identifier, phase: .up,
            edge: edge, target: target, screenGuard: screenGuard, on: client)
        return ok && released
    }

    // MARK: - core

    /// Build, patch, and dispatch one digitizer event. Returns
    /// `false` if any step fails — symbol resolution, IOHIDEvent
    /// construction, wrapper rejection, or message build.
    static func send(
        point: CGPoint, identifier: UInt32, phase: Phase,
        edge: Edge,
        target: UInt32 = IndigoHIDTouchTarget.phone,
        screenGuard: InputScreenGuard? = nil,
        on client: AnyObject
    ) -> Bool {
        guard screenGuard?.allows(phase == .up ? .up : .move) != false,
            ensureSymbols()
        else { return false }
        guard
            let parent = makeDigitizerEvent(
                point: point,
                identifier: identifier,
                phase: phase)
        else { return false }
        // `parent` is a CF-typed object (IOHIDEventRef bridged
        // through Unmanaged.takeRetainedValue); ARC handles its
        // lifetime here once `withExtendedLifetime` keeps it alive
        // long enough for the wrapper call to copy out the data.
        let raw: UnsafeMutableRawPointer? = withExtendedLifetime(parent) {
            wrapTrackpad(event: parent)
        }
        guard let raw else { return false }
        patch(message: raw, edge: edge, target: target)
        return IndigoHIDMessage.send(raw, to: client)
    }

    // MARK: - private — IOHIDEvent construction

    /// Build a digitizer parent event with a finger child appended.
    /// Real iOS touches always arrive as parent + child IOHIDEvent
    /// pairs, never as bare finger events; without the parent the
    /// trackpad wrapper produces a 192-byte stub iOS ignores.
    private static func makeDigitizerEvent(
        point: CGPoint,
        identifier: UInt32,
        phase: Phase
    ) -> CFTypeRef? {
        guard let createParent = createDigitizerFn,
            let createFinger = createFingerFn,
            let appendFn = appendEventFn
        else { return nil }

        let mask = phase.eventMask
        let range = phase.range
        let touch = phase.touch
        let pressure = phase.touch ? 0.0 : 0.0  // pressure non-zero
        // crashed earlier;
        // 0.0 stays safe.
        let now = mach_absolute_time()
        let transducerFinger: UInt32 = 2  // kIOHIDDigitizerTransducerTypeFinger

        guard
            let parentUM = createParent(
                nil, now, transducerFinger,
                0, identifier, mask, 0,
                point.x, point.y, 0.0,
                pressure, 0.0,
                range, touch, 0
            )
        else { return nil }
        let parent = parentUM.takeRetainedValue()

        guard
            let fingerUM = createFinger(
                nil, now,
                0, identifier, mask,
                point.x, point.y, 0.0,
                pressure, 0.0,
                range, touch, 0
            )
        else { return parent }
        let finger = fingerUM.takeRetainedValue()
        appendFn(parent, finger, 0)
        return parent
    }

    /// Run the digitizer event through `IndigoHIDMessageForTrackpadEventFromHIDEventRef`.
    /// The wrapper accepts digitizer-typed events (unlike the
    /// pointer/scroll variants) and produces a 384-byte two-record
    /// message at the correct layout.
    private static func wrapTrackpad(event: CFTypeRef) -> UnsafeMutableRawPointer? {
        guard let wrapFn = trackpadWrapFn else { return nil }
        let raw = Unmanaged.passUnretained(event as AnyObject).toOpaque()
        return wrapFn(raw)
    }

    /// Patch the byte slots the trackpad wrapper leaves
    /// uninitialised. Both target records must be set for iOS to
    /// consume the touch correctly.
    static func patch(
        message msg: UnsafeMutableRawPointer, edge: Edge,
        target: UInt32 = IndigoHIDTouchTarget.phone
    ) {
        msg.storeBytes(of: target, toByteOffset: 0x6c, as: UInt32.self)
        let size = malloc_size(msg)
        if size >= 0x110 {
            msg.storeBytes(of: target, toByteOffset: 0x10c, as: UInt32.self)
        }
        let edgeBit = edge.bit
        let edgePresent: UInt8 = edgeBit == 0 ? 0 : 0x04
        msg.storeBytes(of: edgePresent, toByteOffset: 0x3a, as: UInt8.self)
        msg.storeBytes(of: edgeBit, toByteOffset: 0x3b, as: UInt8.self)
        if size >= 0xdc {
            msg.storeBytes(of: edgePresent, toByteOffset: 0xda, as: UInt8.self)
            msg.storeBytes(of: edgeBit, toByteOffset: 0xdb, as: UInt8.self)
        }
    }

    // MARK: - private — symbol resolution

    /// `IOHIDEventCreateDigitizerEvent(allocator, ts, transducer,
    ///   index, identifier, eventMask, buttonMask, x, y, z,
    ///   tipPressure, barrelPressure, range, touch, options)`.
    /// 9 ints in x0..x7+stack, 5 doubles in d0..d4.
    typealias CreateDigitizerFn =
        @convention(c) (
            CFAllocator?, UInt64, UInt32,
            UInt32, UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double,
            Bool, Bool, UInt32
        ) -> Unmanaged<CFTypeRef>?

    /// `IOHIDEventCreateDigitizerFingerEvent(allocator, ts, index,
    ///   identifier, eventMask, x, y, z, tipPressure, twist,
    ///   range, touch, options)`. 8 ints + 5 doubles.
    typealias CreateFingerFn =
        @convention(c) (
            CFAllocator?, UInt64,
            UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double,
            Bool, Bool, UInt32
        ) -> Unmanaged<CFTypeRef>?

    typealias AppendEventFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    typealias TrackpadWrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?

    // `nonisolated(unsafe)` because these are write-once function
    // pointers cached on first dispatch; the cost of a real lock
    // is unnecessary churn for an effectively-immutable resource.
    nonisolated(unsafe) private static var createDigitizerFn: CreateDigitizerFn?
    nonisolated(unsafe) private static var createFingerFn: CreateFingerFn?
    nonisolated(unsafe) private static var appendEventFn: AppendEventFn?
    nonisolated(unsafe) private static var trackpadWrapFn: TrackpadWrapFn?
    nonisolated(unsafe) private static var symbolsResolved = false

    /// Lazy one-time resolve of the four C symbols. IOKit symbols
    /// (event creation + append) live in the dyld shared cache —
    /// `RTLD_DEFAULT` is enough. The trackpad wrapper requires
    /// `dlopen`-ing SimulatorKit explicitly.
    private static func ensureSymbols() -> Bool {
        if symbolsResolved { return true }
        let dev = CoreSimulators.developerDir()
        guard let kitPath = SimulatorKitFramework.path(developerDir: dev),
            let kit = dlopen(kitPath, RTLD_NOW)
        else { return false }
        let dyld = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pCreateDig = dlsym(dyld, "IOHIDEventCreateDigitizerEvent"),
            let pCreateFin = dlsym(dyld, "IOHIDEventCreateDigitizerFingerEvent"),
            let pAppend = dlsym(dyld, "IOHIDEventAppendEvent"),
            let pWrap = dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef")
        else { return false }
        createDigitizerFn = unsafeBitCast(pCreateDig, to: CreateDigitizerFn.self)
        createFingerFn = unsafeBitCast(pCreateFin, to: CreateFingerFn.self)
        appendEventFn = unsafeBitCast(pAppend, to: AppendEventFn.self)
        trackpadWrapFn = unsafeBitCast(pWrap, to: TrackpadWrapFn.self)
        symbolsResolved = true
        return true
    }
}
