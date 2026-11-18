import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `baguette record` ends a take for one of two reasons — the user
/// pressed Ctrl-C, or `--duration` ran out — and they arrive on two
/// different `DispatchSource`s that can both fire. `RecordingGate` is
/// the latch that lets exactly one of them through and remembers which,
/// because the answer decides what happens to SIGINT next: after a
/// Ctrl-C the user gets the signal handed back (a second press aborts a
/// long flush), and on the duration path they don't, so that their
/// *first* press can't truncate the file being written.
@Suite("RecordingGate")
struct RecordingGateTests {

    @Test func `should report the interrupt as the reason the recording ended`() async {
        let gate = RecordingGate()
        gate.open(.interrupt)
        await gate.wait()

        #expect(gate.openedBy == .interrupt)
    }

    @Test func `should report the duration as the reason the recording ended`() async {
        let gate = RecordingGate()
        gate.open(.duration)
        await gate.wait()

        #expect(gate.openedBy == .duration)
    }

    @Test func `should report no reason while the recording has not ended`() {
        #expect(RecordingGate().openedBy == nil)
    }

    @Test func `should keep the first reason when both the duration and an interrupt end the recording`() async {
        // Both sources really can fire: the duration deadline and a
        // Ctrl-C a millisecond later. The take ended for the first one.
        let gate = RecordingGate()
        gate.open(.duration)
        gate.open(.interrupt)
        await gate.wait()

        #expect(gate.openedBy == .duration)
    }

    @Test func `should release a waiter when the recording ends after it began waiting`() async {
        let gate = RecordingGate()
        Task.detached {
            gate.open(.interrupt)
        }
        await gate.wait()

        #expect(gate.openedBy == .interrupt)
    }
}
