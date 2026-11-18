import Foundation

/// Xcode's private device stack (`CoreDevice.framework`), reached in-process
/// for what `devicectl` has no verb for — today, a phone's touchscreen.
/// Weak-linked (see Package.swift): Swift binds CoreDevice's own symbols with
/// `@_silgen_name` on the stand-ins below. Integration-only; the research
/// is docs/features/real-devices/design.md.
enum CoreDeviceFramework {
    /// Whether this Mac has CoreDevice. Weak-linked symbols are null on a
    /// Mac without it, so nothing here is called before this says yes.
    static var isAvailable: Bool {
        #if COREDEVICE
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s10CoreDevice0B7ManagerC6sharedACvgZ") != nil
        #else
        return false
        #endif
    }

    /// The phone CoreDevice knows by `identifier` (its CoreDevice identifier,
    /// not the UDID), or nil when it isn't listed or CoreDevice is absent.
    static func device(_ identifier: UUID) -> RemoteDevice? {
        #if COREDEVICE
        guard isAvailable else { return nil }
        return DeviceManager.shared?.devices().first { $0.identifier == identifier }
        #else
        return nil
        #endif
    }

    /// A CoreDevice or UniversalHID symbol (type metadata, a conformance).
    static func symbol(_ mangledName: String) -> UnsafeRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), mangledName).map(UnsafeRawPointer.init)
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

/// Stands for any CoreDevice capability: gives Swift an existential's layout.
protocol OpaqueCapability {}

#if COREDEVICE

/// A device as CoreDevice lists it.
struct RemoteDevice: @unchecked Sendable {
    fileprivate let object: RemoteDeviceObject

    var identifier: UUID { object.identifier() }

    /// Open `kind` on this device. Blocks until CoreDevice answers.
    func open(_ kind: CapabilityKind) throws -> OpenedCapability {
        guard let type = CoreDeviceFramework.symbol(kind.typeSymbol),
              let conformance = CoreDeviceFramework.symbol(kind.conformanceSymbol)
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
                try await object.implementation(capability.existential, member, type, conformance)
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

/// CoreDevice's `DeviceManager`, made once per process with every
/// visibility class allowed, so physical phones are listed beside simulators.
private final class DeviceManager: @unchecked Sendable {
    static let shared: DeviceManager? = DeviceManager()

    private let object: DeviceManagerObject

    private init?() {
        guard let managerType = CoreDeviceFramework.symbol("$s10CoreDevice0B7ManagerCN"),
              let visibilityType = CoreDeviceFramework.symbol("$s10CoreDevice0B15VisibilityClassON"),
              let visibility = unsafeBitCast(visibilityType, to: Any.Type.self) as? any Hashable.Type
        else { return nil }
        // Touching the shared manager first initializes the class's
        // resilient metadata, which the allocating initializer relies on.
        _ = sharedDeviceManager()
        let allowed = Self.everyVisibilityClass(visibility)
        object = withExtendedLifetime(allowed) {
            let storage = withUnsafePointer(to: allowed) {
                UnsafeRawPointer($0).load(as: UnsafeMutableRawPointer.self)
            }
            // The initializer takes ownership of the Set it is given.
            retainBridgeObject(storage)
            return unsafeBitCast(managerType, to: DeviceManagerObject.Type.self)
                .make(connection: sharedServiceConnection(), allowed: storage)
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
        Set(unsafeBitCast(visibilityClassAllCases(), to: [T].self))
    }
}

// Stand-ins that give Swift CoreDevice's calling convention: each method is
// bound to CoreDevice's own symbol. Every instance comes from CoreDevice.
private protocol ServiceConnection {}

/// DeviceManager.shared
@_silgen_name("$s10CoreDevice0B7ManagerC6sharedACvgZ")
private func sharedDeviceManager() -> DeviceManagerObject
/// CoreDeviceService.sharedConnection
@_silgen_name("$s10CoreDevice0aB7ServiceV16sharedConnectionAA0abcE0_pvgZ")
private func sharedServiceConnection() -> any ServiceConnection
/// DeviceVisibilityClass.allCases
@_silgen_name("$s10CoreDevice0B15VisibilityClassO8allCasesSayACGvgZ")
private func visibilityClassAllCases() -> UnsafeRawPointer
/// The Swift runtime's retain for a native Set / Array buffer. Looked up,
/// not bound: runtime entry points are off limits to `@_silgen_name`.
private func retainBridgeObject(_ object: UnsafeMutableRawPointer) {
    typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    guard let retain = CoreDeviceFramework.symbol("swift_bridgeObjectRetain") else { return }
    _ = unsafeBitCast(retain, to: Retain.self)(object)
}

private class DeviceManagerObject {
    /// DeviceManager(serviceConnection:allowedDeviceVisibilityClasses:)
    @_silgen_name("$s10CoreDevice0B7ManagerC17serviceConnection07allowedB17VisibilityClassesAcA0ab7ServiceE0_p_ShyAA0bG5ClassOGtcfC")
    static func make(connection: __owned any ServiceConnection, allowed: UnsafeRawPointer) -> DeviceManagerObject
    /// DeviceManager.allDevices()
    @_silgen_name("$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF")
    final func devices() -> [RemoteDeviceObject]
    /// DeviceManager.fullyInitialized
    @_silgen_name("$s10CoreDevice0B7ManagerC16fullyInitializedSbvgTj")
    final func isReady() -> Bool
}

private class RemoteDeviceObject {
    /// RemoteDevice.deviceIdentifier
    @_silgen_name("$s10CoreDevice06RemoteB0C16deviceIdentifier10Foundation4UUIDVvgTj")
    final func identifier() -> UUID
    /// RemoteDevice.getImplementation(for:) async throws
    @_silgen_name("$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTj")
    final func implementation(_ result: UnsafeMutableRawPointer, _ member: UnsafeRawPointer,
                              _ type: UnsafeRawPointer, _ conformance: UnsafeRawPointer) async throws
}

private final class Failure: @unchecked Sendable {
    var error: (any Error)?
}

#else

/// A device as CoreDevice lists it — never, in a build without CoreDevice.
struct RemoteDevice: Sendable {
    var identifier: UUID { UUID() }
    func open(_ kind: CapabilityKind) throws -> OpenedCapability { throw CoreDeviceError.unavailable }
}

#endif
