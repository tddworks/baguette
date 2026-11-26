import BaguetteDeviceFamilies
import Foundation

/// CoreDevice's symbols, looked up in this process. Weak-linked symbols
/// are null on a Mac without CoreDevice, so nothing is called before
/// `isAvailable` says yes.
extension CoreDeviceFramework {
    /// Whether this Mac has CoreDevice.
    static var isAvailable: Bool {
        #if COREDEVICE
        return symbol("$s10CoreDevice0B7ManagerC6sharedACvgZ") != nil
        #else
        return false
        #endif
    }

    /// The phone CoreDevice knows by `identifier` (its CoreDevice identifier,
    /// not the UDID), or nil when it isn't listed or CoreDevice is absent.
    static func device(_ identifier: UUID) -> RemoteDevice? {
        #if COREDEVICE
        guard isAvailable else { return nil }
        return DeviceManager.shared?.device(identifier)
        #else
        return nil
        #endif
    }

    /// A type by its metadata accessor (`…Ma`), for CoreDevice's resilient types.
    static func type(_ accessor: String) -> Any.Type? {
        typealias Accessor = @convention(thin) (Int) -> (UnsafeRawPointer, Int)
        guard let pointer = symbol(accessor) else { return nil }
        return unsafeBitCast(unsafeBitCast(pointer, to: Accessor.self)(0).0, to: Any.Type.self)
    }

    /// A CoreDevice or UniversalHID symbol (type metadata, a conformance).
    static func symbol(_ mangledName: String) -> UnsafeRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), mangledName).map(UnsafeRawPointer.init)
    }
}
