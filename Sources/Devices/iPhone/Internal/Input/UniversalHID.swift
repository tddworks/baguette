import Foundation
import Mockable

/// CoreDevice's Universal HID capability: HID services on a phone, fed
/// reports. Decides nothing — when to open it, and when to try again, is
/// `CoreDeviceDigitizer`'s. The real one is `CoreDeviceUniversalHID`.
@Mockable
protocol UniversalHID: Sendable {
    /// Whether this Xcode's UniversalHID still has the shape a touch
    /// report needs.
    var buildsTouchReports: Bool { get }

    /// The capability opened on `phone` (CoreDevice's identifier, not the
    /// UDID); nil when CoreDevice doesn't list it. Blocks until CoreDevice
    /// answers.
    func open(on phone: UUID) throws -> OpenedCapability?

    /// Hand `report` to the phone's HID service `service`; true when
    /// CoreDevice took it.
    func send(_ report: DigitizerReport, to service: UInt32, through capability: OpenedCapability) -> Bool
}
