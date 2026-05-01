import Foundation

/// One iOS simulator on the host. Identity (`udid`, `name`), current
/// `state`, semantic flags, and the verbs (`boot`, `shutdown`) the user
/// invokes on it.
///
/// Carries `host: any Simulators` so the verbs read as `simulator.boot()` —
/// rich-domain method dispatch on the value, with the actual work done by
/// the injected aggregate. Equality and the JSON projection ignore the
/// host, so two simulators with the same identity compare equal even when
/// produced by different aggregates (e.g. mock vs live).
struct Simulator: Sendable {
    enum State: Sendable, Equatable {
        case creating
        case shutdown
        case booting
        case booted
        case shuttingDown

        var description: String {
            switch self {
            case .creating:     return "Creating"
            case .shutdown:     return "Shutdown"
            case .booting:      return "Booting"
            case .booted:       return "Booted"
            case .shuttingDown: return "ShuttingDown"
            }
        }
    }

    let udid: String
    let name: String
    let state: State
    /// Display name of the simulator's iOS runtime — `"iOS 26.4"` etc.
    /// Surfaced in the `serve` list page's RUNTIME column. Empty
    /// string when the host didn't populate it (e.g. domain-only
    /// tests that don't care).
    let runtime: String
    let host: any Simulators

    init(
        udid: String,
        name: String,
        state: State,
        runtime: String = "",
        host: any Simulators
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.host = host
    }

    /// True iff the simulator is booted and the screen pipeline can attach.
    var canStream: Bool { state == .booted }

    /// True iff the simulator is booted and accepts host-HID input.
    var canAcceptInput: Bool { state == .booted }

    /// Compact JSON for the `list` subcommand's stdout and the
    /// `serve` list endpoint. Field order is part of the contract —
    /// callers grep for it.
    var json: String {
        "{\"udid\":\"\(udid)\",\"name\":\"\(name)\",\"state\":\"\(state.description)\",\"runtime\":\"\(runtime)\"}"
    }

    func boot() throws {
        try host.boot(self)
    }

    func shutdown() throws {
        try host.shutdown(self)
    }

    /// Subscribe to this simulator's frame stream.
    func screen() -> any Screen {
        host.screen(for: self)
    }

    /// Dispatch gestures to this simulator.
    func input() -> any Input {
        host.input(for: self)
    }

    /// Resolve the bezel layout + composite image for this simulator.
    /// Mirrors `tap.execute(on: input)` — chrome lookup is a separate
    /// concern from the runtime, so the aggregate is taken as a
    /// parameter rather than living on the `host`. Returns `nil` for
    /// devices without a matching DeviceKit chrome (e.g. Apple TV).
    func chrome(in chromes: any Chromes) -> DeviceChromeAssets? {
        chromes.assets(forDeviceName: name)
    }
}

extension Simulator: Equatable {
    static func == (lhs: Simulator, rhs: Simulator) -> Bool {
        lhs.udid == rhs.udid && lhs.name == rhs.name && lhs.state == rhs.state
    }
}

/// Failure modes the host surfaces. Each maps to a CLI exit message.
enum SimulatorError: Error, Equatable {
    case bootFailed
    case shutdownFailed
    case notFound(udid: String)
}
