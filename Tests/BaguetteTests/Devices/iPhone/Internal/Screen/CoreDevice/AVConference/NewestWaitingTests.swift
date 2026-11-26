import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// One picture waiting to be converted, the newest: a later one replaces it,
/// and only the first of a run asks for the work to be scheduled.
@Suite("NewestWaiting")
struct NewestWaitingTests {
    @Test func `should ask for the work when nothing was waiting`() {
        let waiting = NewestWaiting<Int>()

        #expect(waiting.offer(1))
    }

    @Test func `should not ask again while a picture is waiting`() {
        let waiting = NewestWaiting<Int>()
        _ = waiting.offer(1)

        #expect(!waiting.offer(2))
    }

    @Test func `should hand over the newest picture when the work runs`() {
        let waiting = NewestWaiting<Int>()
        _ = waiting.offer(1)
        _ = waiting.offer(2)

        #expect(waiting.take() == 2)
        #expect(waiting.take() == nil)
    }

    @Test func `should ask for the work again once the waiting picture was taken`() {
        let waiting = NewestWaiting<Int>()
        _ = waiting.offer(1)
        _ = waiting.take()

        #expect(waiting.offer(3))
    }
}
