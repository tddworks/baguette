import Foundation

/// Layout of the mmap'd buffer at `/tmp/SimCam.bgra` (the path the
/// `VirtualCamera` dylib reads). 24-byte little-endian header, then
/// BGRA pixels (premultiplied-first, byteOrder32Little) up to the
/// canvas cap.
///
/// Header (24 bytes LE):
///   [ 0..< 4]  sequence       UInt32 — monotonic, reader picks up new frames
///   [ 4..< 8]  timestampMs    UInt32 — capture wall clock, milliseconds
///   [ 8..<12]  width          UInt32 — pixel width
///   [12..<16]  height         UInt32 — pixel height
///   [16..<20]  flags          UInt32 — bit 0 fillGravity, bit 1 mirror
///   [20..<24]  reserved       zeros
///   [24...  ]  BGRA pixels
///
/// The canvas cap (1280×1280) is fixed by the dylib's reader — the
/// reader allocates a static buffer of this size and rejects larger
/// frames as a safety net against truncated reads.
enum SharedFrameLayout {
    static let headerSize: Int = 24
    static let maxCanvasWidth: Int = 1280
    static let maxCanvasHeight: Int = 1280
    static var totalByteCount: Int { headerSize + maxCanvasWidth * maxCanvasHeight * 4 }

    static func encodeHeader(
        sequence: UInt32,
        timestampMs: UInt32,
        width: UInt32,
        height: UInt32,
        flags: UInt32
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: headerSize)
        writeLE(sequence,    into: &bytes, at: 0)
        writeLE(timestampMs, into: &bytes, at: 4)
        writeLE(width,       into: &bytes, at: 8)
        writeLE(height,      into: &bytes, at: 12)
        writeLE(flags,       into: &bytes, at: 16)
        return bytes
    }

    private static func writeLE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset]     = UInt8(value        & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8)  & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
