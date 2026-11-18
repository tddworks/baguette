import Foundation

#if COREDEVICE

/// A UniversalHID `DigitizerReport`: the fingers on the glass in one HID
/// report. UniversalHID's own initializers and setters encode it, so this
/// never lays out report bytes; Swift binds them with `@_silgen_name`.
///
/// `DigitizerReport` and `DigitizerContact` each wrap exactly one
/// `Foundation.Data`, so a stand-in holding a `Data` has their layout and
/// Swift retains and releases them correctly. `isAvailable` checks that
/// size before anything relies on it.
struct DigitizerReport {
    fileprivate var storage: HIDData

    /// Whether UniversalHID still has the shape this file assumes.
    static var isAvailable: Bool {
        guard let report = CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVN"),
              let contact = CoreDeviceFramework.symbol("$s12UniversalHID16DigitizerContactVN"),
              CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVAA05EventD18DescriptorProtocolAAWP") != nil,
              CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVAA05EventD8ProtocolAAWP") != nil
        else { return false }
        return CoreDeviceFramework.valueSize(report) == MemoryLayout<HIDData>.size
            && CoreDeviceFramework.valueSize(contact) == MemoryLayout<HIDData>.size
    }

    /// `fingers` (1 or 2) touching, or lifting, at fractions of the screen;
    /// `swipeEdge` 1 left, 2 top, 3 bottom, 4 right marks a swipe in from it.
    init(fingers: [Contact], touching: Bool, swipeEdge: Int) {
        let words = newDigitizerReport(
            CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVN")!,
            CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVAA05EventD18DescriptorProtocolAAWP")!,
            CoreDeviceFramework.symbol("$s12UniversalHID15DigitizerReportVAA05EventD8ProtocolAAWP")!)
        // The initializer handed us a +1 report in the first two words.
        storage = unsafeBitCast((words.0, words.1), to: HIDData.self)
        storage.setContactCount(UInt8(fingers.count))
        for (index, finger) in fingers.enumerated() {
            var contact = newDigitizerContact()
            contact.setIndex(index + 1)
            contact.setX(finger.x)
            contact.setY(finger.y)
            contact.setTouching(touching)
            contact.setInRange(touching)
            storage.setContact(contact, at: index)
            storage.setContactIdentity(UInt8(index + 1), at: index)
            if swipeEdge != 0 {
                // An edge swipe is the inward direction plus "locked", on
                // every report including the lift, so SpringBoard finishes it.
                storage.setSwipeLocked(true, at: index)
                switch swipeEdge {
                case 1: storage.setSwipeRight(true, at: index)
                case 2: storage.setSwipeDown(true, at: index)
                case 3: storage.setSwipeUp(true, at: index)
                default: storage.setSwipeLeft(true, at: index)
                }
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

/// The layout of a UniversalHID report or contact: one `Data`.
struct HIDData {
    var data: Data
}

/// Five words come back indirectly: room for the generic initializer to
/// write the two-word report into.
private typealias IndirectReport = (UInt64, UInt64, UInt64, UInt64, UInt64)

/// EventReportProtocol.init() where Self: EventReportDescriptorProtocol —
/// Self's metadata and its two conformances as the trailing arguments.
@_silgen_name("$s12UniversalHID19EventReportProtocolPA2A0cd10DescriptorE0RzrlExycfC")
private func newDigitizerReport(_ type: UnsafeRawPointer, _ descriptor: UnsafeRawPointer,
                                _ report: UnsafeRawPointer) -> IndirectReport
/// DigitizerContact()
@_silgen_name("$s12UniversalHID16DigitizerContactVACycfC")
private func newDigitizerContact() -> HIDData

private extension HIDData {
    // DigitizerContact setters
    @_silgen_name("$s12UniversalHID16DigitizerContactV5indexSivs") mutating func setIndex(_ value: Int)
    @_silgen_name("$s12UniversalHID16DigitizerContactV1xSdvs") mutating func setX(_ value: Double)
    @_silgen_name("$s12UniversalHID16DigitizerContactV1ySdvs") mutating func setY(_ value: Double)
    @_silgen_name("$s12UniversalHID16DigitizerContactV5touchSbvs") mutating func setTouching(_ value: Bool)
    @_silgen_name("$s12UniversalHID16DigitizerContactV5rangeSbvs") mutating func setInRange(_ value: Bool)
    // DigitizerReport setters
    @_silgen_name("$s12UniversalHID15DigitizerReportV12contactCounts5UInt8Vvs")
    mutating func setContactCount(_ value: UInt8)
    @_silgen_name("$s12UniversalHID15DigitizerReportV10setContact_7atIndexyAA0cF0V_SitF")
    mutating func setContact(_ contact: HIDData, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV18setContactIdentity_7atIndexys5UInt8V_SitF")
    mutating func setContactIdentity(_ identity: UInt8, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV15remoteTimestamps6UInt64VSgvs")
    mutating func setRemoteTimestamp(_ value: UInt64?)
    @_silgen_name("$s12UniversalHID15DigitizerReportV21setContactSwipeLocked_7atIndexySb_SitF")
    mutating func setSwipeLocked(_ value: Bool, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV20setContactSwipeRight_7atIndexySb_SitF")
    mutating func setSwipeRight(_ value: Bool, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV19setContactSwipeDown_7atIndexySb_SitF")
    mutating func setSwipeDown(_ value: Bool, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV17setContactSwipeUp_7atIndexySb_SitF")
    mutating func setSwipeUp(_ value: Bool, at index: Int)
    @_silgen_name("$s12UniversalHID15DigitizerReportV19setContactSwipeLeft_7atIndexySb_SitF")
    mutating func setSwipeLeft(_ value: Bool, at index: Int)
}

#endif
