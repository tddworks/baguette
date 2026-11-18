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

extension RemoteDevice {
    /// Start the device's live screen stream (`MediaStreamFunctions
    /// .startMediaStream(with:)`). CoreDevice's support-info query brings
    /// the tunnel up first; then `makeRequest` builds the `StartRequest` as
    /// JSON (decoded through CoreDevice's own `Decodable`), now that the
    /// tunnel's addresses exist. The answer comes back as the
    /// `StartResponse`'s JSON. Blocks until CoreDevice answers.
    func startMediaStream(_ makeRequest: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any] {
        guard let requestType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV12StartRequestVMa") as? Decodable.Type,
              let responseType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV13StartResponseVMa"),
              let supportType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV19SupportInfoResponseVMa")
        else { throw CoreDeviceError.unavailable }
        let call = StartCall(object: object, requestType: requestType, responseType: responseType,
                             supportType: supportType, makeRequest: makeRequest)
        Task.detached { await call.run() }
        call.done.wait()
        if let error = call.error { throw error }
        guard let json = call.json else { throw CoreDeviceError.unavailable }
        return json
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

/// One start, carried across to the task that awaits CoreDevice.
private final class StartCall: @unchecked Sendable {
    let object: RemoteDeviceObject
    let requestType: Decodable.Type
    let responseType: Any.Type
    let supportType: Any.Type
    let makeRequest: @Sendable () throws -> [String: Any]
    var json: [String: Any]?
    var error: (any Error)?
    let done = DispatchSemaphore(value: 0)

    init(object: RemoteDeviceObject, requestType: Decodable.Type, responseType: Any.Type,
         supportType: Any.Type, makeRequest: @escaping @Sendable () throws -> [String: Any]) {
        self.object = object
        self.requestType = requestType
        self.responseType = responseType
        self.supportType = supportType
        self.makeRequest = makeRequest
    }

    func run() async {
        defer { done.signal() }
        var functions = MediaStreamFunctionsObject(words: mediaStreamFunctions(device: object))
        let result = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { result.deallocate() }
        do {
            try await functions.supportInfo(result)
            discard(result, as: supportType)
            let request = try JSONDecoder().decode(
                requestType, from: JSONSerialization.data(withJSONObject: try makeRequest()))
            let box = RequestBox(request)
            defer { box.release() }
            try await functions.start(result, UnsafeRawPointer(box.pointer))
            json = encodedJSON(result, as: responseType)
        } catch {
            self.error = error
        }
    }
}

/// A decoded request, held at an address for the call that borrows it.
private struct RequestBox {
    let pointer: UnsafeMutableRawPointer
    let release: () -> Void

    init(_ value: Any) {
        func box<T>(_ value: T) -> (UnsafeMutableRawPointer, () -> Void) {
            let typed = UnsafeMutablePointer<T>.allocate(capacity: 1)
            typed.initialize(to: value)
            return (UnsafeMutableRawPointer(typed), { typed.deinitialize(count: 1); typed.deallocate() })
        }
        (pointer, release) = _openExistential(value, do: box)
    }
}

/// `MediaStreamFunctions(device:)` — a small resilient struct, returned
/// indirectly; sixteen words is room enough (checked by size below).
private typealias MediaStreamFunctionsWords = (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                                               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
@_silgen_name("$s10CoreDevice20MediaStreamFunctionsV6deviceAcA06RemoteB0C_tcfC")
private func mediaStreamFunctions(device: __owned RemoteDeviceObject) -> MediaStreamFunctionsWords

/// Stands at a `MediaStreamFunctions` value, so its methods get its address.
private struct MediaStreamFunctionsObject {
    var words: MediaStreamFunctionsWords
}
private extension MediaStreamFunctionsObject {
    /// MediaStreamFunctions.mediaStreamSupportInfo { get async throws }
    @_silgen_name("$s10CoreDevice20MediaStreamFunctionsV05mediaD11SupportInfoAA0bcD0V0gH8ResponseVvg")
    mutating func supportInfo(_ result: UnsafeMutableRawPointer) async throws
    /// MediaStreamFunctions.startMediaStream(with:) async throws
    @_silgen_name("$s10CoreDevice20MediaStreamFunctionsV05startcD04withAA0bcD0V13StartResponseVAG0H7RequestV_tYaKF")
    mutating func start(_ result: UnsafeMutableRawPointer, _ request: UnsafeRawPointer) async throws
}

/// A value of `type` at `pointer`, moved out and encoded as JSON.
private func encodedJSON(_ pointer: UnsafeMutableRawPointer, as type: Any.Type) -> [String: Any]? {
    func open<T>(_: T.Type) -> [String: Any]? {
        let value = pointer.assumingMemoryBound(to: T.self).move()
        guard let encodable = value as? Encodable,
              let data = try? JSONEncoder().encode(EncodableBox(encodable))
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return _openExistential(type, do: open)
}

/// A value of `type` at `pointer`, destroyed.
private func discard(_ pointer: UnsafeMutableRawPointer, as type: Any.Type) {
    func open<T>(_: T.Type) { _ = pointer.assumingMemoryBound(to: T.self).move() }
    _openExistential(type, do: open)
}

private struct EncodableBox: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

#else

/// A device as CoreDevice lists it — never, in a build without CoreDevice.
struct RemoteDevice: Sendable {
    var identifier: UUID { UUID() }
    func open(_ kind: CapabilityKind) throws -> OpenedCapability { throw CoreDeviceError.unavailable }
}

#endif
