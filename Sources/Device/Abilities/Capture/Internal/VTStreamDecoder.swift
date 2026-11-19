import CoreVideo
import Foundation
import IOSurface

/// The `StreamDecoder` on VideoToolbox. A phone's screen stream (H.264) and
/// anything else that hands over raw parameter sets decode here; BGRA,
/// IOSurface-backed, like every Screen. Told the screen's size, it crops
/// each picture to it (the picture's top-left, by a clean aperture
/// VideoToolbox applies as it converts), so frames are the screen and never
/// the stream's padding.
///
/// It decides; the `DecompressionSession` only decompresses: whether to
/// crop, which frames to decode, and which pictures stay alive and go on.
public final class VTStreamDecoder: StreamDecoder, @unchecked Sendable {
    public convenience init() { self.init(session: VideoToolboxDecompressionSession()) }

    init(session: any DecompressionSession) { self.session = session }

    private let session: any DecompressionSession
    private let lock = NSLock()
    private var onFrame: (@Sendable (IOSurface) -> Void)?
    private var reportedDecodeFailure = false
    /// The last few decoded frames, kept alive. VideoToolbox reuses a
    /// frame's IOSurface as soon as its pixel buffer is released; the stream
    /// pipeline reads the newest surface a moment later, on its own tick.
    private var recent: [CVPixelBuffer] = []
    private static let heldFrames = 6
    /// Every NAL unit in a phone's stream carries a four-byte length.
    private static let prefixLength = 4

    /// How many decoded pictures are kept alive.
    var held: Int { lock.withLock { recent.count } }

    public func configure(parameterSets: [Data], screen: Size?, onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let coded: Size
        switch session.picture(parameterSets: parameterSets, nalUnitHeaderLength: Self.prefixLength) {
        case .success(let size): coded = size
        case .failure(let refusal): throw DecoderError(refusal)
        }
        let aperture = screen.flatMap { CleanAperture(screen: $0, picture: coded) }
        if let refusal = session.open(
            parameterSets: parameterSets, nalUnitHeaderLength: Self.prefixLength, croppedTo: aperture
        ) { throw DecoderError(refusal) }

        lock.withLock {
            self.onFrame = onFrame
            recent = []
        }
        log("[video] decoder configured: h264 \(Int(coded.width))×\(Int(coded.height))"
            + (aperture.map { ", cropped to \(Int($0.width))×\(Int($0.height))" } ?? ""))
    }

    /// Decodes synchronously, one frame after another in arrival order.
    public func decode(_ frame: Data) {
        guard let deliver = lock.withLock({ onFrame }), !frame.isEmpty else { return }
        session.decode(frame, asynchronously: false) { [weak self] result in
            guard let self else { return }
            guard let surface = result.surface, let picture = result.picture else {
                // Once: a failure at 60 fps must not flood the log.
                if !self.reportedDecodeFailure {
                    self.reportedDecodeFailure = true
                    log("[video] decode failed: status=\(result.status)")
                }
                return
            }
            self.hold(picture)
            deliver(surface)
        }
    }

    private func hold(_ buffer: CVPixelBuffer) {
        lock.withLock {
            recent.append(buffer)
            if recent.count > Self.heldFrames { recent.removeFirst(recent.count - Self.heldFrames) }
        }
    }

    public func stop() {
        lock.withLock {
            onFrame = nil
            recent = []
        }
        session.close()
    }

    public enum DecoderError: Error {
        case formatRejected(OSStatus)
        case sessionRejected(OSStatus)

        init(_ refusal: DecompressionRefusal) {
            switch refusal {
            case .format(let status): self = .formatRejected(status)
            case .session(let status): self = .sessionRejected(status)
            }
        }
    }
}
