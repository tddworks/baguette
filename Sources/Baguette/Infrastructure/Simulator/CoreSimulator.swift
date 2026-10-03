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
    let metadata: SimulatorMetadata

    private let host: any DeviceHost
    private let deviceSetPath: String?

    init(
        udid: String,
        name: String,
        state: SimulatorState,
        runtime: String,
        deviceTypeName: String,
        host: any DeviceHost,
        deviceSetPath: String? = nil,
        metadata: SimulatorMetadata = SimulatorMetadata()
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.deviceTypeName = deviceTypeName
        self.metadata = metadata
        self.host = host
        self.deviceSetPath = deviceSetPath
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

    /// The device's own plane, bound before use.
    ///
    /// These used to open an unbound `SimulatorKitScreen` (largest
    /// surface each tick) and an `IndigoHIDInput` on the built-in slot.
    /// Both are right on a single-panel device and both are wrong on a
    /// foldable: iPhone Duo's largest surface and its built-in slot are
    /// the unfolded panel, dark while folded. Going through the phone
    /// `Display` binds the panel Connected Screens names `primary` for
    /// the framebuffer, and — only when there are several panels —
    /// addresses that panel's own digitizer. See `SimulatorKitDisplay`.
    func screen() -> any Screen {
        displays().phone.screen()
    }

    func input() -> any Input {
        displays().phone.input()
    }

    func displays() -> any Displays {
        SimulatorKitDisplays(
            udid: udid, host: host, hinge: hinge(), keys: GuestHingeMotor.forDevice(udid, deviceSetPath: deviceSetPath),
            deviceSetPath: deviceSetPath)
    }

    /// One monitor per device: sockets share a watch and binds read the
    /// last sample while it runs. See `SharedHinge`.
    func hinge() -> any Hinge {
        SharedHinge.forDevice(udid, make: { DevicectlHinge(udid: udid) }, motor: GuestHingeMotor.forDevice(udid, deviceSetPath: deviceSetPath))
    }

    func externalDisplays() -> any ExternalDisplays {
        HostExternalDisplays(udid: udid, deviceSetPath: deviceSetPath)
    }

    func accessibility() -> any Accessibility {
        // The observed phone panel supplies the point space, orientation
        // and identity every AX result is expressed in.
        let display = displays().phone
        return AXPTranslatorAccessibility(
            udid: udid, host: host, deviceSetPath: deviceSetPath,
            displayGeometry: { try display.observedScreen() }
        )
    }

    func logs() -> any LogStream {
        SimDeviceLogStream(udid: udid, host: host)
    }

    func orientation() -> any Orientation {
        SimulatorOrientation(
            isFoldable: { [udid, host] in
                let ports = try SimulatorKitFramebufferPorts.sizedPorts(udid: udid, host: host)
                return IntegratedPanels.several(in: ports)
            },
            motor: GuestHingeMotor.forDevice(udid, deviceSetPath: deviceSetPath),
            standard: PurpleEventOrientation(udid: udid, host: host)
        )
    }

    func statusBar() -> any StatusBar {
        SimctlStatusBar(udid: udid)
    }

    func interface() -> any Interface {
        SimctlInterface(udid: udid)
    }

    func location() -> any Location {
        SimctlLocation(udid: udid)
    }

    func shake() -> any Shake {
        SimctlShake(udid: udid)
    }

    /// Resolves the bundled `VirtualMotion.dylib` on the way through, since
    /// publishing an intent is useless without the dylib that reads it. A
    /// build that doesn't ship the dylib yields a handle whose `publish`
    /// throws `MotionError.dylibMissing` rather than silently doing nothing.
    func motion() -> any Motion {
        SharedFileMotion(
            fileURL: URL(fileURLWithPath: SharedFileMotion.path(forUDID: udid)),
            dylibPath: InjectedDylibInstaller.installIfNeeded(.motion),
            injection: SimctlSimulatorInjection()
        )
    }

    /// Resolves the bundled `VirtualNetwork.dylib` on the way through, since
    /// publishing a condition is useless without the dylib that applies it.
    /// A build that doesn't ship the dylib yields a handle whose `apply`
    /// throws `NetworkError.dylibMissing` rather than silently doing nothing
    /// — which for a throttle would be indistinguishable from working.
    func network() -> any Network {
        SharedFileNetwork(
            fileURL: URL(fileURLWithPath: SharedFileNetwork.path(forUDID: udid)),
            dylibPath: InjectedDylibInstaller.installIfNeeded(.network),
            injection: SimctlSimulatorInjection()
        )
    }

    func pasteboard() -> any Pasteboard {
        SimctlPasteboard(udid: udid)
    }

    func apps() -> any Apps {
        SimctlApps(udid: udid)
    }

    func photos() -> any PhotoLibrary {
        SimctlPhotoLibrary(udid: udid)
    }

    func watchPairing() -> any WatchPairing {
        SimctlWatchPairing(udid: udid)
    }
}
