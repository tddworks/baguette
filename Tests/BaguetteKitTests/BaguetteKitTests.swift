import BaguetteKit
import Foundation
import Mockable
import Testing

/// What a package that depends on the `BaguetteKit` product sees: no
/// `@testable`, so everything used here is the library's public face.
@Suite("BaguetteKit")
struct BaguetteKitTests {
    @Test func `should list the simulators of a device set to a package that imports only BaguetteKit`() throws {
        let deviceSet = try emptyDeviceSet()
        defer { try? FileManager.default.removeItem(at: deviceSet) }

        let kinds = DeviceKinds(
            simulators: CoreSimulators(deviceSetPath: deviceSet.path),
            phones: none(),
            androids: none()
        )

        #expect(kinds.devices.all.isEmpty)
    }

    @Test func `should take a host's own copy of the hinge helper for the simulators it lists`() throws {
        let deviceSet = try emptyDeviceSet()
        defer { try? FileManager.default.removeItem(at: deviceSet) }

        let simulators = CoreSimulators(
            deviceSetPath: deviceSet.path,
            hingeControl: URL(fileURLWithPath: "/opt/host/HingeControl"))

        #expect(simulators.all.isEmpty)
    }

    @Test func `should refuse an id that no device family knows`() throws {
        let deviceSet = try emptyDeviceSet()
        defer { try? FileManager.default.removeItem(at: deviceSet) }

        let kinds = DeviceKinds(
            simulators: CoreSimulators(deviceSetPath: deviceSet.path),
            phones: none(),
            androids: none()
        )

        #expect(throws: DeviceError.self) { try kinds.devices.device("NO-SUCH-DEVICE") }
    }
}

private func emptyDeviceSet() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "baguettekit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A family with nothing to list.
private func none() -> MockDevices {
    let devices = MockDevices()
    given(devices).all.willReturn([])
    given(devices).find(id: .any).willReturn(nil)
    return devices
}
