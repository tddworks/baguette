import CoreDeviceABI
import Foundation

/// Xcode's private device stack (`CoreDevice.framework`), reached in-process
/// for what `devicectl` has no verb for — today, a phone's touchscreen.
/// Integration-only: every call crosses into the framework through
/// `CoreDeviceABI`. The research behind it: docs/features/real-devices/design.md.
enum CoreDeviceFramework {
    /// The phone CoreDevice knows by `identifier` (its CoreDevice identifier,
    /// not the UDID), or nil when it isn't listed or CoreDevice is absent.
    static func device(_ identifier: UUID) -> RemoteDevice? {
        DeviceManager.shared?.devices().first { $0.identifier == identifier }
    }
}

/// A capability CoreDevice can open on a device: the Swift type that
/// implements it and its `DeviceCapability` conformance, by symbol.
struct CapabilityKind: Sendable {
    let typeSymbol: String
    let conformanceSymbol: String

    /// Universal HID: create, find and feed HID services on the device.
    static let universalHID = CapabilityKind(
        typeSymbol: "$s10CoreDevice29UniversalHIDServiceCapabilityVN",
        conformanceSymbol: "$s10CoreDevice29UniversalHIDServiceCapabilityVAA0bE0AAWP")
}

/// A device as CoreDevice lists it.
struct RemoteDevice: @unchecked Sendable {
    fileprivate let object: RemoteDeviceObject

    var identifier: UUID { object.identifier() }

    /// Open `kind` on this device. Blocks until CoreDevice answers.
    func open(_ kind: CapabilityKind) throws -> OpenedCapability {
        guard let type = cdabi_symbol(kind.typeSymbol),
              let conformance = cdabi_symbol(kind.conformanceSymbol)
        else { throw CoreDeviceError.unavailable }
        let capability = OpenedCapability()
        let failure = Failure()
        let done = DispatchSemaphore(value: 0)
        let object = self.object
        Task.detached {
            // CapabilityStaticMember<T> holds nothing, but is resilient: the
            // call takes its address, T's metadata and T's conformance.
            let member = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            defer { member.deallocate() }
            do {
                try await object.capability(capability.existential, member, type, conformance)
                capability.isOpen = true
            } catch {
                failure.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = failure.error { throw error }
        return capability
    }
}

/// What CoreDevice wrote for an opened capability: an existential of its
/// own implementation type, destroyed through that type's metadata.
final class OpenedCapability: @unchecked Sendable {
    let existential = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<any OpaqueCapability>.size,
        alignment: MemoryLayout<any OpaqueCapability>.alignment)
    fileprivate(set) var isOpen = false

    deinit {
        if isOpen {
            existential.assumingMemoryBound(to: (any OpaqueCapability).self).deinitialize(count: 1)
        }
        existential.deallocate()
    }
}

enum CoreDeviceError: Error, CustomStringConvertible {
    case unavailable

    var description: String { "CoreDevice is not available on this Mac" }
}

/// CoreDevice's `DeviceManager`, made once per process with every
/// visibility class allowed, so physical phones are listed beside simulators.
private final class DeviceManager: @unchecked Sendable {
    static let shared: DeviceManager? = DeviceManager()

    private let object: DeviceManagerObject

    private init?() {
        guard cdabi_load(),
              let managerType = cdabi_symbol("$s10CoreDevice0B7ManagerCN"),
              let visibilityType = cdabi_symbol("$s10CoreDevice0B15VisibilityClassON"),
              let visibility = unsafeBitCast(visibilityType, to: Any.Type.self) as? any Hashable.Type
        else { return nil }
        // Touching the shared manager first initializes the class's
        // resilient metadata, which the allocating initializer relies on.
        _ = sharedManagerObject()
        let allowed = Self.everyVisibilityClass(visibility)
        object = withExtendedLifetime(allowed) {
            let storage = withUnsafePointer(to: allowed) {
                UnsafeRawPointer($0).load(as: UnsafeMutableRawPointer.self)
            }
            // The initializer takes ownership of the Set it is given.
            cdabi_retain_bridge_object(storage)
            return unsafeBitCast(managerType, to: DeviceManagerObject.Type.self)
                .make(connection: serviceConnection(), allowed: storage)
        }
    }

    /// The devices CoreDevice lists, once it has filled the list (it does so
    /// shortly after the manager is made).
    func devices() -> [RemoteDevice] {
        for _ in 0..<50 where !object.isReady() { usleep(100_000) }
        return object.devices().map(RemoteDevice.init(object:))
    }

    /// Apple's own cases, from its `allCases`, as the Set the initializer takes.
    private static func everyVisibilityClass<T: Hashable>(_: T.Type) -> Any {
        Set(unsafeBitCast(visibilityClasses(), to: [T].self))
    }
}

// Stand-ins that give Swift the calling convention for CoreDevice's own
// objects. Every instance and metadata comes from CoreDevice; none is made here.
protocol OpaqueCapability {}
private protocol ServiceConnection {}

@_silgen_name("cdabi_manager_shared")
private func sharedManagerObject() -> DeviceManagerObject
@_silgen_name("cdabi_service_connection")
private func serviceConnection() -> any ServiceConnection
@_silgen_name("cdabi_visibility_classes")
private func visibilityClasses() -> UnsafeRawPointer

private class DeviceManagerObject {
    @_silgen_name("cdabi_manager_init")
    static func make(connection: __owned any ServiceConnection, allowed: UnsafeRawPointer) -> DeviceManagerObject
    @_silgen_name("cdabi_manager_devices")
    final func devices() -> [RemoteDeviceObject]
    @_silgen_name("cdabi_manager_ready")
    final func isReady() -> Bool
}

private class RemoteDeviceObject {
    @_silgen_name("cdabi_device_identifier")
    final func identifier() -> UUID
    @_silgen_name("cdabi_device_capability")
    final func capability(_ result: UnsafeMutableRawPointer, _ member: UnsafeRawPointer,
                          _ type: UnsafeRawPointer, _ conformance: UnsafeRawPointer) async throws
}

private final class Failure: @unchecked Sendable {
    var error: (any Error)?
}
