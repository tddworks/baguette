import BaguetteDeviceFamilies
import Foundation

#if COREDEVICE

/// A `DigitizerReport` laid out by UniversalHID's own initializers and
/// setters, field by field, so this never lays out report bytes; Swift
/// binds them with `@_silgen_name` (`UniversalHIDSetters.swift`).
///
/// `DigitizerReport` and `DigitizerContact` each wrap exactly one
/// `Foundation.Data`, so a stand-in holding a `Data` has their layout and
/// Swift retains and releases them correctly. `isAvailable` checks that
/// size before anything relies on it.
struct UniversalHIDReport {
    private static let type = "$s12UniversalHID15DigitizerReportVN"
    private static let descriptor = "$s12UniversalHID15DigitizerReportVAA05EventD18DescriptorProtocolAAWP"
    private static let event = "$s12UniversalHID15DigitizerReportVAA05EventD8ProtocolAAWP"
    private var storage: HIDData

    /// Whether UniversalHID still has the shape this file assumes.
    static var isAvailable: Bool {
        guard let report = CoreDeviceFramework.symbol(type),
              let contact = CoreDeviceFramework.symbol("$s12UniversalHID16DigitizerContactVN"),
              CoreDeviceFramework.symbol(descriptor) != nil, CoreDeviceFramework.symbol(event) != nil
        else { return false }
        return CoreDeviceFramework.valueSize(report) == MemoryLayout<HIDData>.size
            && CoreDeviceFramework.valueSize(contact) == MemoryLayout<HIDData>.size
    }

    init(_ report: DigitizerReport) {
        let words = newDigitizerReport(CoreDeviceFramework.symbol(Self.type)!,
                                       CoreDeviceFramework.symbol(Self.descriptor)!, CoreDeviceFramework.symbol(Self.event)!)
        // The initializer handed us a +1 report in the first two words.
        storage = unsafeBitCast((words.0, words.1), to: HIDData.self)
        storage.setContactCount(UInt8(report.fingers.count))
        for (slot, finger) in report.fingers.enumerated() {
            var contact = newDigitizerContact()
            contact.setIndex(finger.index)
            contact.setX(finger.x)
            contact.setY(finger.y)
            contact.setTouching(finger.touching)
            contact.setInRange(finger.touching)
            storage.setContact(contact, at: slot)
            storage.setContactIdentity(UInt8(finger.index), at: slot)
            guard let swipe = finger.swipe else { continue }
            storage.setSwipeLocked(true, at: slot)
            switch swipe {
            case .right: storage.setSwipeRight(true, at: slot)
            case .down: storage.setSwipeDown(true, at: slot)
            case .up: storage.setSwipeUp(true, at: slot)
            case .left: storage.setSwipeLeft(true, at: slot)
            }
        }
        storage.setRemoteTimestamp(mach_absolute_time())
    }

    /// The report's two words, borrowed for the send.
    func withWords<R>(_ body: (UInt64, UInt64) -> R) -> R {
        withUnsafeBytes(of: storage) {
            body($0.load(fromByteOffset: 0, as: UInt64.self), $0.load(fromByteOffset: 8, as: UInt64.self))
        }
    }
}

#endif
