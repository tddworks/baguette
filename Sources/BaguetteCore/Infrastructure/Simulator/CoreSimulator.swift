import Foundation
import ObjectiveC

/// Production `Simulator` — owns identity + state plus the verbs that
/// touch the booted iOS guest. Resolves a fresh `SimDevice` via
/// `host.resolveDevice(udid:)` on each operation so we never act on a
/// stale `NSObject` (CoreSimulator returns a new one when state
/// changes; clients that cached the first ref get hit with `EBADF`-ish
/// errors on subsequent calls).
///
/// Constructed by `CoreSimulators.all` — this type is the only place
/// in the codebase that knows about CoreSimulator's `bootWithError:` /
/// `shutdownWithError:` selectors, and the only place that hands raw
/// UDIDs to `SimulatorKitScreen` / `IndigoHIDInput` /
/// `AXPTranslatorAccessibility` / `SimDeviceLogStream` /
/// `PurpleEventOrientation`.
final class CoreSimulator: Simulator, @unchecked Sendable {
    let udid: String
    let name: String
    let state: SimulatorState
    let runtime: String
    let deviceTypeName: String

    private let host: any DeviceHost

    init(
        udid: String,
        name: String,
        state: SimulatorState,
        runtime: String,
        deviceTypeName: String,
        host: any DeviceHost
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.deviceTypeName = deviceTypeName
        self.host = host
    }

    func boot() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }

        // Try bootWithOptions:error: first (headless boot, persists past disconnect).
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootOpts) {
            var err: NSError?
            let opts: NSDictionary = ["persist": true]
            if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
            if let err { logErr("bootWithOptions failed: \(err)") }
        }

        let bootSel = NSSelectorFromString("bootWithError:")
        if device.responds(to: bootSel) {
            var err: NSError?
            if invokeBoolWithError(device, bootSel, &err) { return }
            if let err { logErr("bootWithError failed: \(err)") }
        }

        throw SimulatorError.bootFailed
    }

    func shutdown() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        let sel = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: sel) else { throw SimulatorError.shutdownFailed }
        var err: NSError?
        guard invokeBoolWithError(device, sel, &err) else {
            if let err { logErr("shutdownWithError failed: \(err)") }
            throw SimulatorError.shutdownFailed
        }
    }

    func screen() -> any Screen {
        SimulatorKitScreen(udid: udid, host: host)
    }

    func input() -> any Input {
        IndigoHIDInput(udid: udid, host: host)
    }

    func accessibility() -> any Accessibility {
        AXPTranslatorAccessibility(udid: udid, host: host)
    }

    func logs() -> any LogStream {
        SimDeviceLogStream(udid: udid, host: host)
    }

    func orientation() -> any Orientation {
        PurpleEventOrientation(udid: udid, host: host)
    }

    func statusBar() -> any StatusBar {
        SimctlStatusBar(udid: udid)
    }
}
