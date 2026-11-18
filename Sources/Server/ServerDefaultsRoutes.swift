import BaguetteDevice
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The `UserDefaults` routes — the same three operations as `baguette
/// defaults`, for a browser editor. Kept out of `Server.swift`'s main body
/// alongside `ServerInterfaceRoutes` / `ServerDeepLinkRoutes`.
extension Server {

    /// `GET    /devices/:udid/defaults.json?bundleId=…[&suite=…][&key=…]`
    /// `POST   /devices/:udid/defaults`   `{"bundleId","suite"?,"key","type","value","relaunch"?}`
    ///                                       or `{"bundleId","suite"?,"values":{…},"relaunch"?}` to import
    /// `DELETE /devices/:udid/defaults?bundleId=…[&suite=…]&key=…[&relaunch=1|whenNeeded]`
    ///
    /// `relaunch` is `true` / `false` or `"whenNeeded"` (only for a key the
    /// running app doesn't watch); every edit answers `relaunched`.
    ///
    /// And for the focus page's Defaults card:
    /// `GET    /devices/:udid/apps.json`                       installed apps, by name
    /// `GET    /devices/:udid/defaults-groups.json?bundleId=…` the app's App Groups
    /// `POST   /devices/:udid/relaunch?bundleId=…`             quit + launch
    ///
    /// Every path keeps the udid second-to-last (one segment after it),
    /// the positional rule `udidParam` reads it by.
    ///
    /// All of them ride the browser-trust check and none is plugin-reachable:
    /// rewriting an app's preferences is not a capability any plugin
    /// declares today.
    /// The path after `/devices/:udid` (or `/simulators/:udid`) of every route registered here.
    static let defaultsRoutePaths: Set<String> = [
        "/defaults.json", "/defaults", "/apps.json", "/defaults-groups.json", "/relaunch",
    ]

    func registerDefaultsRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("defaults.json") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.defaultsResponse(await Self.readDefaults(
                    udid: Self.udidParam(r), query: Self.defaultsQuery(r), devices: devices
                ), udid: Self.udidParam(r))
            }
        }

        for path in Self.deviceRoutes("defaults") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let buffer = try? await r.body.collect(upTo: 1024 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                return Self.defaultsResponse(await Self.writeDefaults(
                    udid: Self.udidParam(r), body: body, devices: devices
                ), udid: Self.udidParam(r))
            }
        }

        for path in Self.deviceRoutes("apps.json") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.defaultsResponse(
                    await Self.installedApps(udid: Self.udidParam(r), devices: devices),
                    udid: Self.udidParam(r)
                )
            }
        }

        for path in Self.deviceRoutes("defaults-groups.json") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.defaultsResponse(await Self.defaultsGroups(
                    udid: Self.udidParam(r), query: Self.defaultsQuery(r), devices: devices
                ), udid: Self.udidParam(r))
            }
        }

        for path in Self.deviceRoutes("relaunch") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.defaultsResponse(await Self.relaunchApp(
                    udid: Self.udidParam(r), query: Self.defaultsQuery(r), devices: devices
                ), udid: Self.udidParam(r))
            }
        }

        for path in Self.deviceRoutes("defaults") {
            router.delete(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.defaultsResponse(await Self.deleteDefaults(
                    udid: Self.udidParam(r), query: Self.defaultsQuery(r), devices: devices
                ), udid: Self.udidParam(r))
            }
        }
    }

    private static func defaultsQuery(_ r: Request) -> [String: String] {
        var query: [String: String] = [:]
        for name in ["bundleId", "suite", "key", "relaunch", "plist"] {
            if let value = r.uri.queryParameters.get(name) { query[name] = String(value) }
        }
        return query
    }

    private static func defaultsResponse(_ outcome: DefaultsOutcome, udid: String) -> Response {
        switch outcome {
        case .ok(let json): return jsonResponse(json)
        case .badRequest(let message): return pluginError(message, status: .badRequest)
        case .unknownDevice: return pluginError("unknown udid: \(udid)", status: .notFound)
        case .refused(let refusal): return Self.refusal(refusal)
        case .notFound(let message): return pluginError(message, status: .notFound)
        case .conflict(let message): return pluginError(message, status: .conflict)
        case .failed(let message): return pluginError(message, status: .internalServerError)
        }
    }

    // MARK: - dispatch

    /// One case per HTTP status. Each failure carries the message the
    /// caller can act on — which app, which group, boot the device.
    enum DefaultsOutcome: Equatable {
        case ok(String)
        case badRequest(String)
        case unknownDevice
        /// The device has no defaults (or apps) to edit.
        case refused(DeviceError)
        /// The app isn't installed, or has no such App Group.
        case notFound(String)
        /// The simulator is shut down.
        case conflict(String)
        case failed(String)
    }

    /// The whole suite — with the keys the running app looks up that nothing
    /// has stored (`lookups`) — or one key as present / absent.
    static func readDefaults(
        udid: String, query: [String: String], devices: any Devices
    ) async -> DefaultsOutcome {
        let suite: PreferenceSuite
        do {
            suite = try PreferenceSuite(bundleID: query["bundleId"] ?? "", name: query["suite"])
        } catch {
            return .badRequest("\(error)")
        }
        let defaults: any Defaults
        switch role(.defaults, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): defaults = role
        }
        do {
            let preferences = try await defaults.read(suite)
            if let key = query["key"] { return .ok(jsonString(preferences.json(forKey: key))) }
            var json = preferences.json(in: suite, plist: ["1", "true"].contains(query["plist"] ?? ""))
            json["lookups"] = PreferenceLookups.json(
                try await defaults.lookups(of: suite.bundleID), unsetIn: preferences, suite: suite)
            return .ok(jsonString(json))
        } catch {
            return outcome(for: error)
        }
    }

    /// Store one typed value. `value` may be a JSON string, number or
    /// boolean; it is read as `type` either way, so `"value": 3` with
    /// `"type": "float"` stores a real.
    static func writeDefaults(
        udid: String, body: String, devices: any Devices
    ) async -> DefaultsOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
              let fields = object as? [String: Any]
        else { return .badRequest("defaults body must be a JSON object") }
        if let values = fields["values"] {
            return await importDefaults(fields: fields, values: values, udid: udid, devices: devices)
        }
        guard let key = fields["key"] as? String, !key.isEmpty else {
            return .badRequest("key is required")
        }
        guard let type = (fields["type"] as? String).flatMap(PreferenceType.init(wireName:)) else {
            let names = PreferenceType.allCases.map(\.wireName).joined(separator: " | ")
            return .badRequest("type must be one of \(names)")
        }
        guard let text = valueText(fields["value"]) else {
            return .badRequest("value is required (a string, number or boolean)")
        }
        guard let relaunch = Relaunch(wire: fields["relaunch"]) else { return Self.badRelaunch }
        let edit: PreferenceEdit
        do {
            edit = PreferenceEdit(
                suite: try PreferenceSuite(
                    bundleID: fields["bundleId"] as? String ?? "", name: fields["suite"] as? String
                ),
                key: key,
                change: .set(try PreferenceValue.parse(type: type, value: text)),
                relaunch: relaunch
            )
        } catch {
            return .badRequest("\(error)")
        }
        return await apply(edit, udid: udid, devices: devices) {
            #"{"ok":true,"relaunched":\#($0.relaunched)}"#
        }
    }

    /// A body carrying `values` (a `defaults export`'s map) writes them all,
    /// relaunching once around the batch when asked.
    private static func importDefaults(
        fields: [String: Any], values: Any, udid: String, devices: any Devices
    ) async -> DefaultsOutcome {
        guard let relaunch = Relaunch(wire: fields["relaunch"]) else { return Self.badRelaunch }
        let restore: PreferenceImport
        do {
            let map = try JSONSerialization.data(withJSONObject: ["values": values])
            restore = PreferenceImport(
                suite: try PreferenceSuite(
                    bundleID: fields["bundleId"] as? String ?? "", name: fields["suite"] as? String
                ),
                preferences: try Preferences(importing: map),
                relaunch: relaunch
            )
        } catch {
            return .badRequest("\(error)")
        }
        let found: (defaults: any Defaults, apps: any Apps)
        switch preferences(of: udid, in: devices) {
        case .answer(let outcome): return outcome
        case .found(let defaults, let apps): found = (defaults, apps)
        }
        do {
            let applied = try await restore.apply(on: found.defaults, apps: found.apps)
            return .ok(#"{"ok":true,"relaunched":\#(applied.relaunched),"written":\#(applied.written)}"#)
        } catch {
            return outcome(for: error)
        }
    }

    /// Remove one key; `removed` says whether it was stored.
    static func deleteDefaults(
        udid: String, query: [String: String], devices: any Devices
    ) async -> DefaultsOutcome {
        guard let key = query["key"], !key.isEmpty else { return .badRequest("key is required") }
        guard let relaunch = Relaunch(wire: query["relaunch"]) else { return Self.badRelaunch }
        let edit: PreferenceEdit
        do {
            edit = PreferenceEdit(
                suite: try PreferenceSuite(bundleID: query["bundleId"] ?? "", name: query["suite"]),
                key: key,
                change: .remove,
                relaunch: relaunch
            )
        } catch {
            return .badRequest("\(error)")
        }
        return await apply(edit, udid: udid, devices: devices) {
            #"{"ok":true,"relaunched":\#($0.relaunched),"removed":\#($0.changed)}"#
        }
    }

    /// Every installed app, sorted by name for a picker. `system` marks
    /// Apple's own (`com.apple.…`), so a picker can put the app under test
    /// first.
    static func installedApps(udid: String, devices: any Devices) async -> DefaultsOutcome {
        let installed: any Apps
        switch role(.apps, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): installed = role
        }
        do {
            let apps = try await installed.installed()
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { app -> [String: Any] in
                    ["bundleId": app.bundleIdentifier, "name": app.name,
                     "system": app.bundleIdentifier.hasPrefix("com.apple.")]
                }
            return .ok(jsonString(["apps": apps]))
        } catch {
            return .failed("\(error)")
        }
    }

    /// The App Groups an app has — the suites a picker offers beside its
    /// standard defaults.
    static func defaultsGroups(
        udid: String, query: [String: String], devices: any Devices
    ) async -> DefaultsOutcome {
        let bundleID: String
        do {
            bundleID = try PreferenceSuite(bundleID: query["bundleId"] ?? "").bundleID
        } catch {
            return .badRequest("\(error)")
        }
        let defaults: any Defaults
        switch role(.defaults, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): defaults = role
        }
        do {
            let groups = try await defaults.groups(of: bundleID)
            return .ok(jsonString(["bundleId": bundleID, "groups": groups]))
        } catch {
            return outcome(for: error)
        }
    }

    /// Quit and launch an app — the one-click fix when an edit was stored
    /// without `relaunch` and the running app still holds the old value.
    static func relaunchApp(
        udid: String, query: [String: String], devices: any Devices
    ) async -> DefaultsOutcome {
        let bundleID: String
        do {
            bundleID = try PreferenceSuite(bundleID: query["bundleId"] ?? "").bundleID
        } catch {
            return .badRequest("\(error)")
        }
        let apps: any Apps
        switch role(.apps, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): apps = role
        }
        do {
            try await apps.terminate(bundleID: bundleID)
            try await apps.launch(bundleID: bundleID)
            return .ok(#"{"ok":true}"#)
        } catch {
            return outcome(for: error)
        }
    }

    private static let badRelaunch = DefaultsOutcome.badRequest(#"relaunch must be true, false or "whenNeeded""#)

    private static func apply(
        _ edit: PreferenceEdit, udid: String, devices: any Devices,
        answer: (PreferenceEdit.Applied) -> String
    ) async -> DefaultsOutcome {
        let found: (defaults: any Defaults, apps: any Apps)
        switch preferences(of: udid, in: devices) {
        case .answer(let outcome): return outcome
        case .found(let defaults, let apps): found = (defaults, apps)
        }
        do {
            return .ok(answer(try await edit.apply(on: found.defaults, apps: found.apps)))
        } catch {
            return outcome(for: error)
        }
    }

    /// A device's defaults and its apps, which an edit relaunching the app
    /// needs both of — or the outcome that answers for one missing.
    private enum PreferencesLookup {
        case found(any Defaults, any Apps)
        case answer(DefaultsOutcome)
    }

    private static func preferences(of udid: String, in devices: any Devices) -> PreferencesLookup {
        switch (role(.defaults, of: udid, in: devices), role(.apps, of: udid, in: devices)) {
        case (.role(let defaults), .role(let apps)): return .found(defaults, apps)
        case (.unknownDevice, _), (_, .unknownDevice): return .answer(.unknownDevice)
        case (.refused(let refusal), _), (_, .refused(let refusal)): return .answer(.refused(refusal))
        }
    }

    private static func outcome(for error: Error) -> DefaultsOutcome {
        switch error as? DefaultsError {
        case .appNotInstalled?, .groupNotFound?: return .notFound("\(error)")
        case .deviceNotBooted?: return .conflict("\(error)")
        default: return .failed("\(error)")
        }
    }

    /// A JSON scalar as the text `PreferenceValue.parse` reads. Booleans
    /// are checked first: `NSNumber` carries them too.
    private static func valueText(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
