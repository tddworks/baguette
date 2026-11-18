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

@Suite("SharedRead")
struct SharedReadTests {
    @Test func `should run one read for every caller that asks while it is in flight`() async {
        let shared = SharedRead<Int>()
        let reads = Reads()

        let results = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? shared.read { Thread.sleep(forTimeInterval: 0.3); return reads.next() }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(reads.total == 1)
        #expect(results == [1, 1, 1, 1])
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
