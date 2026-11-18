import Foundation
import Testing
@testable import Baguette

@Suite("TwinSession")
struct TwinSessionTests {
    private let hello = #"{"type":"hello","udid":"U1","name":"iPhone","model":"iPhone17,2","capabilities":["motion","screen"]}"#
    private let format = #"{"type":"format","width":1290,"height":2796,"codec":"avcc"}"#
    private let attitude = #"{"type":"attitude","q":[0,0,0,1],"t":1.5}"#

    @Test func `should register the companion on its first valid hello`() {
        var session = TwinSession()
        let event = session.receive(text: hello)
        #expect(event == .registered(TwinHello(
            udid: "U1", name: "iPhone", model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        )))
    }

    @Test func `should reject an attitude sample before hello`() {
        var session = TwinSession()
        guard case .rejected = session.receive(text: attitude) else {
            Issue.record("expected rejection before hello")
            return
        }
    }

    @Test func `should pass attitude samples through after hello`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        let event = session.receive(text: attitude)
        #expect(event == .attitude(AttitudeSample(attitude: .identity, timestamp: 1.5)))
    }

    @Test func `should reject a second hello`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        guard case .rejected = session.receive(text: hello) else {
            Issue.record("expected rejection of duplicate hello")
            return
        }
    }

    @Test func `should open the stream on a format declaration after hello`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        let event = session.receive(text: format)
        #expect(event == .streamOpened(VideoFormat(
            width: 1290, height: 2796, orientation: .portrait, codec: "avcc"
        )))
    }

    @Test func `should reject a format before hello`() {
        var session = TwinSession()
        guard case .rejected = session.receive(text: format) else {
            Issue.record("expected rejection before hello")
            return
        }
    }

    @Test func `should reject binary frames before the format declaration`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        guard case .rejected = session.receive(binary: Data([0x00, 0x01])) else {
            Issue.record("expected rejection before format")
            return
        }
    }

    @Test func `should pass binary frames through untouched after the format`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        _ = session.receive(text: format)
        let payload = Data([0x00, 0x00, 0x00, 0x02, 0x02, 0xFF])
        #expect(session.receive(binary: payload) == .frame(payload))
    }

    @Test func `should reject a malformed line with the reason it failed to parse`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        guard case .rejected(let reason) = session.receive(text: "not json") else {
            Issue.record("expected rejection of malformed line")
            return
        }
        #expect(!reason.isEmpty)
    }
}

extension TwinSessionTests {
    @Test func `should reject a hello claiming another udid when the session was opened for one`() {
        var session = TwinSession(expecting: "U-PATH")
        guard case .rejected(let reason) = session.receive(
            text: #"{"type":"hello","udid":"U-OTHER","name":"iPhone","model":"iPhone17,2"}"#
        ) else {
            Issue.record("expected rejection of mismatched udid")
            return
        }
        #expect(reason.contains("U-PATH"))
    }

    @Test func `should accept the matching hello when the session was opened for a udid`() {
        var session = TwinSession(expecting: "U-PATH")
        guard case .registered(let hello) = session.receive(
            text: #"{"type":"hello","udid":"U-PATH","name":"iPhone","model":"iPhone17,2"}"#
        ) else {
            Issue.record("expected registration")
            return
        }
        #expect(hello.udid == "U-PATH")
    }
}
