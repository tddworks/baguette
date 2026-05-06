import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("LogStream rich-domain delegation")
struct LogStreamRichDomainTests {

    @Test func `simulator delegates logs() to the host`() {
        let host = MockSimulators()
        let stub = MockLogStream()
        given(host).logs(for: .any).willReturn(stub)

        let sim = Simulator(udid: "u1", name: "X", state: .booted, host: host)
        let stream = sim.logs()

        #expect(stream === stub)
        verify(host).logs(for: .value(sim)).called(1)
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
