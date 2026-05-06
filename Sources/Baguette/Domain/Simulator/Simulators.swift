import Foundation
import Mockable

/// The host's collection of simulators. Lists what's available, finds by
/// UDID, and runs the lifecycle verbs (`boot` / `shutdown`) that
/// `Simulator.boot()` / `simulator.shutdown()` delegate into.
///
/// `@Mockable` so domain tests can drive the aggregate's contract without
/// CoreSimulator. Class-bound (`AnyObject`) because each `Simulator` value
/// carries `host: any Simulators` as a reference.
@Mockable
protocol Simulators: AnyObject, Sendable {
    var all: [Simulator] { get }
    func find(udid: String) -> Simulator?
    func boot(_ simulator: Simulator) throws
    func shutdown(_ simulator: Simulator) throws

    /// Produce a `Screen` for the simulator. Each call returns a fresh
    /// pipeline; multiple parallel streams are supported.
    func screen(for simulator: Simulator) -> any Screen

    /// Produce an `Input` for the simulator.
    func input(for simulator: Simulator) -> any Input

    /// Produce an `Accessibility` snapshot port for the simulator.
    /// Each call returns a fresh handle; the underlying translator
    /// is a process-wide singleton, so allocations are cheap.
    func accessibility(for simulator: Simulator) -> any Accessibility
}

extension Simulators {
    /// Booted simulators — the RUNNING section of the serve UI.
    var running: [Simulator] {
        all.filter { $0.state == .booted }
    }

    /// Everything that isn't booted (shutdown, booting, shutting
    /// down) — the AVAILABLE section. Booting devices land here so
    /// the user has somewhere to see them while they come up.
    var available: [Simulator] {
        all.filter { $0.state != .booted }
    }

    /// JSON projection consumed by the `/simulators.json` endpoint.
    /// Sorted keys keep diffs and snapshot tests readable; the
    /// section split mirrors the page's RUNNING / AVAILABLE layout.
    var listJSON: String {
        let dict: [String: Any] = [
            "running":   running.map(\.dictionary),
            "available": available.map(\.dictionary),
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

private extension Simulator {
    var dictionary: [String: Any] {
        ["udid": udid, "name": name, "state": state.description, "runtime": runtime]
    }
}
