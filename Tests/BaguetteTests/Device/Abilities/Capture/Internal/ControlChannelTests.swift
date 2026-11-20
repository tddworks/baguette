import Foundation
import Testing

@testable import BaguetteDevice
@testable import protocol BaguetteDevice.Stream

@Suite("ControlChannel")
struct ControlChannelTests {
    @Test func `should stop listening for commands when stdin closes`() async throws {
        let stream = KeyframeStream()
        let stdin = Pipe()
        let channel = ControlChannel(stream: stream, input: stdin.fileHandleForReading)
        channel.start()

        stdin.fileHandleForWriting.write(Data("{\"cmd\":\"force_idr\"}\n".utf8))
        try stdin.fileHandleForWriting.close()

        try await eventually { !channel.isListening }
        #expect(!channel.isListening)
        #expect(stream.keyframes == 1)
    }

    @Test func `should keep listening for commands while stdin stays open`() async throws {
        let stream = KeyframeStream()
        let stdin = Pipe()
        let channel = ControlChannel(stream: stream, input: stdin.fileHandleForReading)
        channel.start()
        defer { channel.stop() }

        stdin.fileHandleForWriting.write(Data("{\"cmd\":\"force_idr\"}\n".utf8))

        try await eventually { stream.keyframes == 1 }
        #expect(channel.isListening)
    }
}

/// Polls `condition` until it holds or two seconds pass: stdin is real I/O, so
/// its handler runs on Foundation's own queue.
private func eventually(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class KeyframeStream: Stream, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let config = StreamConfig.default
    var keyframes: Int { lock.withLock { count } }
    func start(on screen: any Screen) throws {}
    func stop() {}
    func apply(_ config: StreamConfig) throws {}
    func requestKeyframe() { lock.withLock { count += 1 } }
    func requestSnapshot() {}
}
