import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `NetworkSchedule` — how a bandwidth becomes the
/// two numbers the injected dylib paces a response body with.
///
/// Same division of labour motion established: **policy in tested Swift,
/// arithmetic in the dylib.** The dylib holds a byte budget and releases it
/// on a timer; deciding how big the budget is and how often the timer fires
/// is a judgement call, so it happens here where it can be asserted.
@Suite("NetworkSchedule")
struct NetworkScheduleTests {

    @Test func `should pace a 3g body in fifty millisecond ticks`() {
        // 780 kbps is 97 500 bytes/second; a twentieth of that per tick.
        let schedule = NetworkSchedule(bandwidthKbps: 780)
        #expect(schedule?.bytesPerTick == 4_875)
        #expect(schedule?.tickIntervalMs == 50)
    }

    @Test func `should deliver exactly the bandwidth it was given`() {
        // The property that actually matters. Rounding a fractional
        // bytes-per-tick and then keeping a 50 ms tick would quietly
        // deliver the wrong rate, so the interval is derived from the
        // rounded byte count rather than fixed.
        for kbps in [1.0, 7.0, 33.0, 240.0, 780.0, 2_000.0, 50_000.0] {
            let schedule = NetworkSchedule(bandwidthKbps: kbps)
            let bytesPerSecond = Double(schedule!.bytesPerTick)
                / (schedule!.tickIntervalMs / 1000)
            #expect(abs(bytesPerSecond - kbps * 125) < 0.001, "\(kbps) kbps")
        }
    }

    @Test func `should never pace less than a whole byte per tick`() {
        // A zero-byte tick is a stall that never ends. Below roughly
        // 0.08 kbps a 50 ms tick works out to less than half a byte and
        // would round to nothing, so the byte count floors at one and the
        // interval stretches to keep the rate honest — 6.25 bytes/second
        // here, one byte every 160 ms.
        let schedule = NetworkSchedule(bandwidthKbps: 0.05)
        #expect(schedule?.bytesPerTick == 1)
        #expect(schedule?.tickIntervalMs == 160)
    }

    @Test func `should release more per tick on a faster link`() {
        let slow = NetworkSchedule(bandwidthKbps: 240)!
        let fast = NetworkSchedule(bandwidthKbps: 50_000)!
        #expect(fast.bytesPerTick > slow.bytesPerTick)
    }

    @Test func `should not pace anything when the link is unmetered`() {
        // Nil bandwidth means "let bytes arrive at full speed", so there is
        // nothing to pace and the dylib must not invent a tick.
        #expect(NetworkCondition(latencyMs: 300)?.schedule == nil)
        #expect(NetworkCondition(bandwidthKbps: 400)?.schedule != nil)
    }

    @Test func `should refuse to pace a bandwidth that is not a rate`() {
        #expect(NetworkSchedule(bandwidthKbps: 0) == nil)
        #expect(NetworkSchedule(bandwidthKbps: -1) == nil)
        #expect(NetworkSchedule(bandwidthKbps: .infinity) == nil)
    }

    @Test func `should refuse to pace a bandwidth too large to pace`() {
        // `Int(Double)` **traps** on a value outside Int's range, so a
        // finite-but-absurd bandwidth doesn't produce a bad schedule — it
        // takes the process down. A number this size can arrive from the
        // wire, where the condition file is hand-editable.
        #expect(NetworkSchedule(bandwidthKbps: 1e300) == nil)
        #expect(NetworkSchedule(bandwidthKbps: .greatestFiniteMagnitude) == nil)
    }

    @Test func `should never accept a condition with a bandwidth it cannot pace`() {
        // The invariant that makes `schedule` safe to reach for anywhere: if
        // a condition validated, its bandwidth can be turned into a schedule.
        #expect(NetworkCondition(bandwidthKbps: 1e300) == nil)
        #expect(NetworkCondition(bandwidthKbps: .greatestFiniteMagnitude) == nil)
        #expect(NetworkCondition(bandwidthKbps: 50_000)?.schedule != nil)
    }
}
