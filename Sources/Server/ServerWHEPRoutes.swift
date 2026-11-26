import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import WebRTCKit

/// The WebRTC (WHEP, draft-ietf-wish-whep) live view: a page posts an SDP offer and gets a
/// viewer of the device with a stream of its own; its touches and stream
/// control ride the viewer's control socket; `DELETE` hangs it up.
///
///   GET    /webrtc/ice-servers                 {"iceServers":[{"urls":"stun:…"}]}: for the page's RTCPeerConnection
///   POST   /devices/:udid/whep[?congestion=transport-cc|remb|off]   offer → 201, Location, Link (ICE servers), answer
///   DELETE /devices/:udid/whep/:viewer          hang up → 204
///   WS     /devices/:udid/whep/:viewer/control  gestures, describe_ui, paste, retune
///
/// Design: docs/features/webrtc/design.md.
extension Server {
    func registerWHEPRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?,
        trustedWebSocketUpgrade: @escaping @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade
    ) {
        let (devices, viewers) = (allDevices, viewers)

        // The page asks before its offer: its browser gathers its own public
        // address with them, and posts that among its candidates.
        router.get("/webrtc/ice-servers") { request, _ in
            if let rejected = rejectUntrustedBrowser(request) { return rejected }
            let servers = viewers.iceServers.map { server in
                var fields = [#""urls":"\#(jsonEscape(server.url))""#]
                if let username = server.username { fields.append(#""username":"\#(jsonEscape(username))""#) }
                if let credential = server.credential { fields.append(#""credential":"\#(jsonEscape(credential))""#) }
                return "{" + fields.joined(separator: ",") + "}"
            }.joined(separator: ",")
            return Self.jsonResponse(#"{"iceServers":[\#(servers)]}"#)
        }

        for path in Self.deviceRoutes("whep") {
            router.post(RouterPath(path)) { request, _ in
                if let rejected = rejectUntrustedBrowser(request) { return rejected }
                let offer = String(buffer: try await request.body.collect(upTo: 64 * 1024))
                return Self.admit(offer: offer, request: request, devices: devices, viewers: viewers)
            }
        }
        for path in Self.deviceRoutes("whep/:viewer") {
            router.delete(RouterPath(path)) { request, context in
                if let rejected = rejectUntrustedBrowser(request) { return rejected }
                let id = context.parameters.get("viewer") ?? ""
                let udid = request.uri.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                guard (try? viewers.hangUp(id, of: DeviceID(udid.removingPercentEncoding ?? udid))) != nil else {
                    return Self.pluginError("unknown viewer: \(id)", status: .notFound)
                }
                return Response(status: .noContent)
            }
        }
        for path in Self.deviceRoutes("whep/:viewer/control") {
            router.ws(RouterPath(path), shouldUpgrade: trustedWebSocketUpgrade) { inbound, outbound, context in
                await Self.viewerControl(
                    context.request, devices: devices, viewers: viewers, inbound: inbound, outbound: outbound)
            }
        }
    }

    /// A viewer for the device the path names, on the display plane the query
    /// asks for, with the congestion control it asks for (`CongestionChoice`)
    /// and the codec (`CodecChoice`).
    static func admit(offer: String, request: Request, devices: any Devices, viewers: WebRTCViewers) -> Response {
        var congestion: CongestionChoice?
        if let asked = request.uri.queryParameters.get("congestion").map({ String($0) }) {
            guard let choice = CongestionChoice(rawValue: asked) else {
                return pluginError("unknown congestion control: \(asked) (transport-cc, remb or off)", status: .badRequest)
            }
            congestion = choice
        }
        // `?codec=h265`: H.265 when the offer carries it and this Mac encodes it.
        var codec: CodecChoice?
        if let asked = request.uri.queryParameters.get("codec").map({ String($0) }) {
            guard let choice = CodecChoice(rawValue: asked) else {
                return pluginError("unknown codec: \(asked) (h265, h264 or auto)", status: .badRequest)
            }
            codec = choice
        }
        // `?pacing=off`: the bench's baseline, the same sender without its pacer.
        var pacing = true
        if let asked = request.uri.queryParameters.get("pacing").map({ String($0) }) {
            guard asked == "on" || asked == "off" else {
                return pluginError("pacing is on or off, not \(asked)", status: .badRequest)
            }
            pacing = asked == "on"
        }
        // `?rtx=off`: the bench's baseline, resends as they were sent, not on their own stream.
        var rtx = true
        if let asked = request.uri.queryParameters.get("rtx").map({ String($0) }) {
            guard asked == "on" || asked == "off" else {
                return pluginError("rtx is on or off, not \(asked)", status: .badRequest)
            }
            rtx = asked == "on"
        }
        let udid = udidParam(request)
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            return pluginError("unknown udid: \(udid)", status: .notFound)
        }
        let plan = StreamDisplayPlan.from(
            query: request.uri.queryParameters.get("display"),
            panel: request.uri.queryParameters.get("panel").map { String($0) },
            requireExistingDisplay: false)
        do {
            let bound = try plan.bind(to: device)
            let (id, answer) = try viewers.admit(
                offer: offer, on: bound.screen, of: DeviceID(udid), input: bound.input, congestion: congestion, pacing: pacing, rtx: rtx, codec: codec)
            return Response(
                status: .created,
                headers: Self.answerHeaders(location: "/devices/\(udid)/whep/\(id)", iceServers: viewers.iceServers),
                body: .init(byteBuffer: ByteBuffer(string: answer)))
        } catch let refusal as DeviceError {
            return Self.refusal(refusal)
        } catch let refusal as SessionDescription.Refusal {
            return pluginError(refusal.description, status: .unprocessableContent)
        } catch {
            return pluginError(String(describing: error), status: .internalServerError)
        }
    }

    /// The viewer's control socket: what the stream socket carries from its
    /// page — gestures, `describe_ui`, paste and copy, retune — with no video.
    static func viewerControl(
        _ request: Request, devices: any Devices, viewers: WebRTCViewers,
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter
    ) async {
        // /<tree>/:udid/whep/:viewer/control — deeper than the one-verb rule
        // `udidParam` reads, so both come by position from the front.
        let parts = request.uri.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let udid = parts.count > 1 ? parts[1] : ""
        let id = parts.count > 3 ? parts[3] : ""
        // The viewer only through the device it watches: one id, one device.
        guard let viewer = try? viewers.find(id, of: DeviceID(udid)) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown viewer: \#(jsonEscape(id))"}"#))
            return
        }
        guard let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }
        // The input bound with the viewer's picture when it was admitted — the
        // same display plane and panel — never a second binding from this URL.
        let input = ((try? viewers.input(of: id)) ?? nil) ?? Abilities(device: device.name)
        let pasteboard = try? device.require(.pasteboard)
        let accessibility = try? device.require(.accessibility)
        let dispatcher = GestureDispatcher(input: input)
        do {
            for try await frame in inbound where frame.opcode == .text {
                let line = String(buffer: frame.data)
                if let accessibility, await handleDescribeUI(line: line, accessibility: accessibility, outbound: outbound) {
                    continue
                }
                if let pasteboard, let reply = await PasteDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input).resultFrame {
                    try? await outbound.write(.text(reply))
                    continue
                }
                if let pasteboard, let reply = await CopyDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input).resultFrame {
                    try? await outbound.write(.text(reply))
                    continue
                }
                do {
                    try await handleInbound(line: line, stream: viewer.ownStream, dispatcher: dispatcher, udid: udid)
                } catch {
                    try? await outbound.write(.text(#"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#))
                    return
                }
            }
        } catch {
            // the page closed its control socket; the viewer lives on until it hangs up
        }
    }

    /// The answer's headers; its ICE servers as WHEP names them (`Link`, one
    /// per server, comma-joined).
    static func answerHeaders(location: String, iceServers: [WebRTCViewers.ICEServer]) -> HTTPFields {
        var headers: HTTPFields = [.location: location, .contentType: "application/sdp", .cacheControl: "no-cache"]
        if !iceServers.isEmpty {
            headers[HTTPField.Name("Link")!] = iceServers.map { server in
                var link = "<\(server.url)>; rel=\"ice-server\""
                if let username = server.username, let credential = server.credential {
                    link += "; username=\"\(username)\"; credential=\"\(credential)\"; credential-type=\"password\""
                }
                return link
            }.joined(separator: ", ")
        }
        return headers
    }
}
