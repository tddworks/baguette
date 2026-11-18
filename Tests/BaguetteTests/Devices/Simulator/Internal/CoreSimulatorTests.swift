import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// One simulator: booting and shutting it down through CoreSimulator's
/// `SimDevice` messages, and reaching each of its abilities.
@Suite("CoreSimulator")
struct CoreSimulatorTests {

    /// A `SimDevice` that answers the boot and shutdown messages as told,
    /// and remembers what it was asked.
    @objc(FakeBootableDevice) final class FakeDevice: NSObject, @unchecked Sendable {
        let headless: Bool
        let plain: Bool
        let shutsDown: Bool
        private(set) var headlessOptions: NSDictionary?
        private(set) var plainBoots = 0
        private(set) var shutdowns = 0

        init(headless: Bool = true, plain: Bool = true, shutsDown: Bool = true) {
            self.headless = headless
            self.plain = plain
            self.shutsDown = shutsDown
        }

        @objc(bootWithOptions:error:) func boot(options: NSDictionary, error: NSErrorPointer) -> Bool {
            headlessOptions = options
            if !headless { error?.pointee = NSError(domain: "fake", code: 1) }
            return headless
        }

        @objc(bootWithError:) func boot(error: NSErrorPointer) -> Bool {
            plainBoots += 1
            if !plain { error?.pointee = NSError(domain: "fake", code: 2) }
            return plain
        }

        @objc(shutdownWithError:) func shutdown(error: NSErrorPointer) -> Bool {
            shutdowns += 1
            if !shutsDown { error?.pointee = NSError(domain: "fake", code: 3) }
            return shutsDown
        }
    }

    /// A `SimDevice` that only knows the plain boot.
    @objc(FakePlainBootDevice) final class FakePlainDevice: NSObject {
        private(set) var boots = 0
        @objc(bootWithError:) func boot(error: NSErrorPointer) -> Bool {
            boots += 1
            return true
        }
    }

    private func simulator(_ device: NSObject?, udid: String = "U") -> CoreSimulator {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(device)
        return CoreSimulator(
            udid: udid, name: "iPhone", state: .shutdown, runtime: "iOS 26.4", deviceTypeName: "iPhone 17",
            host: host)
    }

    // MARK: - boot

    @Test func `should boot headless so the device outlives this process`() throws {
        let device = FakeDevice()

        try simulator(device).boot()

        #expect(device.headlessOptions == ["persist": true])
        #expect(device.plainBoots == 0)
    }

    @Test func `should boot plainly when a headless boot is refused`() throws {
        let device = FakeDevice(headless: false)

        try simulator(device).boot()

        #expect(device.plainBoots == 1)
    }

    @Test func `should boot plainly when the device knows no headless boot`() throws {
        let device = FakePlainDevice()

        try simulator(device).boot()

        #expect(device.boots == 1)
    }

    @Test func `should fail to boot when every boot is refused`() {
        #expect(throws: SimulatorError.bootFailed) {
            try simulator(FakeDevice(headless: false, plain: false)).boot()
        }
    }

    @Test func `should fail to boot when the device knows no way to boot`() {
        #expect(throws: SimulatorError.bootFailed) { try simulator(NSObject()).boot() }
    }

    @Test func `should fail to boot a device that is not in the set`() {
        #expect(throws: SimulatorError.notFound(udid: "U")) { try simulator(nil).boot() }
    }

    // MARK: - shutdown

    @Test func `should shut the device down`() throws {
        let device = FakeDevice()

        try simulator(device).shutdown()

        #expect(device.shutdowns == 1)
    }

    @Test func `should fail to shut down when the device refuses`() {
        #expect(throws: SimulatorError.shutdownFailed) {
            try simulator(FakeDevice(shutsDown: false)).shutdown()
        }
    }

    @Test func `should fail to shut down when the device knows no way to`() {
        #expect(throws: SimulatorError.shutdownFailed) { try simulator(NSObject()).shutdown() }
    }

    @Test func `should fail to shut down a device that is not in the set`() {
        #expect(throws: SimulatorError.notFound(udid: "U")) { try simulator(nil).shutdown() }
    }

    // MARK: - abilities

    @Test func `should reach each ability through the simulator's own adapter`() {
        let simulator = simulator(nil, udid: "abilities-\(UUID().uuidString)")

        #expect(simulator.statusBar() is SimctlStatusBar)
        #expect(simulator.interface() is SimctlInterface)
        #expect(simulator.location() is SimctlLocation)
        #expect(simulator.shake() is SimctlShake)
        #expect(simulator.pasteboard() is SimctlPasteboard)
        #expect(simulator.notify() is SimctlApps)
        #expect(simulator.apps() is SimctlApps)
        #expect(simulator.defaults() is SimctlDefaults)
        #expect(simulator.photos() is SimctlPhotoLibrary)
        #expect(simulator.watchPairing() is SimctlWatchPairing)
        #expect(simulator.logs() is SimDeviceLogStream)
        #expect(simulator.externalDisplays() is HostExternalDisplays)
        #expect(simulator.inputSurface() is SimctlInputSurface)
        #expect(simulator.camera() is SimulatorCamera)
        #expect(simulator.accessibility() is AXPTranslatorAccessibility)
        #expect(simulator.orientation() is SimulatorOrientation)
        #expect(simulator.displays() is SimulatorKitDisplays)
        #expect(simulator.hinge() is SharedHinge)
    }

    @Test func `should share one hinge between every caller of the same simulator`() {
        let simulator = simulator(nil, udid: "hinge-\(UUID().uuidString)")

        #expect((simulator.hinge() as? SharedHinge) === (simulator.hinge() as? SharedHinge))
    }

    @Test func `should see and touch the phone plane on the built-in slot when it cannot be bound`() {
        let simulator = simulator(nil, udid: "plane-\(UUID().uuidString)")

        #expect(simulator.screen() is SimulatorKitScreen)
        #expect((simulator.input() as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.phone)
    }
}
