import AVFoundation
import CoreVideo
import Foundation

/// `CaptureSession` on AVFoundation: each call is the `AVCaptureSession`
/// plumbing it names. Which preset and size is `HostVideoCapture`'s.
final class AVFoundationCaptureSession: NSObject, CaptureSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "baguette.camera.capture")
    private let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private var onPicture: (@Sendable (CVPixelBuffer, Double) -> Void)?

    func supports(_ preset: AVCaptureSession.Preset) -> Bool { session.canSetSessionPreset(preset) }

    func run(
        camera uniqueID: String, preset: AVCaptureSession.Preset?, width: Int, height: Int,
        onPicture: @escaping @Sendable (CVPixelBuffer, Double) -> Void
    ) throws -> Bool {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { return false }
        let input = try AVCaptureDeviceInput(device: device)
        self.onPicture = onPicture

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        if let preset { session.sessionPreset = preset }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        output = out

        session.startRunning()
        return true
    }

    func stop() {
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        output = nil
        onPicture = nil
    }
}

extension AVFoundationCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let onPicture, let picture = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPicture(picture, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
}
