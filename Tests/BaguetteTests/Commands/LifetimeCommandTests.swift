import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette lifetime`: which policy its flags ask for, and how it reports
/// the one in force.
@Suite("Lifetime command")
struct LifetimeCommandTests {

    @Test func `should only read the policy when no flag is given`() throws {
        #expect(try LifetimeCommand.parse([]).desired == nil)
    }

    @Test func `should ask to leave devices booted with --detach`() throws {
        #expect(try LifetimeCommand.parse(["--detach"]).desired == .detached)
    }

    @Test func `should ask for Apple's default with --shutdown`() throws {
        #expect(try LifetimeCommand.parse(["--shutdown"]).desired == .appleDefault)
    }

    @Test func `should report that booted devices survive when the policy detaches`() {
        let lines = LifetimeCommand.report(.detached, colored: false)

        #expect(lines == [
            "Simulator lifetime (\(SimulatorAppPreferences.domain))",
            "  closing a window   leaves the device booted",
            "  quitting the app   leaves the device booted",
            "",
            "Booted devices survive Simulator.app.",
        ])
    }

    @Test func `should report the advisory when closing a window shuts devices down`() throws {
        let lines = LifetimeCommand.report(.appleDefault, colored: false)

        #expect(lines[1] == "  closing a window   shuts the device down")
        let advisory = try #require(SimulatorLifetime.appleDefault.advisory)
        #expect(lines.last == TerminalStyle.warning(advisory, colored: false))
    }

    @Test func `should headline the change in what Simulator.app will do`() {
        #expect(LifetimeCommand.headline(.detached) == "Simulator.app will leave booted devices running.")
        #expect(LifetimeCommand.headline(.appleDefault)
            == "Simulator.app will shut devices down on window close and quit.")
    }
}
