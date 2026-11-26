import BaguetteDevice
import Foundation

/// This Mac shared to its viewers, each through a display of the viewer's
/// shape, by the display's UUID — its device id. A share makes the display;
/// as the main display when the viewer asks, the previous main given back when
/// the share ends; made again in the new shape as the viewer turns (a made
/// display takes no other shape), under the same serial so its id holds;
/// removed when it ends.
/// Design: docs/features/mac-screen/design.md#sharing-to-a-viewers-shape.
public final class VirtualDisplayShares: ScreenShares, @unchecked Sendable {
    private struct Share {
        let viewer: String
        let serial: UInt32
        let use: ShareUse
        var shape: SharedScreenShape
        var display: any VirtualDisplay
        /// The main display before this share took it, to give back.
        var previousMain: UInt32?
    }

    private let displays: any VirtualDisplays
    private let arrangement: any DisplayArrangement
    private let lock = NSLock()
    /// Starting, turning and ending, one at a time: a viewer leaving mid-turn
    /// waits for the turn, then ends the share it made.
    private let work = NSRecursiveLock()
    private var shares: [String: Share] = [:]
    private var serials: UInt32 = 0

    public init(displays: any VirtualDisplays, arrangement: any DisplayArrangement) {
        self.displays = displays
        self.arrangement = arrangement
    }

    /// Share the Mac to `viewer` through a new display of `shape`; its device
    /// id, or nil when the Mac won't make the display.
    public func start(viewer: String, shape: SharedScreenShape, use: ShareUse) -> String? {
        work.lock(); defer { work.unlock() }
        let serial = lock.withLock { serials += 1; return serials }
        // Read before the display is made: macOS calls a new display main for a moment.
        let main = use == .main ? arrangement.main : nil
        guard let display = displays.create(named: Self.name(viewer), shape: shape, serial: serial) else { return nil }
        var previousMain: UInt32?
        if let main, arrangement.makeMain(display.id, freeingDock: true) { previousMain = main }
        lock.withLock {
            shares[display.uuid] = Share(viewer: viewer, serial: serial, use: use, shape: shape, display: display,
                                         previousMain: previousMain)
        }
        return display.uuid
    }

    /// The pixels the share's display was made with; nil when no share has the id.
    public func pixels(of id: String) -> Size? {
        lock.withLock { shares[id]?.shape.pixels }
    }

    public func isSharing(_ id: String) -> Bool {
        lock.withLock { shares[id] != nil }
    }

    /// The viewer turned, or resized: the display made again in the new
    /// shape, the same device, main again if it was.
    public func reshape(_ id: String, to shape: SharedScreenShape) -> Bool {
        work.lock(); defer { work.unlock() }
        guard var share = lock.withLock({ shares[id] }) else { return false }
        // macOS removes the main display slowly — it chooses another and moves
        // everything first — so main goes back before the old display does.
        let wasMain = arrangement.main == share.display.id
        if wasMain, let previousMain = share.previousMain { _ = arrangement.makeMain(previousMain, freeingDock: false) }
        let old = share.display.id
        share.display.remove()
        guard let display = displays.create(named: Self.name(share.viewer), shape: shape, serial: share.serial) else {
            // Not made again: the share ends — its display is already gone, and main already given back.
            lock.withLock {
                shares[id] = nil
                handBack(from: old, to: share.previousMain)
            }
            return false
        }
        if wasMain { _ = arrangement.makeMain(display.id, freeingDock: true) }
        share.display = display
        share.shape = shape
        lock.withLock {
            shares[id] = share
            handBack(from: old, to: display.id)
        }
        return true
    }

    private static func name(_ viewer: String) -> String { "baguette – \(viewer)" }

    /// The viewer left: the main display given back — when this share's
    /// display still is main — and the display removed.
    public func end(_ id: String) {
        work.lock(); defer { work.unlock() }
        guard let share = lock.withLock({ shares.removeValue(forKey: id) }) else { return }
        if arrangement.main == share.display.id, let previousMain = share.previousMain {
            _ = arrangement.makeMain(previousMain, freeingDock: false)
        }
        lock.withLock { handBack(from: share.display.id, to: share.previousMain) }
        share.display.remove()
    }

    /// A share that would give main back to display `old` gives it to `new`
    /// instead — `old` is gone. Under `lock`.
    private func handBack(from old: UInt32, to new: UInt32?) {
        for (id, other) in shares where other.previousMain == old {
            shares[id]?.previousMain = new
        }
    }
}
