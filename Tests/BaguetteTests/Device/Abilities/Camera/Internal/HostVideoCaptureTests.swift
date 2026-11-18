import AVFoundation
import CoreVideo
import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// What the Mac's camera capture decides, with AVFoundation's capture
/// session mocked: which camera and preset it runs, at what size, and how
/// each picture becomes a raw BGRA frame.
@Suite("HostVideoCapture")
struct HostVideoCaptureTests {

    /// A session that supports `supported` presets, runs any camera but
    /// `missing`, and keeps the picture handler it is given.
    private func session(
        supporting supported: [AVCaptureSession.Preset] = [.hd1280x720, .high, .medium],
        missing: String? = nil, handler: Handler = Handler()
    ) -> MockCaptureSession {
        let session = MockCaptureSession()
        given(session).supports(.any).willProduce { supported.contains($0) }
        given(session).run(camera: .any, preset: .any, width: .any, height: .any, onPicture: .any)
            .willProduce { camera, _, _, _, onPicture in
                handler.onPicture = onPicture
                return camera != missing
            }
        given(session).stop().willReturn()
        return session
    }

    @Test func `should run the chosen camera at 720p in BGRA`() async throws {
        let session = session()
        let capture = HostVideoCapture(session: session)

        try await capture.start(deviceUniqueID: "U") { _ in }

        verify(session).run(camera: .value("U"), preset: .value(.hd1280x720), width: .value(1280), height: .value(720),
                            onPicture: .any).called(1)
    }

    @Test func `should fall back to the best preset the camera supports`() async throws {
        let session = session(supporting: [.medium, .high])
        let capture = HostVideoCapture(session: session)

        try await capture.start(deviceUniqueID: "U") { _ in }

        verify(session).run(camera: .any, preset: .value(.high), width: .any, height: .any, onPicture: .any).called(1)
    }

    @Test func `should keep the camera's own preset when it supports none of ours`() async throws {
        let session = session(supporting: [])
        let capture = HostVideoCapture(session: session)

        try await capture.start(deviceUniqueID: "U") { _ in }

        verify(session).run(camera: .any, preset: .value(nil), width: .any, height: .any, onPicture: .any).called(1)
    }

    @Test func `should refuse a camera that is not attached`() async {
        let capture = HostVideoCapture(session: session(missing: "gone"))

        await #expect(throws: HostVideoCaptureError.self) {
            try await capture.start(deviceUniqueID: "gone") { _ in }
        }
    }

    @Test func `should refuse a camera that cannot be opened`() async {
        let session = MockCaptureSession()
        given(session).supports(.any).willReturn(true)
        given(session).run(camera: .any, preset: .any, width: .any, height: .any, onPicture: .any)
            .willThrow(CameraBusy())
        let capture = HostVideoCapture(session: session)

        await #expect(throws: CameraBusy.self) {
            try await capture.start(deviceUniqueID: "U") { _ in }
        }
    }

    @Test func `should hand each picture on as a raw BGRA frame stamped in milliseconds`() async throws {
        let handler = Handler()
        let capture = HostVideoCapture(session: session(handler: handler))
        let frames = Frames()
        try await capture.start(deviceUniqueID: "U") { frames.append($0) }

        handler.onPicture?(Self.picture(width: 4, height: 2, filledWith: 0x5A), 1.2345)

        let frame = try #require(frames.all.first)
        #expect(frame.width == 4 && frame.height == 2)
        #expect(frame.bytesPerRow >= 16)
        #expect(frame.timestampMs == 1234)
        #expect(frame.firstByte == 0x5A)
    }

    @Test func `should hand on no frames once stopped`() async throws {
        let handler = Handler()
        let session = session(handler: handler)
        let capture = HostVideoCapture(session: session)
        let frames = Frames()
        try await capture.start(deviceUniqueID: "U") { frames.append($0) }

        await capture.stop()
        handler.onPicture?(Self.picture(width: 4, height: 2, filledWith: 0), 0)

        #expect(frames.all.isEmpty)
        verify(session).stop().called(1)
    }

    private static func picture(width: Int, height: Int, filledWith byte: Int32) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), byte, CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }
}

private struct CameraBusy: Error {}

/// The picture handler a session was given.
private final class Handler: @unchecked Sendable {
    var onPicture: (@Sendable (CVPixelBuffer, Double) -> Void)?
}

/// What each frame said while its bytes were still valid.
private final class Frames: @unchecked Sendable {
    struct Seen { let width, height: UInt32; let bytesPerRow: Int; let timestampMs: UInt32; let firstByte: UInt8 }
    private let lock = NSLock()
    private var seen: [Seen] = []

    func append(_ frame: RawBGRAFrame) {
        let first = frame.baseAddress.load(as: UInt8.self)
        lock.withLock {
            seen.append(Seen(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
                             timestampMs: frame.timestampMs, firstByte: first))
        }
    }

    var all: [Seen] { lock.withLock { seen } }
}
