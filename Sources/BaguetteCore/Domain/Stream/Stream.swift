import Foundation

/// A live frame stream of a particular wire format. Owns its lifecycle,
/// runtime config, and any format-specific state (envelope assembly,
/// encoder pipeline, AVCC seed bookkeeping). The orchestrator only sees
/// the verbs below — adding a new format means adding a new `Stream`
/// type, not editing the caller.
protocol Stream: AnyObject {
    /// Read-only view of the current runtime config.
    var config: StreamConfig { get }

    /// Subscribe to `screen` and start emitting envelopes to the sink.
    /// Throws if the screen pipe can't be wired (e.g. simulator not booted).
    func start(on screen: any Screen) throws

    /// Detach from the screen and stop emitting.
    func stop()

    /// Apply a new runtime config. Implementations apply only the deltas
    /// that affect them (e.g. H.264 retunes VT bitrate; MJPEG just stores
    /// scale for the next encode).
    func apply(_ config: StreamConfig)

    /// Force the next encoded frame to be a keyframe (IDR). No-op for
    /// stateless formats like MJPEG.
    func requestKeyframe()

    /// Emit a one-shot JPEG seed so consumers can paint immediately. No-op
    /// for formats that can't carry a seed envelope.
    func requestSnapshot()
}
