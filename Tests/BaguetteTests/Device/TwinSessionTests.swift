import Foundation
import Testing
@testable import Baguette

@Suite("TwinSession")
struct TwinSessionTests {
    private let hello = #"{"type":"hello","udid":"U1","name":"iPhone","model":"iPhone17,2","capabilities":["motion","screen"]}"#
    private let format = #"{"type":"format","width":1290,"height":2796,"codec":"avcc"}"#
    private let attitude = #"{"type":"attitude","q":[0,0,0,1],"t":1.5}"#

    @Test func `the first valid hello registers the companion`() {
        var session = TwinSession()
        let event = session.receive(text: hello)
        #expect(event == .registered(TwinHello(
            udid: "U1", name: "iPhone", model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        )))
    }

    @Test func `an attitude sample before hello is rejected`() {
        var session = TwinSession()
        guard case .rejected = session.receive(text: attitude) else {
            Issue.record("expected rejection before hello")
            return
        }
    }

    @Test func `attitude samples after hello are emitted`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        let event = session.receive(text: attitude)
        #expect(event == .attitude(AttitudeSample(attitude: .identity, timestamp: 1.5)))
    }

    @Test func `a second hello is rejected`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        guard case .rejected = session.receive(text: hello) else {
            Issue.record("expected rejection of duplicate hello")
            return
        }
    }

    @Test func `the format declaration opens the stream after hello`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        let event = session.receive(text: format)
        #expect(event == .streamOpened(VideoFormat(
            width: 1290, height: 2796, orientation: .portrait, codec: "avcc"
        )))
    }

    @Test func `a format before hello is rejected`() {
        var session = TwinSession()
        guard case .rejected = session.receive(text: format) else {
            Issue.record("expected rejection before hello")
            return
        }
    }

    @Test func `binary frames before the format declaration are rejected`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        guard case .rejected = session.receive(binary: Data([0x00, 0x01])) else {
            Issue.record("expected rejection before format")
            return
        }
    }

    @Test func `binary frames after the format pass through untouched`() {
        var session = TwinSession()
        _ = session.receive(text: hello)
        _ = session.receive(text: format)
        let payload = Data([0x00, 0x00, 0x00, 0x02, 0x02, 0xFF])
        #expect(session.receive(binary: payload) == .frame(payload))
    }

    @Test func `a malformed line is rejected with the parse reason`() {
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
    @Test func `a session opened for one udid rejects a hello claiming another`() {
        var session = TwinSession(expecting: "U-PATH")
        guard case .rejected(let reason) = session.receive(
            text: #"{"type":"hello","udid":"U-OTHER","name":"iPhone","model":"iPhone17,2"}"#
        ) else {
            Issue.record("expected rejection of mismatched udid")
            return
        }
        #expect(reason.contains("U-PATH"))
    }

    @Test func `a session opened for a udid accepts the matching hello`() {
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
