import Foundation
import Testing
@testable import Baguette

@Suite("TwinEnvelope")
struct TwinEnvelopeTests {
    @Test func `should read a hello carrying the device identity and capabilities`() throws {
        let line = """
        {"type":"hello","udid":"00008140-AA","name":"Baguette's iPhone","model":"iPhone17,2","capabilities":["motion","screen"]}
        """
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .hello(TwinHello(
            udid: "00008140-AA",
            name: "Baguette's iPhone",
            model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        )))
    }

    @Test func `should assume no capabilities when a hello lists none`() throws {
        let line = """
        {"type":"hello","udid":"00008140-AA","name":"iPhone","model":"iPhone17,2"}
        """
        guard case .hello(let hello) = try TwinEnvelope.parse(line: line) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.capabilities == [])
    }

    @Test func `should reject a hello without a udid`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"hello","name":"iPhone","model":"iPhone17,2"}"#)
        }
    }

    @Test func `should read an attitude sample in wire order`() throws {
        let line = #"{"type":"attitude","q":[0.012,-0.221,0.003,0.975],"t":163412.041}"#
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .attitude(AttitudeSample(
            attitude: Attitude(x: 0.012, y: -0.221, z: 0.003, w: 0.975),
            timestamp: 163412.041
        )))
    }

    @Test func `should reject an attitude with a malformed or missing quaternion`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"attitude","q":[0.1,0.2,0.3],"t":1}"#)
        }
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"attitude","t":1}"#)
        }
    }

    @Test func `should read a video format with its orientation and codec`() throws {
        let line = #"{"type":"format","width":1290,"height":2796,"orientation":"landscape-left","codec":"avcc"}"#
        let envelope = try TwinEnvelope.parse(line: line)
        #expect(envelope == .format(VideoFormat(
            width: 1290,
            height: 2796,
            orientation: .landscapeLeft,
            codec: "avcc"
        )))
    }

    @Test func `should assume portrait when a video format names no orientation`() throws {
        let line = #"{"type":"format","width":1290,"height":2796,"codec":"avcc"}"#
        guard case .format(let format) = try TwinEnvelope.parse(line: line) else {
            Issue.record("expected format")
            return
        }
        #expect(format.orientation == .portrait)
    }

    @Test func `should reject a video format with an unknown orientation`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"format","width":1,"height":1,"orientation":"sideways","codec":"avcc"}"#)
        }
    }

    @Test func `should reject an unknown envelope type`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: #"{"type":"teleport"}"#)
        }
    }

    @Test func `should reject a line that is not JSON`() {
        #expect(throws: (any Error).self) {
            try TwinEnvelope.parse(line: "not json")
        }
    }
}
