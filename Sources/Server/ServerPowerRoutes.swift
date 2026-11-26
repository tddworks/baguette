import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Boot and shutdown, for any device that registers a lifecycle — under
/// `/devices/:udid/…` and a simulator's old `/simulators/:udid/…`.
extension Server {

    /// `POST …/boot`       turn the device on, then reclaim its input
    ///                     surface if Device Hub took it
    /// `POST …/shutdown`   turn it off
    func registerPowerRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("boot") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let udid = Self.udidParam(r)
                let outcome = Self.applyPower(.boot, udid: udid, devices: devices)
                if outcome == .ok { await Self.healAfterBoot(udid: udid, devices: devices) }
                return Self.powerResponse(outcome, udid: udid)
            }
        }

        for path in Self.deviceRoutes("shutdown") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let udid = Self.udidParam(r)
                return Self.powerResponse(Self.applyPower(.shutdown, udid: udid, devices: devices), udid: udid)
            }
        }
    }

    enum PowerVerb { case boot, shutdown }

    /// One case per HTTP status a power route answers with.
    enum PowerOutcome: Equatable {
        case ok
        case unknownDevice
        /// The device can't be turned on or off.
        case refused(DeviceError)
        /// It tried and failed; what it said.
        case failed(String)
    }

    /// Turn the device on or off. Pure, so every branch is driven without
    /// booting Hummingbird.
    static func applyPower(_ verb: PowerVerb, udid: String, devices: any Devices) -> PowerOutcome {
        switch role(.power, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let power):
            do {
                switch verb {
                case .boot: try power.turnOn()
                case .shutdown: try power.turnOff()
                }
                return .ok
            } catch {
                return .failed(String(describing: error))
            }
        }
    }

    /// The heal `baguette boot` performs: nothing runs on a device that has
    /// just booted, so reclaiming its input surface from Device Hub costs
    /// nothing. Only a simulator has one; a failure is advisory, since the
    /// boot itself succeeded.
    private static func healAfterBoot(udid: String, devices: any Devices) async {
        guard let surface = try? devices.require(.inputSurface, of: DeviceID(udid)) else { return }
        do {
            if try await surface.healAfterBoot() == .reclaimed {
                log("[serve] \(HealOutcome.reclaimed.summary) for \(udid)")
            }
        } catch {
            log("[serve] input surface heal failed for \(udid): \(error)")
        }
    }

    private static func powerResponse(_ outcome: PowerOutcome, udid: String) -> Response {
        switch outcome {
        case .ok: return okJSON
        case .unknownDevice: return pluginError("unknown udid: \(udid)", status: .notFound)
        case .refused(let refusal): return Self.refusal(refusal)
        case .failed(let message): return pluginError(message, status: .internalServerError)
        }
    }
}
