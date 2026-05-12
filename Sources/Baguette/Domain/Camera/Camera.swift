import CoreGraphics
import Foundation
import Mockable

/// Inject image frames into a simulator's camera pipeline. Each call
/// to `injectImage` pushes one frame; `injectVideo` loops a file
/// continuously until `stop`. Per simulator — constructed via
/// `simulator.camera()`.
///
/// Uses `CGImage` at the domain boundary — it's a public Apple type
/// (no private-API leakage), and every image source (file, network,
/// in-memory buffer) converts to it cheaply.
@Mockable
protocol Camera: AnyObject, Sendable {
    /// Push a single still frame into the simulator's camera feed.
    func injectImage(_ image: CGImage) throws

    /// Begin looping video frames from the file at `url` into the
    /// simulator's camera feed. Frames are decoded and pushed at the
    /// video's native frame rate. Replaces any previously running
    /// video loop. Call `stop` to end.
    func injectVideo(url: URL) throws

    /// Tear down the camera pipeline and stop any active video loop.
    func stop()
}

enum CameraError: Error, Equatable {
    case deviceNotFound(udid: String)
    case ioUnavailable
    case cameraDescriptorNotFound
    case injectionFailed(reason: String)
    case videoDecodingFailed
    case unsupportedFormat
}
