import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `LogBatcher` collects emitted log lines into batches that flush
/// either when a size cap is reached or when a time window elapses.
/// It is the pure-domain counterpart to the per-line WebSocket fan-out
/// in `Server.logsWS`: ingesting one line per WS frame at hundreds of
/// lines/second pegs the browser's main thread; one batched frame per
/// ~50 ms collapses that pressure to ~20 frames/sec.
///
/// Window behaviour: the window opens on the first ingested line.
/// Drains (size-cap, time-cap, explicit flush) close the window;
/// the next ingest starts a fresh one.
@Suite("LogBatcher")
struct LogBatcherTests {

    // MARK: - empty / no-op

    @Test func `should send no batch on a tick when no lines arrived`() {
        var b = LogBatcher(maxLines: 10, windowMs: 50)
        #expect(b.tick(now: Date()) == nil)
    }

    @Test func `should send no batch on a flush when no lines arrived`() {
        var b = LogBatcher(maxLines: 10, windowMs: 50)
        #expect(b.flush() == nil)
    }

    // MARK: - size cap

    @Test func `should hold lines while under the size cap and inside the window`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 3, windowMs: 50)
        #expect(b.ingest("a", now: t0) == nil)
        #expect(b.ingest("b", now: t0.addingTimeInterval(0.001)) == nil)
    }

    @Test func `should send the batch as soon as it reaches the size cap`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 3, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0)
        let batch = b.ingest("c", now: t0)
        #expect(batch == ["a", "b", "c"])
    }

    @Test func `should start a fresh window after a full batch is sent`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 2, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0)            // drains [a, b]
        #expect(b.tick(now: t0.addingTimeInterval(0.1)) == nil) // empty after drain
        #expect(b.ingest("c", now: t0.addingTimeInterval(0.2)) == nil) // new window
    }

    // MARK: - time window

    @Test func `should hold lines on a tick before the window elapses`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        #expect(b.tick(now: t0.addingTimeInterval(0.020)) == nil)
    }

    @Test func `should send the batch on a tick once the window elapses`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0.addingTimeInterval(0.010))
        let batch = b.tick(now: t0.addingTimeInterval(0.050))
        #expect(batch == ["a", "b"])
    }

    @Test func `should send nothing on later ticks until a new line arrives`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.tick(now: t0.addingTimeInterval(0.060))   // drains [a]
        #expect(b.tick(now: t0.addingTimeInterval(0.200)) == nil)
    }

    // MARK: - flush

    @Test func `should send a partial batch on flush regardless of the window`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("only", now: t0)
        #expect(b.flush() == ["only"])
        #expect(b.flush() == nil)               // already drained
    }
}
