import Foundation

/// Mutable knobs the user can retune mid-stream — frame rate, bitrate, and
/// resolution scale. Carried as an immutable value; reconfig produces a
/// new value via `with(...)` rather than mutating in place.
struct StreamConfig: Equatable, Sendable {
    let fps: Int
    let bitrateBps: Int
    let scale: Int

    /// 8 Mbps default — H.264 with `MaxKeyFrameInterval = 1` makes every
    /// frame an IDR, so per-frame budget is the whole bitrate divided by
    /// fps. 2 Mbps starves at 60fps; 8 Mbps gives the High profile room
    /// to produce a clean image. MJPEG ignores this knob (uses `quality`).
    static let `default` = StreamConfig(fps: 60, bitrateBps: 8_000_000, scale: 1)

    /// Returns a copy with the supplied fields replaced. Pass only the
    /// knobs the user is changing; the rest fall through unchanged.
    func with(fps: Int? = nil, bitrateBps: Int? = nil, scale: Int? = nil) -> StreamConfig {
        StreamConfig(
            fps: fps ?? self.fps,
            bitrateBps: bitrateBps ?? self.bitrateBps,
            scale: scale ?? self.scale
        )
    }
}
