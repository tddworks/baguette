import BaguetteDeviceFamilies
import Foundation

#if COREDEVICE

// Stand-ins that give Swift CoreDevice's calling convention: each method is
// bound to CoreDevice's own symbol. Every instance comes from CoreDevice.
protocol CoreDeviceServiceConnection {}

/// DeviceManager.shared
@_silgen_name("$s10CoreDevice0B7ManagerC6sharedACvgZ")
func sharedDeviceManager() -> DeviceManagerObject
/// CoreDeviceService.sharedConnection
@_silgen_name("$s10CoreDevice0aB7ServiceV16sharedConnectionAA0abcE0_pvgZ")
func sharedServiceConnection() -> any CoreDeviceServiceConnection
/// DeviceVisibilityClass.allCases
@_silgen_name("$s10CoreDevice0B15VisibilityClassO8allCasesSayACGvgZ")
func visibilityClassAllCases() -> UnsafeRawPointer

class DeviceManagerObject {
    /// DeviceManager(serviceConnection:allowedDeviceVisibilityClasses:)
    @_silgen_name("$s10CoreDevice0B7ManagerC17serviceConnection07allowedB17VisibilityClassesAcA0ab7ServiceE0_p_ShyAA0bG5ClassOGtcfC")
    static func make(connection: __owned any CoreDeviceServiceConnection, allowed: UnsafeRawPointer) -> DeviceManagerObject
    /// DeviceManager.allDevices()
    @_silgen_name("$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF")
    final func devices() -> [RemoteDeviceObject]
    /// DeviceManager.fullyInitialized
    @_silgen_name("$s10CoreDevice0B7ManagerC16fullyInitializedSbvgTj")
    final func isReady() -> Bool
}

class RemoteDeviceObject {
    /// RemoteDevice.deviceIdentifier
    @_silgen_name("$s10CoreDevice06RemoteB0C16deviceIdentifier10Foundation4UUIDVvgTj")
    final func identifier() -> UUID
    /// RemoteDevice.connect() async throws
    @_silgen_name("$s10CoreDevice06RemoteB0C7connectyyYaKFTj")
    final func connect() async throws
    /// RemoteDevice.getImplementation(for:) async throws
    @_silgen_name("$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTj")
    final func implementation(_ result: UnsafeMutableRawPointer, _ member: UnsafeRawPointer,
                              _ type: UnsafeRawPointer, _ conformance: UnsafeRawPointer) async throws
}

#endif
