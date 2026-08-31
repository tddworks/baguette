import Foundation
import Testing
@testable import Baguette

@Suite("TwinEnvelope")
struct TwinEnvelopeTests {
    @Test func `parses a hello with identity and capabilities`() throws {
        let line = """
        {"type":"hello","udid":"00008140-AA","name":"Renwei's iPhone","model":"iPhone17,2","capabilities":["motion","screen"]}
        """
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .hello(TwinHello(
            udid: "00008140-AA",
            name: "Renwei's iPhone",
            model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        )))
    }

    @Test func `hello capabilities default to empty`() throws {
        let line = """
        {"type":"hello","udid":"00008140-AA","name":"iPhone","model":"iPhone17,2"}
        """
        guard case .hello(let hello) = try TwinEnvelope.parse(line: line) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.capabilities == [])
    }

    @Test func `hello without a udid is rejected`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"hello","name":"iPhone","model":"iPhone17,2"}"#)
        }
    }

    @Test func `parses an attitude sample in wire order`() throws {
        let line = #"{"type":"attitude","q":[0.012,-0.221,0.003,0.975],"t":163412.041}"#
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .attitude(AttitudeSample(
            attitude: Attitude(x: 0.012, y: -0.221, z: 0.003, w: 0.975),
            timestamp: 163412.041
        )))
    }

    @Test func `attitude with a malformed quaternion is rejected`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"attitude","q":[0.1,0.2,0.3],"t":1}"#)
        }
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"attitude","t":1}"#)
        }
    }

    @Test func `parses a video format with orientation and codec`() throws {
        let line = #"{"type":"format","width":1290,"height":2796,"orientation":"landscape-left","codec":"avcc"}"#
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .format(VideoFormat(
            width: 1290,
            height: 2796,
            orientation: .landscapeLeft,
            codec: "avcc"
        )))
    }

    @Test func `format orientation defaults to portrait`() throws {
        let line = #"{"type":"format","width":1290,"height":2796,"codec":"avcc"}"#
        guard case .format(let format) = try TwinEnvelope.parse(line: line) else {
            Issue.record("expected format")
            return
        }
        #expect(format.orientation == .portrait)
    }

    @Test func `format with an unknown orientation is rejected`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"format","width":1,"height":1,"orientation":"sideways","codec":"avcc"}"#)
        }
    }

    @Test func `unknown envelope types are rejected`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"teleport"}"#)
        }
    }

    @Test func `non-JSON lines are rejected`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: "not json")
        }
    }
}
