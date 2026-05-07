import Testing
import Foundation
@testable import Baguette

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

    @Test func `empty batcher returns nil on tick`() {
        var b = LogBatcher(maxLines: 10, windowMs: 50)
        #expect(b.tick(now: Date()) == nil)
    }

    @Test func `empty batcher returns nil on flush`() {
        var b = LogBatcher(maxLines: 10, windowMs: 50)
        #expect(b.flush() == nil)
    }

    // MARK: - size cap

    @Test func `ingest under size cap and inside window returns nil`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 3, windowMs: 50)
        #expect(b.ingest("a", now: t0) == nil)
        #expect(b.ingest("b", now: t0.addingTimeInterval(0.001)) == nil)
    }

    @Test func `ingest hitting size cap drains the batch`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 3, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0)
        let batch = b.ingest("c", now: t0)
        #expect(batch == ["a", "b", "c"])
    }

    @Test func `ingest after size-cap drain starts a fresh window`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 2, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0)            // drains [a, b]
        #expect(b.tick(now: t0.addingTimeInterval(0.1)) == nil) // empty after drain
        #expect(b.ingest("c", now: t0.addingTimeInterval(0.2)) == nil) // new window
    }

    // MARK: - time window

    @Test func `tick before window elapses returns nil`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        #expect(b.tick(now: t0.addingTimeInterval(0.020)) == nil)
    }

    @Test func `tick at or past window drains the batch`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.ingest("b", now: t0.addingTimeInterval(0.010))
        let batch = b.tick(now: t0.addingTimeInterval(0.050))
        #expect(batch == ["a", "b"])
    }

    @Test func `tick after a drain returns nil until a new line arrives`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("a", now: t0)
        _ = b.tick(now: t0.addingTimeInterval(0.060))   // drains [a]
        #expect(b.tick(now: t0.addingTimeInterval(0.200)) == nil)
    }

    // MARK: - flush

    @Test func `flush drains any partial batch regardless of window`() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = LogBatcher(maxLines: 100, windowMs: 50)
        _ = b.ingest("only", now: t0)
        #expect(b.flush() == ["only"])
        #expect(b.flush() == nil)               // already drained
    }
}
