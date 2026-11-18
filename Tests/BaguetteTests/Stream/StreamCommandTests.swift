import Mockable
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("StreamCommand", .serialized)
struct StreamCommandTests {
    @Test func `should keep capturing while the stream runs and stop once it completes`() async throws {
        let stream = CaptureProbe()
        try await StreamCommand.capture(stream, on: MockScreen()) {
            #expect(stream.running)
            #expect(stream.stops == 0)
        }
        #expect(!stream.running)
        #expect(stream.stops == 1)
    }

    @Test func `should release the screen and surface the error when capture fails to start`() async {
        let stream = CaptureProbe(failStart: true)
        do {
            try await StreamCommand.capture(stream, on: MockScreen()) {
                Issue.record("A failed capture must not wait for termination")
            }
            Issue.record("Expected capture failure")
        } catch {
            #expect(error is CaptureFailure)
        }
        #expect(!stream.running)
        #expect(stream.stops == 1)
    }

    @Test func `should release the screen when the stream is cancelled while waiting`() async {
        let stream = CaptureProbe()
        do {
            try await StreamCommand.capture(stream, on: MockScreen()) {
                #expect(stream.running)
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!stream.running)
        #expect(stream.stops == 1)
    }
}

private struct CaptureFailure: Error {}

private final class CaptureProbe: Stream {
    let config = StreamConfig.default
    let failStart: Bool
    private(set) var running = false
    private(set) var stops = 0

    init(failStart: Bool = false) { self.failStart = failStart }

    func start(on screen: any Screen) throws {
        running = true
        if failStart { throw CaptureFailure() }
    }

    func stop() {
        running = false
        stops += 1
    }

    func apply(_ config: StreamConfig) {}
    func requestKeyframe() {}
    func requestSnapshot() {}
}
