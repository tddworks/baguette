import Foundation

/// Bytes that wrap each frame on the wire for `StreamFormat.mjpeg`.
/// Standard `multipart/x-mixed-replace` HTTP envelope so any browser
/// rendering `<img src="…/stream.mjpeg">` displays it natively.
enum MJPEGEnvelope {
    static let header: Data = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n".utf8
    )

    static func framed(jpeg: Data) -> Data {
        var out = Data()
        out.append(Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8))
        out.append(jpeg)
        out.append(Data("\r\n".utf8))
        return out
    }
}

/// Bytes that wrap each frame on the wire for `StreamFormat.avcc` (and
/// the underlying `h264` output, modulo the seed). Each chunk is a
/// length-prefixed payload tagged with one of four kinds:
///
/// - `0x01` description — avcC parameter-set blob (SPS/PPS)
/// - `0x02` keyframe — IDR with VCL NALUs
/// - `0x03` delta — non-IDR P-frame
/// - `0x04` seed — JPEG image used to paint the first frame instantly,
///   so consumers don't stare at a blank canvas waiting for the first IDR
///
/// The 4-byte big-endian length covers the tag byte plus the payload, so
/// a parser reads `len` then `len` bytes that start with the tag.
enum AVCCEnvelope {
    static let descriptionTag: UInt8 = 0x01
    static let keyframeTag:    UInt8 = 0x02
    static let deltaTag:       UInt8 = 0x03
    static let seedTag:        UInt8 = 0x04

    /// Reverse of `wrap` — recover the tag and payload of one chunk.
    /// Returns `nil` when the chunk is too short or its length prefix
    /// disagrees with the bytes actually present, so a consumer never
    /// trusts a truncated frame. Used by the device-twin ingest, which
    /// receives chunks in this envelope from the companion app.
    static func unwrap(_ chunk: Data) -> (tag: UInt8, payload: Data)? {
        guard chunk.count >= 5 else { return nil }
        let start = chunk.startIndex
        let length = UInt32(chunk[start]) << 24
            | UInt32(chunk[start + 1]) << 16
            | UInt32(chunk[start + 2]) << 8
            | UInt32(chunk[start + 3])
        guard length == UInt32(chunk.count - 4) else { return nil }
        return (chunk[start + 4], chunk.subdata(in: (start + 5)..<chunk.endIndex))
    }

    static func description(avcc: Data) -> Data { wrap(tag: descriptionTag, payload: avcc) }
    static func keyframe(avcc: Data) -> Data    { wrap(tag: keyframeTag, payload: avcc) }
    static func delta(avcc: Data) -> Data       { wrap(tag: deltaTag, payload: avcc) }
    static func seed(jpeg: Data) -> Data        { wrap(tag: seedTag, payload: jpeg) }

    private static func wrap(tag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count + 1)
        var out = Data(capacity: 5 + payload.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8)  & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(tag)
        out.append(payload)
        return out
    }
}
