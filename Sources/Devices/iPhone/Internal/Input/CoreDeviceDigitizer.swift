import BaguetteDevice
import Foundation

/// A physical phone's touchscreen, fed through CoreDevice's Universal HID
/// capability — the path Device Hub's live view uses. The gestures
/// themselves are `DigitizerTouch`'s; this opens the touch service when
/// first needed and keeps it.
final class CoreDeviceDigitizer: Digitizer, @unchecked Sendable {
    /// The Universal HID service a phone registers for its main touchscreen
    /// (display id 1). Measured on an iPhone 18 Pro Max, iOS 27.0.1: a
    /// registration, never arithmetic — see the HID-target law.
    static let mainTouchscreen: UInt32 = 0x101

    private let identifier: UUID
    private let hid: any UniversalHID
    private let tunnel: any Tunnel
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var capability: OpenedCapability?
    /// When opening the touch service last failed: a swipe's many reports
    /// mustn't each wait out CoreDevice again (up to seconds apiece).
    private var failedAt: Date?
    private static let retryAfter: TimeInterval = 10

    /// - Parameter identifier: CoreDevice's identifier for the phone (not its UDID).
    init(identifier: UUID, hid: any UniversalHID,
         tunnel: any Tunnel,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.identifier = identifier
        self.hid = hid
        self.tunnel = tunnel
        self.now = now
    }

    func report(_ contacts: [Contact], touching: Bool, edge: DeviceEdge?) -> Bool {
        guard (1...2).contains(contacts.count), let capability = touchService() else { return false }
        let report = DigitizerReport(contacts: contacts, touching: touching, edge: edge)
        return hid.send(report, to: Self.mainTouchscreen, through: capability)
    }

    /// The phone's Universal HID capability, opened on first use.
    private func touchService() -> OpenedCapability? {
        lock.withLock {
            if let capability { return capability }
            if let failedAt, now().timeIntervalSince(failedAt) < Self.retryAfter { return nil }
            guard hid.buildsTouchReports else {
                log("[coredevice] this Xcode's UniversalHID can't build a touch report")
                return nil
            }
            do {
                try tunnel.open(to: identifier)
                capability = try hid.open(on: identifier)
                if capability == nil { log("[coredevice] CoreDevice does not list \(identifier)") }
            } catch {
                log("[coredevice] could not open the touch service: \(error)")
            }
            failedAt = capability == nil ? now() : nil
            return capability
        }
    }
}
