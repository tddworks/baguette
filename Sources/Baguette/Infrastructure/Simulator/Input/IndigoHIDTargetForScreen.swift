import Foundation

/// Infra wrapper around SimulatorKit's `IndigoHIDTargetForScreen`.
enum IndigoHIDTargetForScreen {
    private typealias Fn = @convention(c) (UInt32) -> UInt32
    private static let lock = NSLock()
    // Locked above; Swift concurrency cannot prove NSLock protection.
    nonisolated(unsafe) private static var cached: Fn?

    /// Returns the digitizer target for a live connected screen id, or
    /// `nil` when SimulatorKit / the symbol cannot be loaded.
    static func target(for connectedScreenId: UInt32) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        if cached == nil {
            cached = load()
        }
        guard let fn = cached else { return nil }
        return fn(connectedScreenId)
    }

    private static func load() -> Fn? {
        let dev = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        guard let path = SimulatorKitFramework.path(developerDir: dev) else {
            return nil
        }
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, "IndigoHIDTargetForScreen") else {
            return nil
        }
        return unsafeBitCast(sym, to: Fn.self)
    }
}
