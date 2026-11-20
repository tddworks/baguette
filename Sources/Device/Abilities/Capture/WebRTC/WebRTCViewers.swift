import Foundation
import WebRTCKit

/// The live WebRTC (WHEP) viewers of one server, by id. It admits a browser's
/// offer with a viewer of its own, streaming the screen it is given, and lets
/// the viewer go the moment it hangs up, for whatever reason (its stream, which
/// stops its screen, goes with it). An id it doesn't know, or asked for through
/// another device than the one its viewer watches, is a refusal naming it.
public final class WebRTCViewers: @unchecked Sendable {
    public enum Refusal: Error, Equatable { case unknownViewer(String) }

    /// The outside world a viewer needs, trusting the certificate its offer named.
    public typealias Connect = @Sendable (_ browserFingerprint: String) throws -> (any Datagrams, any Handshake)

    private let lock = NSLock()
    /// One admitted viewer: the device it watches, and the input bound with its
    /// picture (its touches go where it shows) — one record, so they can't disagree.
    private struct Admitted {
        let viewer: WebRTCViewer
        let device: DeviceID?
        let input: Abilities?
    }
    private var admitted: [String: Admitted] = [:]
    private let connect: Connect
    private let makeStream: (any FrameSink) -> any Stream
    /// Asked, per viewer and through its own socket, for the address the world
    /// sees it at — offered to the browser beside the Mac's own.
    private let stun: STUNServer?

    /// The ICE servers a browser should use too (WHEP `Link: rel="ice-server"`,
    /// and the page's own config), as their URLs.
    public var iceServers: [String] { stun.map { [$0.url] } ?? [] }
    private var timer: DispatchSourceTimer?

    /// `ticking`: how often consent and DTLS retransmission are checked; nil
    /// leaves it to whoever calls `tick(now:)`. `stream`: what a viewer is
    /// shown — H.264 at the stream socket's defaults.
    public init(
        ticking interval: TimeInterval? = 1,
        connect: @escaping Connect = WebRTCViewers.onThisMac(),
        stream: @escaping (any FrameSink) -> any Stream = { sink in
            StreamFormat.avcc.makeStream(config: .default, sink: sink, quality: 0.5)
        },
        stun: STUNServer? = nil
    ) {
        self.connect = connect
        self.makeStream = stream
        self.stun = stun
        guard let interval else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "baguette.webrtc.viewers"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick(now: Date()) }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// A UDP socket on this Mac, on the first free port of `ports`, and a
    /// BoringSSL DTLS server.
    public static func onThisMac(ports: MediaPorts = .any) -> Connect {
        { fingerprint in
            let handshake = try BoringSSLHandshake()
            handshake.expect(fingerprint)
            return (try ports.bind { try UDPDatagrams(port: $0) }, handshake)
        }
    }

    public var count: Int { lock.withLock { admitted.count } }

    /// A viewer for the browser whose WHEP `offer` this is, its own stream
    /// started on `screen`: its id, and the SDP answer. Throws the offer's
    /// refusal, or why the viewer couldn't be connected or started.
    /// `device`: the device `screen` is of; the viewer is found only through it.
    /// `input`: the input bound with `screen` (the same display plane and
    /// panel), kept for the viewer's control socket. `congestion`: the method
    /// asked for (`?congestion=`), or nil for the default. `pacing`: off only
    /// for the bench's baseline (`?pacing=off`).
    public func admit(
        offer: String, on screen: any Screen, of device: DeviceID? = nil, input: Abilities? = nil,
        congestion: CongestionChoice? = nil, pacing: Bool = true
    ) throws -> (id: String, answer: String) {
        let description = try SessionDescription(offer: offer)
        let (datagrams, handshake) = try connect(description.browserFingerprint)
        let id = UUID().uuidString.lowercased()
        let reflexive = stun?.publicAddress(through: datagrams)
        let viewer = WebRTCViewer(
            offer: description, datagrams: datagrams, handshake: handshake, stream: makeStream,
            congestion: { CongestionChoice.control(asked: congestion, offer: description, ceiling: $0) },
            reflexive: reflexive, pacing: pacing, id: id)
        do {
            try viewer.start(on: screen)
        } catch {
            viewer.hangUp()
            throw error
        }
        lock.withLock { admitted[id] = Admitted(viewer: viewer, device: device, input: input) }
        viewer.onHangUp { [weak self] in
            self?.lock.withLock { self?.admitted[id] = nil }
        }
        return (id, viewer.answer)
    }

    /// The input bound with viewer `id`'s picture, or nil when it was admitted without one.
    public func input(of id: String) throws -> Abilities? {
        try lock.withLock {
            guard let found = admitted[id] else { throw Refusal.unknownViewer(id) }
            return found.input
        }
    }

    /// Viewer `id`, when it watches `device` (any device, when nil).
    public func find(_ id: String, of device: DeviceID? = nil) throws -> WebRTCViewer {
        guard let found = lock.withLock({ admitted[id] }), device == nil || found.device == device else {
            throw Refusal.unknownViewer(id)
        }
        return found.viewer
    }

    public func hangUp(_ id: String, of device: DeviceID? = nil) throws { try find(id, of: device).hangUp() }

    /// Time passing, for every viewer: those whose browsers went quiet hang up.
    public func tick(now: Date) {
        lock.withLock { admitted.values.map(\.viewer) }.forEach { $0.tick(now: now) }
    }
}
