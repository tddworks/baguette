import Foundation

/// Side-channel that taps an AVCCStream's encoder output and produces a
/// finished `RecordingArtifact` on stop. Lives at the same layer as
/// `FrameSink` — Infrastructure-side port consumed by AVCCStream so the
/// stream doesn't know how the bytes are muxed.
///
/// All methods are called on the encoder's queue; impls must be safe to
/// call from there. `finish()` is called from a different queue (the
/// server's WS task) — impls block until the muxer has fully closed and
/// the file is on disk before returning.
protocol H264Recorder: AnyObject, Sendable {
    /// avcC parameter-set blob — emitted exactly once on the first IDR
    /// (and again on a forced keyframe). Recorder caches it as the
    /// SPS+PPS preamble for every keyframe it writes.
    func write(description avcc: Data)

    /// Length-prefixed AVCC NALUs for an IDR.
    func write(keyframe avcc: Data)

    /// Length-prefixed AVCC NALUs for a non-IDR P-frame.
    func write(delta avcc: Data)

    /// Close the muxer, wait for the file to land, return the artifact.
    /// Throws if the muxer never produced a non-empty file.
    func finish() throws -> RecordingArtifact

    /// Tear down without producing an artifact — used when the WS
    /// closes mid-recording. Must not throw.
    func cancel()
}
