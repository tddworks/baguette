import BaguetteDeviceFamilies
import Foundation

#if COREDEVICE

/// CoreDevice's `DeviceManager`, made once per process with every
/// visibility class allowed, so physical phones are listed beside simulators.
final class DeviceManager: @unchecked Sendable {
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

    /// The device CoreDevice lists by `identifier`, waited for as
    /// `CoreDeviceListing` decides.
    func device(_ identifier: UUID) -> RemoteDevice? {
        CoreDeviceListing.find(where: { $0.identifier() == identifier },
                               listed: { object.devices() }, isComplete: { object.isReady() })
            .map(RemoteDevice.init(object:))
    }

    /// Apple's own cases, from its `allCases`, as the Set the initializer takes.
    private static func everyVisibilityClass<T: Hashable>(_: T.Type) -> Any {
        Set(unsafeBitCast(visibilityClassAllCases(), to: [T].self))
    }
}

/// The Swift runtime's retain for a native Set / Array buffer. Looked up,
/// not bound: runtime entry points are off limits to `@_silgen_name`.
private func retainBridgeObject(_ object: UnsafeMutableRawPointer) {
    typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    guard let retain = CoreDeviceFramework.symbol("swift_bridgeObjectRetain") else { return }
    _ = unsafeBitCast(retain, to: Retain.self)(object)
}

#endif
