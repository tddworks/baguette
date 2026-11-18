import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette location`, `motion` and `network` against the devices a test
/// hands them.
@Suite("Condition commands")
struct ConditionCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    // MARK: - location

    private func location(failing: Bool = false) -> any Devices {
        let location = MockLocation()
        if failing {
            given(location).set(.any).willThrow(Refused())
            given(location).start(.any).willThrow(Refused())
            given(location).clear().willThrow(Refused())
        } else {
            given(location).set(.any).willReturn()
            given(location).start(.any).willReturn()
            given(location).clear().willReturn()
        }
        return routeDevices { $0.register(.location) { location } }
    }

    @Test func `should pin the device to the position given`() async throws {
        let ran = try await run(try LocationCommand.Set.parse(["--udid", "U", "37.5,-122.25"]), on: location())

        #expect(ran.exit == 0)
        #expect(ran.told == ["Set iPhone 17 location to 37.5,-122.25"])
    }

    @Test func `should exit 1 when the position is off the globe`() async throws {
        let ran = try await run(try LocationCommand.Set.parse(["--udid", "U", "91,0"]), on: location())

        #expect(ran.exit == 1)
        #expect(ran.told == ["location set: latitude must be -90…90 and longitude -180…180"])
    }

    @Test func `should exit 1 when pinning the position fails`() async throws {
        let ran = try await run(try LocationCommand.Set.parse(["--udid", "U", "1,2"]), on: location(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["location set failed: refused"])
    }

    @Test func `should run a route over the waypoints given`() async throws {
        let ran = try await run(try LocationCommand.Start.parse(["--udid", "U", "1,2", "3,4"]), on: location())

        #expect(ran.told == ["Started iPhone 17 route over 2 waypoints"])
    }

    @Test func `should exit 1 when a route has too few waypoints`() async throws {
        let ran = try await run(try LocationCommand.Start.parse(["--udid", "U", "1,2"]), on: location())

        #expect(ran.exit == 1)
        #expect(ran.told == ["location start: give two or more valid lat,lon waypoints"])
    }

    @Test func `should exit 1 when the route fails to start`() async throws {
        let ran = try await run(try LocationCommand.Start.parse(["--udid", "U", "1,2", "3,4"]),
                                on: location(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["location start failed: refused"])
    }

    @Test func `should walk the device along the bearing given`() async throws {
        let ran = try await run(
            try LocationCommand.Walk.parse(["--udid", "U", "--bearing", "90", "--speed", "1.4", "1,2"]),
            on: location())

        #expect(ran.exit == 0)
        #expect(ran.told.first?.hasPrefix("Walking iPhone 17 from 1.0,2.0 on bearing 90.0°") == true)
    }

    @Test func `should exit 1 when a walk has no speed`() async throws {
        let ran = try await run(
            try LocationCommand.Walk.parse(["--udid", "U", "--bearing", "90", "--speed", "0", "1,2"]),
            on: location())

        #expect(ran.exit == 1)
        #expect(ran.told == ["location walk: give a valid lat,lon origin and a speed above 0"])
    }

    @Test func `should exit 1 when the walk fails to start`() async throws {
        let ran = try await run(
            try LocationCommand.Walk.parse(["--udid", "U", "--bearing", "90", "--speed", "1", "1,2"]),
            on: location(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["location walk failed: refused"])
    }

    @Test func `should clear the simulated location`() async throws {
        let ran = try await run(try LocationCommand.Clear.parse(["--udid", "U"]), on: location())

        #expect(ran.told == ["Cleared iPhone 17 simulated location"])
    }

    @Test func `should exit 1 when clearing the location fails`() async throws {
        let ran = try await run(try LocationCommand.Clear.parse(["--udid", "U"]), on: location(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["location clear failed: refused"])
    }

    @Test func `should exit 1 locating a device that has no location`() async throws {
        let ran = try await run(try LocationCommand.Clear.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do location"])
    }

    // MARK: - motion

    private func motion(failing: Bool = false) -> any Devices {
        let motion = MockMotion()
        given(motion).published().willReturn(nil)
        if failing {
            given(motion).publish(.any).willThrow(Refused())
            given(motion).clear().willThrow(Refused())
        } else {
            given(motion).publish(.any).willReturn()
            given(motion).clear().willReturn()
        }
        return routeDevices { $0.register(.motion) { motion } }
    }

    @Test func `should arm motion walking at the usual pace and ask for a relaunch`() async throws {
        let ran = try await run(try MotionCommand.Start.parse(["--udid", "U"]), on: motion())

        #expect(ran.told == ["Motion armed on iPhone 17: walking at 1.4 m/s. Relaunch the app to pick it up."])
    }

    @Test func `should change the reported activity`() async throws {
        let ran = try await run(try MotionCommand.Set.parse(["--udid", "U", "--activity", "running"]), on: motion())

        #expect(ran.told == ["iPhone 17 motion: running at 3.5 m/s"])
    }

    @Test func `should exit 1 when the activity can't be published`() async throws {
        let ran = try await run(try MotionCommand.Set.parse(["--udid", "U"]), on: motion(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["motion failed: refused"])
    }

    @Test func `should park the device and stop motion`() async throws {
        let ran = try await run(try MotionCommand.Stop.parse(["--udid", "U"]), on: motion())

        #expect(ran.told == ["Motion stopped on iPhone 17"])
    }

    @Test func `should exit 1 when motion can't be stopped`() async throws {
        let ran = try await run(try MotionCommand.Stop.parse(["--udid", "U"]), on: motion(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["motion stop failed: refused"])
    }

    @Test func `should exit 1 driving motion on a device without it`() async throws {
        let ran = try await run(try MotionCommand.Stop.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do motion"])
    }

    // MARK: - network

    private func network(current: NetworkCondition? = nil, failing: Bool = false) -> any Devices {
        let network = MockNetwork()
        given(network).current().willReturn(current)
        if failing {
            given(network).apply(.any).willThrow(Refused())
            given(network).clear().willThrow(Refused())
        } else {
            given(network).apply(.any).willReturn()
            given(network).clear().willReturn()
        }
        return routeDevices { $0.register(.network) { network } }
    }

    @Test func `should condition the network as the preset says and ask for a relaunch`() async throws {
        let ran = try await run(try NetworkCommand.Set.parse(["--udid", "U", "--offline"]), on: network())

        #expect(ran.told == ["Network conditioned on iPhone 17: offline. Relaunch the app to pick it up."])
    }

    @Test func `should exit 1 when the network can't be conditioned`() async throws {
        let ran = try await run(try NetworkCommand.Set.parse(["--udid", "U", "--offline"]), on: network(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["network set failed: refused"])
    }

    @Test func `should stop conditioning the network`() async throws {
        let ran = try await run(try NetworkCommand.Clear.parse(["--udid", "U"]), on: network())

        #expect(ran.told == ["Network conditioning cleared on iPhone 17"])
    }

    @Test func `should exit 1 when conditioning can't be cleared`() async throws {
        let ran = try await run(try NetworkCommand.Clear.parse(["--udid", "U"]), on: network(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["network clear failed: refused"])
    }

    @Test func `should report the condition applied`() async throws {
        let ran = try await run(try NetworkCommand.Status.parse(["--udid", "U"]), on: network(current: .offline))

        #expect(ran.told == ["iPhone 17 network: offline"])
    }

    @Test func `should report that nothing is applied when the network is unconditioned`() async throws {
        let ran = try await run(try NetworkCommand.Status.parse(["--udid", "U"]), on: network())

        #expect(ran.told == ["iPhone 17: no network conditioning applied."])
    }

    @Test func `should exit 1 conditioning a device without a network`() async throws {
        let ran = try await run(try NetworkCommand.Status.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do network"])
    }
}
