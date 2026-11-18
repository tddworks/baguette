import Foundation
import Mockable
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("SimulatorMetadata")
struct SimulatorMetadataTests {
    @Test func `should list the stable model and runtime metadata when the user has renamed the simulator`() throws {
        let simulator = CoreSimulator(
            udid: "U1", name: "Renamed QA tablet", state: .booted,
            runtime: "iOS 26.5", deviceTypeName: "iPhone 17 Pro", host: MockDeviceHost(),
            metadata: SimulatorMetadata(
                deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                productFamily: "iPhone", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                runtimeVersion: "26.5"))
        let host = MockSimulators()
        given(host).all.willReturn([simulator])
        let result = try #require(
            JSONSerialization.jsonObject(with: Data(host.listJSON.utf8)) as? [String: [[String: Any]]])
        let device = try #require(result["running"]?.first)
        #expect(device["name"] as? String == "Renamed QA tablet")
        #expect(device["productFamily"] as? String == "iPhone")
        #expect(device["runtimeVersion"] as? String == "26.5")
        #expect(device["runtimeIdentifier"] as? String == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        #expect(device["deviceTypeIdentifier"] as? String == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    }

    @Test func `should leave missing metadata unknown rather than guess it from user labels`() {
        let metadata = SimulatorMetadata()
        #expect(metadata.dictionary.values.allSatisfy { $0 is NSNull })
    }
}
