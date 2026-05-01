import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("Simulators")
struct SimulatorsTests {

    @Test func `running returns only booted simulators`() {
        let host = MockSimulators()
        given(host).all.willReturn([
            sim("U1", "iPhone 17 Pro Max", .booted, host: host),
            sim("U2", "iPhone 17 Pro",     .shutdown, host: host),
            sim("U3", "iPhone 17",         .booting, host: host),
            sim("U4", "iPhone Air",        .booted, host: host),
        ])

        let running = host.running
        #expect(running.map(\.udid) == ["U1", "U4"])
    }

    @Test func `available returns everything that isn't booted`() {
        let host = MockSimulators()
        given(host).all.willReturn([
            sim("U1", "iPhone 17 Pro Max", .booted, host: host),
            sim("U2", "iPhone 17 Pro",     .shutdown, host: host),
            sim("U3", "iPhone 17",         .booting, host: host),
            sim("U4", "iPhone Air",        .shuttingDown, host: host),
        ])

        let available = host.available
        #expect(available.map(\.udid) == ["U2", "U3", "U4"])
    }

    @Test func `listJSON splits sections and preserves field shape`() throws {
        let host = MockSimulators()
        given(host).all.willReturn([
            sim("U1", "iPhone 17 Pro Max", .booted,   runtime: "iOS 26.4", host: host),
            sim("U2", "iPhone 17 Pro",     .shutdown, runtime: "iOS 26.4", host: host),
        ])

        let json = host.listJSON
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

        let running = parsed?["running"] as? [[String: Any]]
        let available = parsed?["available"] as? [[String: Any]]

        #expect(running?.count == 1)
        #expect(running?.first?["udid"] as? String == "U1")
        #expect(running?.first?["name"] as? String == "iPhone 17 Pro Max")
        #expect(running?.first?["state"] as? String == "Booted")
        #expect(running?.first?["runtime"] as? String == "iOS 26.4")

        #expect(available?.count == 1)
        #expect(available?.first?["udid"] as? String == "U2")
        #expect(available?.first?["state"] as? String == "Shutdown")
    }

    @Test func `listJSON renders empty sections as empty arrays`() throws {
        let host = MockSimulators()
        given(host).all.willReturn([])

        let parsed = try JSONSerialization.jsonObject(
            with: Data(host.listJSON.utf8)
        ) as? [String: Any]

        #expect((parsed?["running"]   as? [[String: Any]])?.isEmpty == true)
        #expect((parsed?["available"] as? [[String: Any]])?.isEmpty == true)
    }

    // MARK: - helpers

    private func sim(
        _ udid: String, _ name: String, _ state: Simulator.State,
        runtime: String = "", host: any Simulators
    ) -> Simulator {
        Simulator(udid: udid, name: name, state: state, runtime: runtime, host: host)
    }
}
