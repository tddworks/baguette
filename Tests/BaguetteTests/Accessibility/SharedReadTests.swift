import Foundation
import Testing
@testable import Baguette

/// Counts the reads that actually ran.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var total: Int { lock.withLock { count } }
}

/// What each caller got back.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int?] = []
    func add(_ value: Int?) { lock.withLock { values.append(value) } }
    var all: [Int?] { lock.withLock { values } }
}

@Suite("SharedRead")
struct SharedReadTests {
    @Test func `should run one read for every caller that asks while it is in flight`() {
        let shared = SharedRead<Int>()
        let reads = Reads()
        let results = Results()
        let leading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        // The first caller's read holds until the others have asked.
        finished.enter()
        Thread.detachNewThread {
            results.add(try? shared.read { leading.signal(); release.wait(); return reads.next() })
            finished.leave()
        }
        leading.wait()
        for _ in 0..<3 {
            finished.enter()
            Thread.detachNewThread {
                results.add(try? shared.read { reads.next() })
                finished.leave()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        release.signal()
        finished.wait()

        #expect(reads.total == 1)
        #expect(results.all == [1, 1, 1, 1])
    }

    @Test func `should read afresh once the read before has finished`() throws {
        let shared = SharedRead<Int>()
        let reads = Reads()

        let first = try shared.read { reads.next() }
        let second = try shared.read { reads.next() }

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func `should hand every waiting caller the read's failure`() {
        struct Closed: Error {}
        let shared = SharedRead<Int>()

        #expect(throws: Closed.self) { try shared.read { throw Closed() } }
    }
}
