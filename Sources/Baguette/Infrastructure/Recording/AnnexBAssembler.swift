import Foundation

/// Stitches the three flavours of `H264Encoder.Encoded` (description,
/// keyframe, delta) into a single Annex B byte stream that can be piped
/// straight to `ffmpeg -f h264 -i pipe:`. State machine:
///
///   1. Drop frames before the first `description` arrives — ffmpeg
///      can't decode a half-stream without SPS/PPS, and the encoder
///      always emits description on the very first IDR anyway.
///   2. Cache SPS+PPS Annex B from each `description`.
///   3. Re-emit SPS+PPS in front of every keyframe. Reseating the
///      parameter sets at every IDR keeps each keyframe a clean seek
///      point and survives mid-stream resolution / bitrate changes.
///   4. Deltas are emitted as their NALU payloads alone.
struct AnnexBAssembler {
    private var cachedParameterSets: Data?

    mutating func description(_ avcCBlob: Data) {
        if let annexB = AVCCToAnnexB.parameterSetsAnnexB(fromAvcCBlob: avcCBlob) {
            cachedParameterSets = annexB
        }
    }

    mutating func keyframe(_ avcc: Data) -> Data {
        guard let preamble = cachedParameterSets else { return Data() }
        var out = Data()
        out.append(preamble)
        out.append(AVCCToAnnexB.naluPayloads(fromAvcc: avcc))
        return out
    }

    mutating func delta(_ avcc: Data) -> Data {
        guard cachedParameterSets != nil else { return Data() }
        return AVCCToAnnexB.naluPayloads(fromAvcc: avcc)
    }
}
