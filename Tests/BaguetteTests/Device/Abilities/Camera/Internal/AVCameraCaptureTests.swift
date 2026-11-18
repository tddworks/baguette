import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("AVCameraCapture orchestrator")
struct AVCameraCaptureTests {

    final class Captures: @unchecked Sendable {
        var onFrame: (@Sendable (RawBGRAFrame) -> Void)?
        var stopCount: Int = 0
        var startedDeviceUID: String?
    }

    private func makeCapture() -> (AVCameraCapture, MockVideoCapture, Captures) {
        let video = MockVideoCapture()
        let cap = Captures()
        given(video).start(deviceUniqueID: .any, onFrame: .any).willProduce { uid, onFrame in
            cap.startedDeviceUID = uid
            cap.onFrame = onFrame
        }
        given(video).stop().willProduce { cap.stopCount += 1 }
        let capture = AVCameraCapture(video: video)
        return (capture, video, cap)
    }

    private static let webcam = CameraSource.device(uid: "U")

    @Test func `should open the chosen webcam when the camera starts`() async throws {
        let (capture, _, cap) = makeCapture()
        try await capture.start(source: Self.webcam) { _ in }
        #expect(cap.startedDeviceUID == "U")
    }

    @Test func `should refuse to start the webcam when the source is a file`() async {
        let (capture, _, _) = makeCapture()
        await #expect(throws: (any Error).self) {
            try await capture.start(source: .image(path: "/tmp/pic.png")) { _ in }
        }
    }

    @Test func `should deliver each webcam frame as a packed camera frame`() async throws {
        let (capture, _, cap) = makeCapture()
        let received = Recorder<CameraFrame>()
        try await capture.start(source: Self.webcam) { frame in
            received.record(frame)
        }

        // Push a 2×2 raw BGRA buffer through the captured onFrame.
        let pixels = Data([0x11, 0x22, 0x33, 0xFF,  0x44, 0x55, 0x66, 0xFF,
                           0x77, 0x88, 0x99, 0xFF,  0xAA, 0xBB, 0xCC, 0xFF])
        pixels.withUnsafeBytes { ptr in
            let raw = RawBGRAFrame(
                baseAddress: ptr.baseAddress!,
                width: 2, height: 2, bytesPerRow: 8, timestampMs: 99
            )
            cap.onFrame?(raw)
        }

        let frames = received.values
        #expect(frames.count == 1)
        #expect(frames[0].width == 2)
        #expect(frames[0].height == 2)
        #expect(frames[0].timestampMs == 99)
        #expect(frames[0].pixels == pixels)
    }

    @Test func `should number webcam frames in increasing sequence`() async throws {
        let (capture, _, cap) = makeCapture()
        let received = Recorder<CameraFrame>()
        try await capture.start(source: Self.webcam) { received.record($0) }
        let pixels = Data(repeating: 0, count: 16)
        pixels.withUnsafeBytes { ptr in
            let raw = RawBGRAFrame(
                baseAddress: ptr.baseAddress!,
                width: 2, height: 2, bytesPerRow: 8, timestampMs: 0
            )
            cap.onFrame?(raw); cap.onFrame?(raw); cap.onFrame?(raw)
        }
        #expect(received.values.map(\.sequence) == [1, 2, 3])
    }

    @Test func `should release the webcam when the camera stops`() async throws {
        let (capture, _, cap) = makeCapture()
        try await capture.start(source: Self.webcam) { _ in }
        await capture.stop()
        #expect(cap.stopCount == 1)
    }

    /// Class-boxed recorder so @Sendable callbacks can store frames.
    final class Recorder<T>: @unchecked Sendable {
        var values: [T] = []
        func record(_ v: T) { values.append(v) }
    }
}
