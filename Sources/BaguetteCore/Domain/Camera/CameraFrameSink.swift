import Foundation
import Mockable

/// Writes a `CameraFrame` into the shared-memory ring buffer the
/// VirtualCamera dylib reads. `flags` ride in the same header so
/// the in-sim reader can apply Fit/Fill + Mirror without an
/// out-of-band signalling channel.
@Mockable
protocol CameraFrameSink: AnyObject, Sendable {
    var path: String { get }
    func write(_ frame: CameraFrame, flags: CameraFlags) throws
}
