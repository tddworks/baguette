import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// A foldable's hinge — read and driven — for any device, through
/// `Devices`, under `/devices/:udid/hinge` and a simulator's old
/// `/simulators/:udid/hinge`. A device that doesn't fold answers
/// `foldable:false` and is never asked again.
extension Server {

    func registerHingeRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices
        let chromes = self.chromes

        // Hinge — a foldable's pose. The page polls this on iPhone Duo so
        // that when Device Hub folds or unfolds the device, the stream,
        // the bezel and the tap space follow the newly lit panel; every
        // other device answers `foldable:false` once and is never asked
        // again.
        for path in Self.deviceRoutes("hinge") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                guard let json = Self.hingeJSON(
                    udid: Self.udidParam(r), devices: devices, chromes: chromes
                ) else {
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                }
                return Self.jsonResponse(json)
            }
        }
        // Move the hinge — Device Hub's pose picker, over HTTP:
        // `?pose=closed|open|flat` or `?angle=<0–180>`, `&duration=<s>`.
        // Blocks for the sweep (Device Hub's 0.8 s by default).
        for path in Self.deviceRoutes("hinge") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let q = r.uri.queryParameters
                switch Self.driveHinge(
                    udid: Self.udidParam(r), pose: q.get("pose"), angle: q.get("angle"),
                    duration: q.get("duration"), devices: devices
                ) {
                case .ok:
                    return Self.okJSON
                case .invalid(let reason):
                    return Self.pluginError(Self.hingeCommandMessage(reason), status: .badRequest)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .failed(let error):
                    return Self.pluginError("hinge could not be driven: \(error)", status: .internalServerError)
                case .unconfirmed:
                    return Self.pluginError(
                        "hinge move unconfirmed: the guest pose helper timed out; read the hinge before retrying",
                        status: .gatewayTimeout
                    )
                }
            }
        }
    }

    enum HingeDriveOutcome: Equatable {
        case ok
        case invalid(HingeCommandError)
        case unknownDevice
        case refused(DeviceError)
        case failed(HingeError)
        /// The helper timed out and was stopped; the move may have landed.
        case unconfirmed
    }

    /// Pure dispatch for `POST …/hinge` and the 3D
    /// socket's `set_pose`: parse the pose or angle, find the device,
    /// sweep its hinge. Blocks for the sweep.
    static func driveHinge(
        udid: String, pose: String?, angle: String?, duration: String?,
        devices: any Devices
    ) -> HingeDriveOutcome {
        let command: HingeCommand
        do {
            command = try HingeCommand.parse(pose: pose, angle: angle, duration: duration)
        } catch let error as HingeCommandError {
            return .invalid(error)
        } catch {
            return .invalid(.missingTarget)
        }
        let hinge: any Hinge
        switch role(.hinge, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): hinge = role
        }
        do {
            try hinge.fold(to: command.degrees, over: command.duration)
            return .ok
        } catch {
            guard PoseDelivery(failure: error) != .unconfirmed else { return .unconfirmed }
            return .failed(error as? HingeError ?? .toolFailed(status: -1))
        }
    }

    /// Pure data producer for `GET …/hinge`.
    ///
    /// `foldable` comes from the profile (does the device have a second
    /// panel), `angleDegrees` from the hinge — `null` when no reading
    /// arrived, which on a foldable means "as booted" — and `litPanel`
    /// is the one the chrome, screen and tap space currently describe.
    /// A single-panel device's hinge is never consulted.
    static func hingeJSON(
        udid: String, devices: any Devices, chromes: any Chromes
    ) -> String? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else { return nil }
        // Every device answers; only one whose bezel has a second panel
        // folds, and only it is asked for its hinge and its phone plane.
        let foldable = chromes.panels(forDeviceName: device.kind.model).contains(.secondary)
        let angle = foldable ? (try? device.require(.hinge))?.angle() : nil
        let degrees = angle.map { "\($0.degrees)" } ?? "null"
        let lit = angle?.litPanel ?? .primary
        // The guest turns the unfolded panel to landscape on its own, so
        // the page has to be told which way it faces; the binding of the
        // phone plane carries what Connected Screens reports.
        let orientation = (foldable ? try? device.require(.displays).phone.resolve() : nil)?
            .orientation.map { "\"\($0.wireName)\"" } ?? "null"
        return #"{"ok":true,"foldable":\#(foldable),"angleDegrees":\#(degrees),"#
            + #""litPanel":"\#(lit == .primary ? "primary" : "secondary")","orientation":\#(orientation)}"#
    }
}
