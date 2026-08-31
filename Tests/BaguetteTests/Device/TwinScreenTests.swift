import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette

@Suite("TwinScreen")
struct TwinScreenTests {
    /// Captures the frame callback `decoder.configure` was called with
    /// so tests can fire decoded surfaces on demand. Class so the
    /// `@Sendable` callback can box mutable state safely.
    final class Captures: @unchecked Sendable {
        var descriptions: [Data] = []
        var onFrame: (@Sendable (IOSurface) -> Void)?
    }

    final class Recorder: @unchecked Sendable {
        var frames: [IOSurface] = []
        func record(_ surface: IOSurface) { frames.append(surface) }
    }

    final class Clock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    private func makeScreen(clock: Clock = Clock()) -> (TwinScreen, MockH264Decoder, Captures) {
        let decoder = MockH264Decoder()
        let captures = Captures()
        given(decoder).configure(description: .any, onFrame: .any).willProduce { description, onFrame in
            captures.descriptions.append(description)
            captures.onFrame = onFrame
        }
        given(decoder).decode(.any).willReturn()
        given(decoder).stop().willReturn()
        return (TwinScreen(decoder: decoder, now: { clock.now }), decoder, captures)
    }

    private func surface() throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: 2, .height: 2, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
    }

    private let description = AVCCEnvelope.description(avcc: Data([0xAA, 0xBB]))
    private let keyframe = AVCCEnvelope.keyframe(avcc: Data([0x01]))
    private let delta = AVCCEnvelope.delta(avcc: Data([0x02]))

    @Test func `chunks before the description never reach the decoder`() {
        let (screen, decoder, _) = makeScreen()
        screen.ingest(chunk: keyframe)
        screen.ingest(chunk: delta)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `the description builds the decoder and frames decode after it`() {
        let (screen, decoder, captures) = makeScreen()
        screen.ingest(chunk: description)
        screen.ingest(chunk: keyframe)
        #expect(captures.descriptions == [Data([0xAA, 0xBB])])
        verify(decoder).decode(.value(Data([0x01]))).called(1)
    }

    @Test func `a second description reconfigures the decoder`() {
        let (screen, _, captures) = makeScreen()
        screen.ingest(chunk: description)
        screen.ingest(chunk: AVCCEnvelope.description(avcc: Data([0xCC])))
        #expect(captures.descriptions == [Data([0xAA, 0xBB]), Data([0xCC])])
    }

    @Test func `malformed chunks are ignored`() {
        let (screen, decoder, captures) = makeScreen()
        screen.ingest(chunk: Data([0x00]))
        #expect(captures.descriptions.isEmpty)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `decoded surfaces reach every subscribed view`() throws {
        let (screen, _, captures) = makeScreen()
        screen.ingest(chunk: description)
        let first = Recorder()
        let second = Recorder()
        try screen.view().start { first.record($0) }
        try screen.view().start { second.record($0) }
        captures.onFrame?(try surface())
        #expect(first.frames.count == 1)
        #expect(second.frames.count == 1)
    }

    @Test func `a late view immediately receives the latest surface`() throws {
        let (screen, _, captures) = makeScreen()
        screen.ingest(chunk: description)
        captures.onFrame?(try surface())
        let late = Recorder()
        try screen.view().start { late.record($0) }
        #expect(late.frames.count == 1)
    }

    @Test func `stopping a view detaches only that view`() throws {
        let (screen, _, captures) = makeScreen()
        screen.ingest(chunk: description)
        let kept = Recorder()
        let dropped = Recorder()
        let keptView = screen.view()
        let droppedView = screen.view()
        try keptView.start { kept.record($0) }
        try droppedView.start { dropped.record($0) }
        droppedView.stop()
        captures.onFrame?(try surface())
        #expect(kept.frames.count == 1)
        #expect(dropped.frames.isEmpty)
    }

    @Test func `the hub records when it last published a frame`() throws {
        // The gyro's render clock skips its forced refresh while
        // mirror frames are flowing — pose rides the next frame for
        // free — and only renders itself when the source goes idle
        // (ReplayKit stops sending when the phone's screen is static).
        let clock = Clock()
        let (screen, _, captures) = makeScreen(clock: clock)
        screen.ingest(chunk: description)
        #expect(screen.lastPublish == nil)
        clock.now = 123.5
        captures.onFrame?(try surface())
        #expect(screen.lastPublish == 123.5)
    }

    @Test func `close tears down the decoder and detaches every view`() throws {
        let (screen, decoder, captures) = makeScreen()
        screen.ingest(chunk: description)
        let viewer = Recorder()
        try screen.view().start { viewer.record($0) }
        screen.close()
        verify(decoder).stop().called(1)
        captures.onFrame?(try surface())
        #expect(viewer.frames.isEmpty)
    }
}
