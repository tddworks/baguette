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

    /// Catalog identity from the installed device type and runtime.
    /// Stable across `simctl` renames, unlike `name`; fields the host
    /// did not populate are `nil`.
    var metadata: SimulatorMetadata { get }

    func boot() throws
    func shutdown() throws

    /// Subscribe to this simulator's frame stream. Each call returns
    /// a fresh pipeline; multiple parallel streams are supported.
    /// Legacy phone alias — equivalent to `displays().phone.screen()`
    /// once Infra wires the display aggregate.
    func screen() -> any Screen

    /// Dispatch gestures to this simulator.
    /// Legacy phone alias — equivalent to `displays().phone.input()`
    /// once Infra wires the display aggregate.
    func input() -> any Input

    /// Display planes for this simulator (phone + CarPlay aggregates).
    func displays() -> any Displays

    /// The device's hinge — meaningful on a foldable, where its angle
    /// decides which panel the phone plane binds. Read-only today.
    func hinge() -> any Hinge

    /// Host external-display panel (CarPlay enablement).
    func externalDisplays() -> any ExternalDisplays

    /// Read this simulator's on-screen UI tree (labels, frames,
    /// traits). Each call returns a fresh handle; the underlying
    /// translator is a process-wide singleton.
    func accessibility() -> any Accessibility

    /// Subscribe to this simulator's unified-log feed. Each call
    /// returns a fresh handle; multiple parallel subscribers are
    /// supported (each spawns its own `/usr/bin/log stream` child).
    func logs() -> any LogStream

    /// Drive this simulator's physical orientation.
    func orientation() -> any Orientation

    /// Override this simulator's status bar (time, carrier, network,
    /// signal bars, battery) or clear back to live values. Each call
    /// returns a fresh handle; the underlying `simctl status_bar`
    /// invocation is stateless.
    func statusBar() -> any StatusBar

    /// Read or set this simulator's interface settings — appearance
    /// style (light / dark), Increase Contrast, and content size
    /// (Dynamic Type). Each call returns a fresh handle; the underlying
    /// `simctl ui` invocation is stateless.
    func interface() -> any Interface

    /// Drive this simulator's simulated GPS location — pin a single
    /// point, run a moving route, or clear back to the live value. Each
    /// call returns a fresh handle; the underlying `simctl location`
    /// invocation is stateless.
    func location() -> any Location

    /// Drive what this simulator's apps read from CoreMotion — activity,
    /// pedometer counters and device-motion samples. Unlike `location()`
    /// there is no `simctl` verb behind it: the surface is unavailable in a
    /// stock simulator, so it works by injecting a dylib into apps. Each
    /// call returns a fresh handle; the state lives in the published intent
    /// file, not the handle.
    func motion() -> any Motion

    /// Condition what this simulator's apps see of the network — latency,
    /// downlink bandwidth, request loss, and hard offline. Like `motion()`
    /// there is no `simctl` verb behind it, and for a sharper reason: the
    /// host's own tooling for this is system-wide, so scoping it to one
    /// simulator means injecting into the app under test. Each call returns
    /// a fresh handle; the state lives in the published condition file, not
    /// the handle.
    func network() -> any Network

    /// This simulator's shared pasteboard — set plain text, read it
    /// back, or sync the host Mac's full pasteboard across (images
    /// included). Each call returns a fresh handle; the underlying
    /// `simctl pbcopy | pbpaste | pbsync` invocation is stateless.
    func pasteboard() -> any Pasteboard

    /// The apps installed on this simulator — install an `AppBundle`
    /// (`.ipa` / `.app`). Each call returns a fresh handle; the
    /// underlying `simctl install` invocation is stateless.
    func apps() -> any Apps

    /// This simulator's photo library — import a `MediaItem` (image or
    /// video). Each call returns a fresh handle; the underlying `simctl
    /// addmedia` invocation is stateless.
    func photos() -> any PhotoLibrary

    /// Deliver a motion shake to the booted simulator — the same signal
    /// as Simulator.app's "Device → Shake". Each call returns a fresh
    /// handle; the underlying `simctl spawn notifyutil` invocation is
    /// stateless.
    func shake() -> any Shake

    /// This phone's side of the host's watch pairing table. Each call
    /// returns a fresh handle; the underlying `simctl list pairs`
    /// invocation is stateless.
    func watchPairing() -> any WatchPairing
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

    /// Inverse of `description` — reads the state strings the host's
    /// own JSON tools print (`simctl list -j`, `simctl list pairs -j`).
    /// A word we don't model reads as `.shutdown`: an unrecognised
    /// state is not one we can act on, which is what shutdown already
    /// means to every caller.
    static func named(_ raw: String) -> SimulatorState {
        switch raw {
        case "Creating":     return .creating
        case "Booting":      return .booting
        case "Booted":       return .booted
        case "ShuttingDown": return .shuttingDown
        default:             return .shutdown
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
        chrome(in: chromes, panel: litPanel(in: chromes))
    }

    /// One named panel's chrome, hinge not consulted. Image routes take
    /// the panel from the URL the definition handed out, so a cached
    /// `bezel.png` can never be the other panel's.
    func chrome(in chromes: any Chromes, panel: IntegratedPanel) -> DeviceChromeAssets? {
        switch panel {
        case .primary:   return chromes.assets(forDeviceName: deviceTypeName)
        case .secondary: return chromes.assets(forDeviceName: deviceTypeName, panel: .secondary)
        }
    }

    /// Which of this device's panels the chrome, screen and tap space
    /// describe right now.
    ///
    /// One panel is the only answer on every device but a foldable,
    /// and it is answered from the profile alone. A foldable asks its
    /// hinge — a devicectl round-trip — and takes no reading as folded,
    /// which is how the device boots.
    func litPanel(in chromes: any Chromes) -> IntegratedPanel {
        guard chromes.panels(forDeviceName: deviceTypeName).contains(.secondary) else {
            return .primary
        }
        return hinge().angle()?.litPanel ?? .primary
    }

    /// Resolve the installed 3D model for this simulator. Device type
    /// is stable across simulator renames, so a definition that targets
    /// a named device is matched against the type name first; the
    /// visible name remains a fallback for definitions that only know
    /// the user-given name.
    func deviceModel(in models: any DeviceModels) throws -> InstalledDeviceModel? {
        try models.match(deviceType: deviceTypeName, deviceName: deviceTypeName)
            ?? models.match(deviceType: deviceTypeName, deviceName: name)
    }
}

/// Failure modes the host surfaces. Each maps to a CLI exit message.
enum SimulatorError: Error, Equatable {
    case bootFailed
    case shutdownFailed
    case notFound(udid: String)
}
