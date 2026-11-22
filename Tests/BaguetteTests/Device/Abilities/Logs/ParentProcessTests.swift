import Testing
@testable import BaguetteDevice

/// A helper process's parent, as the helper started under it: gone once the
/// helper is handed to launchd — including when that happened before it looked.
@Suite("ParentProcess")
struct ParentProcessTests {
    @Test func `should see the parent still there while the helper's parent is the one it started under`() {
        #expect(!ParentProcess(startedUnder: 4242).isGone(now: 4242))
    }

    @Test func `should see the parent gone when the helper was handed to launchd`() {
        #expect(ParentProcess(startedUnder: 4242).isGone(now: 1))
    }

    @Test func `should see the parent gone when it was gone before the helper first looked`() {
        #expect(ParentProcess(startedUnder: 1).isGone(now: 1))
    }
}
