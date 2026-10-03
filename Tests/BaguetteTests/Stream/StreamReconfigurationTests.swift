import CoreMedia
import Foundation
import Testing

@testable import Baguette
@testable import protocol Baguette.Stream

@Suite("StreamReconfiguration")
struct StreamReconfigurationTests {
    @Test func `changing FPS never rewinds presentation timestamps`() {
        var timeline = H264Timeline()
        let values = [30, 30, 60, 30].map { CMTimeGetSeconds(timeline.next(fps: Int32($0))) }
        #expect(abs(values[0] - 1.0 / 30) < 0.000001)
        #expect(abs(values[1] - 2.0 / 30) < 0.000001)
        #expect(abs(values[2] - 5.0 / 60) < 0.000001)
        #expect(abs(values[3] - 7.0 / 60) < 0.000001)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func `invalid bitrate cannot be accepted before the codec starts`() {
        let encoder = H264Encoder(fps: 30)
        #expect(throws: (any Error).self) { try encoder.setBitrate(0) }
    }

    @Test func `a rejected runtime codec property stops the CLI stream`() {
        let stream = RejectedStream()
        let failures = FailureCount()
        let channel = ControlChannel(stream: stream) { _ in failures.increment() }
        channel.feed(Data("{\"cmd\":\"set_fps\",\"fps\":30}\n".utf8))
        #expect(stream.stopped)
        #expect(stream.config.fps == 60)
        channel.feed(Data("{\"cmd\":\"force_idr\"}\n".utf8))
        #expect(stream.keyframes == 0 && failures.value == 1)
    }
}

private final class RejectedStream: Stream {
    let config = StreamConfig.default
    var stopped = false
    var keyframes = 0
    func start(on screen: any Screen) throws {}
    func stop() { stopped = true }
    func apply(_ config: StreamConfig) throws { throw Rejection.codecProperty }
    func requestKeyframe() { keyframes += 1 }
    func requestSnapshot() {}
    private enum Rejection: Error { case codecProperty }
}

private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
