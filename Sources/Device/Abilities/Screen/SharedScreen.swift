import Foundation
import IOSurface

/// One live screen, watched by many. A device whose screen streams to a single
/// receiver — a phone on a cable sends its picture to one, and a second ask
/// takes it over, and that one's goodbye ends it for all — is watched through
/// this: the first viewer starts the device's screen, every viewer is shown
/// each picture (one who joins late, the newest at once), and the last to
/// leave stops it. A start that fails throws to that viewer and leaves nothing
/// running, so the next viewer tries again.
public final class SharedScreen: @unchecked Sendable {
    /// Makes the device's screen; each start makes a fresh one.
    let make: @Sendable () -> any Screen
    private let lock = NSLock()
    private var live: (any Screen)?
    private var viewers: [UUID: @Sendable (IOSurface) -> Void] = [:]
    private var newest: IOSurface?

    /// `make`: the device's screen, made fresh each time it starts.
    public init(make: @escaping @Sendable () -> any Screen) {
        self.make = make
    }

    /// One viewer's screen: started and stopped as any other.
    public func view() -> any Screen {
        SharedScreenView(shared: self)
    }

    fileprivate func join(_ id: UUID, onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if live == nil {
            let screen = make()
            // Started under the lock, so a second viewer waits for the first's
            // start rather than starting the device's screen again.
            try screen.start { [weak self] surface in self?.show(surface) }
            live = screen
            newest = nil
        }
        viewers[id] = onFrame
        if let newest { onFrame(newest) }
    }

    fileprivate func leave(_ id: UUID) {
        let ended: (any Screen)? = lock.withLock {
            guard viewers.removeValue(forKey: id) != nil, viewers.isEmpty else { return nil }
            defer { live = nil; newest = nil }
            return live
        }
        ended?.stop()
    }

    private func show(_ surface: IOSurface) {
        let watching = lock.withLock {
            newest = surface
            return Array(viewers.values)
        }
        for onFrame in watching { onFrame(surface) }
    }
}

/// One viewer of a `SharedScreen`.
final class SharedScreenView: Screen, @unchecked Sendable {
    /// The screen it watches with every other viewer.
    let shared: SharedScreen
    private let id = UUID()

    init(shared: SharedScreen) {
        self.shared = shared
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        try shared.join(id, onFrame: onFrame)
    }

    func stop() {
        shared.leave(id)
    }
}

/// Each device's one `SharedScreen`, for a family that makes its devices
/// afresh on every lookup: it outlives them, so every viewer of a device —
/// whichever lookup it came through — watches the same live screen.
public final class SharedScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [DeviceID: SharedScreen] = [:]

    public init() {}

    /// A viewer's screen of device `id`; `make` makes the device's screen when it starts.
    public func view(of id: DeviceID, make: @escaping @Sendable () -> any Screen) -> any Screen {
        lock.withLock {
            if let shared = screens[id] { return shared }
            let shared = SharedScreen(make: make)
            screens[id] = shared
            return shared
        }.view()
    }
}
