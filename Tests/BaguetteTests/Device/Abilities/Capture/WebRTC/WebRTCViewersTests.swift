import Foundation
import Mockable
import Testing
@testable import BaguetteDevice
@testable import protocol BaguetteDevice.Stream

private let offer = [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=rtpmap:112 H264/90000",
    "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
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

    init(streamStarts: Bool = true) {
        given(datagrams).addresses.willReturn([DatagramAddress(ip: [127, 0, 0, 1], port: 5000)])
        given(datagrams).onReceive(.any).willReturn()
        given(datagrams).close().willReturn()
        given(handshake).fingerprint.willReturn("sha-256 AA")
        given(stream).stop().willReturn()
        if streamStarts {
            given(stream).start(on: .any).willReturn()
        } else {
            given(stream).start(on: .any).willThrow(CancellationError())
        }
        given(screen).stop().willReturn()
        let (datagrams, handshake, trusted) = (datagrams, handshake, trusted)
        viewers = WebRTCViewers(ticking: nil, connect: { fingerprint in
            trusted.value.append(fingerprint)
            return (datagrams, handshake)
        })
    }

    func admit(_ sdp: String = offer) throws -> (id: String, answer: String) {
        let stream = stream
        return try viewers.admit(offer: sdp, on: screen, stream: { _ in stream })
    }
}

@Suite("WebRTCViewers")
struct WebRTCViewersTests {
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
        verify(rig.screen).stop().called(1)
    }

    @Test func `should let a viewer go, and stop its screen, once it hangs up`() throws {
        let rig = Rig()
        let (id, _) = try rig.admit()

        try rig.viewers.hangUp(id)

        #expect(throws: WebRTCViewers.Refusal.unknownViewer(id)) { try rig.viewers.find(id) }
        #expect(rig.viewers.count == 0)
        verify(rig.screen).stop().called(1)
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
}
