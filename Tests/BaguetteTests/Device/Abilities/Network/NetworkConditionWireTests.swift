import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Coverage for the bytes `NetworkCondition` publishes into the simulator
/// and the injected dylib reads back.
///
/// Byte-for-byte, with sorted keys, the same discipline `MotionIntent`
/// holds — the dylib parses this with `NSJSONSerialization`, and a field
/// that silently changes shape is a condition that silently stops applying.
@Suite("NetworkCondition wire format")
struct NetworkConditionWireTests {

    @Test func `should publish the condition as sorted-key JSON with the pacing resolved`() throws {
        // 400 kbps is 50 000 bytes/second, so a 50 ms tick carries 2 500 of
        // them. The dylib is handed both numbers and multiplies nothing.
        let condition = NetworkCondition(
            latencyMs: 300, bandwidthKbps: 400, lossPercent: 5)!
        let json = String(decoding: try condition.encoded(), as: UTF8.self)
        #expect(json == """
            {"bandwidthKbps":400,"latencyMs":300,"lossPercent":5,"offline":false,\
            "pacing":{"bytesPerTick":2500,"tickIntervalMs":50}}
            """)
    }

    @Test func `should leave the bandwidth out entirely when the link is unmetered`() throws {
        // Absent, not zero. A zero on the wire would have to mean either
        // "unlimited" or "nothing gets through", and the dylib would have to
        // guess which.
        let json = String(
            decoding: try NetworkCondition(latencyMs: 300)!.encoded(), as: UTF8.self)
        #expect(json == #"{"latencyMs":300,"lossPercent":0,"offline":false}"#)
    }

    @Test func `should publish offline as a plain flag`() throws {
        let json = String(decoding: try NetworkCondition.offline.encoded(), as: UTF8.self)
        #expect(json == #"{"latencyMs":0,"lossPercent":0,"offline":true}"#)
    }

    @Test func `should publish a cleared condition as one that changes nothing`() throws {
        // What `network clear` writes before disarming. An app already
        // running still has the dylib loaded and still reads this file, so
        // the last thing it reads has to say "nothing is being done to you".
        let json = String(
            decoding: try NetworkCondition.unconditioned.encoded(), as: UTF8.self)
        #expect(json == #"{"latencyMs":0,"lossPercent":0,"offline":false}"#)
    }

    @Test func `should read back every condition it publishes unchanged`() throws {
        for condition in [
            NetworkCondition(latencyMs: 300, bandwidthKbps: 400, lossPercent: 5)!,
            NetworkCondition(latencyMs: 300)!,
            .offline,
            .unconditioned,
            NetworkProfile.veryBadNetwork.condition,
        ] {
            #expect(try NetworkCondition(decoding: try condition.encoded()) == condition)
        }
    }

    @Test func `should refuse to read a published condition that describes no network`() throws {
        // The file is on shared /tmp and hand-editable. Decoding goes
        // through the same validating door as everything else, so a
        // negative latency is a decode failure rather than a condition
        // nobody can explain later.
        let bad = #"{"latencyMs":-5,"lossPercent":0,"offline":false}"#
        #expect(throws: (any Error).self) {
            try NetworkCondition(decoding: Data(bad.utf8))
        }
    }
}
