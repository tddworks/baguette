import Foundation

/// Mutable knobs the user can retune mid-stream — frame rate, bitrate, and
/// resolution scale. Carried as an immutable value; reconfig produces a
/// new value via `with(...)` rather than mutating in place.
public struct StreamConfig: Equatable, Sendable {
    public let fps: Int
    public let bitrateBps: Int
    public let scale: Int

    /// 8 Mbps default — H.264 with `MaxKeyFrameInterval = 1` makes every
    /// frame an IDR, so per-frame budget is the whole bitrate divided by
    /// fps. 2 Mbps starves at 60fps; 8 Mbps gives the High profile room
    /// to produce a clean image. MJPEG ignores this knob (uses `quality`).
    public static let `default` = StreamConfig(fps: 60, bitrateBps: 8_000_000, scale: 1)

    /// Where a stream of `format` starts. Every MJPEG image is a whole
    /// picture — ~890 KB at an iPhone's full size — so it starts at half
    /// size and 30 fps, an eighth of the bytes; `set_scale` / `set_fps`
    /// still raise it (docs/features/stream/design.md).
    public static func `default`(for format: StreamFormat) -> StreamConfig {
        format == .mjpeg ? Self.default.with(fps: 30).with(scale: 2) : Self.default
    }

    /// Returns a copy with the supplied fields replaced. Pass only the
    /// knobs the user is changing; the rest fall through unchanged.
    public func with(fps: Int? = nil, bitrateBps: Int? = nil, scale: Int? = nil) -> StreamConfig {
        StreamConfig(
            fps: fps ?? self.fps,
            bitrateBps: bitrateBps ?? self.bitrateBps,
            scale: scale ?? self.scale
        )
    }

    /// One knob turned: what a page's `set_bitrate` / `set_fps` / `set_scale`
    /// or a viewer's retune asks of a running stream. A stream applies it to
    /// its config as it stands then, so two at once both land.
    public enum Change: Equatable, Sendable {
        case bitrate(Int)
        case fps(Int)
        case scale(Int)

        public func applied(to config: StreamConfig) -> StreamConfig {
            switch self {
            case .bitrate(let bps): config.with(bitrateBps: bps)
            case .fps(let fps): config.with(fps: fps)
            case .scale(let scale): config.with(scale: scale)
            }
        }
    }

    public init(fps: Int, bitrateBps: Int, scale: Int) {
        self.fps = fps
        self.bitrateBps = bitrateBps
        self.scale = scale
    }
}
