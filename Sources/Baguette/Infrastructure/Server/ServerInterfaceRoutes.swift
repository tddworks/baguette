import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The interface-settings routes — appearance, Increase Contrast and
/// content size. Kept out of `Server.swift`'s main body for the same
/// reason the plugin routes are: that file's router-builder inference
/// grinds once too many closures share one function.
extension Server {

    /// `GET  /devices/:udid/interface.json`   all three settings
    /// `POST /devices/:udid/interface`        set any subset
    ///
    /// Both are browser-facing and ride the existing browser-trust
    /// check. Both are also plugin-reachable under the `interface`
    /// capability — `PluginGrantMiddleware` has already turned away a
    /// plugin that didn't declare it by the time these run.
    func registerInterfaceRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("interface.json") {
            router.get(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                switch await Self.readInterface(udid: Self.udidParam(r), devices: devices) {
                case .ok(let json):
                    return Self.jsonResponse(json)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .failed(let message):
                    return Self.pluginError(message, status: .internalServerError)
                }
            }
        }

        for path in Self.deviceRoutes("interface") {
            router.post(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                guard let update = Self.parseInterfaceUpdate(json: body) else {
                    return Self.pluginError(
                        "interface body must be a JSON object naming appearance, "
                            + "increaseContrast and/or contentSize with settable values",
                        status: .badRequest
                    )
                }
                switch await Self.applyInterface(
                    udid: Self.udidParam(r), update: update, devices: devices
                ) {
                case .ok(let applied):
                    // Answer with the resulting state so a caller that just
                    // changed something doesn't need a second round-trip to
                    // re-render — and sees what actually landed, not what it
                    // asked for.
                    switch await Self.readInterface(udid: Self.udidParam(r), devices: devices) {
                    case .ok(let json):
                        return Self.jsonResponse(json)
                    default:
                        // The settings landed but the device won't say what
                        // it now reads as. Still a success — failing here
                        // would invite a retry that re-applies them — but
                        // answered in a shape that admits the read didn't
                        // happen, rather than a bare `{"ok":true}`.
                        return Self.jsonResponse(Self.appliedJSON(applied))
                    }
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .failed(let message, let applied):
                    // 500, but carrying the settings that did land — the
                    // caller can't otherwise tell a request that changed
                    // nothing from one that changed two of three.
                    return Response(
                        status: .internalServerError,
                        headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                        body: .init(byteBuffer: ByteBuffer(
                            string: Self.appliedJSON(applied, error: message)
                        ))
                    )
                }
            }
        }
    }

    // MARK: - parse

    /// Parse a `POST …/interface` body. Nil when the
    /// body isn't a JSON object, or when a field names a value that can
    /// only be read — so a bad request is refused whole rather than
    /// half-applied.
    static func parseInterfaceUpdate(json: String) -> InterfaceUpdate? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return InterfaceUpdate.from(json: object)
    }

    // MARK: - read

    enum InterfaceReadOutcome: Equatable {
        case ok(String)
        case unknownDevice
        case refused(DeviceError)
        case failed(String)
    }

    /// All three settings in one answer.
    ///
    /// A device that isn't booted reports `unknown` for each rather than
    /// failing the request — that's a state the caller needs to be able
    /// to render ("boot the device"), not an error.
    static func readInterface(
        udid: String, devices: any Devices
    ) async -> InterfaceReadOutcome {
        let interface: any Interface
        switch role(.interface, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): interface = role
        }
        do {
            let reading = InterfaceReading(
                appearance: try await interface.appearance(),
                increaseContrast: try await interface.increaseContrast(),
                contentSize: try await interface.contentSize()
            )
            return .ok(reading.json)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - apply

    enum InterfaceApplyOutcome: Equatable {
        /// Everything the body named landed. Carries the field names in
        /// the order they were applied.
        case ok(applied: [String])
        case unknownDevice
        case refused(DeviceError)
        /// A setter threw. `applied` names the settings that had
        /// already landed before it did — this request was not
        /// all-or-nothing, and a caller that assumes otherwise will
        /// re-apply settings that are already set.
        case failed(String, applied: [String])
    }

    /// Dispatch only the settings the body named. Each is its own
    /// `simctl` spawn, so a partial body means fewer spawns rather than
    /// a read-modify-write of the two it didn't mention.
    ///
    /// Three spawns is also three chances to fail halfway, and there is
    /// no rollback: `simctl ui` has no transaction. So rather than
    /// pretend, the outcome reports exactly which settings landed and
    /// stops at the first failure.
    static func applyInterface(
        udid: String, update: InterfaceUpdate, devices: any Devices
    ) async -> InterfaceApplyOutcome {
        let interface: any Interface
        switch role(.interface, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): interface = role
        }
        var applied: [String] = []
        do {
            if let appearance = update.appearance {
                try await interface.setAppearance(appearance)
                applied.append("appearance")
            }
            if let contrast = update.increaseContrast {
                try await interface.setIncreaseContrast(contrast)
                applied.append("increaseContrast")
            }
            if let contentSize = update.contentSize {
                try await interface.setContentSize(contentSize)
                applied.append("contentSize")
            }
            return .ok(applied: applied)
        } catch {
            return .failed(String(describing: error), applied: applied)
        }
    }

    /// An answer that names what actually landed.
    ///
    /// Both callers need it for the same reason: the request wasn't
    /// all-or-nothing, and the resulting state can't be shown. Used
    /// when a setter failed partway, and when every setter succeeded
    /// but the read-back afterwards didn't.
    static func appliedJSON(_ applied: [String], error: String? = nil) -> String {
        var dict: [String: Any] = ["ok": error == nil, "applied": applied]
        if let error { dict["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"applied":[]}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
