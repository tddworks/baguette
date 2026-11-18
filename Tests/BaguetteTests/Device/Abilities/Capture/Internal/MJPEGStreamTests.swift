import Foundation
import IOSurface
import Mockable
import Testing
@testable import BaguetteDevice

/// What the MJPEG stream sends: a multipart header, then one JPEG part for
/// each screen that changed.
@Suite("MJPEGStream")
struct MJPEGStreamTests {

    private func screen() -> MockScreen {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willReturn()
        given(screen).stop().willReturn()
        return screen
    }

    @Test func `should open the stream with its multipart header`() throws {
        let sink = RecordingSink()
        let stream = MJPEGStream(config: .default, sink: sink, quality: 0.7)

        try stream.start(on: screen())

        #expect(sink.writes == [MJPEGEnvelope.header])
        stream.stop()
    }

    @Test func `should send each changed screen as a JPEG part`() throws {
        let sink = RecordingSink()
        let stream = MJPEGStream(config: .default, sink: sink, quality: 0.7)
        try stream.start(on: screen())

        stream.queue.sync { stream.encode(Surfaces.filled(0x10)) }
        stream.queue.sync { stream.encode(Surfaces.filled(0x20)) }

        #expect(sink.writes.dropFirst().count == 2)
        #expect(sink.writes.dropFirst().allSatisfy { $0.starts(with: Data("--frame\r\nContent-Type: image/jpeg".utf8)) })
        stream.stop()
    }

    @Test func `should send nothing when the screen has not changed since its last part`() throws {
        let sink = RecordingSink()
        let stream = MJPEGStream(config: .default, sink: sink, quality: 0.7)
        try stream.start(on: screen())
        let surface = Surfaces.filled(0x10)

        stream.queue.sync { stream.encode(surface) }
        stream.queue.sync { stream.encode(surface) }

        #expect(sink.writes.dropFirst().count == 1)
        stream.stop()
    }

    @Test func `should let go of the screen when it cannot start`() {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willThrow(ScreenDown())
        given(screen).stop().willReturn()
        let stream = MJPEGStream(config: .default, sink: RecordingSink(), quality: 0.7)

        #expect(throws: ScreenDown.self) { try stream.start(on: screen) }
        verify(screen).stop().called(1)
    }

    @Test func `should stop watching the screen when stopped`() throws {
        let screen = screen()
        let stream = MJPEGStream(config: .default, sink: RecordingSink(), quality: 0.7)
        try stream.start(on: screen)

        stream.stop()

        verify(screen).stop().called(1)
    }

    @Test func `should take a new frame rate and scale`() {
        let stream = MJPEGStream(config: .default, sink: RecordingSink(), quality: 0.7)

        stream.apply(StreamConfig.default.with(fps: 15, scale: 2))

        #expect(stream.config == StreamConfig(fps: 15, bitrateBps: StreamConfig.default.bitrateBps, scale: 2))
    }
}

struct ScreenDown: Error {}

/// Every chunk and failure a stream sent.
final class RecordingSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var errors: [any Error] = []

    func write(_ data: Data) { lock.withLock { chunks.append(data) } }
    func fail(_ error: any Error) { lock.withLock { errors.append(error) } }

    var writes: [Data] { lock.withLock { chunks } }
    var failures: Int { lock.withLock { errors.count } }
}

/// Small BGRA screens, filled with one byte.
enum Surfaces {
    static func filled(_ byte: Int32, width: Int = 8, height: Int = 8) -> IOSurface {
        let bytesPerRow = width * 4
        let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow, kIOSurfaceAllocSize: bytesPerRow * height,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary)!
        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), byte, bytesPerRow * height)
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}
