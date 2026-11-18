import CoreDeviceABI
import Foundation

/// A physical phone's touchscreen, fed through CoreDevice's Universal HID
/// capability — the path Device Hub's live view uses. Integration-only: the
/// gestures themselves are `DigitizerInput`'s.
final class CoreDeviceDigitizer: Digitizer, @unchecked Sendable {
    /// The Universal HID service a phone registers for its main touchscreen
    /// (display id 1). Measured on an iPhone 18 Pro Max, iOS 27.0.1: a
    /// registration, never arithmetic — see the HID-target law.
    static let mainTouchscreen: UInt32 = 0x101

    private let identifier: UUID
    private let lock = NSLock()
    private var hid: OpenedCapability?

    /// - Parameter identifier: CoreDevice's identifier for the phone (not its UDID).
    init(identifier: UUID) {
        self.identifier = identifier
    }

    func report(_ contacts: [Contact], touching: Bool, edge: DeviceEdge?) -> Bool {
        guard (1...2).contains(contacts.count), let hid = universalHID() else { return false }
        let fingers = contacts.map { cdabi_finger(x: $0.x, y: $0.y) }
        return fingers.withUnsafeBufferPointer {
            cdabi_send_digitizer_report(
                hid.existential, Self.mainTouchscreen, $0.baseAddress,
                UInt8($0.count), touching, edge.swipeEdge)
        }
    }

    /// The phone's Universal HID capability, opened on first use.
    private func universalHID() -> OpenedCapability? {
        lock.withLock {
            if let hid { return hid }
            guard cdabi_digitizer_ready() else {
                log("[coredevice] this Xcode's UniversalHID can't build a touch report")
                return nil
            }
            guard let device = CoreDeviceFramework.device(identifier) else {
                log("[coredevice] CoreDevice does not list \(identifier)")
                return nil
            }
            do {
                hid = try device.open(.universalHID)
            } catch {
                log("[coredevice] could not open the touch service: \(error)")
            }
            return hid
        }
    }
}

private extension Optional where Wrapped == DeviceEdge {
    /// Universal HID's swipe-in edges: 0 none, 1 left, 2 top, 3 bottom, 4 right.
    var swipeEdge: UInt8 {
        switch self {
        case .none:    return 0
        case .left?:   return 1
        case .top?:    return 2
        case .bottom?: return 3
        case .right?:  return 4
        }
    }
}
