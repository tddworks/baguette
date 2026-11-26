import BaguetteDevice
import Foundation

/// Xcode's private device stack (`CoreDevice.framework`), reached in-process
/// for what `devicectl` has no verb for — a phone's touchscreen and its live
/// screen. Weak-linked (see Package.swift): Swift binds CoreDevice's own
/// symbols with `@_silgen_name`, in `Internal/System/` (`CoreDeviceSymbols`,
/// `CoreDeviceManager`, `RemoteDevice`). What is decided about them — how
/// long to wait, what an answer means — is here and tested. The research is
/// docs/features/real-devices/design.md.
package enum CoreDeviceFramework {
    /// A value's size, from its type's value-witness table (one word before
    /// the metadata; the size is its ninth entry).
    package static func valueSize(_ metadata: UnsafeRawPointer) -> Int {
        let witnesses = metadata.load(fromByteOffset: -8, as: UnsafeRawPointer.self)
        return witnesses.load(fromByteOffset: 8 * 8, as: Int.self)
    }
}

/// A capability CoreDevice can open on a device: the Swift type that
/// implements it and its `DeviceCapability` conformance, by symbol.
package struct CapabilityKind: Sendable {
    package let typeSymbol: String
    package let conformanceSymbol: String

    /// Universal HID: create, find and feed HID services on the device.
    package static let universalHID = CapabilityKind(
        typeSymbol: "$s10CoreDevice29UniversalHIDServiceCapabilityVN",
        conformanceSymbol: "$s10CoreDevice29UniversalHIDServiceCapabilityVAA0bE0AAWP")
}

/// What CoreDevice wrote for an opened capability: an existential of its
/// own implementation type, destroyed through that type's metadata.
package final class OpenedCapability: @unchecked Sendable {
    package let existential = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<any OpaqueCapability>.size,
        alignment: MemoryLayout<any OpaqueCapability>.alignment)
    /// Set once CoreDevice has written the existential.
    package var isOpen = false

    package init() {}

    deinit {
        if isOpen {
            existential.assumingMemoryBound(to: (any OpaqueCapability).self).deinitialize(count: 1)
        }
        existential.deallocate()
    }
}

package enum CoreDeviceError: Error, CustomStringConvertible {
    case unavailable
    /// CoreDevice didn't answer in time: a phone asleep, or a stalled tunnel.
    case noAnswer(String)

    package var description: String {
        switch self {
        case .unavailable: "CoreDevice is not available on this Mac"
        case let .noAnswer(what): "CoreDevice didn't answer \(what) in time"
        }
    }
}

/// Stands for any CoreDevice capability: gives Swift an existential's layout.
protocol OpaqueCapability {}
