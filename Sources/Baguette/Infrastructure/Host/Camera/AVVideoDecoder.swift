import Foundation
import AVFoundation
import CoreVideo

/// The irreducible AVFoundation side of video-file playback: opens an
/// `AVAssetReader` over the video track, requests BGRA output already
/// scaled to the fitted size (mirroring how `HostVideoCapture` bounds
/// the webcam via `videoSettings`), and hands successive frames back as
/// `DecodedVideoFrame`s. Integration-only — the loop/pacing logic it
/// serves is unit-tested in `VideoFileCapture` via `MockVideoDecoder`.
///
/// Rotation metadata (`preferredTransform`) is not applied to the
/// pixels — a video recorded in a rotated sensor orientation streams in
/// its encoded orientation. See `docs/features/camera/README.md` known limits.
///
/// All mutable state is behind sync accessors so the async `start` /
/// `rewind` never touch the lock in an async context.
final class AVVideoDecoder: VideoDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPath: String?
    private var maxDimension = SharedFrameLayout.maxCanvasWidth
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    func start(path: String, maxDimension: Int) async throws {
        stop()  // cancel any reader still streaming, so start is self-contained
        setConfig(path: path, maxDimension: maxDimension)
        try await openReader()
    }

    func nextFrame() throws -> DecodedVideoFrame? {
        let (rdr, out) = currentReader()
        guard let out, let rdr else { throw VideoDecoderError.notStarted }
        guard rdr.status == .reading, let sample = out.copyNextSampleBuffer() else {
            return nil  // end of asset (or a read failure — orchestrator loops/guards)
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        return Self.decode(
            pixelBuffer: pixelBuffer,
            presentationMs: DecodedVideoFrame.presentationMs(seconds: seconds)
        )
    }

    func rewind() async throws {
        stop()
        try await openReader()
    }

    func stop() {
        let (rdr, _) = currentReader()
        setReader(nil, output: nil)
        rdr?.cancelReading()
    }

    // MARK: - Reader setup

    private func openReader() async throws {
        let (path, maxDimension) = config()
        guard let path else { throw VideoDecoderError.notStarted }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw VideoDecoderError.noVideoTrack(path)
        }
        let natural = try await track.load(.naturalSize)
        let fit = ScaleToFit.fit(
            width: Int(abs(natural.width)),
            height: Int(abs(natural.height)),
            max: maxDimension
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: fit.width,
                kCVPixelBufferHeightKey as String: fit.height,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoDecoderError.cannotRead(path) }
        reader.add(output)
        guard reader.startReading() else { throw VideoDecoderError.cannotRead(path) }

        setReader(reader, output: output)
    }

    // MARK: - Sync lock accessors

    private func setConfig(path: String, maxDimension: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.storedPath = path
        self.maxDimension = maxDimension
    }

    private func config() -> (String?, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (storedPath, maxDimension)
    }

    private func setReader(_ reader: AVAssetReader?, output: AVAssetReaderTrackOutput?) {
        lock.lock()
        defer { lock.unlock() }
        self.reader = reader
        self.output = output
    }

    private func currentReader() -> (AVAssetReader?, AVAssetReaderTrackOutput?) {
        lock.lock()
        defer { lock.unlock() }
        return (reader, output)
    }

    // MARK: - Pixel copy

    /// Copy a locked `CVPixelBuffer` into a tightly-packed BGRA
    /// `DecodedVideoFrame`, stripping any row padding.
    private static func decode(pixelBuffer: CVPixelBuffer, presentationMs: UInt32) -> DecodedVideoFrame {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tight = width * 4
        var pixels = Data(count: tight * height)
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            pixels.withUnsafeMutableBytes { dst in
                guard let out = dst.baseAddress else { return }
                if bytesPerRow == tight {
                    memcpy(out, base, tight * height)
                } else {
                    for row in 0..<height {
                        memcpy(out + row * tight, base + row * bytesPerRow, tight)
                    }
                }
            }
        }
        return DecodedVideoFrame(
            pixels: pixels,
            width: UInt32(width),
            height: UInt32(height),
            presentationMs: presentationMs
        )
    }
}

/// `LocalizedError` as well as `CustomStringConvertible` — see
/// `StillImageError` for why both spellings are needed.
enum VideoDecoderError: LocalizedError, Equatable, CustomStringConvertible {
    case notStarted
    case noVideoTrack(String)
    case cannotRead(String)

    var description: String {
        switch self {
        case .notStarted: return "video decoder: not started"
        case .noVideoTrack(let path): return "video decoder: no video track in '\(path)'"
        case .cannotRead(let path): return "video decoder: could not read '\(path)'"
        }
    }

    var errorDescription: String? { description }
}
