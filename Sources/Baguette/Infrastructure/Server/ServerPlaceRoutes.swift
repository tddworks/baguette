import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Where the device is and how it moves — location, motion, network — for
/// any device, through `Devices`, under `/devices/:udid/…` and a
/// simulator's old `/simulators/:udid/…`.
extension Server {

    func registerPlaceRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices
        let motionSessions = self.motionSessions

        // Location — `POST` sets the simulated GPS position (a single
        // point; a moving route when the body carries `waypoints`; or the
        // joystick's walk vector when it carries `bearing`); `DELETE`
        // clears it back to live. Backed by `simctl location`; pure parse
        // + dispatch lives in `Server.applyLocation` / `clearLocation`
        // for unit testing.
        for path in Self.deviceRoutes("location") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                switch await Self.applyLocation(
                    udid: Self.udidParam(r), body: body, devices: devices,
                    sessions: motionSessions
                ) {
                case .ok:
                    return Self.okJSON
                case .invalidBody:
                    return Self.pluginError("location body must be a point {latitude,longitude}, a {waypoints:[…]} route, or a {latitude,longitude,bearing,speed} walk", status: .badRequest)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError("location change failed (simctl error)", status: .internalServerError)
                }
            }
        }
        for path in Self.deviceRoutes("location") {
            router.delete(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch await Self.clearLocation(udid: Self.udidParam(r), devices: devices,
                                                sessions: motionSessions) {
                case .ok:
                    return Self.okJSON
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError("location clear failed (simctl error)", status: .internalServerError)
                case .invalidBody:
                    return Self.okJSON // unreachable for clear; keep the switch total
                }
            }
        }

        // Motion — `POST` arms the injected dylib and states what the device
        // is doing; `DELETE` parks it as stationary and disarms. Once armed,
        // the location routes above drive the activity from the speed the
        // device is moving at, so the browser's joystick needs no new wire.
        //
        // Unlike location there is no simctl verb behind this: all three
        // CoreMotion surfaces report unavailable in a stock simulator. Only
        // apps launched *after* the POST see anything — dyld inserts at exec
        // time. See `docs/features/motion/README.md`.
        for path in Self.deviceRoutes("motion") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                switch await Self.applyMotion(
                    udid: Self.udidParam(r), body: body, devices: devices,
                    sessions: motionSessions
                ) {
                case .ok:
                    return Self.jsonResponse(
                        await Self.motionStateJSON(udid: Self.udidParam(r), sessions: motionSessions))
                case .invalidBody:
                    return Self.pluginError(
                        "motion body must name an activity: stationary, walking, running, cycling, or automotive",
                        status: .badRequest)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError(
                        "motion failed — is VirtualMotion.dylib bundled in this build?",
                        status: .internalServerError)
                }
            }
        }
        // Read-back for the card's readout — the one place motion differs
        // from location, which has no GET because simctl cannot report the
        // active position. Here the state is ours, so we can answer.
        for path in Self.deviceRoutes("motion") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                guard let json = await Self.motionState(
                    udid: Self.udidParam(r), devices: devices, sessions: motionSessions
                ) else {
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                }
                return Self.jsonResponse(json)
            }
        }
        for path in Self.deviceRoutes("motion") {
            router.delete(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch await Self.stopMotion(udid: Self.udidParam(r), devices: devices,
                                             sessions: motionSessions) {
                case .ok:
                    return Self.okJSON
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .invalidBody, .dispatchFailed:
                    return Self.pluginError("motion stop failed", status: .internalServerError)
                }
            }
        }

        // Network conditioning — `POST` arms the injected dylib and states
        // how degraded the network is; `GET` reports what this simulator is
        // actually subject to; `DELETE` stops conditioning, including for
        // apps that are already running.
        //
        // Like motion there is no simctl verb behind this, and for a
        // sharper reason: the host's own tooling (Network Link Conditioner,
        // and the dnctl/pfctl rules under it) is system-wide, so scoping to
        // one simulator means injecting into the app under test. Only apps
        // launched *after* the POST are conditioned — dyld inserts at exec
        // time — though changing the condition afterwards reaches a running
        // app fine. See `docs/features/network/README.md`.
        for path in Self.deviceRoutes("network") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                switch await Self.applyNetwork(
                    udid: Self.udidParam(r), body: body, devices: devices
                ) {
                case .ok:
                    do {
                        guard let json = try await Self.networkStateJSON(
                            udid: Self.udidParam(r), devices: devices
                        ) else {
                            return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                        }
                        return Self.jsonResponse(json)
                    } catch {
                        return Self.pluginError(
                            "network condition applied; status read-back failed: \(error)",
                            status: .internalServerError)
                    }
                case .invalidBody:
                    return Self.pluginError(
                        "network body must name exactly one of: a profile "
                        + "(\"profile\":\"3g\"), explicit numbers (\"latencyMs\", "
                        + "\"bandwidthKbps\", \"lossPercent\"), or \"offline\":true",
                        status: .badRequest)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError(
                        "network conditioning failed — is VirtualNetwork.dylib bundled "
                        + "in this build?",
                        status: .internalServerError)
                }
            }
        }
        // Read-back for the card's readout and, more to the point, its armed
        // badge. A throttle nobody remembers arming presents as "the app is
        // slow", so the UI has to be able to say plainly that one is on.
        for path in Self.deviceRoutes("network") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                do {
                    guard let json = try await Self.networkStateJSON(
                        udid: Self.udidParam(r), devices: devices
                    ) else {
                        return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                    }
                    return Self.jsonResponse(json)
                } catch let refusal as DeviceError {
                    return Self.refusal(refusal)
                } catch {
                    // An unreadable injection state is not "no conditioning".
                    return Self.pluginError("network status failed: \(error)", status: .internalServerError)
                }
            }
        }
        for path in Self.deviceRoutes("network") {
            router.delete(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                switch await Self.clearNetwork(udid: Self.udidParam(r), devices: devices) {
                case .ok:
                    return Self.okJSON
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .invalidBody, .dispatchFailed:
                    return Self.pluginError("network clear failed", status: .internalServerError)
                }
            }
        }

    }

    // MARK: - Location routes

    /// A parsed location request — a single point (`set`), a moving route
    /// (`start`), or the browser joystick's walk vector. The route body is
    /// distinguished by a `waypoints` array and the walk by a `bearing`;
    /// otherwise a bare `latitude`/`longitude` pair is a point.
    enum LocationRequest: Equatable {
        case point(Coordinate)
        case route(LocationRoute)
        case walk(LocationWalk)
    }

    /// Outcome of the location routes — one case per HTTP-status branch.
    enum LocationOutcome: Equatable {
        case ok
        case invalidBody
        case unknownDevice
        /// The device can't be placed, or isn't running.
        case refused(DeviceError)
        case dispatchFailed
    }

    /// Parse a `LocationRequest` from a JSON request body. Returns `nil`
    /// for malformed JSON, an out-of-range point, a route with fewer
    /// than two valid waypoints, or a walk with no positive speed — fail
    /// loud rather than silently dropping it. Numbers arrive as JSON
    /// numbers; `Coordinate` / `LocationRoute` / `LocationWalk` own the
    /// validation.
    ///
    /// Order matters. A walk body carries `latitude`/`longitude` just
    /// like a point does, so `bearing` has to be read *before* the bare
    /// point branch — otherwise every joystick vector would parse as a
    /// stationary point and the device would never move.
    static func parseLocationRequest(json: String) -> LocationRequest? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        if let raw = dict["waypoints"] as? [Any] {
            let coords = raw.compactMap { coordinateFromJSON($0) }
            guard coords.count == raw.count else { return nil }
            guard let route = LocationRoute(
                waypoints: coords,
                speed: doubleField(dict["speed"]),
                distance: doubleField(dict["distance"]),
                interval: doubleField(dict["interval"])
            ) else { return nil }
            return .route(route)
        }
        if let bearing = doubleField(dict["bearing"]) {
            guard let origin = coordinateFromJSON(object),
                  let speed = doubleField(dict["speed"]),
                  let walk = LocationWalk(
                      origin: origin, bearing: Bearing(degrees: bearing), speed: speed
                  ) else { return nil }
            return .walk(walk)
        }
        guard let coordinate = coordinateFromJSON(object) else { return nil }
        return .point(coordinate)
    }

    /// Build a `Coordinate` from a `{"latitude":…,"longitude":…}` JSON
    /// object, validating the range. Returns `nil` for a non-object or an
    /// out-of-range pair.
    private static func coordinateFromJSON(_ value: Any) -> Coordinate? {
        guard let dict = value as? [String: Any],
              let lat = doubleField(dict["latitude"]),
              let lon = doubleField(dict["longitude"]) else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// JSON numbers arrive as `NSNumber`; accept either a `Double` or an
    /// `Int` spelling so `1` and `1.0` both work.
    private static func doubleField(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// Pure parse + dispatch for `POST …/location`, so unit tests drive
    /// every branch with one device's `MockLocation`.
    ///
    /// When `sessions` carries a **running** motion session for this device,
    /// the same request also drives motion: the browser keeps posting the
    /// walk vector it always did, and the activity follows from its speed.
    /// A session is never created here — motion stays opt-in.
    static func applyLocation(
        udid: String,
        body: String,
        devices: any Devices,
        sessions: MotionSessions? = nil
    ) async -> LocationOutcome {
        let location: any Location
        switch role(.location, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): location = role
        }
        guard let request = parseLocationRequest(json: body) else {
            return .invalidBody
        }
        do {
            switch request {
            case .point(let coordinate): try await location.set(coordinate)
            case .route(let route): try await location.start(route)
            // A walk is a route — projected over the horizon along its
            // bearing — so the joystick reuses the `start` path that makes
            // locationd derive course, rather than the `set` path that
            // reports course = -1.
            case .walk(let walk): try await location.start(walk.route())
            }
        } catch {
            return .dispatchFailed
        }
        await driveMotion(with: request, on: udid, sessions: sessions)
        return .ok
    }

    /// The speed a location request moves the device at, which is what
    /// classifies the motion. A pinned point isn't travelling at all —
    /// locationd reports `course = -1` for it — so it parks motion rather
    /// than leaving a stale walk running.
    private static func driveMotion(
        with request: LocationRequest,
        on udid: String,
        sessions: MotionSessions?
    ) async {
        guard let sessions else { return }
        guard let session = await sessions.active(udid: udid) else { return }
        let speed: Double
        switch request {
        case .point: speed = 0
        // An untuned route runs at simctl's own default of 20 m/s, which is
        // motorway-ish — so an untuned route reads as automotive, not as a
        // stroll.
        case .route(let route): speed = route.speed ?? 20
        case .walk(let walk): speed = walk.speed
        }
        await session.drive(speed: speed)
    }

    /// Pure dispatch for `DELETE /simulators/:udid/location`.
    ///
    /// Dropping the location override also parks motion: the device has
    /// stopped being driven anywhere, so an app shouldn't keep reading a
    /// walk.
    static func clearLocation(
        udid: String,
        devices: any Devices,
        sessions: MotionSessions? = nil
    ) async -> LocationOutcome {
        let location: any Location
        switch role(.location, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): location = role
        }
        do {
            try await location.clear()
        } catch {
            return .dispatchFailed
        }
        if let session = await sessions?.active(udid: udid) {
            await session.drive(speed: 0)
        }
        return .ok
    }

    // MARK: - motion

    /// A parsed `POST /simulators/:udid/motion` body.
    struct MotionRequest: Equatable {
        let kind: MotionKind
        let confidence: MotionConfidence
        let speed: Double
    }

    /// Parse a `MotionRequest` from either spelling:
    ///
    /// - `{"activity":"running"}` — names the kind outright, as the CLI
    ///   does. Its speed defaults to that kind's usual pace.
    /// - `{"speed":6}` — names only how fast the device is moving, as the
    ///   **browser** does, and the kind is classified here.
    ///
    /// The second spelling is what keeps `MotionKind`'s thresholds out of
    /// the frontend: the card posts the speed it's already set to move at,
    /// exactly as it posts walk vectors, and Swift owns the classification.
    /// Two copies of those bands would drift.
    ///
    /// An `activity` that names no real kind is a `400` rather than a
    /// silent `unknown`, which would look like the feature was working.
    static func parseMotionRequest(json: String) -> MotionRequest? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        // A supplied-but-unknown confidence is rejected rather than quietly
        // downgraded to `high` — reporting a confidence nobody asked for is
        // worse than refusing the request.
        let confidence: MotionConfidence
        if let word = dict["confidence"] as? String {
            guard let parsed = MotionConfidence(rawValue: word) else { return nil }
            confidence = parsed
        } else {
            confidence = .high
        }
        // A negative speed classifies as `unknown`, which would arm a session
        // that reports no motion at all — indistinguishable from a broken
        // feature. CoreLocation's "-1 means I don't know" has no meaning as
        // an *instruction*.
        let speed = doubleField(dict["speed"])
        if let speed, speed < 0 { return nil }
        if let activity = dict["activity"] as? String {
            guard let kind = MotionKind(rawValue: activity), kind != .unknown else { return nil }
            return MotionRequest(
                kind: kind, confidence: confidence,
                speed: speed ?? MotionCommand.defaultSpeed(for: kind))
        }
        guard let speed else { return nil }
        return MotionRequest(kind: .from(speed: speed), confidence: confidence, speed: speed)
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/motion` — arms the
    /// dylib and states what the device is doing. Creates the session, so
    /// this is the one place motion turns on.
    static func applyMotion(
        udid: String,
        body: String,
        devices: any Devices,
        sessions: MotionSessions
    ) async -> LocationOutcome {
        let motion: any Motion
        switch role(.motion, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): motion = role
        }
        guard let request = parseMotionRequest(json: body) else {
            return .invalidBody
        }
        let session = await sessions.session(for: udid, motion: { motion })
        let name = deviceName(udid, in: devices)
        await session.set(kind: request.kind, confidence: request.confidence,
                          speed: request.speed)
        // Say what was armed. Injection only takes effect on the next app
        // launch, so when someone reports "my app sees nothing" this line is
        // the first thing worth checking.
        if let failure = await session.lastError {
            log("motion: failed to arm \(name) — \(failure)")
            return .dispatchFailed
        }
        log("motion: \(name) is \(request.kind.rawValue) at \(request.speed) m/s")
        return .ok
    }

    /// Pure dispatch for `DELETE /simulators/:udid/motion` — parks the
    /// device as stationary, disarms the dylib, and forgets the session so a
    /// later walk stops driving it.
    static func stopMotion(
        udid: String,
        devices: any Devices,
        sessions: MotionSessions
    ) async -> LocationOutcome {
        let motion: any Motion
        switch role(.motion, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): motion = role
        }
        // A restarted server has no session in memory, but the guest is
        // still reading the intent it published; an explicit stop must
        // park and disarm regardless. Keep the session when the stop
        // failed, so a retry still has something to disarm — dropping it
        // would strand an armed dylib with nothing tracking it.
        let session = await sessions.session(for: udid, motion: { motion })
        guard await session.stop() else { return .dispatchFailed }
        await sessions.end(udid: udid)
        return .ok
    }

    /// The `{"activity":…,"steps":…}` payload the browser's readout shows, or
    /// `nil` when no such device exists — the caller turns that into the
    /// same `404` the POST and DELETE routes give, rather than reporting an
    /// unknown device as one with motion switched off.
    static func motionState(udid: String, devices: any Devices,
                            sessions: MotionSessions) async -> String? {
        guard !udid.isEmpty, (try? devices.find(id: DeviceID(udid))) != nil else { return nil }
        return await motionStateJSON(udid: udid, sessions: sessions)
    }

    static func motionStateJSON(udid: String, sessions: MotionSessions) async -> String {
        guard let session = await sessions.active(udid: udid) else {
            return #"{"ok":true,"active":false}"#
        }
        let kind: String
        switch await session.phase {
        case .idle: kind = MotionKind.stationary.rawValue
        case .publishing(let k): kind = k.rawValue
        }
        let steps = await session.steps
        let metres = await session.metres
        let speed = await session.speed
        return #"{"ok":true,"active":true,"activity":"\#(kind)","steps":\#(steps),"#
            + #""metres":\#(String(format: "%.1f", metres)),"#
            + #""speed":\#(String(format: "%.2f", speed))}"#
    }

    // MARK: - network

    /// Parse a `NetworkCondition` from one of three spellings:
    ///
    /// - `{"profile":"3g"}` — a named preset, resolved here so Network Link
    ///   Conditioner's figures live in Swift alone and never get copied into
    ///   JavaScript where the two would drift.
    /// - `{"latencyMs":300,"bandwidthKbps":400,"lossPercent":5}` — explicit.
    /// - `{"offline":true}`.
    ///
    /// **Exactly one** of those, matching the CLI: "3G but lossier" reads
    /// like it ought to work, and once it does, whether the preset or the
    /// field wins becomes something a caller has to remember. A body that
    /// conditions nothing is a `400` rather than a no-op, because arming
    /// costs an app relaunch and achieving nothing visible would look like
    /// the feature being broken.
    ///
    /// `"offline":false` is *not* a source: the browser card posts its whole
    /// form, so that key arrives alongside real numbers on every ordinary
    /// request, and counting it would make each of those a conflict.
    static func parseNetworkRequest(json: String) -> NetworkCondition? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        let latency = doubleField(dict["latencyMs"])
        let bandwidth = doubleField(dict["bandwidthKbps"])
        let loss = doubleField(dict["lossPercent"])
        let profile = dict["profile"] as? String
        let offline = (dict["offline"] as? Bool) == true
        let namesNumbers = latency != nil || bandwidth != nil || loss != nil

        let sources = [profile != nil, offline, namesNumbers].filter { $0 }.count
        guard sources == 1 else { return nil }

        if let profile { return NetworkProfile(rawValue: profile)?.condition }
        if offline { return .offline }
        return NetworkCondition(
            latencyMs: latency ?? 0, bandwidthKbps: bandwidth, lossPercent: loss ?? 0)
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/network` — arms the
    /// dylib and states how degraded the network is.
    static func applyNetwork(
        udid: String,
        body: String,
        devices: any Devices
    ) async -> LocationOutcome {
        let network: any Network
        switch role(.network, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): network = role
        }
        let name = deviceName(udid, in: devices)
        guard let condition = parseNetworkRequest(json: body) else {
            return .invalidBody
        }
        do {
            try await network.apply(condition)
        } catch {
            log("network: failed to condition \(name) — \(error)")
            return .dispatchFailed
        }
        // Say what was armed. Injection only takes effect on the next app
        // launch, so when someone reports "my app isn't slow" this line is
        // the first thing worth checking — and when they report the
        // opposite, months later, it's the record that explains why.
        log("network: \(name) is conditioned — \(condition.summary)")
        return .ok
    }

    /// Pure dispatch for `DELETE …/network`.
    static func clearNetwork(
        udid: String,
        devices: any Devices
    ) async -> LocationOutcome {
        let network: any Network
        switch role(.network, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): network = role
        }
        let name = deviceName(udid, in: devices)
        do {
            try await network.clear()
        } catch {
            log("network: failed to clear \(name) — \(error)")
            return .dispatchFailed
        }
        return .ok
    }

    /// What the device's network is subject to, `nil` when no device has
    /// that id; throws the refusal when it can't be conditioned.
    static func networkStateJSON(udid: String, devices: any Devices) async throws -> String? {
        let profiles = NetworkProfile.allCases
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ",")
        let network: any Network
        switch role(.network, of: udid, in: devices) {
        case .unknownDevice: return nil
        case .refused(let refusal): throw refusal
        case .role(let role): network = role
        }
        guard let condition = try await network.current() else {
            return #"{"ok":true,"active":false,"profiles":[\#(profiles)]}"#
        }
        let bandwidth = condition.bandwidthKbps.map { "\($0)" } ?? "null"
        // Naming the preset lets the card keep the pill the user pressed
        // lit, without the frontend holding NLC's figures to recognise the
        // numbers it gets back.
        let profile = NetworkProfile.matching(condition).map { "\"\($0.rawValue)\"" } ?? "null"
        return #"{"ok":true,"active":true,"profile":\#(profile),"#
            + #""latencyMs":\#(condition.latencyMs),"#
            + #""bandwidthKbps":\#(bandwidth),"lossPercent":\#(condition.lossPercent),"#
            + #""offline":\#(condition.isOffline),"summary":"\#(condition.summary)","#
            + #""profiles":[\#(profiles)]}"#
    }

    /// The name a log line says a device by, or its id when it's gone.
    private static func deviceName(_ udid: String, in devices: any Devices) -> String {
        ((try? devices.find(id: DeviceID(udid))) ?? nil)?.name ?? udid
    }
}
