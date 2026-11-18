import Foundation

#if COREDEVICE

/// The layout of a UniversalHID report or contact: one `Data`.
struct HIDData {
    var data: Data
}

/// Five words come back indirectly: room for the generic initializer to
/// write the two-word report into.
typealias IndirectReport = (UInt64, UInt64, UInt64, UInt64, UInt64)

/// EventReportProtocol.init() where Self: EventReportDescriptorProtocol —
/// Self's metadata and its two conformances as the trailing arguments.
@_silgen_name("$s12UniversalHID19EventReportProtocolPA2A0cd10DescriptorE0RzrlExycfC")
func newDigitizerReport(_ type: UnsafeRawPointer, _ descriptor: UnsafeRawPointer,
                        _ report: UnsafeRawPointer) -> IndirectReport
/// DigitizerContact()
@_silgen_name("$s12UniversalHID16DigitizerContactVACycfC")
func newDigitizerContact() -> HIDData

extension HIDData {
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
