import CoreDeviceABI
import Foundation

/// `UniversalHID` through CoreDevice: the capability opened by its
/// symbols, a report laid out by UniversalHID's own setters and sent
/// through the C shim. Integration-only; deciding when is
/// `CoreDeviceDigitizer`'s.
struct CoreDeviceUniversalHID: UniversalHID {
    #if COREDEVICE
    var buildsTouchReports: Bool { UniversalHIDReport.isAvailable }

    func open(on phone: UUID) throws -> OpenedCapability? {
        try CoreDeviceFramework.device(phone)?.open(.universalHID)
    }

    func send(_ report: DigitizerReport, to service: UInt32, through capability: OpenedCapability) -> Bool {
        UniversalHIDReport(report).withWords { lo, hi in
            cdabi_send_report(lo, hi, service, capability.existential)
        }
    }
    #else
    var buildsTouchReports: Bool { false }
    func open(on phone: UUID) throws -> OpenedCapability? { nil }
    func send(_ report: DigitizerReport, to service: UInt32, through capability: OpenedCapability) -> Bool { false }
    #endif
}
