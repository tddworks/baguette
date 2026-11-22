import Foundation
import Mockable
import Testing
@testable import BaguetteDevice
@testable import protocol BaguetteDevice.Stream
@testable import WebRTCKit

private let offer = [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=rtpmap:112 H264/90000",
    "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
].joined(separator: "\r\n")

/// An offer carrying Main-profile H.265 beside High-profile H.264, as Chrome's does.
private let bothCodecs = offer.replacingOccurrences(of: "SAVPF 112", with: "SAVPF 49 112") + "\r\n" + [
    "a=rtpmap:49 H265/90000", "a=fmtp:49 level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST",
].joined(separator: "\r\n")

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Viewers whose sockets, handshakes and streams are mocks; what `connect`
/// was asked to trust.
private struct Rig {
    let datagrams = MockDatagrams()
    let handshake = MockHandshake()
    let stream = MockStream()
    let screen = MockScreen()
    let trusted = Box<[String]>([])
    let viewers: WebRTCViewers

    /// `stun`: a STUN server the viewers ask; `seenAt`, what it answers (nil: silence).
    /// `encodable`: the codecs this Mac can encode.
    init(streamStarts: Bool = true, stun: STUNServer? = nil, seenAt: DatagramAddress? = nil, turn: TURNServer? = nil,
         encodable: Set<VideoCodec.Kind> = [.h264, .h265]) {
        given(datagrams).addresses.willReturn([DatagramAddress(ip: [127, 0, 0, 1], port: 5000)])
        let handler = Box<(@Sendable (Data, DatagramAddress) -> Void)?>(nil)
        given(datagrams).onReceive(.any).willProduce { handler.value = $0 }
        given(datagrams).send(.any, to: .any).willProduce { request, to in
            // A TURN server: a challenge, then a relay at :50001 and permissions, for "secret".
            if let turn, to == turn.address, let asked = TURNReply(request) {
                let key = TURNAuth(credentials: turn.credentials, realm: "r", nonce: "n").key
                let reply: Data
                if !asked.isSigned(with: key) {
                    reply = TURNMessage.encode(type: asked.type | 0x0110, transactionID: asked.transactionID, attributes: [
                        (TURNMessage.errorCode, [0, 0, 4, 1]), (TURNMessage.realm, [UInt8]("r".utf8)), (TURNMessage.nonce, [UInt8]("n".utf8)),
                    ])
                } else if asked.type == TURNMessage.allocateRequest {
                    reply = TURNMessage.encode(type: TURNMessage.allocateSuccess, transactionID: asked.transactionID, attributes: [
                        (TURNMessage.xorRelayedAddress, TURNMessage.xor(DatagramAddress(ip: turn.address.ip, port: 50001), transactionID: asked.transactionID)),
                    ], key: key)
                } else {
                    reply = TURNMessage.encode(type: asked.type | 0x0100, transactionID: asked.transactionID, attributes: [], key: key)
                }
                handler.value?(reply, to)
                return
            }
            // The server answers a Binding request with the address it saw.
            guard let seenAt, let asked = STUNMessage(request), asked.isBindingRequest else { return }
            let port = seenAt.port ^ 0x2112, cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
            let ip = zip(seenAt.ip, cookie).map { $0 ^ $1 }
            let attribute: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)] + ip
            handler.value?(Data([0x01, 0x01, 0x00, 0x0C] + cookie + asked.transactionID + attribute), to)
        }
        given(datagrams).close().willReturn()
        given(handshake).fingerprint.willReturn("sha-256 AA")
        given(stream).stop().willReturn()
        given(stream).config.willReturn(.default)
        if streamStarts {
            given(stream).start(on: .any).willReturn()
        } else {
            given(stream).start(on: .any).willThrow(CancellationError())
        }
        let (datagrams, handshake, trusted, stream) = (datagrams, handshake, trusted, stream)
        viewers = WebRTCViewers(
            ticking: nil,
            connect: { fingerprint in
                trusted.value.append(fingerprint)
                return (datagrams, handshake)
            },
            stream: { _, _ in stream },
            encodable: encodable,
            stun: stun, turn: turn)
    }

    func admit(_ sdp: String = offer, codec: CodecChoice? = nil) throws -> (id: String, answer: String) {
        try viewers.admit(offer: sdp, on: screen, codec: codec)
    }
}

@Suite("WebRTCViewers")
struct WebRTCViewersTests {
    @Test func `should answer with H.265 when it was asked for and the offer carries it`() throws {
        let (_, answer) = try Rig().admit(bothCodecs, codec: .h265)

        #expect(answer.contains("a=rtpmap:49 H265/90000"))
    }

    @Test func `should answer with H.264 when nothing was asked for`() throws {
        let (_, answer) = try Rig().admit(bothCodecs)

        #expect(answer.contains("a=rtpmap:112 H264/90000") && !answer.contains("H265"))
    }

    @Test func `should answer with H.264 when H.265 was asked for but this Mac can't encode it`() throws {
        let (_, answer) = try Rig(encodable: [.h264]).admit(bothCodecs, codec: .h265)

        #expect(answer.contains("a=rtpmap:112 H264/90000") && !answer.contains("H265"))
    }

    @Test func `should offer each viewer the public address its STUN server sees`() throws {
        let stun = STUNServer(address: DatagramAddress(ip: [198, 51, 100, 4], port: 3478))
        let rig = Rig(stun: stun, seenAt: DatagramAddress(ip: [203, 0, 113, 7], port: 61000))

        let (_, answer) = try rig.admit()

        #expect(answer.contains("203.0.113.7 61000 typ srflx"))
    }

    @Test func `should offer each viewer a relayed address on its TURN server`() throws {
        let turn = TURNServer(address: DatagramAddress(ip: [198, 51, 100, 4], port: 3478),
                              credentials: TURNCredentials(username: "baguette", password: "secret"))
        let rig = Rig(turn: turn)

        let (_, answer) = try rig.admit()

        #expect(answer.contains("198.51.100.4 50001 typ relay"))
    }

    @Test func `should still answer, with its own addresses, when its STUN server is silent`() throws {
        let rig = Rig(stun: STUNServer(address: DatagramAddress(ip: [198, 51, 100, 4], port: 3478)))

        let (_, answer) = try rig.admit()

        #expect(answer.contains("typ host") && !answer.contains("srflx"))
    }

    @Test func `should admit a browser with a viewer of its own, streaming its screen, and answer its offer`() throws {
        let rig = Rig()

        let (id, answer) = try rig.admit()

        #expect(answer.contains("a=ice-lite\r\n") && answer.contains("a=fingerprint:sha-256 AA\r\n"))
        #expect(try rig.viewers.find(id).answer == answer)
        #expect(rig.trusted.value == ["sha-256 6B:8B"])
        verify(rig.stream).start(on: .any).called(1)
    }

    @Test func `should give each viewer its own id`() throws {
        let rig = Rig()

        let first = try rig.admit(), second = try rig.admit()

        #expect(first.id != second.id)
        #expect(rig.viewers.count == 2)
    }

    @Test func `should refuse an offer it can't answer, and keep nothing`() {
        let rig = Rig()

        #expect(throws: SessionDescription.Refusal.noVideo) { try rig.admit("v=0\r\n") }
        #expect(rig.viewers.count == 0)
        #expect(rig.trusted.value.isEmpty)
    }

    @Test func `should keep no viewer whose stream couldn't start`() {
        let rig = Rig(streamStarts: false)

        #expect(throws: (any Error).self) { try rig.admit() }
        #expect(rig.viewers.count == 0)
        verify(rig.stream).stop().called(1)
    }

    @Test func `should let a viewer go, and stop its stream, once it hangs up`() throws {
        let rig = Rig()
        let (id, _) = try rig.admit()

        try rig.viewers.hangUp(id)

        #expect(throws: WebRTCViewers.Refusal.unknownViewer(id)) { try rig.viewers.find(id) }
        #expect(rig.viewers.count == 0)
        verify(rig.stream).stop().called(1)
    }

    @Test func `should refuse a viewer it doesn't know, naming it`() {
        let rig = Rig()

        #expect(throws: WebRTCViewers.Refusal.unknownViewer("ghost")) { try rig.viewers.find("ghost") }
        #expect(throws: WebRTCViewers.Refusal.unknownViewer("ghost")) { try rig.viewers.hangUp("ghost") }
    }

    @Test func `should let go of viewers whose browsers have gone quiet`() throws {
        let rig = Rig()
        _ = try rig.admit()

        rig.viewers.tick(now: Date().addingTimeInterval(WebRTCViewer.consentTimeout + 1))

        #expect(rig.viewers.count == 0)
    }

    @Test func `should know a viewer only by the device it watches`() throws {
        let rig = Rig()

        let (id, _) = try rig.viewers.admit(offer: offer, on: rig.screen, of: "U")

        #expect((try? rig.viewers.find(id, of: "U")) != nil)
        #expect(throws: WebRTCViewers.Refusal.unknownViewer(id)) { try rig.viewers.find(id, of: "OTHER") }
        #expect(throws: WebRTCViewers.Refusal.unknownViewer(id)) { try rig.viewers.hangUp(id, of: "OTHER") }
        #expect(rig.viewers.count == 1)
    }

    @Test func `should keep the input bound with a viewer's picture, for its touches`() throws {
        let rig = Rig()
        let touch = MockTouch()
        var input = Abilities(device: "iPhone 17")
        input.register(.touch) { touch }

        let (id, _) = try rig.viewers.admit(offer: offer, on: rig.screen, input: input)

        let kept = try #require(try rig.viewers.input(of: id))
        #expect((try kept.require(.touch) as AnyObject) === touch)
        #expect(throws: WebRTCViewers.Refusal.unknownViewer("ghost")) { try rig.viewers.input(of: "ghost") }
    }
}
