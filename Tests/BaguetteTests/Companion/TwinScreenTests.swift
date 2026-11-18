import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette

final class LockedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    func append(_ chunk: Data) { lock.lock(); stored.append(chunk); lock.unlock() }
    var chunks: [Data] { lock.lock(); defer { lock.unlock() }; return stored } 
}

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

    @Test func `should decode nothing that arrives before the stream description`() {
        let (screen, decoder, _) = makeScreen()
        screen.ingest(chunk: keyframe)
        screen.ingest(chunk: delta)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `should start decoding from the stream description once a frame viewer watches`() {
        let (screen, decoder, captures) = makeScreen()
        try? screen.view().start { _ in }
        screen.ingest(chunk: description)
        screen.ingest(chunk: keyframe)
        #expect(captures.descriptions == [Data([0xAA, 0xBB])])
        verify(decoder).decode(.value(Data([0x01]))).called(1)
    }

    @Test func `should decode nothing when no frame viewer watches`() {
        // Lazy pixels: a connected but unwatched phone costs nothing.
        let (screen, decoder, _) = makeScreen()
        screen.ingest(chunk: description)
        screen.ingest(chunk: keyframe)
        screen.ingest(chunk: delta)
        verify(decoder).configure(description: .any, onFrame: .any).called(0)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `should start decoding for a late frame viewer from the cached description and next keyframe`() {
        let (screen, decoder, captures) = makeScreen()
        screen.ingest(chunk: description)
        screen.ingest(chunk: keyframe)
        try? screen.view().start { _ in }
        #expect(captures.descriptions == [Data([0xAA, 0xBB])])
        screen.ingest(chunk: delta) // pre-keyframe from the new session's view
        verify(decoder).decode(.any).called(0)
        screen.ingest(chunk: keyframe)
        verify(decoder).decode(.any).called(1)
    }

    @Test func `should stop decoding when the last frame viewer leaves`() {
        let (screen, decoder, _) = makeScreen()
        let view = screen.view()
        try? view.start { _ in }
        screen.ingest(chunk: description)
        view.stop()
        verify(decoder).stop().called(1)
        screen.ingest(chunk: keyframe)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `should give a byte viewer the cached description, then video from the next keyframe`() {
        // The byte role: H.264 passthrough, no decode anywhere.
        let (screen, decoder, _) = makeScreen()
        screen.ingest(chunk: description)
        screen.ingest(chunk: keyframe)
        let received = LockedChunks()
        let id = UUID()
        screen.attachBytes(id: id) { received.append($0) }
        #expect(received.chunks == [description])   // replayed at attach
        screen.ingest(chunk: delta)                  // references unseen frames
        #expect(received.chunks == [description])
        screen.ingest(chunk: keyframe)
        screen.ingest(chunk: delta)
        #expect(received.chunks == [description, keyframe, delta])
        verify(decoder).configure(description: .any, onFrame: .any).called(0)
    }

    @Test func `should hold byte viewers back until the next keyframe when a fresh description arrives`() {
        let (screen, _, _) = makeScreen()
        screen.ingest(chunk: description)
        let received = LockedChunks()
        let id = UUID()
        screen.attachBytes(id: id) { received.append($0) }
        screen.ingest(chunk: keyframe)
        let second = AVCCEnvelope.description(avcc: Data([0xCC]))
        screen.ingest(chunk: second)
        screen.ingest(chunk: delta)   // stale against the new parameters
        #expect(received.chunks == [description, keyframe, second])
        screen.ingest(chunk: keyframe)
        #expect(received.chunks.count == 4)
    }

    @Test func `should send nothing further to a byte viewer once detached`() {
        let (screen, _, _) = makeScreen()
        screen.ingest(chunk: description)
        let received = LockedChunks()
        let id = UUID()
        screen.attachBytes(id: id) { received.append($0) }
        screen.detachBytes(id: id)
        screen.ingest(chunk: keyframe)
        #expect(received.chunks == [description])
    }

    @Test func `should reconfigure decoding when a second stream description arrives`() {
        let (screen, _, captures) = makeScreen()
        try? screen.view().start { _ in }
        screen.ingest(chunk: description)
        screen.ingest(chunk: AVCCEnvelope.description(avcc: Data([0xCC])))
        #expect(captures.descriptions == [Data([0xAA, 0xBB]), Data([0xCC])])
    }

    @Test func `should ignore a malformed video chunk`() {
        let (screen, decoder, captures) = makeScreen()
        screen.ingest(chunk: Data([0x00]))
        #expect(captures.descriptions.isEmpty)
        verify(decoder).decode(.any).called(0)
    }

    @Test func `should deliver each decoded frame to every watching viewer`() throws {
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

    @Test func `should give a late frame viewer the latest frame right away`() throws {
        let (screen, _, captures) = makeScreen()
        try screen.view().start { _ in } // first consumer starts the decoder
        screen.ingest(chunk: description)
        captures.onFrame?(try surface())
        let late = Recorder()
        try screen.view().start { late.record($0) }
        #expect(late.frames.count == 1)
    }

    @Test func `should stop delivering only to the frame viewer that stops`() throws {
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

    @Test func `should remember when it last published a frame`() throws {
        // The gyro's render clock skips its forced refresh while
        // mirror frames are flowing — pose rides the next frame for
        // free — and only renders itself when the source goes idle
        // (ReplayKit stops sending when the phone's screen is static).
        let clock = Clock()
        let (screen, _, captures) = makeScreen(clock: clock)
        try screen.view().start { _ in }
        screen.ingest(chunk: description)
        #expect(screen.lastPublish == nil)
        clock.now = 123.5
        captures.onFrame?(try surface())
        #expect(screen.lastPublish == 123.5)
    }

    @Test func `should drop delta frames until a keyframe follows each stream description`() {
        // A companion (re)sends its description mid-GOP on reconnects;
        // the deltas that follow reference frames this decoder never
        // saw and VideoToolbox rejects them (-12909). Video resumes at
        // the next keyframe, exactly like a late-joining viewer.
        let (screen, decoder, _) = makeScreen()
        try? screen.view().start { _ in }
        screen.ingest(chunk: description)
        screen.ingest(chunk: delta)
        verify(decoder).decode(.any).called(0)
        screen.ingest(chunk: keyframe)
        screen.ingest(chunk: delta)
        verify(decoder).decode(.any).called(2)
        screen.ingest(chunk: AVCCEnvelope.description(avcc: Data([0xCC])))
        screen.ingest(chunk: delta)
        verify(decoder).decode(.any).called(2)
    }

    @Test func `should stop decoding and detach every viewer when closed`() throws {
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
