import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The screen-state routes — orientation, shake, status bar — for any
/// device, through `Devices`. Each answers under `/devices/:udid/…` and,
/// for a simulator, under its old `/simulators/:udid/…` too, so the page
/// and plugins keep working while they move.
extension Server {

    /// `POST   …/orientation?value=portrait|landscape-left|landscape-right|portrait-upside-down`
    /// `POST   …/shake`
    /// `POST   …/status-bar`   set overrides from a JSON body
    /// `GET    …/status-bar`   the current overrides, so the panel hydrates
    /// `DELETE …/status-bar`   clear them
    func registerScreenStateRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("orientation") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let value = r.uri.queryParameters.get("value") ?? ""
                switch Self.applyOrientation(udid: Self.udidParam(r), value: value, devices: devices) {
                case .ok:
                    return Self.okJSON
                case .invalidValue:
                    return Self.pluginError(
                        "value must be one of portrait, landscape-left, landscape-right, portrait-upside-down",
                        status: .badRequest)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError(
                        "orientation change failed (device configuration, event port or guest pose helper unavailable)",
                        status: .internalServerError)
                case .unconfirmed:
                    return Self.pluginError(
                        "orientation change unconfirmed: the guest pose helper timed out; read the device state before retrying",
                        status: .gatewayTimeout)
                }
            }
        }

        for path in Self.deviceRoutes("shake") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch await Self.applyShake(udid: Self.udidParam(r), devices: devices) {
                case .ok:
                    return Self.okJSON
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError("shake failed (simctl error)", status: .internalServerError)
                }
            }
        }

        // DELETE rather than a deeper `/clear` path keeps the udid
        // second-to-last, so `udidParam` reads it the same way.
        for path in Self.deviceRoutes("status-bar") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                return Self.statusBarResponse(
                    await Self.applyStatusBar(udid: Self.udidParam(r), body: body, devices: devices),
                    udid: Self.udidParam(r), failure: "status-bar override failed (simctl error)")
            }
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch await Self.readStatusBar(udid: Self.udidParam(r), devices: devices) {
                case .ok(let override):
                    return Self.jsonResponse(override.jsonString)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .failed:
                    return Self.pluginError("status-bar read failed (simctl error)", status: .internalServerError)
                }
            }
            router.delete(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.statusBarResponse(
                    await Self.clearStatusBar(udid: Self.udidParam(r), devices: devices),
                    udid: Self.udidParam(r), failure: "status-bar clear failed (simctl error)")
            }
        }
    }

    private static func statusBarResponse(_ outcome: StatusBarOutcome, udid: String, failure: String) -> Response {
        switch outcome {
        case .ok:
            return okJSON
        case .invalidBody:
            return pluginError("status-bar body must be a JSON object of valid override fields", status: .badRequest)
        case .emptyOverride:
            return pluginError("set at least one status-bar field", status: .badRequest)
        case .unknownDevice:
            return pluginError("unknown udid: \(udid)", status: .notFound)
        case .refused(let refusal):
            return Self.refusal(refusal)
        case .dispatchFailed:
            return pluginError(failure, status: .internalServerError)
        }
    }

    // MARK: - Orientation

    /// One case per HTTP status the orientation route answers with.
    enum OrientationOutcome: Equatable {
        case ok
        case invalidValue
        case unknownDevice
        /// The device can't turn, or isn't running.
        case refused(DeviceError)
        case dispatchFailed
        case unconfirmed
    }

    /// Validate `value`, find the device's orientation, and set it. Pure,
    /// so every branch is driven without booting Hummingbird.
    static func applyOrientation(udid: String, value: String, devices: any Devices) -> OrientationOutcome {
        guard let orientation = DeviceOrientation(wireName: value) else { return .invalidValue }
        switch role(.orientation, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role):
            switch role.set(orientation) {
            case .delivered: return .ok
            case .rejected: return .dispatchFailed
            case .unconfirmed: return .unconfirmed
            }
        }
    }

    // MARK: - Shake

    /// One case per HTTP status the shake route answers with.
    enum ShakeOutcome: Equatable {
        case ok
        case unknownDevice
        case refused(DeviceError)
        case dispatchFailed
    }

    /// Shake the device: a UIKit `motionShake` on a simulator.
    static func applyShake(udid: String, devices: any Devices) async -> ShakeOutcome {
        switch role(.shake, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let shake):
            do {
                try await shake.shake()
                return .ok
            } catch {
                return .dispatchFailed
            }
        }
    }

    // MARK: - Status bar

    /// One case per HTTP status the status-bar routes answer with.
    enum StatusBarOutcome: Equatable {
        case ok
        case invalidBody
        case emptyOverride
        case unknownDevice
        case refused(DeviceError)
        case dispatchFailed
    }

    /// Parse a `StatusBarOverride` from a JSON request body. Returns
    /// `nil` for malformed JSON or a present enum field with an
    /// unrecognised value — fail loud rather than silently dropping it.
    /// Numeric fields are accepted as JSON numbers; range clamping is
    /// the value type's job.
    static func parseStatusBarOverride(json: String) -> StatusBarOverride? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        var override = StatusBarOverride()
        override.time = dict["time"] as? String
        override.operatorName = dict["operatorName"] as? String
        if let raw = dict["dataNetwork"] as? String {
            guard let value = DataNetwork(wireName: raw) else { return nil }
            override.dataNetwork = value
        }
        if let raw = dict["wifiMode"] as? String {
            guard let value = WifiMode(wireName: raw) else { return nil }
            override.wifiMode = value
        }
        if let raw = dict["cellularMode"] as? String {
            guard let value = CellularMode(wireName: raw) else { return nil }
            override.cellularMode = value
        }
        if let raw = dict["batteryState"] as? String {
            guard let value = BatteryState(wireName: raw) else { return nil }
            override.batteryState = value
        }
        override.wifiBars = intField(dict["wifiBars"])
        override.cellularBars = intField(dict["cellularBars"])
        override.batteryLevel = intField(dict["batteryLevel"])
        return override
    }

    /// JSON numbers arrive as `NSNumber`; accept either an `Int` or a
    /// `Double` spelling so `3` and `3.0` both work.
    private static func intField(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// Override the device's status bar with the fields `body` sets.
    static func applyStatusBar(udid: String, body: String, devices: any Devices) async -> StatusBarOutcome {
        switch role(.statusBar, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let statusBar):
            guard let override = parseStatusBarOverride(json: body) else { return .invalidBody }
            guard !override.isEmpty else { return .emptyOverride }
            do {
                try await statusBar.override(override)
                return .ok
            } catch {
                return .dispatchFailed
            }
        }
    }

    /// Clear every override on the device's status bar.
    static func clearStatusBar(udid: String, devices: any Devices) async -> StatusBarOutcome {
        switch role(.statusBar, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let statusBar):
            do {
                try await statusBar.clear()
                return .ok
            } catch {
                return .dispatchFailed
            }
        }
    }

    /// What `GET …/status-bar` answers.
    enum StatusBarReadOutcome: Equatable {
        case ok(StatusBarOverride)
        case unknownDevice
        case refused(DeviceError)
        case failed
    }

    /// The device's current status-bar overrides.
    static func readStatusBar(udid: String, devices: any Devices) async -> StatusBarReadOutcome {
        switch role(.statusBar, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let statusBar):
            do {
                return .ok(try await statusBar.read())
            } catch {
                return .failed
            }
        }
    }
}
