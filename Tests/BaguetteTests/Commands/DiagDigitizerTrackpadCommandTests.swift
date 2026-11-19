import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette diag-digitizer-trackpad`: what the probe makes of SimulatorKit's
/// answer — the verdict line, the patched message it sends, the sequence a
/// cycle or swipe dispatches — against stand-in Indigo messages.
@Suite("Diag digitizer trackpad command")
struct DiagDigitizerTrackpadCommandTests {

    /// What the stand-in SimulatorKit was asked to build and send.
    private final class Bench: @unchecked Sendable {
        let lock = NSLock()
        var fingers: [DigitizerFinger] = []
        var sent: [[UInt8]] = []
        var paused: [UInt32] = []
    }

    private func messages(_ build: TrackpadMessage = .built([UInt8](repeating: 0, count: 0x180)),
                          sends: Bool = true, bench: Bench) -> MockIndigoMessages {
        let messages = MockIndigoMessages()
        given(messages).trackpad(from: .any).willProduce { finger in
            bench.lock.withLock { bench.fingers.append(finger) }
            return build
        }
        given(messages).send(.any, udid: .any, deviceSet: .any).willProduce { message, _, _ in
            bench.lock.withLock { bench.sent.append(message) }
            return sends
        }
        given(messages).mouse(x: .any, y: .any, edge: .any).willReturn([0x01, 0x41])
        return messages
    }

    private func probe(_ argv: [String], _ messages: MockIndigoMessages, bench: Bench) async throws -> CommandRun {
        try await DiagDigitizerTrackpadCommand.$messages.withValue(messages) {
            try await DiagDigitizerTrackpadCommand.$pause.withValue({ ms in
                bench.lock.withLock { bench.paused.append(ms) }
            }) {
                try await run(try DiagDigitizerTrackpadCommand.parse(["--udid", "U"] + argv))
            }
        }
    }

    @Test func `should report a message the wrapper accepted and not send it unless asked`() async throws {
        let bench = Bench()

        let ran = try await probe([], messages(bench: bench), bench: bench)

        #expect(ran.said == [
            #"{"accepted":true,"messageSize":384,"dispatched":false,"reason":"wrapper accepted; dispatch skipped (use --dispatch to send)"}"#,
        ])
        #expect(bench.sent.isEmpty)
        #expect(bench.fingers == [DigitizerFinger(
            index: 0, identifier: 0, eventMask: 0x04, x: 0.5, y: 0.5, pressure: 0,
            range: false, touch: false, withParent: false)])
    }

    @Test func `should report why when the wrapper refuses the event`() async throws {
        let bench = Bench()

        let ran = try await probe([], messages(.refused("wrapper returned nil"), bench: bench), bench: bench)

        #expect(ran.said == [#"{"accepted":false,"messageSize":0,"dispatched":false,"reason":"wrapper returned nil"}"#])
    }

    @Test func `should send the message patched with the touch target and the edge`() async throws {
        let bench = Bench()

        let ran = try await probe(
            ["--dispatch", "--patch-target", "--patch-edge", "bottom", "--event-mask", "0x07", "--with-parent"],
            messages(bench: bench), bench: bench)

        #expect(ran.said.first?.contains(#""dispatched":true"#) == true)
        let sent = try #require(bench.sent.first)
        #expect(Array(sent[0x6c..<0x70]) == [0x32, 0, 0, 0])
        #expect(Array(sent[0x10c..<0x110]) == [0x32, 0, 0, 0])
        #expect(Array(sent[0x3a...0x3b]) == [0x04, 0x01])
        #expect(Array(sent[0xda...0xdb]) == [0x04, 0x01])
        #expect(bench.fingers.first?.eventMask == 0x07)
        #expect(bench.fingers.first?.withParent == true)
    }

    @Test func `should say the dispatch failed when the device can't be reached`() async throws {
        let bench = Bench()

        let ran = try await probe(["--dispatch"], messages(sends: false, bench: bench), bench: bench)

        #expect(ran.said.first?.contains("wrapper accepted but dispatch failed") == true)
    }

    @Test func `should leave a message too short for a slot unpatched`() async throws {
        let bench = Bench()

        _ = try await probe(["--dispatch", "--patch-target", "--patch-edge", "left"],
                            messages(.built([UInt8](repeating: 0, count: 0x20)), bench: bench), bench: bench)

        #expect(bench.sent == [[UInt8](repeating: 0, count: 0x20)])
    }

    @Test func `should dump the message as hex rows with an ASCII gutter`() async throws {
        let bench = Bench()

        let ran = try await probe(["--dump"], messages(.built(Array("AB".utf8) + [0x00]), bench: bench), bench: bench)

        #expect(ran.said.last == "  0000  41 42 00 " + String(repeating: "   ", count: 13) + " AB.\n")
    }

    @Test func `should dump the mouse message at both edges for comparison`() async throws {
        let bench = Bench()

        let ran = try await probe(["--compare-with-mouse"], messages(bench: bench), bench: bench)

        #expect(Array(ran.said.dropFirst()) == [
            "--- mouse-event message edge=0 ---",
            "size=2\n  0000  01 41 " + String(repeating: "   ", count: 14) + " .A\n",
            "--- mouse-event message edge=3 (bottom) ---",
            "size=2\n  0000  01 41 " + String(repeating: "   ", count: 14) + " .A\n",
        ])
    }

    @Test func `should cycle a touch down and up, holding between them`() async throws {
        let bench = Bench()

        let ran = try await probe(["--cycle", "--hold-ms", "30", "--touch", "--range", "--dump"],
                                  messages(.built([0x00]), bench: bench), bench: bench)

        #expect(ran.said.count == 4)
        #expect(ran.said[0].hasPrefix("DOWN: "))
        #expect(ran.said[2].hasPrefix("UP:   "))
        #expect(bench.paused == [30])
        #expect(bench.fingers.map(\.touch) == [true, false])
        #expect(bench.fingers.map(\.eventMask) == [0x04, 0x06])
    }

    @Test func `should swipe as one finger down, moving, dwelling, and up`() async throws {
        let bench = Bench()

        let ran = try await probe(
            ["--y", "0.9", "--swipe-end-y", "0.1", "--swipe-steps", "4", "--swipe-dwell-ms", "100"],
            messages(bench: bench), bench: bench)

        #expect(ran.said.map { String($0.prefix(8)) } == ["DOWN  : ", "MOVE 02:", "MOVE 04:", "DWELL : ", "UP    : "])
        let identifiers = Set(bench.fingers.map(\.identifier))
        #expect(identifiers == [UInt32(0xC0DE)])
        // down, four moves, two dwell pulses, up
        #expect(bench.fingers.count == 8)
        #expect(bench.fingers.last?.y == 0.1)
        #expect(bench.fingers.last?.eventMask == 0x06)
    }
}
