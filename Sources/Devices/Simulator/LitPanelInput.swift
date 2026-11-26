import BaguetteDevice
import Foundation

/// A foldable's input across folds: each gesture goes to the panel the
/// hinge lights. iPhone Duo's page keeps one socket while the hinge
/// moves (the book draws both panels), so an input bound once would
/// keep addressing a panel that has gone dark.
///
/// A finger stays on the digitizer it touched down on until it lifts:
/// the hinge can move from outside (Device Hub, `baguette hinge`)
/// mid-drag, and an `up` sent to the other panel would leave the first
/// one holding a contact nobody releases.
public final class LitPanelInput: HID, @unchecked Sendable {
    private let cover: any HID
    private let unfolded: any HID
    private let hinge: any Hinge
    private let lock = NSLock()
    /// The panel each contact stream went down on; a one-finger drag and
    /// a pinch can overlap, and each keeps its own digitizer.
    private enum Contact { case oneFinger, twoFingers }
    private var touching: [Contact: IntegratedPanel] = [:]

    public init(cover: any HID, unfolded: any HID, hinge: any Hinge) {
        self.cover = cover
        self.unfolded = unfolded
        self.hinge = hinge
    }

    /// A foldable's live input from its two panels and its hinge.
    public convenience init(displays: any Displays, hinge: any Hinge) {
        self.init(
            cover: displays.panel(.primary).input(),
            unfolded: displays.panel(.secondary).input(),
            hinge: hinge)
    }

    private func input(on panel: IntegratedPanel) -> any HID { panel == .primary ? cover : unfolded }

    private var lit: any HID { input(on: hinge.litPanel) }

    /// The panel a contact's phase goes to: the lit one on `down`, the
    /// same one until `up`.
    private func contact(_ stream: Contact, _ phase: GesturePhase) -> any HID {
        lock.lock()
        defer { lock.unlock() }
        let panel = (phase == .down ? nil : touching[stream]) ?? hinge.litPanel
        touching[stream] = phase == .up ? nil : panel
        return input(on: panel)
    }

    public func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        lit.tap(at: point, size: size, duration: duration, edge: edge)
    }

    public func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        lit.swipe(from: start, to: end, size: size, duration: duration)
    }

    public func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        contact(.oneFinger, phase).touch1(phase: phase, at: point, size: size, edge: edge)
    }

    public func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        contact(.twoFingers, phase).touch2(phase: phase, first: first, second: second, size: size)
    }

    public var available: Set<DeviceButton> { lit.available }

    public func button(_ button: DeviceButton, duration: Double) -> Bool {
        lit.button(button, duration: duration)
    }

    public func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        lit.key(key, modifiers: modifiers, duration: duration)
    }

    public func scroll(deltaX: Double, deltaY: Double) -> Bool {
        lit.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    public func twoFingerPath(
        start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double
    ) -> Bool {
        lit.twoFingerPath(
            start1: start1, end1: end1, start2: start2, end2: end2, size: size, duration: duration)
    }
}
