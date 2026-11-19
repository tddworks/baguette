import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette boot`, `shutdown` and `heal` against the devices a test hands them.
@Suite("Power commands")
struct PowerCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private func power(on: Bool = true, off: Bool = true) -> MockPower {
        let power = MockPower()
        if on { given(power).turnOn().willReturn() } else { given(power).turnOn().willThrow(Refused()) }
        if off { given(power).turnOff().willReturn() } else { given(power).turnOff().willThrow(Refused()) }
        return power
    }

    private func surface(shadowed: Bool, reclaim: Bool = true) -> MockInputSurface {
        let surface = MockInputSurface()
        given(surface).ready().willReturn()
        given(surface).shadowed().willReturn(shadowed)
        if reclaim { given(surface).reclaim().willReturn() } else { given(surface).reclaim().willThrow(Refused()) }
        return surface
    }

    // MARK: - boot

    @Test func `should boot the device and leave an unshadowed input surface alone`() async throws {
        let power = power(), surface = surface(shadowed: false)

        let ran = try await run(try BootCommand.parse(["--udid", "U"]), on: routeDevices {
            $0.register(.power) { power }
            $0.register(.inputSurface) { surface }
        })

        #expect(ran.exit == 0)
        #expect(ran.told == ["Booted iPhone 17"])
    }

    @Test func `should reclaim the input surface after boot when Device Hub shadowed it`() async throws {
        let power = power(), surface = surface(shadowed: true)

        let ran = try await run(try BootCommand.parse(["--udid", "U"]), on: routeDevices {
            $0.register(.power) { power }
            $0.register(.inputSurface) { surface }
        })

        #expect(ran.told == ["Booted iPhone 17", HealOutcome.reclaimed.summary])
    }

    @Test func `should still boot when reclaiming the input surface fails`() async throws {
        let power = power(), surface = surface(shadowed: true, reclaim: false)

        let ran = try await run(try BootCommand.parse(["--udid", "U"]), on: routeDevices {
            $0.register(.power) { power }
            $0.register(.inputSurface) { surface }
        })

        #expect(ran.exit == 0)
        #expect(ran.told == ["Booted iPhone 17"])
    }

    @Test func `should boot without asking about the input surface when told not to heal`() async throws {
        let power = power()

        let ran = try await run(try BootCommand.parse(["--udid", "U", "--no-heal"]),
                                on: routeDevices { $0.register(.power) { power } })

        #expect(ran.told == ["Booted iPhone 17"])
    }

    @Test func `should boot a device that has no input surface to heal`() async throws {
        let power = power()

        let ran = try await run(try BootCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.power) { power } })

        #expect(ran.exit == 0)
        #expect(ran.told == ["Booted iPhone 17"])
    }

    @Test func `should exit 1 when boot fails`() async throws {
        let power = power(on: false)

        let ran = try await run(try BootCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.power) { power } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["Boot failed: refused"])
    }

    @Test func `should exit 1 when booting a device that has no power to turn on`() async throws {
        let ran = try await run(try BootCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do power"])
    }

    @Test func `should exit 1 when booting a udid no device has`() async throws {
        let ran = try await run(try BootCommand.parse(["--udid", "NOPE"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Device NOPE not found"])
    }

    // MARK: - shutdown

    @Test func `should shut the device down and say so`() async throws {
        let power = power()

        let ran = try await run(try ShutdownCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.power) { power } })

        #expect(ran.exit == 0)
        #expect(ran.told == ["Shut down iPhone 17"])
    }

    @Test func `should exit 1 when shutdown fails`() async throws {
        let power = power(off: false)

        let ran = try await run(try ShutdownCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.power) { power } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["Shutdown failed: refused"])
    }

    @Test func `should exit 1 when shutting down a device without power`() async throws {
        let ran = try await run(try ShutdownCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do power"])
    }

    // MARK: - heal

    @Test func `should reclaim a shadowed input surface on heal`() async throws {
        let surface = surface(shadowed: true)

        let ran = try await run(try HealCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.inputSurface) { surface } })

        #expect(ran.exit == 0)
        #expect(ran.told == [HealOutcome.reclaimed.summary])
    }

    @Test func `should say there is nothing to heal when the surface is not shadowed`() async throws {
        let surface = surface(shadowed: false)

        let ran = try await run(try HealCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.inputSurface) { surface } })

        #expect(ran.told == [HealOutcome.unshadowed.summary])
    }

    @Test func `should exit 1 when heal fails`() async throws {
        let surface = surface(shadowed: true, reclaim: false)

        let ran = try await run(try HealCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.inputSurface) { surface } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["Heal failed: refused"])
    }

    @Test func `should exit 1 when healing a device without an input surface`() async throws {
        let ran = try await run(try HealCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do inputSurface"])
    }
}
