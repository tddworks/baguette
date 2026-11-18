import BaguetteDevice
import Foundation
import IOSurface
import ObjectiveC

/// Enumerates live `com.apple.framebuffer.display` ports on a
/// SimulatorKit device — size from the current IOSurface when present,
/// otherwise the port's default width/height. Never calls
/// `updateIOPorts` when framebuffer display ports already exist.
enum SimulatorKitFramebuffers {
    /// SimulatorKit materialises a device's IO ports lazily, reading
    /// their descriptors through file handles it closes as it goes; two
    /// threads enumerating at once have raised
    /// `-[NSConcreteFileHandle readDataOfLength:]: Bad file descriptor`
    /// out of it, an ObjC exception no Swift frame can catch. One
    /// enumeration at a time.
    private static let enumerationLock = NSLock()

    static func sizedFramebuffers(udid: String, host: any DeviceHost) throws -> [SizedFramebuffer] {
        enumerationLock.lock()
        defer { enumerationLock.unlock() }
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        guard let io = device.perform(NSSelectorFromString("io"))?
            .takeUnretainedValue() as? NSObject
        else {
            throw ScreenError.ioUnavailable
        }

        var ports = framebuffers(on: io)
        if FramebufferRefresh.shouldUpdate(hasFramebuffers: !ports.isEmpty) {
            io.perform(NSSelectorFromString("updateIOPorts"))
            ports = framebuffers(on: io)
        }
        guard !ports.isEmpty else {
            throw ScreenError.noFramebuffer
        }

        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")
        var result: [SizedFramebuffer] = []

        for port in ports {
            guard port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject
            else { continue }

            let size: Size
            if desc.responds(to: surfSel),
               let surfObj = desc.perform(surfSel)?.takeUnretainedValue() {
                let surf = unsafeBitCast(surfObj, to: IOSurface.self)
                let w = IOSurfaceGetWidth(surf)
                let h = IOSurfaceGetHeight(surf)
                if w > 0, h > 0 {
                    size = Size(width: Double(w), height: Double(h))
                } else if let defaults = FramebufferDefaultSize.read(from: port) {
                    size = defaults
                } else {
                    continue
                }
            } else if let defaults = FramebufferDefaultSize.read(from: port) {
                size = defaults
            } else {
                continue
            }

            result.append(SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: size
            ))
        }
        return result
    }

    private static func framebuffers(on io: NSObject) -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            return []
        }
        let pidSel = NSSelectorFromString("portIdentifier")
        return ports.filter { port in
            guard port.responds(to: pidSel),
                  let pid = port.perform(pidSel)?.takeUnretainedValue()
            else { return false }
            return "\(pid)" == "com.apple.framebuffer.display"
        }
    }
}
