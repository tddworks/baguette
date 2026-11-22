import BaguetteDevice
import Foundation

/// This Mac shared to its viewers, each through a display of the viewer's
/// shape, by the display's UUID — its device id. A share makes the display;
/// as the main display when the viewer asks, the previous main given back when
/// the share ends; made again in the new shape as the viewer turns (a made
/// display takes no other shape), under the same serial so its id holds;
/// removed when it ends.
/// Design: docs/features/mac-screen/design.md#sharing-to-a-viewers-shape.
final class ScreenShares: @unchecked Sendable {
    /// How the shared display sits among the Mac's others.
    enum Use: String, Sendable {
        /// The main display while shared: menu bar, Dock and new windows there.
        case main
        /// One more display beside the Mac's own; the main display stays.
        case extra

        /// The use a viewer asks for by name; extra when they name none.
        init?(wire: String?) {
            guard let wire else { self = .extra; return }
            self.init(rawValue: wire)
        }
    }

    private struct Share {
        let viewer: String
        let serial: UInt32
        let use: Use
        var display: any VirtualDisplay
        /// The main display before this share took it, to give back.
        let previousMain: UInt32?
    }

    private let displays: any VirtualDisplays
    private let arrangement: any DisplayArrangement
    private let lock = NSLock()
    private var shares: [String: Share] = [:]
    private var serials: UInt32 = 0

    init(displays: any VirtualDisplays, arrangement: any DisplayArrangement) {
        self.displays = displays
        self.arrangement = arrangement
    }

    /// Share the Mac to `viewer` through a new display of `shape`; its device
    /// id, or nil when the Mac won't make the display.
    func start(viewer: String, shape: SharedScreenShape, use: Use) -> String? {
        let serial = lock.withLock { serials += 1; return serials }
        // Read before the display is made: macOS calls a new display main for a moment.
        let main = use == .main ? arrangement.main : nil
        guard let display = displays.create(named: Self.name(viewer), shape: shape, serial: serial) else { return nil }
        var previousMain: UInt32?
        if let main, arrangement.makeMain(display.id) { previousMain = main }
        lock.withLock {
            shares[display.uuid] = Share(viewer: viewer, serial: serial, use: use, display: display,
                                         previousMain: previousMain)
        }
        return display.uuid
    }

    func isSharing(_ id: String) -> Bool {
        lock.withLock { shares[id] != nil }
    }

    /// The viewer turned, or resized: the display made again in the new
    /// shape, the same device, main again if it was.
    func reshape(_ id: String, to shape: SharedScreenShape) -> Bool {
        guard var share = lock.withLock({ shares[id] }) else { return false }
        // macOS removes the main display slowly — it chooses another and moves
        // everything first — so main goes back before the old display does.
        if let previousMain = share.previousMain { _ = arrangement.makeMain(previousMain) }
        share.display.remove()
        guard let display = displays.create(named: Self.name(share.viewer), shape: shape, serial: share.serial) else {
            end(id)
            return false
        }
        if share.use == .main { _ = arrangement.makeMain(display.id) }
        share.display = display
        lock.withLock { shares[id] = share }
        return true
    }

    private static func name(_ viewer: String) -> String { "baguette – \(viewer)" }

    /// The viewer left: the main display given back, the display removed.
    func end(_ id: String) {
        guard let share = lock.withLock({ shares.removeValue(forKey: id) }) else { return }
        if let previousMain = share.previousMain { _ = arrangement.makeMain(previousMain) }
        share.display.remove()
    }
}
