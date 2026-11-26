import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation
import Mockable

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
/// The calls into SimulatorKit and IOKit are `IndigoMessages`
/// (`Internal/System/`); what the probe makes of their answers is here.
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


    /// SimulatorKit's Indigo messages and how long to wait between events:
    /// this Mac's, unless a test stands in.
    @TaskLocal static var messages: any IndigoMessages = HostIndigoMessages()
    @TaskLocal static var pause: @Sendable (_ milliseconds: UInt32) -> Void = HostIndigoMessages.pause

    func run() {
        let mask = parseHexU32(eventMask) ?? 0x04
        if let endY = swipeEndY {
            // Down → N moves → up. Same identifier across the
            // whole chain so iOS treats it as one finger. Move
            // events use mask `0x04` (Position only) per
            // SimulatorKit / digitizer convention.
            let downStartId: UInt32 = identifier == 0 ? 0xC0DE : identifier
            let down = probe(y: y, pressure: pressure, identifier: downStartId,
                             eventMask: mask, range: range, touch: touch, dump: false)
            say("DOWN  : " + jsonLine(down))
            for i in 1...swipeSteps {
                Self.pause(swipeStepMs)
                let t = Double(i) / Double(swipeSteps)
                let yAt = y + (endY - y) * t
                // Move events keep Range+Touch on so iOS sees a
                // sustained touch with a position change. Bare
                // Position (0x04) made iOS think the finger had
                // lifted between moves.
                let mv = probe(y: yAt, pressure: pressure, identifier: downStartId,
                               eventMask: 0x07, range: true, touch: true, dump: false)
                if i == swipeSteps / 2 || i == swipeSteps {
                    say(String(format: "MOVE %02d: ", i) + jsonLine(mv))
                }
            }
            Self.pause(swipeStepMs)
            // Optional dwell at endY — keeps the touch state alive
            // (iOS treats the period between move events as the
            // finger held still). Required to discriminate App
            // Switcher from a fast flick-Home gesture.
            if swipeDwellMs > 0 {
                let pulses = max(1, Int(swipeDwellMs / 50))
                for _ in 0..<pulses {
                    _ = probe(y: endY, pressure: pressure, identifier: downStartId,
                              eventMask: 0x07, range: true, touch: true, dump: false)
                    Self.pause(50)
                }
                say("DWELL : \(swipeDwellMs)ms held at y=\(endY)")
            }
            let up = probe(y: endY, pressure: 0.0, identifier: downStartId,
                           eventMask: 0x06, range: false, touch: false, dump: false)
            say("UP    : " + jsonLine(up))
            return
        }
        if cycle {
            // Paired touch-down + touch-up. Down event uses the
            // configured mask + range/touch flags; up event always
            // clears them (mask=Touch|Position so iOS sees a
            // touch-state change, with `touch=false` + `range=false`
            // signalling lift-off).
            let down = probe(y: y, pressure: pressure, identifier: identifier,
                             eventMask: mask, range: range, touch: touch, dump: dumpBytes)
            say("DOWN: " + jsonLine(down))
            if let hex = down.hex { say(hex) }
            Self.pause(holdMs)
            // Send the matching up. eventMask = 0x06 (Touch|Position)
            // so iOS gets a clear "touch ended" signal, with
            // touch=false/range=false to mark the finger as lifted.
            let up = probe(y: y, pressure: 0.0, identifier: identifier,
                           eventMask: 0x06, range: false, touch: false, dump: dumpBytes)
            say("UP:   " + jsonLine(up))
            if let hex = up.hex { say(hex) }
            return
        }
        let outcome = probe(y: y, pressure: pressure, identifier: identifier,
                            eventMask: mask, range: range, touch: touch, dump: dumpBytes)
        say(jsonLine(outcome))
        if let hex = outcome.hex { say(hex) }

        if compareWithMouse {
            // The mouse-event message at the same point, built (never
            // sent) with the 9-arg recipe production uses: dumping it at
            // edge=0 and edge=3 shows which byte is the edge slot.
            say("--- mouse-event message edge=0 ---")
            if let h0 = Self.messages.mouse(x: x, y: y, edge: 0) {
                say("size=\(h0.count)\n\(Self.hexDump(h0))")
            }
            say("--- mouse-event message edge=3 (bottom) ---")
            if let h3 = Self.messages.mouse(x: x, y: y, edge: 3) {
                say("size=\(h3.count)\n\(Self.hexDump(h3))")
            }
        }
    }

    /// One probe at `y` with this command's finger, parent and patches.
    private func probe(y: Double, pressure: Double, identifier: UInt32,
                       eventMask: UInt32, range: Bool, touch: Bool, dump: Bool) -> Outcome {
        Self.probe(
            DigitizerFinger(index: index, identifier: identifier, eventMask: eventMask,
                            x: x, y: y, pressure: pressure, range: range, touch: touch,
                            withParent: withParent),
            patchTarget: patchTarget, patchEdge: edgeBitFromName(patchEdge),
            dispatch: doDispatch, dump: dump,
            udid: options.udid, deviceSet: options.deviceSet, messages: Self.messages)
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
        let messageSize: Int   // the wrapper output's allocation, 0 when nil
        let dispatched: Bool
        let reason: String
        let hex: String?       // hex dump of the wrapper output (when --dump)
    }

    /// Ask the trackpad wrapper for a message from `finger`, patch it as
    /// asked, and — only when `dispatch` — send it. Default (`dispatch =
    /// false`) only asks "does the wrapper accept this event shape?"; set
    /// it once the wrapper output looks plausible.
    static func probe(_ finger: DigitizerFinger,
                      patchTarget: Bool, patchEdge: UInt8,
                      dispatch: Bool, dump: Bool,
                      udid: String, deviceSet: String?,
                      messages: any IndigoMessages) -> Outcome {
        var message: [UInt8]
        switch messages.trackpad(from: finger) {
        case .refused(let reason):
            return Outcome(accepted: false, messageSize: 0, dispatched: false, reason: reason, hex: nil)
        case .built(let built):
            message = built
        }
        let size = message.count

        // The wrapper leaves uninitialised bytes at offset 0x6c (first
        // record) and 0x10c (second record); iOS reads `0x32` =
        // `IndigoHIDTouchTarget` from those slots to route the touch to
        // the digitizer subsystem. Without the patch, the message
        // arrives in an unconsumed channel and gets dropped silently.
        if patchTarget {
            let target: [UInt8] = [0x32, 0, 0, 0]
            if size >= 0x70 { message.replaceSubrange(0x6c..<0x70, with: target) }
            if size >= 0x110 { message.replaceSubrange(0x10c..<0x110, with: target) }
        }
        // First record's edge slot at 0x3a/0x3b, second record's at
        // 0xda/0xdb. Byte 0x3a is the "edges present" flag (0x04 when
        // any edge is set), byte 0x3b is the per-edge bitmask.
        if patchEdge != 0 {
            if size >= 0x3c { message.replaceSubrange(0x3a..<0x3c, with: [0x04, patchEdge]) }
            if size >= 0xdc { message.replaceSubrange(0xda..<0xdc, with: [0x04, patchEdge]) }
        }

        let hex = dump ? hexDump(message) : nil
        // Default leaves the simulator untouched so mask/flag
        // combinations can be swept safely.
        guard dispatch else {
            return Outcome(
                accepted: true, messageSize: size, dispatched: false,
                reason: "wrapper accepted; dispatch skipped (use --dispatch to send)", hex: hex)
        }
        let dispatched = messages.send(message, udid: udid, deviceSet: deviceSet)
        return Outcome(
            accepted: true, messageSize: size, dispatched: dispatched,
            reason: dispatched
                ? "wrapper accepted; message dispatched (size=\(size) bytes)"
                : "wrapper accepted but dispatch failed (HID client / device lookup)",
            hex: hex)
    }

    /// Pretty-print a buffer as 16-byte rows of hex + ASCII gutter.
    /// Used to inspect wrapper output structure without a debugger.
    static func hexDump(_ bytes: [UInt8]) -> String {
        var out = ""
        var offset = 0
        while offset < bytes.count {
            let row = min(16, bytes.count - offset)
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
}

/// One digitizer finger event, as `IOHIDEventCreateDigitizerFingerEvent`
/// takes it — optionally wrapped in a digitizer parent, the shape real iOS
/// touches arrive in. Real `IOHIDDigitizerEventMask` bits: Range = 0x01,
/// Touch = 0x02, Position = 0x04, Stop = 0x08, Peak = 0x10, Identity =
/// 0x20, Attribute = 0x40, Cancel = 0x80.
struct DigitizerFinger: Equatable, Sendable {
    let index: UInt32
    let identifier: UInt32
    let eventMask: UInt32
    let x: Double
    let y: Double
    let pressure: Double
    let range: Bool
    let touch: Bool
    let withParent: Bool
}

/// What SimulatorKit's trackpad wrapper made of a digitizer event: the
/// Indigo message it built, or why there is none.
enum TrackpadMessage: Equatable, Sendable {
    case built([UInt8])
    case refused(String)
}

/// SimulatorKit's Indigo messages, as the trackpad probe asks for them:
/// one built from a digitizer event, one built from a mouse event for
/// comparison, and sending one to a device.
@Mockable
protocol IndigoMessages: Sendable {
    /// The message `IndigoHIDMessageForTrackpadEventFromHIDEventRef`
    /// builds from `finger`, or why it — or IOKit before it — wouldn't.
    func trackpad(from finger: DigitizerFinger) -> TrackpadMessage
    /// The message production's 9-arg mouse-event recipe builds at
    /// (x, y) with `edge`; nil when SimulatorKit can't be reached.
    func mouse(x: Double, y: Double, edge: UInt32) -> [UInt8]?
    /// Send `message` to the device; false when it or its HID client
    /// can't be found.
    func send(_ message: [UInt8], udid: String, deviceSet: String?) -> Bool
}
