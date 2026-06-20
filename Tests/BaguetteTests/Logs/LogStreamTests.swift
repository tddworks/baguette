import Testing
import Foundation
import Mockable
@testable import BaguetteCore

@Suite("LogStream rich-domain delegation")
struct LogStreamRichDomainTests {

    @Test func `simulator vends a fresh LogStream from logs()`() {
        let sim = MockSimulator()
        let stub = MockLogStream()
        given(sim).logs().willReturn(stub)

        let stream = sim.logs()

        #expect(stream === stub)
        verify(sim).logs().called(1)
    }

    @Test func `start forwards filter and callbacks to the host`() throws {
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

    @Test func `stop forwards to the host`() {
        let stream = MockLogStream()
        given(stream).stop().willReturn()
        stream.stop()
        verify(stream).stop().called(1)
    }
}
