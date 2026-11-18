import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The simulators CoreSimulator lists, read through stand-ins for its
/// service context, device sets, devices, runtimes and device types.
@Suite("CoreSimulators")
struct CoreSimulatorsTests {

    @objc(FakeCoreSimRuntime) final class FakeRuntime: NSObject {
        @objc let name: String?
        @objc let versionString: String?
        @objc let identifier: String?
        init(name: String?, versionString: String?, identifier: String? = nil) {
            self.name = name
            self.versionString = versionString
            self.identifier = identifier
        }
    }

    @objc(FakeCoreSimDeviceType) final class FakeDeviceType: NSObject {
        @objc let name: String?
        @objc let identifier: String?
        @objc let productFamily: String?
        init(name: String?, identifier: String? = nil, productFamily: String? = nil) {
            self.name = name
            self.identifier = identifier
            self.productFamily = productFamily
        }
    }

    @objc(FakeCoreSimDevice) final class FakeDevice: NSObject {
        @objc let UDID: NSUUID
        @objc let name: String?
        @objc let state: NSNumber?
        @objc let runtime: NSObject?
        @objc let deviceType: NSObject?
        init(
            _ udid: NSUUID = NSUUID(), name: String? = "iPhone 17", state: NSNumber? = 3,
            runtime: NSObject? = nil, deviceType: NSObject? = nil
        ) {
            UDID = udid
            self.name = name
            self.state = state
            self.runtime = runtime
            self.deviceType = deviceType
        }
    }

    @objc(FakeCoreSimSet) final class FakeSet: NSObject {
        @objc let availableDevices: [NSObject]
        init(_ devices: [NSObject]) { availableDevices = devices }
    }

    /// A service context with a default set, and a set at each path it knows.
    @objc(FakeCoreSimContext) final class FakeContext: NSObject, @unchecked Sendable {
        let defaultSet: FakeSet?
        let sets: [String: FakeSet]
        init(default defaultSet: FakeSet? = nil, sets: [String: FakeSet] = [:]) {
            self.defaultSet = defaultSet
            self.sets = sets
        }
        @objc(defaultDeviceSetWithError:) func defaultDeviceSet(_ error: NSErrorPointer) -> NSObject? { defaultSet }
        @objc(deviceSetWithPath:error:) func deviceSet(path: NSString, error: NSErrorPointer) -> NSObject? {
            sets[path as String]
        }
    }

    /// A context that knows only the default set's selector, not sets by path.
    @objc(FakeCoreSimDefaultOnlyContext) final class FakeDefaultOnlyContext: NSObject, @unchecked Sendable {
        @objc(defaultDeviceSetWithError:) func defaultDeviceSet(_ error: NSErrorPointer) -> NSObject? { nil }
    }

    private func simulators(_ context: NSObject?, deviceSetPath: String? = nil) -> CoreSimulators {
        nonisolated(unsafe) let context = context
        return CoreSimulators(deviceSetPath: deviceSetPath, serviceContext: { context })
    }

    private func scratch() throws -> String {
        let path = NSTemporaryDirectory() + "baguette-sets-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path + "/Devices", withIntermediateDirectories: true)
        return path
    }

    // MARK: - listing

    @Test func `should list each available device with its name, state, runtime and model`() throws {
        let udid = NSUUID()
        let device = FakeDevice(
            udid, name: "My Phone", state: 3,
            runtime: FakeRuntime(name: "iOS 26.4", versionString: "26.4", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            deviceType: FakeDeviceType(
                name: "iPhone 17 Pro", identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                productFamily: "iPhone"))

        let listed = try #require(simulators(FakeContext(default: FakeSet([device]))).all.first as? CoreSimulator)

        #expect(listed.udid == udid.uuidString)
        #expect(listed.name == "My Phone")
        #expect(listed.state == .booted)
        #expect(listed.runtime == "iOS 26.4")
        #expect(listed.deviceTypeName == "iPhone 17 Pro")
        #expect(listed.deviceSetPath == nil)
        #expect(listed.metadata == SimulatorMetadata(
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", productFamily: "iPhone",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4", runtimeVersion: "26.4"))
    }

    @Test func `should name the runtime by its version when it has no name`() throws {
        let device = FakeDevice(runtime: FakeRuntime(name: nil, versionString: "26.4"))

        let listed = try #require(simulators(FakeContext(default: FakeSet([device]))).all.first)

        #expect(listed.runtime == "26.4")
    }

    @Test func `should model a device by its own name when it has no device type`() throws {
        let device = FakeDevice(name: "Clone of iPhone", runtime: nil, deviceType: nil)

        let listed = try #require(simulators(FakeContext(default: FakeSet([device]))).all.first)

        #expect(listed.deviceTypeName == "Clone of iPhone")
        #expect(listed.runtime == "")
    }

    @Test func `should read a device with no name or state as an unknown device that is shut down`() throws {
        let device = FakeDevice(name: nil, state: nil)

        let listed = try #require(simulators(FakeContext(default: FakeSet([device]))).all.first)

        #expect(listed.name == "Unknown")
        #expect(listed.state == .shutdown)
    }

    @Test(arguments: [
        (0, SimulatorState.creating), (1, .shutdown), (2, .booting), (3, .booted), (4, .shuttingDown), (99, .shutdown),
    ])
    func `should read each CoreSimulator state as the simulator's state`(raw: Int, state: SimulatorState) throws {
        let device = FakeDevice(state: NSNumber(value: raw))

        let listed = try #require(simulators(FakeContext(default: FakeSet([device]))).all.first)

        #expect(listed.state == state)
    }

    @Test func `should list nothing when CoreSimulator is unavailable`() {
        #expect(simulators(nil).all.isEmpty)
    }

    @Test func `should list nothing when there is no default device set`() {
        #expect(simulators(FakeContext()).all.isEmpty)
        #expect(simulators(NSObject()).all.isEmpty)
    }

    @Test func `should find a simulator by its udid`() {
        let udid = NSUUID()
        let set = FakeSet([FakeDevice(name: "Other"), FakeDevice(udid, name: "Mine")])
        let simulators = simulators(FakeContext(default: set))

        #expect(simulators.find(udid: udid.uuidString)?.name == "Mine")
        #expect(simulators.find(udid: "ghost") == nil)
    }

    // MARK: - a custom device set

    @Test func `should list a custom device set at its path`() throws {
        let path = try scratch()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let context = FakeContext(sets: [path: FakeSet([FakeDevice()])])

        let listed = simulators(context, deviceSetPath: path).all

        #expect(listed.count == 1)
        #expect((listed.first as? CoreSimulator)?.deviceSetPath == path)
    }

    @Test func `should list the Devices folder of a custom set when the path itself holds no devices`() throws {
        let path = try scratch()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let nested = path + "/Devices"
        let context = FakeContext(sets: [path: FakeSet([]), nested: FakeSet([FakeDevice()])])

        let listed = simulators(context, deviceSetPath: path).all

        #expect((listed.first as? CoreSimulator)?.deviceSetPath == nested)
    }

    @Test func `should list nothing when a custom set path is not a folder`() {
        let path = NSTemporaryDirectory() + "baguette-missing-\(UUID().uuidString)"
        let context = FakeContext(sets: [path: FakeSet([FakeDevice()])])

        #expect(simulators(context, deviceSetPath: path).all.isEmpty)
    }

    @Test func `should list nothing when CoreSimulator cannot open a set by path`() throws {
        let path = try scratch()
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(simulators(FakeDefaultOnlyContext(), deviceSetPath: path).all.isEmpty)
    }

    // MARK: - loading the frameworks

    @Test func `should load CoreSimulator and the SimulatorKit of the selected Xcode`() throws {
        let developer = try scratch()
        defer { try? FileManager.default.removeItem(atPath: developer) }
        let simKit = developer + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        try FileManager.default.createDirectory(
            atPath: (simKit as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: simKit, contents: Data())
        var opened: [String] = []

        let problems = CoreSimulators.frameworkLoadProblems(developerDir: developer) { opened.append($0); return nil }

        #expect(opened == ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", simKit])
        #expect(problems.isEmpty)
    }

    @Test func `should say why a framework failed to load`() throws {
        let developer = try scratch()
        defer { try? FileManager.default.removeItem(atPath: developer) }
        let simKit = developer + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        try FileManager.default.createDirectory(
            atPath: (simKit as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: simKit, contents: Data())

        let problems = CoreSimulators.frameworkLoadProblems(developerDir: developer) { _ in "no image" }

        #expect(problems == ["CoreSimulator load failed: no image", "SimulatorKit load failed: no image"])
    }

    @Test func `should name every place it looked when no Xcode carries SimulatorKit`() {
        let developer = "/nowhere/Xcode.app/Contents/Developer"
        var opened: [String] = []

        let problems = CoreSimulators.frameworkLoadProblems(developerDir: developer) { opened.append($0); return nil }

        #expect(opened.count == 1)
        #expect(problems == [
            "SimulatorKit not found. Searched:",
            "  /nowhere/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "  /nowhere/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "Set DEVELOPER_DIR to an Xcode that has it, or see",
            "https://github.com/tddworks/baguette/issues/28",
        ])
    }
}
