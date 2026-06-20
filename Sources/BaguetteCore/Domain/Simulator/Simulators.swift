import Foundation
import Mockable

/// The host's collection of simulators — a true DDD repository.
/// Lists what's available and finds by UDID; capability factories
/// (`screen`, `input`, `orientation`, …) live on `Simulator` itself.
///
/// `@Mockable` so domain tests can drive the aggregate without
/// CoreSimulator. Class-bound (`AnyObject`) because the production
/// impl `CoreSimulators` is reference-typed.
@Mockable
protocol Simulators: AnyObject, Sendable {
    var all: [any Simulator] { get }
    func find(udid: String) -> (any Simulator)?
}

extension Simulators {
    /// Booted simulators — the RUNNING section of the serve UI.
    var running: [any Simulator] {
        all.filter { $0.state == .booted }
    }

    /// Everything that isn't booted (shutdown, booting, shutting
    /// down) — the AVAILABLE section. Booting devices land here so
    /// the user has somewhere to see them while they come up.
    var available: [any Simulator] {
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
