import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The companion-screens route — what the focus-mode rail asks before
/// it offers anything. Kept out of `Server.swift`'s main body for the
/// same reason the interface and plugin routes are: that file's
/// router-builder inference grinds once too many closures share one
/// function.
extension Server {

    /// `GET /devices/:udid/companion-screens.json`
    ///
    /// Browser-facing only. It reports what the host has attached to a
    /// device, which is the sort of thing a plugin should have to
    /// declare a capability for, and no capability covers it yet — so
    /// it rides the browser-trust check alone.
    func registerCompanionScreenRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("companion-screens.json") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch Self.readCompanionScreens(udid: Self.udidParam(r), devices: devices) {
                case .ok(let json):
                    return Self.jsonResponse(json)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                }
            }
        }

        // Drives Simulator.app's menus, so it stays browser-only and
        // out of reach of plugins — a capability that can click another
        // application's UI is not one to hand out with a manifest line.
        // Three segments, not `…/companion-screens/carplay`: `udidParam`
        // reads the udid positionally as the second-to-last one.
        for path in Self.deviceRoutes("carplay-display") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch Self.reattachCarPlay(udid: Self.udidParam(r), devices: devices) {
                case .ok(let json):
                    return Self.jsonResponse(json)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .failed(let message):
                    // The overwhelmingly common cause is macOS refusing the
                    // Apple event, which is a permission the user grants
                    // once — so say what to do, not just what broke.
                    return Self.pluginError(
                        "could not drive Simulator.app: \(message). "
                            + "Grant Automation + Accessibility access to the terminal "
                            + "running baguette in System Settings → Privacy & Security.",
                        status: .internalServerError
                    )
                }
            }
        }
    }

    enum CompanionScreensOutcome: Equatable {
        case ok(String)
        case unknownDevice
        case refused(DeviceError)
    }

    enum CarPlayReattachOutcome: Equatable {
        /// The resulting availability, in the same shape the rail reads.
        case ok(String)
        case unknownDevice
        case refused(DeviceError)
        case failed(String)
    }

    /// Attach (or reattach) this device's CarPlay display, then say what
    /// it can do afterwards.
    ///
    /// The menu dance is baguette's to drive — it already raises the
    /// device's own window first, which is the step that goes wrong when
    /// a person does it by hand with the wrong simulator frontmost. What
    /// it can't promise is a framebuffer: the click can land and leave
    /// nothing to stream, so the answer is a fresh bind probe rather
    /// than `{"ok":true}`.
    static func reattachCarPlay(
        udid: String, devices: any Devices
    ) -> CarPlayReattachOutcome {
        let external: any ExternalDisplays
        switch role(.externalDisplays, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): external = role
        }
        do {
            try external.reattachCarPlay()
        } catch {
            return .failed(String(describing: error))
        }
        switch readCompanionScreens(udid: udid, devices: devices) {
        case .ok(let json):   return .ok(json)
        case .unknownDevice:  return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        }
    }

    /// What extra screens this device can show right now.
    ///
    /// CarPlay availability is a **bind**, not a name lookup.
    /// `ExternalDisplays.isCarPlayConnected` answers the easier question
    /// — does Connected Screens list something of that type — and a
    /// device can carry a registered CarPlay screen with no framebuffer
    /// behind it, left over from an enable whose host window has gone.
    /// The host is quite clear about it (`simctl screenshot` on that
    /// screen fails with "Timeout waiting for screen surfaces"), but the
    /// name is still in the list. Believing the name lights the rail and
    /// opens a pane that can never paint.
    ///
    /// So we ask the same `resolve()` the stream asks. If it can't bind,
    /// the stream couldn't either, and the useful answer is the
    /// instructions for attaching a working one.
    ///
    /// Only an unknown udid fails. Both probes answer "no" rather than
    /// throwing — a shutdown device resolves nothing, and an unreadable
    /// pairing table yields no watch — so a device that is merely off
    /// still gets a renderable answer instead of a 500 the rail would
    /// have to guess at.
    static func readCompanionScreens(
        udid: String, devices: any Devices
    ) -> CompanionScreensOutcome {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            return .unknownDevice
        }
        // The device's own abilities, not `require`: a device that is merely
        // off still answers (it resolves no CarPlay screen), as the rail
        // needs; one that has no displays at all is refused by name.
        let displays: any Displays
        let pairing: any WatchPairing
        do {
            displays = try device.abilities.require(.displays)
            pairing = try device.abilities.require(.watchPairing)
        } catch let refusal as DeviceError {
            return .refused(refusal)
        } catch {
            return .unknownDevice
        }
        // The binding's own size, so the rail can name what it bound
        // rather than assume the menu attached a CarPlay-shaped screen.
        let screens = CompanionScreens(
            externalSize: (try? displays.carPlay.resolve())?.size,
            watch: pairing.watch
        )
        return .ok(screens.json)
    }
}
