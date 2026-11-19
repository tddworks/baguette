import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("LogStream rich-domain delegation")
struct LogStreamRichDomainTests {

    @Test func `should give access to the simulator logs`() {
        let sim = MockSimulator()
        let stub = MockLogStream()
        given(sim).logs().willReturn(stub)

        let stream = sim.logs()

        #expect(stream === stub)
        verify(sim).logs().called(1)
    }

    @Test func `should start streaming logs with the chosen filter`() throws {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willReturn()

        let filter = LogFilter(level: .debug, style: .json)
        try stream.start(
            filter: filter,
            onLine: { _ in },
            onTerminate: { _ in }
        )

        verify(stream).start(
            filter: .value(filter),
            onLine: .any,
            onTerminate: .any
        ).called(1)
    }

    @Test func `should stop streaming logs`() {
        let stream = MockLogStream()
        given(stream).stop().willReturn()
        stream.stop()
        verify(stream).stop().called(1)
    }
}
