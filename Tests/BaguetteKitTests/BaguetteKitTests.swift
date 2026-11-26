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

/// The resources folder is the process's: one suite, one test at a time.
@Suite("BaguetteResources", .serialized)
struct BaguetteResourcesTests {
    @Test func `should hand a host's resources folder to every lookup after it chooses one`() {
        let folder = URL(fileURLWithPath: "/opt/host/baguette-resources", isDirectory: true)
        defer { BaguetteResources.use(folder: nil) }

        BaguetteResources.use(folder: folder)

        #expect(BaguetteResources.folder == folder)
    }

    @Test func `should have no resources folder until a host chooses one`() {
        #expect(BaguetteResources.folder == nil)
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
