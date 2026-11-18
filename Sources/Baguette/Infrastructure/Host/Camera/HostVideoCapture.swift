import Foundation
import AVFoundation
import CoreVideo

/// Thin production wrapper around `AVCaptureSession`. This is the
/// integration-only file in the camera capture path — every line
/// either talks to AVFoundation or hands off to the orchestrator.
/// No business logic lives here; coverage is satisfied by manual
/// smoke (run `baguette serve`, point a Mac camera at the picker,
/// verify frames appear in the simulator).
final class HostVideoCapture: NSObject, VideoCapture, @unchecked Sendable {

    private let queue = DispatchQueue(label: "baguette.camera.capture")
    private let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private var onFrame: (@Sendable (RawBGRAFrame) -> Void)?

    func start(
        deviceUniqueID: String,
        onFrame: @escaping @Sendable (RawBGRAFrame) -> Void
    ) async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw HostVideoCaptureError.deviceUnavailable(uid: deviceUniqueID)
        }
        let input = try AVCaptureDeviceInput(device: device)
        self.onFrame = onFrame

        let out = AVCaptureVideoDataOutput()
        // Pin the output size to the shared-buffer canvas cap. Without
        // these keys AVFoundation emits at the camera's *native*
        // resolution (1080p / 4K on modern FaceTime HD), which exceeds
        // `SharedFrameLayout.maxCanvasWidth/Height` (1280×1280) and
        // every frame gets rejected before reaching the dylib's
        // reader. SimCamMac does the same — `.hd1280x720` preset +
        // pinned width/height — see asc-pro/SimCam/AVCameraSource.
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: 1280,
            kCVPixelBufferHeightKey as String: 720,
        ]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        // Pick the most-specific preset this device supports up to
        // 1280×720. Continuity Camera devices don't advertise every
        // preset; degrade gracefully.
        for preset: AVCaptureSession.Preset in [.hd1280x720, .high, .medium] {
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
        }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        self.output = out

        session.startRunning()
    }

    func stop() async {
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        self.output = nil
        self.onFrame = nil
    }
}

extension HostVideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let onFrame = self.onFrame,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
        let w = UInt32(CVPixelBufferGetWidth(pixel))
        let h = UInt32(CVPixelBufferGetHeight(pixel))
        let bpr = CVPixelBufferGetBytesPerRow(pixel)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ms = UInt32(truncatingIfNeeded: Int64(CMTimeGetSeconds(pts) * 1000))

        let raw = RawBGRAFrame(
            baseAddress: UnsafeRawPointer(base),
            width: w, height: h,
            bytesPerRow: bpr,
            timestampMs: ms
        )
        onFrame(raw)
    }
}

enum HostVideoCaptureError: Error, CustomStringConvertible {
    case deviceUnavailable(uid: String)

    var description: String {
        switch self {
        case .deviceUnavailable(let uid):
            return "no AVCaptureDevice with unique ID '\(uid)'"
        }
    }
}
