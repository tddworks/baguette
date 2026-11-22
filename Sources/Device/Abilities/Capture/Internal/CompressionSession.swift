import CoreMedia
import CoreVideo
import Foundation
import Mockable

/// A hardware H.264 compression session — VideoToolbox's
/// `VTCompressionSession`, reduced to the calls the encoder makes. Every
/// call answers an `OSStatus` (`0` is success) and decides nothing: when to
/// open, which frame is a keyframe and which answer counts belong to
/// `VideoEncoder`. The real one is `VideoToolboxSession`.
@Mockable
protocol CompressionSession: AnyObject, Sendable {
    /// Open a session for frames of this size, closing any open one first.
    func open(width: Int32, height: Int32, codec: CMVideoCodecType, lowLatencyRateControl: Bool) -> Int32
    func set(_ property: CompressionProperty) -> Int32
    func prepare() -> Int32
    /// Hand one frame in. `done` is called once, on the session's own queue,
    /// with what became of it.
    func submit(
        _ frame: CVPixelBuffer, at time: CMTime, keyframe: Bool,
        done: @escaping @Sendable (CompressionResult) -> Void
    ) -> Int32
    func close()
}

/// What the session made of one submitted frame.
struct CompressionResult: Sendable {
    let status: Int32
    /// A real-time session may finish a frame without emitting one.
    let dropped: Bool
    let frame: CompressedFrame?
}

/// One compressed frame: its length-prefixed NAL units, whether it is a
/// keyframe, and — on a keyframe — the parameter sets it was encoded with.
struct CompressedFrame: Equatable, Sendable {
    let avcc: Data
    let keyframe: Bool
    /// The decoder configuration records the encoder made for a keyframe, by
    /// atom — `"avcC"` for H.264, `"hvcC"` for HEVC — as it hands them back.
    var records: [String: Data] = [:]
}
