import BaguetteDevice
import Foundation
import Mockable

/// The Indigo channel into one simulator — SimulatorKit's
/// `SimDeviceLegacyHIDClient`, reduced to the calls `IndigoHIDInput` makes.
/// Each `send` builds one Indigo message with SimulatorKit's own builder and
/// sends it; it decides nothing. Which messages a gesture becomes, in what
/// order, with which waits, in which coordinates, and what to do when one
/// cannot be built or delivered all belong to `IndigoHIDInput`. The real one
/// is `SimulatorKitIndigoChannel`.
@Mockable
protocol IndigoChannel: AnyObject, Sendable {
    /// Open a HID client to `device`, replacing any open one. `false` when
    /// SimulatorKit cannot make one.
    func connect(to device: NSObject) -> Bool
    /// Build `message` and send it over the open client.
    func send(_ message: IndigoMessage) -> IndigoDelivery
}

/// One Indigo message, named by what it asks of the guest. Each case is
/// one SimulatorKit builder, its arguments exactly as that builder takes
/// them.
enum IndigoMessage: Equatable, Sendable {
    /// `IndigoHIDMessageToCreatePointerService` / `…MouseService` /
    /// `…ToRemovePointerService`.
    case createPointerService, createMouseService, removePointerService
    /// `IndigoHIDMessageToCreateCarPlayService(hasTouchScreen)`. Unlike its
    /// siblings it takes one byte; Simulator.app's call site passes
    /// `[[self starkConfig] hasTouchScreen]` — `true` for a touchscreen head
    /// unit, `false` for a knob-driven one. Same 192-byte struct as the
    /// siblings, opcode `[0x30] = 7`, flag at `[0x44]`.
    case createCarPlayService(hasTouchScreen: Bool)
    /// `IndigoHIDMessageToRemoveCarPlayService`.
    case removeCarPlayService
    /// `IndigoHIDMessageForButton(code, direction, target)` — direction
    /// 1 = down, 2 = up (0 crashes backboardd on iOS 26.4); the third
    /// argument is a routing target (0x33), not a timestamp.
    case button(code: UInt32, direction: UInt32, target: UInt32)
    /// `IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)` —
    /// operation 1 = down, 2 = up. No timestamp, despite what some
    /// open-source bridges assume.
    case usage(HIDUsage, operation: UInt32, target: UInt32)
    /// `IndigoHIDMessageForScrollEvent(target, dx, dy, 0)`.
    case scroll(deltaX: Double, deltaY: Double, target: UInt32)
    /// The 9-arg `IndigoHIDMessageForMouseNSEvent` (Xcode 26 preview-kit),
    /// built on the main thread: points NORMALISED 0–1, `size` in device
    /// points. eventType 1 = down, 2 = up, 6 = dragged; direction
    /// 1 = down, 0 = move, 2 = up.
    case mouse(
        first: CGPoint, second: CGPoint?, target: UInt32,
        eventType: UInt32, direction: UInt32, size: Size)
    /// One finger of a real `IOHIDEvent` digitizer touch, wrapped and patched
    /// by `IOHIDDigitizerDispatch.send`. Point normalised 0–1.
    case touch(
        CGPoint, identifier: UInt32, phase: IOHIDDigitizerDispatch.Phase,
        edge: IOHIDDigitizerDispatch.Edge, target: UInt32)
}

/// What became of one `send`.
enum IndigoDelivery: Equatable, Sendable {
    /// The simulator confirmed the send.
    case delivered
    /// Built, but the send failed or timed out.
    case undelivered
    /// SimulatorKit's builder answered no message.
    case unbuilt
    /// SimulatorKit has no such builder, or no client is open.
    case unavailable

    /// Whether a message was built at all — delivered or not.
    var built: Bool { self == .delivered || self == .undelivered }
}
