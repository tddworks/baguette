import CoreGraphics
import Foundation
import IOSurface
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
    /// Blocks until the frame has been delivered to the descriptor.
    func injectImage(_ image: CGImage) throws

    /// Begin looping video frames from the file at `url` into the
    /// simulator's camera feed. Frames are decoded and pushed at the
    /// video's native frame rate. Replaces any previously running
    /// video loop. Call `stop` to end.
    func injectVideo(url: URL) throws

    /// Tear down the camera pipeline and stop any active video loop.
    /// Safe to call multiple times.
    func stop()
}

/// Failure modes surfaced by the camera subsystem. Each maps to a
/// CLI exit message or an HTTP error response.
enum CameraError: Error, Equatable {
    /// The device host has no simulator with this UDID.
    case deviceNotFound(udid: String)

    /// `SimDeviceIO` is unavailable — the simulator may not be booted.
    case ioUnavailable

    /// No `com.apple.camera.*` IO port descriptor was found on the
    /// simulator's `SimDeviceIO` object.
    case cameraDescriptorNotFound

    /// A frame push failed after the descriptor was resolved.
    case injectionFailed(reason: String)

    /// `AVAssetReader` could not decode the video file.
    case videoDecodingFailed

    /// The file format is not a supported image or video type.
    case unsupportedFormat
}

/// Thin collaborator that owns the irreducible ObjC `perform(_:with:)`
/// calls for pushing an `IOSurface` into a SimulatorKit camera
/// descriptor. Extracted so `SimulatorKitCamera`'s orchestration can
/// be tested via `MockSurfacePusher` without a live simulator.
@Mockable
protocol SurfacePusher: AnyObject, Sendable {
    /// Push one `IOSurface` frame to the camera descriptor. Throws
    /// when no compatible selector (`pushIOSurface:`,
    /// `sendIOSurface:`, `setFramebufferSurface:`) responds.
    func push(_ surface: IOSurface, to descriptor: NSObject) throws
}

/// Thin collaborator that decodes a video file into a sequence of
/// `IOSurface` frames. Extracted so video-loop orchestration can be
/// tested via `MockVideoDecoder` without linking AVFoundation.
@Mockable
protocol VideoDecoder: AnyObject, Sendable {
    /// Decode frames from `url` and call `onFrame` for each. Loops
    /// the video until the task is cancelled. Throws on decode errors
    /// (missing track, reader init failure, etc.).
    func decodeLoop(url: URL, onFrame: @escaping @Sendable (IOSurface) throws -> Void) async throws
}
