import ArgumentParser
import Foundation

/// `baguette diag-digitizer-trackpad --udid <UDID>`
///
/// One-shot research probe asking a single empirical question:
///   *Does `IndigoHIDMessageForTrackpadEventFromHIDEventRef` accept
///   an `IOHIDEventCreateDigitizerFingerEvent`-built event?*
///
/// Background: opensafari's #491 investigation proved the *Pointer*
/// variant of the FromHIDEventRef wrappers rejects digitizer-typed
/// events. The Trackpad variant has the same shape but a different
/// name and is conceptually closer to multi-finger digitizer input —
/// and nobody has tested it. If it accepts the event, we have a
/// new injection route for proper edge gestures (Option A from
/// docs/option-a-investigation). If it rejects, this confirms that
/// the only path forward is the much larger `SimDigitizerInputView`
/// reflective dispatch (opensafari Candidate C, Effort L).
///
/// Output is a single JSON line — `{"accepted":bool,"dispatched":bool,
/// "reason":"…"}` — so a future automation harness can grep for the
/// verdict without parsing prose.
///
/// Lives entirely in this command file. No production code path
/// reaches this code; it is integration-only by design.
struct DiagDigitizerTrackpadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag-digitizer-trackpad",
        abstract: "Probe whether IndigoHIDMessageForTrackpadEventFromHIDEventRef accepts an IOHIDEvent digitizer-finger event"
    )

    @OptionGroup var options: DeviceOption

    /// Hex-encoded `IOHIDDigitizerEventMask`. The real bit values
    /// from `IOHIDFamily/IOHIDEvent.h` are:
    ///   Range = 0x01, Touch = 0x02, Position = 0x04, Stop = 0x08,
    ///   Peak  = 0x10, Identity = 0x20, Attribute = 0x40, Cancel = 0x80.
    /// Default `0x04` (Position only) is the smallest mask that
    /// still says "the finger is at this coordinate". A full
    /// touch-down event uses `0x07` (Range | Touch | Position).
    /// Earlier crash with `0xD0` was Cancel|Attribute|Peak — pure
    /// garbage to the digitizer; lesson learned.
    @Option(help: "IOHIDDigitizerEventMask (hex). Default = 0x04 (Position). Touch-down = 0x07.")
    var eventMask: String = "0x04"

    @Option(help: "Touch X (normalized 0..1)")
    var x: Double = 0.5
    @Option(help: "Touch Y (normalized 0..1)")
    var y: Double = 0.5
    @Option(help: "Tip pressure (0..1)")
    var pressure: Double = 0.0
    @Option(help: "Finger index")
    var index: UInt32 = 0
    @Option(help: "Touch identifier")
    var identifier: UInt32 = 0
    @Flag(help: "Set the in-range bit on the digitizer event")
    var range: Bool = false
    @Flag(help: "Set the touching-surface bit on the digitizer event")
    var touch: Bool = false

    /// Default OFF. The wrapper accepting the event tells us the
    /// path is open; sending the message can crash the simulator
    /// when the format is still malformed. Turn this on only after
    /// the wrapper output looks plausible (non-nil + sensible size).
    @Flag(name: .customLong("dispatch"),
          help: "After the wrapper accepts, send the message via SimDeviceLegacyHIDClient (may crash the sim if event shape is wrong)")
    var doDispatch: Bool = false

    @Flag(name: .customLong("dump"),
          help: "Print the wrapper output as hex bytes so we can inspect message structure")
    var dumpBytes: Bool = false

    /// Build a *mouse-event* message at the same coords for
    /// side-by-side comparison. The mouse path is known to work
    /// (modulo the Xcode 26 regression for taps), so its message
    /// kind / payload is the gold standard. If our trackpad-from-
    /// digitizer message has a different kind tag, that explains
    /// why iOS ignores it.
    @Flag(name: .customLong("compare-with-mouse"),
          help: "Also build a mouse-event message at the same coords and dump bytes for comparison")
    var compareWithMouse: Bool = false

    /// Wrap the finger event in a `IOHIDEventCreateDigitizerEvent`
    /// parent (transducer = Finger). Real iOS touches are
    /// parent+child IOHIDEvents, not bare finger events. The
    /// mouse-event wrapper produces 384-byte messages (two
    /// records); our finger-only digitizer event produces 192-byte
    /// messages (one record). Adding the parent should make the
    /// trackpad wrapper emit a 2-record message that iOS actually
    /// processes.
    @Flag(name: .customLong("with-parent"),
          help: "Build a digitizer-parent event with the finger appended as a child (mirrors real iOS touch shape)")
    var withParent: Bool = false

    /// After the wrapper builds the message, overwrite the
    /// `target` field at offset 0x6c (first record) and 0x10c
    /// (second record) with `0x32` — `IndigoHIDTouchTarget`. The
    /// trackpad wrapper leaves uninitialised bytes there, so iOS
    /// can't route the touch. The mouse-event wrapper writes
    /// `0x32` in both slots, which is what iOS expects.
    @Flag(name: .customLong("patch-target"),
          help: "Overwrite the target slots at 0x6c + 0x10c with 0x32 (IndigoHIDTouchTarget) before dispatch")
    var patchTarget: Bool = false

    /// Set the screen-edge flag in the message. The mouse-event
    /// path encodes the IndigoHIDEdge as a bitmask at byte `0x3b`
    /// (and mirrored at `0xdb` in the second record), with byte
    /// `0x3a / 0xda` set to `0x04` when *any* edge is present.
    /// Bottom edge = bit 0 = `0x01`, which is the flag iOS reads
    /// to route a touch to the home-indicator gesture recognizer.
    /// The trackpad-from-digitizer wrapper doesn't set this slot,
    /// so a properly-formed trackpad touch never reaches the home
    /// gesture recogniser without this patch.
    @Option(name: .customLong("patch-edge"),
            help: "Patch the edge slot. One of: none|left|top|bottom|right")
    var patchEdge: String = "none"

    /// When set, dispatches a full swipe in one invocation: down
    /// at (x, y) → 10 interpolated position moves → up at
    /// (x, swipe-end-y). All events share the same `identifier`
    /// so iOS sees one continuous touch sequence. Requires
    /// `--with-parent --patch-target --dispatch` for the touches
    /// to actually land.
    @Option(name: .customLong("swipe-end-y"),
            help: "Run a swipe from y to this normalised end-y (sends down + 10 moves + up in one invocation)")
    var swipeEndY: Double?

    @Option(name: .customLong("swipe-steps"),
            help: "Number of interpolated move events for the swipe (default 10)")
    var swipeSteps: Int = 10

    @Option(name: .customLong("swipe-step-ms"),
            help: "Delay (ms) between move events (default 16 ≈ 60fps)")
    var swipeStepMs: UInt32 = 16

    @Option(name: .customLong("swipe-dwell-ms"),
            help: "After reaching the end y, hold the finger there for this long (resending move events) before lifting. iOS uses dwell to discriminate Home vs App Switcher.")
    var swipeDwellMs: UInt32 = 0

    /// When set with `--dispatch`, sends a down→up *pair* with the
    /// supplied identifier, holding the finger for `--hold-ms` in
    /// between. iOS's HID processor expects matched touch-down /
    /// touch-up events; the first crash sent only a down with no
    /// up, leaving an orphan permanent-touch that corrupted
    /// `backboardd`'s tracker. Cycle mode prevents that.
    @Flag(name: .customLong("cycle"),
          help: "Dispatch a paired touch-down + touch-up sequence (safer than a single event)")
    var cycle: Bool = false

    @Option(help: "Hold time between cycle down and up (ms)")
    var holdMs: UInt32 = 50

    func run() {
        let mask = parseHexU32(eventMask) ?? 0x04
        if let endY = swipeEndY {
            // Down → N moves → up. Same identifier across the
            // whole chain so iOS treats it as one finger. Move
            // events use mask `0x04` (Position only) per
            // SimulatorKit / digitizer convention.
            let downStartId: UInt32 = identifier == 0 ? 0xC0DE : identifier
            let down = Self.probe(
                udid: options.udid, deviceSet: options.deviceSet,
                x: x, y: y, pressure: pressure,
                index: index, identifier: downStartId,
                eventMask: mask, range: range, touch: touch,
                withParent: withParent, patchTarget: patchTarget,
                patchEdge: edgeBitFromName(patchEdge),
                dispatch: doDispatch, dump: false
            )
            print("DOWN  : " + jsonLine(down))
            for i in 1...swipeSteps {
                usleep(swipeStepMs * 1000)
                let t = Double(i) / Double(swipeSteps)
                let yAt = y + (endY - y) * t
                // Move events keep Range+Touch on so iOS sees a
                // sustained touch with a position change. Bare
                // Position (0x04) made iOS think the finger had
                // lifted between moves.
                let mv = Self.probe(
                    udid: options.udid, deviceSet: options.deviceSet,
                    x: x, y: yAt, pressure: pressure,
                    index: index, identifier: downStartId,
                    eventMask: 0x07, range: true, touch: true,
                    withParent: withParent, patchTarget: patchTarget,
                    patchEdge: edgeBitFromName(patchEdge),
                    dispatch: doDispatch, dump: false
                )
                if i == swipeSteps / 2 || i == swipeSteps {
                    print(String(format: "MOVE %02d: ", i) + jsonLine(mv))
                }
            }
            usleep(swipeStepMs * 1000)
            // Optional dwell at endY — keeps the touch state alive
            // (iOS treats the period between move events as the
            // finger held still). Required to discriminate App
            // Switcher from a fast flick-Home gesture.
            if swipeDwellMs > 0 {
                let pulses = max(1, Int(swipeDwellMs / 50))
                for _ in 0..<pulses {
                    _ = Self.probe(
                        udid: options.udid, deviceSet: options.deviceSet,
                        x: x, y: endY, pressure: pressure,
                        index: index, identifier: downStartId,
                        eventMask: 0x07, range: true, touch: true,
                        withParent: withParent, patchTarget: patchTarget,
                        patchEdge: edgeBitFromName(patchEdge),
                        dispatch: doDispatch, dump: false
                    )
                    usleep(50_000)
                }
                print("DWELL : \(swipeDwellMs)ms held at y=\(endY)")
            }
            let up = Self.probe(
                udid: options.udid, deviceSet: options.deviceSet,
                x: x, y: endY, pressure: 0.0,
                index: index, identifier: downStartId,
                eventMask: 0x06, range: false, touch: false,
                withParent: withParent, patchTarget: patchTarget,
                patchEdge: edgeBitFromName(patchEdge),
                dispatch: doDispatch, dump: false
            )
            print("UP    : " + jsonLine(up))
            return
        }
        if cycle {
            // Paired touch-down + touch-up. Down event uses the
            // configured mask + range/touch flags; up event always
            // clears them (mask=Touch|Position so iOS sees a
            // touch-state change, with `touch=false` + `range=false`
            // signalling lift-off).
            let down = Self.probe(
                udid: options.udid, deviceSet: options.deviceSet,
                x: x, y: y, pressure: pressure,
                index: index, identifier: identifier,
                eventMask: mask, range: range, touch: touch,
                withParent: withParent, patchTarget: patchTarget,
                patchEdge: edgeBitFromName(patchEdge),
                dispatch: doDispatch, dump: dumpBytes
            )
            print("DOWN: " + jsonLine(down))
            if let hex = down.hex { print(hex) }
            usleep(holdMs * 1000)
            // Send the matching up. eventMask = 0x06 (Touch|Position)
            // so iOS gets a clear "touch ended" signal, with
            // touch=false/range=false to mark the finger as lifted.
            let up = Self.probe(
                udid: options.udid, deviceSet: options.deviceSet,
                x: x, y: y, pressure: 0.0,
                index: index, identifier: identifier,
                eventMask: 0x06, range: false, touch: false,
                withParent: withParent, patchTarget: patchTarget,
                patchEdge: edgeBitFromName(patchEdge),
                dispatch: doDispatch, dump: dumpBytes
            )
            print("UP:   " + jsonLine(up))
            if let hex = up.hex { print(hex) }
            return
        }
        let outcome = Self.probe(
            udid: options.udid, deviceSet: options.deviceSet,
            x: x, y: y, pressure: pressure,
            index: index, identifier: identifier,
            eventMask: mask, range: range, touch: touch,
            withParent: withParent, patchTarget: patchTarget,
            patchEdge: edgeBitFromName(patchEdge),
            dispatch: doDispatch, dump: dumpBytes
        )
        print(jsonLine(outcome))
        if let hex = outcome.hex { print(hex) }

        if compareWithMouse {
            print("--- mouse-event message edge=0 ---")
            if let h0 = Self.dumpMouseEventMessage(x: x, y: y, edge: 0) {
                print(h0)
            }
            print("--- mouse-event message edge=3 (bottom) ---")
            if let h3 = Self.dumpMouseEventMessage(x: x, y: y, edge: 3) {
                print(h3)
            }
        }
    }

    /// Build (but do not dispatch) a mouse-event message at (x, y)
    /// using the same legacy 9-arg signature `IndigoHIDInput` uses
    /// in production, with `edge` placed in the x4 register. Used
    /// only for byte-level comparison: dumping at edge=0 vs edge=3
    /// reveals which byte is the edge slot in the message buffer.
    private static func dumpMouseEventMessage(x: Double, y: Double, edge: UInt32) -> String? {
        let dev = CoreSimulators.developerDir()
        let kitPath = (dev as NSString).appendingPathComponent(
            "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        )
        guard let kit = dlopen(kitPath, RTLD_NOW) else { return nil }
        guard let sym = dlsym(kit, "IndigoHIDMessageForMouseNSEvent") else { return nil }
        // 9-arg shape — same `MouseFn` typealias as IndigoHIDInput.
        typealias MouseFn = @convention(c) (
            UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
            UInt32, UInt32, UInt32,
            Double, Double, Double, Double
        ) -> UnsafeMutableRawPointer?
        let mfn = unsafeBitCast(sym, to: MouseFn.self)
        var pt = CGPoint(x: x, y: y)
        let msg = withUnsafePointer(to: &pt) { p1 in
            // target=0x32 digitizer, eventType=1 down, x4 = edge,
            // NSSize=1.0×1.0, the trailing two doubles are unused
            // by the actual function (extra args under the 9-arg
            // shape).
            mfn(p1, nil, 0x32, 1, edge, 1.0, 1.0, 1.0, 1.0)
        }
        guard let msg else { return nil }
        let size = malloc_size(msg)
        let dump = hexDump(msg, length: size)
        free(msg)
        return "size=\(size)\n\(dump)"
    }

    private func jsonLine(_ outcome: Outcome) -> String {
        let a = outcome.accepted   ? "true" : "false"
        let d = outcome.dispatched ? "true" : "false"
        let r = outcome.reason.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"accepted\":\(a),\"messageSize\":\(outcome.messageSize),\"dispatched\":\(d),\"reason\":\"\(r)\"}"
    }

    private func parseHexU32(_ s: String) -> UInt32? {
        let trimmed = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return UInt32(trimmed, radix: 16)
    }

    /// Map a kebab-case edge name to the bitmask byte the
    /// `IndigoHIDMessageForMouseNSEvent` path writes at offset
    /// `0x3b`/`0xdb`. Empirically derived (sweep over edge=0..4):
    ///   none = 0x00, left = 0x02, right = 0x04, top = 0x08, bottom = 0x01.
    /// Returns 0 for unrecognised names so the patch is a no-op.
    private func edgeBitFromName(_ name: String) -> UInt8 {
        switch name {
        case "left":   return 0x02
        case "top":    return 0x08
        case "right":  return 0x04
        case "bottom": return 0x01
        default:       return 0x00
        }
    }

    struct Outcome {
        let accepted: Bool
        let messageSize: Int   // malloc_size() of the wrapper output, 0 when nil
        let dispatched: Bool
        let reason: String
        let hex: String?       // hex dump of the wrapper output (when --dump)
    }

    /// All the dlsym + IOKit + SimulatorKit dance, kept as a static
    /// so the probe is mechanically reusable (an integration test or
    /// a higher-level scratch script can invoke this without going
    /// through ArgumentParser). Default — `dispatch=false` — only
    /// asks "does the wrapper accept this event shape?". Set
    /// `dispatch=true` once the wrapper output looks plausible.
    static func probe(udid: String, deviceSet: String?,
                      x: Double, y: Double, pressure: Double,
                      index: UInt32, identifier: UInt32,
                      eventMask: UInt32, range: Bool, touch: Bool,
                      withParent: Bool, patchTarget: Bool,
                      patchEdge: UInt8,
                      dispatch: Bool, dump: Bool) -> Outcome {
        // 1. Open SimulatorKit — same dlopen the production HID input
        //    already does. We need the trackpad wrapper symbol.
        let dev = CoreSimulators.developerDir()
        let kitPath = (dev as NSString).appendingPathComponent(
            "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        )
        guard let kit = dlopen(kitPath, RTLD_NOW) else {
            return Outcome(accepted: false, messageSize: 0, dispatched: false,
                           reason: "dlopen SimulatorKit failed: \(String(cString: dlerror()))",
                           hex: nil)
        }
        guard let wrapSym = dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef") else {
            return Outcome(accepted: false, messageSize: 0, dispatched: false,
                           reason: "IndigoHIDMessageForTrackpadEventFromHIDEventRef unresolved",
                           hex: nil)
        }
        // The wrapper takes a CFTypeRef IOHIDEventRef and returns a
        // newly malloc'd Indigo message (or nil on rejection).
        typealias WrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
        let wrapFn = unsafeBitCast(wrapSym, to: WrapFn.self)

        // 2. Resolve IOHIDEventCreateDigitizerFingerEvent. It lives
        //    inside the dyld shared cache (HID/IOKit) — RTLD_DEFAULT
        //    is enough.
        guard let createSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                    "IOHIDEventCreateDigitizerFingerEvent") else {
            return Outcome(accepted: false, messageSize: 0, dispatched: false,
                           reason: "IOHIDEventCreateDigitizerFingerEvent unresolved",
                           hex: nil)
        }
        // Real signature (from IOHIDEvent.h):
        //   IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
        //     CFAllocatorRef allocator,
        //     AbsoluteTime timeStamp,
        //     uint32_t index, uint32_t identifier,
        //     IOHIDDigitizerEventMask eventMask,
        //     IOHIDFloat x, y, z, tipPressure, twist,
        //     Boolean range, Boolean touch,
        //     IOOptionBits options
        //   )
        // ARM64 ABI: 8 ints in x0..x7, 5 doubles in d0..d4.
        typealias CreateFn = @convention(c) (
            CFAllocator?,                              // x0
            UInt64,                                    // x1
            UInt32, UInt32, UInt32,                    // x2..x4
            Double, Double, Double, Double, Double,    // d0..d4
            Bool, Bool, UInt32                         // x5..x7
        ) -> Unmanaged<CFTypeRef>?
        let createFn = unsafeBitCast(createSym, to: CreateFn.self)

        // 3. Build the digitizer-finger event with caller-supplied
        //    parameters. Real `IOHIDDigitizerEventMask` bit values:
        //    Range = 0x01, Touch = 0x02, Position = 0x04, Stop = 0x08,
        //    Peak = 0x10, Identity = 0x20, Attribute = 0x40,
        //    Cancel = 0x80. A full touch-down event uses 0x07
        //    (Range | Touch | Position); a pure position update is
        //    0x04. The first crash sent 0xD0 (Cancel | Attribute |
        //    Peak) thinking it was Touch | Position | Range — a
        //    garbage mask that asked the digitizer to *cancel* an
        //    in-progress touch on a digitizer with no in-progress
        //    touch, which is undefined behaviour in `backboardd`.
        let unmanaged = createFn(
            nil,                            // CFAllocator (default)
            mach_absolute_time(),           // timestamp
            index, identifier,
            eventMask,
            x, y, 0.0,                      // x, y, z (normalised)
            pressure,
            0.0,                            // twist
            range,
            touch,
            0                               // options
        )
        guard let unmanaged else {
            return Outcome(accepted: false, messageSize: 0, dispatched: false,
                           reason: "IOHIDEventCreateDigitizerFingerEvent returned nil",
                           hex: nil)
        }
        let fingerCF = unmanaged.takeRetainedValue()

        // 3b. If `--with-parent`, wrap the finger in a digitizer
        //     parent event with the finger appended as a child.
        //     Real iOS touches arrive as parent+child pairs (the
        //     mouse-event message is a 2-record envelope); a bare
        //     finger event produces a 1-record envelope iOS ignores.
        let eventCF: CFTypeRef
        if withParent {
            // IOHIDEventCreateDigitizerEvent signature (from
            // IOHIDEvent.h):
            //   IOHIDEventRef IOHIDEventCreateDigitizerEvent(
            //     CFAllocatorRef, AbsoluteTime,
            //     IOHIDDigitizerTransducerType,
            //     uint32_t index, uint32_t identifier,
            //     IOHIDDigitizerEventMask,
            //     uint32_t buttonMask,
            //     IOHIDFloat x, y, z,
            //     IOHIDFloat tipPressure, barrelPressure,
            //     Boolean range, Boolean touch,
            //     IOOptionBits options
            //   )
            // ARM64: 9 ints (x0..x7 + 1 spilled) + 5 doubles (d0..d4).
            guard let createParentSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                              "IOHIDEventCreateDigitizerEvent") else {
                return Outcome(accepted: false, messageSize: 0, dispatched: false,
                               reason: "IOHIDEventCreateDigitizerEvent unresolved",
                               hex: nil)
            }
            typealias CreateParentFn = @convention(c) (
                CFAllocator?, UInt64,                          // x0, x1
                UInt32,                                        // x2 transducer
                UInt32, UInt32, UInt32, UInt32,                // x3..x6
                Double, Double, Double, Double, Double,        // d0..d4
                Bool, Bool, UInt32                             // x7, stack…
            ) -> Unmanaged<CFTypeRef>?
            let createParent = unsafeBitCast(createParentSym, to: CreateParentFn.self)
            // Transducer type 2 = kIOHIDDigitizerTransducerTypeFinger.
            let parentUM = createParent(
                nil, mach_absolute_time(),
                2,                                 // transducer = Finger
                index, identifier,
                eventMask,
                0,                                 // buttonMask
                x, y, 0.0,                         // x, y, z
                pressure, 0.0,                     // tipPressure, barrelPressure
                range, touch,
                0
            )
            guard let parentUM else {
                return Outcome(accepted: false, messageSize: 0, dispatched: false,
                               reason: "IOHIDEventCreateDigitizerEvent returned nil",
                               hex: nil)
            }
            let parent = parentUM.takeRetainedValue()

            // Append the finger child to the parent.
            guard let appendSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                        "IOHIDEventAppendEvent") else {
                return Outcome(accepted: false, messageSize: 0, dispatched: false,
                               reason: "IOHIDEventAppendEvent unresolved",
                               hex: nil)
            }
            typealias AppendFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
            let append = unsafeBitCast(appendSym, to: AppendFn.self)
            append(parent, fingerCF, 0)
            eventCF = parent
        } else {
            eventCF = fingerCF
        }

        // 4. Hand the digitizer event to the trackpad wrapper.
        //    Non-nil = the wrapper accepted the event shape; nil
        //    means rejected. The first run with mask=0xD0 returned
        //    non-nil + crashed on dispatch, so wrapper acceptance
        //    alone isn't sufficient — message contents have to
        //    survive downstream HID processing too.
        let raw = Unmanaged.passUnretained(eventCF as AnyObject).toOpaque()
        let msg = wrapFn(raw)
        guard let msg else {
            return Outcome(
                accepted: false, messageSize: 0, dispatched: false,
                reason: "IndigoHIDMessageForTrackpadEventFromHIDEventRef returned nil",
                hex: nil
            )
        }
        let size = malloc_size(msg)

        // 4b. Patch target slots if asked. The wrapper leaves
        //     uninitialised bytes at offset 0x6c (first record)
        //     and 0x10c (second record); iOS reads `0x32` =
        //     `IndigoHIDTouchTarget` from those slots to route
        //     the touch to the digitizer subsystem. Without the
        //     patch, the message arrives in an unconsumed channel
        //     and gets dropped silently.
        if patchTarget {
            let target: UInt32 = 0x32
            msg.storeBytes(of: target, toByteOffset: 0x6c, as: UInt32.self)
            if size >= 0x110 {
                msg.storeBytes(of: target, toByteOffset: 0x10c, as: UInt32.self)
            }
        }
        if patchEdge != 0 {
            // First record's edge slot at 0x3a/0x3b, second
            // record's at 0xda/0xdb. Byte 0x3a is the "edges
            // present" flag (0x04 when any edge is set), byte
            // 0x3b is the per-edge bitmask.
            msg.storeBytes(of: UInt8(0x04), toByteOffset: 0x3a, as: UInt8.self)
            msg.storeBytes(of: patchEdge,   toByteOffset: 0x3b, as: UInt8.self)
            if size >= 0xdc {
                msg.storeBytes(of: UInt8(0x04), toByteOffset: 0xda, as: UInt8.self)
                msg.storeBytes(of: patchEdge,   toByteOffset: 0xdb, as: UInt8.self)
            }
        }

        let hex = dump ? hexDump(msg, length: size) : nil

        // 5. Optional dispatch — only when the caller explicitly
        //    asks. Default leaves the simulator untouched so we can
        //    sweep mask/flag combinations safely.
        if !dispatch {
            free(msg)
            return Outcome(
                accepted: true, messageSize: size, dispatched: false,
                reason: "wrapper accepted; dispatch skipped (use --dispatch to send)",
                hex: hex
            )
        }
        let dispatched = Self.dispatch(message: msg, udid: udid, deviceSet: deviceSet)
        return Outcome(
            accepted: true, messageSize: size, dispatched: dispatched,
            reason: dispatched
                ? "wrapper accepted; message dispatched (size=\(size) bytes)"
                : "wrapper accepted but dispatch failed (HID client / device lookup)",
            hex: hex
        )
    }

    /// Pretty-print a buffer as 16-byte rows of hex + ASCII gutter.
    /// Used to inspect wrapper output structure without a debugger.
    private static func hexDump(_ ptr: UnsafeMutableRawPointer, length: Int) -> String {
        var out = ""
        let bytes = ptr.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset < length {
            let row = min(16, length - offset)
            var line = String(format: "  %04x  ", offset)
            for i in 0..<row { line += String(format: "%02x ", bytes[offset + i]) }
            for _ in row..<16 { line += "   " }
            line += " "
            for i in 0..<row {
                let b = bytes[offset + i]
                line += (b >= 0x20 && b < 0x7f) ? String(UnicodeScalar(b)) : "."
            }
            out += line + "\n"
            offset += row
        }
        return out
    }

    /// Send a built Indigo message via `SimDeviceLegacyHIDClient.send`.
    /// Mirrors the production path in `IndigoHIDInput` so the probe's
    /// dispatch is byte-identical to a real button press; only the
    /// message contents differ.
    private static func dispatch(message: UnsafeMutableRawPointer,
                                 udid: String, deviceSet: String?) -> Bool {
        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        guard let device = simulators.resolveDevice(udid: udid) else { return false }
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else { return false }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let imp = class_getMethodImplementation(cls, initSel) else { return false }
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        let initFn = unsafeBitCast(imp, to: InitFn.self)
        guard let metaCls = object_getClass(cls) else { return false }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocImp = class_getMethodImplementation(metaCls, allocSel) else { return false }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocFn = unsafeBitCast(allocImp, to: AllocFn.self)
        guard let allocated = allocFn(cls, allocSel) else { return false }
        var err: NSError?
        guard let client = initFn(allocated, initSel, device, &err) else { return false }

        let sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let sendImp = class_getMethodImplementation(object_getClass(client)!, sendSel) else { return false }
        typealias SendFn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        let sendFn = unsafeBitCast(sendImp, to: SendFn.self)
        let nilObj: AnyObject? = nil
        sendFn(client, sendSel, message, ObjCBool(true), nilObj, nilObj)
        return true
    }
}
