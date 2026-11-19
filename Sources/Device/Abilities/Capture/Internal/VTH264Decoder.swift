import CoreVideo
import Foundation
import IOSurface

/// The `H264Decoder` on VideoToolbox, behind the device twin's video.
///
/// It decides; the `DecompressionSession` only decompresses: which avcC
/// records it takes (parsed by `AVCCParameterSets`), which parameter sets
/// its session opens with, and which pictures go on.
public final class VTH264Decoder: H264Decoder, @unchecked Sendable {
    public convenience init() { self.init(session: VideoToolboxDecompressionSession()) }

    init(session: any DecompressionSession) { self.session = session }

    private let session: any DecompressionSession
    private let lock = NSLock()
    private var onFrame: (@Sendable (IOSurface) -> Void)?
    private var reportedDecodeFailure = false

    public func configure(description: Data, onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        guard let sets = AVCCParameterSets.parse(avcC: description) else {
            throw DecoderError.malformedDescription
        }
        if let refusal = session.open(
            parameterSets: [sets.sps[0], sets.pps[0]], nalUnitHeaderLength: sets.naluHeaderLength, croppedTo: nil
        ) {
            switch refusal {
            case .format(let status): throw DecoderError.formatRejected(status)
            case .session(let status): throw DecoderError.sessionRejected(status)
            }
        }
        lock.withLock { self.onFrame = onFrame }
        log("[device] decoder configured (\(sets.naluHeaderLength)-byte NALU prefixes)")
    }

    public func decode(_ frame: Data) {
        guard let deliver = lock.withLock({ onFrame }) else { return }
        session.decode(frame, asynchronously: true) { [weak self] result in
            guard let surface = result.surface else {
                // One line, once — a decode failure at 30 fps must not
                // flood the log, but a silent black mirror is worse.
                if let self, !self.reportedDecodeFailure {
                    self.reportedDecodeFailure = true
                    log("[device] decode failed: status=\(result.status) surfaceBacked=\(result.picture != nil)")
                }
                return
            }
            deliver(surface)
        }
    }

    public func stop() {
        lock.withLock { onFrame = nil }
        session.close()
    }

    public enum DecoderError: Error {
        case malformedDescription
        case formatRejected(OSStatus)
        case sessionRejected(OSStatus)
    }
}
