import Foundation
import HTTPTypes
import HummingbirdTesting
import HummingbirdWSTesting
import Mockable
import Testing
import WSClient
@testable import Baguette
@testable import BaguetteDevice

private let offer = [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=rtpmap:112 H264/90000",
    "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f", "",
].joined(separator: "\r\n")

/// Viewers whose sockets, handshakes and streams are mocks: no port, no DTLS,
/// no encoder.
private func mockViewers() -> WebRTCViewers {
    WebRTCViewers(
        ticking: nil,
        connect: { _ in
            let datagrams = MockDatagrams()
            given(datagrams).addresses.willReturn([DatagramAddress(ip: [127, 0, 0, 1], port: 5000)])
            given(datagrams).onReceive(.any).willReturn()
            given(datagrams).close().willReturn()
            let handshake = MockHandshake()
            given(handshake).fingerprint.willReturn("sha-256 AA")
            return (datagrams, handshake)
        },
        stream: { _ in
            let stream = MockStream()
            given(stream).start(on: .any).willReturn()
            given(stream).stop().willReturn()
            given(stream).config.willReturn(.default)
            given(stream).apply(.any).willReturn()
            given(stream).requestKeyframe().willReturn()
            given(stream).requestSnapshot().willReturn()
            return stream
        })
}

private func screen() -> MockScreen {
    let screen = MockScreen()
    given(screen).start(onFrame: .any).willReturn()
    given(screen).stop().willReturn()
    return screen
}

private func whepServer(
    devices: any Devices = routeDevices { $0.register(.screen) { screen() } },
    viewers: WebRTCViewers = mockViewers()
) -> InProcessServer {
    let chromes = MockChromes()
    given(chromes).panels(forDeviceName: .any).willReturn([.primary])
    return InProcessServer(devices: devices, chromes: chromes, allowedHosts: ["localhost"], viewers: viewers)
}

private let sdp: HTTPFields = [.contentType: "application/sdp"]

/// The offer with both congestion-control extensions, as Chrome sends it.
private let offerWithBoth = offer.replacingOccurrences(
    of: "a=setup:actpass\r\n",
    with: "a=setup:actpass\r\na=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n"
        + "a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n")

@Suite("Serve router: WHEP")
struct WHEPRouterTests {
    @Test func `should answer a browser's offer with a viewer of the device, on both trees`() async throws {
        let viewers = mockViewers()
        try await whepServer(viewers: viewers).test { client in
            for path in bothTrees("whep") {
                let response = try await client.send(.post, path, body: offer, headers: sdp)

                #expect(response.status == .created, "\(path)")
                #expect(response.header("Content-Type") == "application/sdp")
                #expect(response.text.contains("a=ice-lite\r\n"))
                let location = try #require(response.header("Location"))
                #expect(location.hasPrefix("/devices/U/whep/"))
                #expect(try viewers.find(String(location.split(separator: "/").last!)).answer == response.text)
            }
        }
    }

    @Test func `should say so when no device has the id`() async throws {
        try await whepServer().test { client in
            let response = try await client.send(.post, "/devices/ghost/whep", body: offer, headers: sdp)

            #expect(response.status == .notFound)
            #expect(response.text.contains("unknown udid"))
        }
    }

    @Test func `should refuse an offer with no H.264 the encoder can send, saying why`() async throws {
        let vp8 = offer.replacingOccurrences(of: "H264", with: "VP8")
        try await whepServer().test { client in
            let response = try await client.send(.post, "/devices/U/whep", body: vp8, headers: sdp)

            #expect(response.status == .unprocessableContent)
            #expect(response.text.contains("High-profile H.264"))
        }
    }

    @Test func `should refuse a device that has no screen to show`() async throws {
        try await whepServer(devices: routeDevices()).test { client in
            let response = try await client.send(.post, "/devices/U/whep", body: offer, headers: sdp)

            #expect(response.status.code >= 400)
        }
    }

    @Test func `should refuse an offer from a page on another origin`() async throws {
        try await whepServer().test { client in
            var headers = sdp
            headers[.origin] = "https://evil.example"

            #expect(await client.status(.post, "/devices/U/whep", body: offer, headers: headers) == .forbidden)
        }
    }

    @Test func `should hang a viewer up when its page says goodbye, and not know it after`() async throws {
        let viewers = mockViewers()
        try await whepServer(viewers: viewers).test { client in
            let location = try #require(try await client.send(.post, "/devices/U/whep", body: offer, headers: sdp)
                .header("Location"))

            #expect(await client.status(.delete, location) == .noContent)
            #expect(viewers.count == 0)
            #expect(await client.status(.delete, location) == .notFound)
        }
    }

    @Test func `should carry a viewer's touches and questions over its control socket`() async throws {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))))
        let devices = routeDevices {
            $0 = .input(of: "iPhone 17", all: input)
            $0.register(.screen) { screen() }
            $0.register(.accessibility) { ax }
        }
        let server = whepServer(devices: devices)
        let location = try await server.test { client in
            try #require(try await client.send(.post, "/devices/U/whep", body: offer, headers: sdp).header("Location"))
        }

        let messages = try await socketConversation(
            location + "/control", server: server,
            sending: [#"{"type":"tap","x":1,"y":2,"width":10,"height":20}"#, #"{"type":"describe_ui"}"#],
            until: { $0.contains("describe_ui_result") })

        #expect(messages.last?.contains("AXApplication") == true)
        verify(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(1)
    }

    @Test func `should say so on the control socket when no viewer has the id`() async throws {
        let messages = try await socketConversation("/devices/U/whep/ghost/control", server: whepServer())

        #expect(messages == [#"{"ok":false,"error":"unknown viewer: ghost"}"#])
    }

    @Test func `should give a viewer the congestion control asked for, and REMB when nothing is`() async throws {
        try await whepServer().test { client in
            let remb = try await client.send(.post, "/devices/U/whep?congestion=remb", body: offerWithBoth, headers: sdp)
            #expect(remb.status == .created)
            #expect(remb.text.contains("a=rtcp-fb:112 goog-remb\r\n"))
            #expect(!remb.text.contains("transport-cc"))

            let cc = try await client.send(.post, "/devices/U/whep?congestion=transport-cc", body: offerWithBoth, headers: sdp)
            #expect(cc.text.contains("a=rtcp-fb:112 transport-cc\r\n"))

            let plain = try await client.send(.post, "/devices/U/whep", body: offerWithBoth, headers: sdp)
            #expect(plain.text.contains("a=rtcp-fb:112 goog-remb\r\n"))
            #expect(!plain.text.contains("transport-cc"))

            let off = try await client.send(.post, "/devices/U/whep?congestion=off", body: offerWithBoth, headers: sdp)
            #expect(!off.text.contains("extmap"))
        }
    }

    @Test func `should refuse a congestion control it doesn't know, naming the ones it does`() async throws {
        try await whepServer().test { client in
            let response = try await client.send(.post, "/devices/U/whep?congestion=gcc", body: offerWithBoth, headers: sdp)

            #expect(response.status == .badRequest)
            #expect(response.text.contains("unknown congestion control: gcc (transport-cc, remb or off)"))
        }
    }
}
