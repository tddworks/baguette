import Foundation

/// The in-memory `Devices` implementation. Membership is driven by
/// companion sockets: a valid hello registers the device, the socket
/// closing unregisters it. Registration order is preserved so the UI
/// lists devices stably; a re-registered udid keeps its slot but takes
/// the fresh identity (the phone may have been renamed between
/// connects).
final class LiveDevices: Devices, @unchecked Sendable {
    private let lock = NSLock()
    // Registration is COUNTED: the video and motion sockets each
    // register the same udid, and the device stays listed until the
    // last one closes.
    private var ordered: [(device: Device, connections: Int)] = []

    var all: [Device] {
        lock.lock()
        defer { lock.unlock() }
        return ordered.map(\.device)
    }

    func register(hello: TwinHello) {
        let device = Device(hello: hello)
        lock.lock()
        if let index = ordered.firstIndex(where: { $0.device.udid == device.udid }) {
            ordered[index] = (device, ordered[index].connections + 1)
        } else {
            ordered.append((device, 1))
        }
        lock.unlock()
        log("[device] companion connected: \(device.name) (\(device.udid))")
    }

    func unregister(udid: String) {
        lock.lock()
        if let index = ordered.firstIndex(where: { $0.device.udid == udid }) {
            let remaining = ordered[index].connections - 1
            if remaining <= 0 {
                ordered.remove(at: index)
            } else {
                ordered[index].connections = remaining
            }
        }
        lock.unlock()
        log("[device] companion disconnected: \(udid)")
    }
}
