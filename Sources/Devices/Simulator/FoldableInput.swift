import BaguetteDevice
import Foundation

/// A foldable's input: touches go to the lit panel's digitizer as on any
/// phone, while the hardware keys go to the guest the way Device Hub
/// presses them (`DeviceKeys`). On iPhone Duo the legacy button path
/// reaches backboardd but on a touchscreen service, which SpringBoard
/// ignores; Device Hub's own `mainScreenButtons` service is what it
/// listens to, and the keys it sends are the ones below.
struct FoldableInput: HID {
    let touches: any HID
    let keys: any DeviceKeys

    /// Device Hub's hold: a quarter second between down and up.
    static let hold: TimeInterval = 0.25

    /// The key Device Hub sends for a button, measured on iPhone Duo.
    /// Power and the sleep/wake key are the same consumer `Power`
    /// usage; the camera control is Apple's vendor keyboard `0x66`.
    static func key(for button: DeviceButton) -> HIDUsage? {
        guard case .hardware(let hardware) = button else { return nil }
        switch hardware {
        case .power, .lock:  return HIDUsage(page: 0x0C, usage: 0x30)
        case .volumeUp:      return HIDUsage(page: 0x0C, usage: 0xE9)
        case .volumeDown:    return HIDUsage(page: 0x0C, usage: 0xEA)
        case .action:        return HIDUsage(page: 0xFF00, usage: 0x66)
        case .digitalCrown, .sideButton, .leftSideButton: return nil
        }
    }

    var available: Set<DeviceButton> { touches.available }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        guard let key = Self.key(for: button) else {
            return touches.button(button, duration: duration)
        }
        do {
            try keys.press(key, holding: [], hold: duration > 0 ? duration : Self.hold)
            return true
        } catch {
            log("[keys] press \(button.rawValue) failed: \(error)")
            return false
        }
    }

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        touches.tap(at: point, size: size, duration: duration, edge: edge)
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        touches.swipe(from: start, to: end, size: size, duration: duration)
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        touches.touch1(phase: phase, at: point, size: size, edge: edge)
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        touches.touch2(phase: phase, first: first, second: second, size: size)
    }

    /// A keystroke's hold when the caller names none: the panel's tap.
    static let keystroke: TimeInterval = 0.1

    /// iPhone Duo drops the Indigo keyboard message whichever panel it
    /// addresses; a key on the guest's buttons service types.
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        let held = modifiers.sorted { $0.rawValue < $1.rawValue }.map(\.hidUsage)
        do {
            try keys.press(key.hidUsage, holding: held, hold: duration > 0 ? duration : Self.keystroke)
            return true
        } catch {
            log("[keys] key \(key.hidUsage.usage) failed: \(error)")
            return false
        }
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        touches.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    func twoFingerPath(
        start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double
    ) -> Bool {
        touches.twoFingerPath(
            start1: start1, end1: end1, start2: start2, end2: end2, size: size, duration: duration)
    }
}
