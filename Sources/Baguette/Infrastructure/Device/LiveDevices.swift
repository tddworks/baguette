import Foundation

/// The in-memory `Devices` implementation. Membership is driven by
/// companion sockets: a valid hello registers the device, the socket
/// closing unregisters it. Registration order is preserved so the UI
/// lists devices stably; a re-registered udid keeps its slot but takes
/// the fresh identity (the phone may have been renamed between
/// connects).
final class LiveDevices: Devices, @unchecked Sendable {
    private let lock = NSLock()
    private var ordered: [Device] = []

    var all: [Device] {
        lock.lock()
        defer { lock.unlock() }
        return ordered
    }

    func register(hello: TwinHello) {
        let device = Device(hello: hello)
        lock.lock()
        if let index = ordered.firstIndex(where: { $0.udid == device.udid }) {
            ordered[index] = device
        } else {
            ordered.append(device)
        }
        lock.unlock()
        log("[device] companion connected: \(device.name) (\(device.udid))")
    }

    func unregister(udid: String) {
        lock.lock()
        ordered.removeAll { $0.udid == udid }
        lock.unlock()
        log("[device] companion disconnected: \(udid)")
    }
}
