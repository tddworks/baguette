import Foundation
import Mockable

/// One iOS simulator on the host. Identity (`udid`, `name`), current
/// `state`, runtime, and the verbs (`boot`, `shutdown`, `screen`, …)
/// the user invokes on it.
///
/// `@Mockable` so domain tests can drive simulators without
/// CoreSimulator. The production impl is `CoreSimulator`
/// (Infrastructure) which holds a `DeviceHost` and resolves a fresh
/// `SimDevice` on each operation.
@Mockable
protocol Simulator: Sendable {
    var udid: String { get }
    var name: String { get }
    var state: SimulatorState { get }

    /// Display name of the simulator's iOS runtime — `"iOS 26.4"`
    /// etc. Surfaced in the serve list page's RUNTIME column. Empty
    /// string when the host didn't populate it.
    var runtime: String { get }

    /// CoreSimulator device-type name — e.g. `"iPhone 17 Pro Max"` —
    /// the stable filename of the `.simdevicetype` bundle that owns
    /// this device's chrome. The user-given `name` drifts on `simctl
    /// clone` / rename, so chrome lookup keys off this instead.
    var deviceTypeName: String { get }

    func boot() throws
    func shutdown() throws

    /// Subscribe to this simulator's frame stream. Each call returns
    /// a fresh pipeline; multiple parallel streams are supported.
    func screen() -> any Screen

    /// Dispatch gestures to this simulator.
    func input() -> any Input

    /// Read this simulator's on-screen UI tree (labels, frames,
    /// traits). Each call returns a fresh handle; the underlying
    /// translator is a process-wide singleton.
    func accessibility() -> any Accessibility

    /// Subscribe to this simulator's unified-log feed. Each call
    /// returns a fresh handle; multiple parallel subscribers are
    /// supported (each spawns its own `/usr/bin/log stream` child).
    func logs() -> any LogStream

    /// Drive this simulator's interface orientation. Each call
    /// returns a fresh handle; the underlying GSEvent dispatch is
    /// stateless.
    func orientation() -> any Orientation

    /// Override this simulator's status bar (time, carrier, network,
    /// signal bars, battery) or clear back to live values. Each call
    /// returns a fresh handle; the underlying `simctl status_bar`
    /// invocation is stateless.
    func statusBar() -> any StatusBar
}

/// `Simulator.State` lifted to a top-level enum so the protocol can
/// declare it as a property type.
enum SimulatorState: Sendable, Equatable {
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

extension Simulator {
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

    /// Resolve the bezel layout + composite image for this
    /// simulator. Mirrors `tap.execute(on: input)` — chrome lookup
    /// is a separate concern from the runtime, so the aggregate is
    /// taken as a parameter rather than living on the simulator.
    /// Returns `nil` for devices without a matching DeviceKit chrome
    /// (e.g. Apple TV).
    func chrome(in chromes: any Chromes) -> DeviceChromeAssets? {
        chromes.assets(forDeviceName: deviceTypeName)
    }
}

/// Failure modes the host surfaces. Each maps to a CLI exit message.
enum SimulatorError: Error, Equatable {
    case bootFailed
    case shutdownFailed
    case notFound(udid: String)
}
