import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// `FrameSink` impl that pushes encoded bytes onto a Hummingbird
/// WebSocket as binary messages.
///
/// MJPEG and AVCC streams emit format-specific *transport envelopes*
/// designed for HTTP / stdout consumers — multipart MIME for MJPEG,
/// 4-byte big-endian length prefix for AVCC. Browsers reading from a
/// WebSocket want one frame per binary message, *without* those
/// envelopes. This sink parses what the encoder hands it and emits
/// WS-ready bytes:
///
///   MJPEG: scan multipart for JPEG (`FFD8`…`FFD9`) → emit raw JPEG.
///   AVCC:  strip the 4-byte length prefix             → emit
///                                                       [1B tag][payload]
///                                                       (the JS decoder
///                                                       already expects
///                                                       this shape).
///
/// Async writes are serialised per-client by chaining one Task onto
/// the next so chunks arrive in order without blocking the encoder.
/// Slow clients accumulate Tasks; the WebSocket close drains them.
final class WebSocketFrameSink: FrameSink, @unchecked Sendable {
    private let outbound: WebSocketOutboundWriter
    private let format: StreamFormat
    private let lock = NSLock()
    private var lastWrite: Task<Void, Never>?

    // Per-format parser state, lock-protected. The encoder calls
    // `write` from its own queue; we keep the parser strictly
    // single-threaded.
    private var mjpegBuffer = Data()
    private var mjpegHeaderSkipped = false
    private var avccBuffer = Data()

    init(outbound: WebSocketOutboundWriter, format: StreamFormat) {
        self.outbound = outbound
        self.format = format
    }

    func write(_ data: Data) {
        let messages = parse(data)
        guard !messages.isEmpty else { return }
        for msg in messages {
            enqueue(msg)
        }
    }

    // MARK: - parsing (lock held)

    private func parse(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        switch format {
        case .mjpeg: return parseMJPEG(chunk)
        case .avcc:  return parseAVCC(chunk)
        }
    }

    /// Strip the multipart preamble once, then peel raw JPEGs by
    /// SOI/EOI (`FFD8`…`FFD9`). Mirrors `MJPEGParser` in the plugin.
    private func parseMJPEG(_ chunk: Data) -> [Data] {
        if !mjpegHeaderSkipped {
            mjpegBuffer.append(chunk)
            if let r = mjpegBuffer.range(of: Data("\r\n\r\n".utf8)) {
                mjpegBuffer = Data(mjpegBuffer[r.upperBound...])
                mjpegHeaderSkipped = true
            } else {
                return []
            }
        } else {
            mjpegBuffer.append(chunk)
        }
        if mjpegBuffer.count > 2 * 1024 * 1024 {
            mjpegBuffer = Data(mjpegBuffer.suffix(1024 * 1024))
        }

        var frames: [Data] = []
        while true {
            guard let soi = mjpegBuffer.firstRange(of: Data([0xFF, 0xD8])) else { break }
            let after = mjpegBuffer.index(soi.lowerBound, offsetBy: 2)
            guard after < mjpegBuffer.endIndex,
                  let eoi = mjpegBuffer[after...].firstRange(of: Data([0xFF, 0xD9]))
            else { break }
            frames.append(Data(mjpegBuffer[soi.lowerBound..<eoi.upperBound]))
            mjpegBuffer = Data(mjpegBuffer[eoi.upperBound...])
        }
        return frames
    }

    /// Drop the 4-byte length prefix per envelope; the remaining
    /// `[tag][payload]` shape is what the JS decoder expects.
    private func parseAVCC(_ chunk: Data) -> [Data] {
        avccBuffer.append(chunk)
        var msgs: [Data] = []
        while avccBuffer.count >= 4 {
            let len =
                Int(avccBuffer[avccBuffer.startIndex])     << 24 |
                Int(avccBuffer[avccBuffer.startIndex + 1]) << 16 |
                Int(avccBuffer[avccBuffer.startIndex + 2]) << 8  |
                Int(avccBuffer[avccBuffer.startIndex + 3])
            guard len > 0, avccBuffer.count >= 4 + len else { break }
            let body = Data(avccBuffer[
                avccBuffer.startIndex + 4 ..< avccBuffer.startIndex + 4 + len
            ])
            avccBuffer = Data(avccBuffer[(avccBuffer.startIndex + 4 + len)...])
            msgs.append(body)
        }
        return msgs
    }

    // MARK: - WS write serialisation

    private func enqueue(_ data: Data) {
        let bytes = ByteBuffer(bytes: data)
        lock.lock()
        let prev = lastWrite
        let outbound = self.outbound
        lastWrite = Task {
            await prev?.value
            try? await outbound.write(.binary(bytes))
        }
        lock.unlock()
    }
}
