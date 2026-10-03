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
/// Async writes are serialised per-client: a single drain task owns
/// the socket, so chunks arrive in order without blocking the encoder.
/// A client that reads slower than the encoder produces cannot grow
/// the server without bound — `FrameBacklog` discards the oldest MJPEG
/// frames once its byte budget is reached, while an AVCC backlog keeps
/// every encoded reference and the socket closes with an error once the
/// consumer falls `FrameBacklog.referenceByteBudget` behind.
final class WebSocketFrameSink: FrameSink, @unchecked Sendable {
    private let outbound: WebSocketOutboundWriter
    private let format: StreamFormat
    private let lock = NSLock()
    private var backlog: FrameBacklog
    private var stopped = false
    private var draining = false

    // Per-format parser state, lock-protected. The encoder calls
    // `write` from its own queue; we keep the parser strictly
    // single-threaded.
    private var mjpegBuffer = Data()
    private var mjpegHeaderSkipped = false
    private var avccBuffer = Data()

    init(outbound: WebSocketOutboundWriter, format: StreamFormat) {
        self.outbound = outbound
        self.format = format
        self.backlog = FrameBacklog(format: format)
    }

    func write(_ data: Data) {
        let messages = parse(data)
        guard !messages.isEmpty else { return }
        for msg in messages {
            enqueue(msg)
        }
    }

    /// Drops whatever is queued and refuses further frames; the drain
    /// task, if one is running, stops at its next read.
    func stop() {
        lock.withLock {
            stopped = true
            backlog = FrameBacklog()
        }
    }

    /// Encoder-side failure: report once, then close. Later frames and
    /// failures are ignored.
    func fail(_ error: any Error) {
        let firstFailure = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            backlog = FrameBacklog()
            return true
        }
        if firstFailure { Task { await reportFailure(String(describing: error)) } }
    }

    /// The same report from a route that can await the close itself.
    func failAndClose(_ error: any Error) async {
        let firstFailure = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            backlog = FrameBacklog()
            return true
        }
        if firstFailure { await reportFailure(String(describing: error)) }
    }

    private func reportFailure(_ message: String) async {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "error": message])
            try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
        } catch { log("WebSocket stream error delivery failed: \(error)") }
        do { try await outbound.close(.unexpectedServerError, reason: "Stream failed") } catch {
            log("WebSocket stream close failed: \(error)")
        }
    }

    // MARK: - parsing (lock held)

    private func parse(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        switch format {
        case .mjpeg: return parseMJPEG(chunk)
        case .avcc: return parseAVCC(chunk)
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
                Int(avccBuffer[avccBuffer.startIndex]) << 24 | Int(avccBuffer[avccBuffer.startIndex + 1]) << 16 | Int(
                    avccBuffer[avccBuffer.startIndex + 2]) << 8 | Int(avccBuffer[avccBuffer.startIndex + 3])
            guard len > 0, avccBuffer.count >= 4 + len else { break }
            let body = Data(
                avccBuffer[
                    avccBuffer.startIndex + 4..<avccBuffer.startIndex + 4 + len
                ])
            avccBuffer = Data(avccBuffer[(avccBuffer.startIndex + 4 + len)...])
            msgs.append(body)
        }
        return msgs
    }

    // MARK: - WS write serialisation

    /// Hand the frame to the backlog, then make sure exactly one drain
    /// task is running. A single task owns frame ordering, while the codec's
    /// backlog policy bounds memory without losing H.264 references.
    private func enqueue(_ data: Data) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        guard backlog.append(data) else {
            stopped = true
            backlog = FrameBacklog()
            lock.unlock()
            Task { await reportFailure("H.264 consumer fell \(FrameBacklog.referenceByteBudget) bytes behind") }
            return
        }
        let needsDrain = !draining
        if needsDrain { draining = true }
        lock.unlock()
        if needsDrain { startDraining() }
    }

    /// Write pending frames until the backlog runs dry, then stand down.
    /// The next `enqueue` starts a fresh drain — so at most one task is
    /// ever outstanding, however far behind the client falls.
    private func startDraining() {
        let outbound = self.outbound
        Task { [weak self] in
            while let next = self?.nextFrame() {
                do {
                    try await outbound.write(.binary(ByteBuffer(bytes: next)))
                } catch {
                    // A write can fail with the socket still open; report
                    // and close rather than leave a client on a frozen
                    // picture. On a socket that is already gone the report
                    // and close fail too and are logged.
                    log("WebSocket frame delivery failed: \(error)")
                    await self?.failAndClose(error)
                    return
                }
            }
        }
    }

    /// Pop the next frame, standing the drain down when none is left.
    /// Synchronous on purpose: `NSLock` is unavailable from an async
    /// context, so the critical section stays out of the drain's `await`.
    private func nextFrame() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            draining = false
            return nil
        }
        let next = backlog.popFirst()
        if next == nil { draining = false }
        return next
    }
}
