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
    /// When opening the touch service last failed: a swipe's many reports
    /// mustn't each wait out CoreDevice again (up to seconds apiece).
    private var failedAt: Date?
    private static let retryAfter: TimeInterval = 10

    /// - Parameter identifier: CoreDevice's identifier for the phone (not its UDID).
    init(identifier: UUID) {
        self.identifier = identifier
    }

    func report(_ contacts: [Contact], touching: Bool, edge: DeviceEdge?) -> Bool {
        #if COREDEVICE
        guard (1...2).contains(contacts.count), let hid = universalHID() else { return false }
        let report = DigitizerReport(fingers: contacts, touching: touching, swipeEdge: edge.swipeEdge)
        return report.withWords { lo, hi in
            cdabi_send_report(lo, hi, Self.mainTouchscreen, hid.existential)
        }
        #else
        return false
        #endif
    }

    #if COREDEVICE
    /// The phone's Universal HID capability, opened on first use.
    private func universalHID() -> OpenedCapability? {
        lock.withLock {
            if let hid { return hid }
            if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { return nil }
            guard DigitizerReport.isAvailable else {
                log("[coredevice] this Xcode's UniversalHID can't build a touch report")
                return nil
            }
            guard let device = CoreDeviceFramework.device(identifier) else {
                log("[coredevice] CoreDevice does not list \(identifier)")
                failedAt = Date()
                return nil
            }
            do {
                hid = try device.open(.universalHID)
            } catch {
                log("[coredevice] could not open the touch service: \(error)")
            }
            failedAt = hid == nil ? Date() : nil
            return hid
        }
    }
    #endif
}

private extension Optional where Wrapped == DeviceEdge {
    /// Universal HID's swipe-in edges: 0 none, 1 left, 2 top, 3 bottom, 4 right.
    var swipeEdge: Int {
        switch self {
        case .none:    return 0
        case .left?:   return 1
        case .top?:    return 2
        case .bottom?: return 3
        case .right?:  return 4
        }
    }
}
