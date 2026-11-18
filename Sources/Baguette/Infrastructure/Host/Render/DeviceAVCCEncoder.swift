import CoreVideo
import Foundation
import IOSurface

/// Copies each render before its surface is reused. Only an unsubmitted snapshot
/// can be replaced; every submitted frame and its reference chain is delivered.
final class DeviceAVCCEncoder: @unchecked Sendable {
    typealias Completion = @Sendable (Result<H264Encoder.Encoded?, any Error>) -> Void
    // The copied buffer is retained and never mutated after submission.
    private struct Snapshot: @unchecked Sendable {
        let pixels: CVPixelBuffer
        let placement: DeviceFramePlacement?
    }

    private let queue = DispatchQueue(label: "baguette.3d.avcc")
    private let copy: (IOSurface) -> CVPixelBuffer?
    private let seed: (CVPixelBuffer) -> Data?
    private let encode: (CVPixelBuffer, @escaping Completion) -> Void
    private let deliver: @Sendable (Data) -> Void
    private let onError: @Sendable (any Error) -> Void
    private let stopEncoding: () -> Void
    private var pending: Snapshot?
    private var encoding = false
    private var stopped = false
    private var frameID = 0

    init(
        copy: @escaping (IOSurface) -> CVPixelBuffer?, seed: @escaping (CVPixelBuffer) -> Data?,
        encode: @escaping (CVPixelBuffer, @escaping Completion) -> Void,
        deliver: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable (any Error) -> Void,
        stopEncoding: @escaping () -> Void = {}
    ) {
        self.copy = copy
        self.seed = seed
        self.encode = encode
        self.deliver = deliver
        self.onError = onError
        self.stopEncoding = stopEncoding
    }

    convenience init(
        config: StreamConfig, quality: Double, deliver: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        let scaler = VideoFrameScaler()
        let jpeg = JPEGEncoder(quality: quality)
        let video = H264Encoder(fps: config.fps, bitrate: config.bitrateBps, tuning: .strict)
        self.init(
            copy: { scaler.scale($0, by: config.scale) }, seed: { jpeg.encode($0) },
            encode: { video.encode($0, completion: $1) }, deliver: deliver, onError: onError,
            stopEncoding: { video.stop() })
    }

    func receive(_ result: Result<DeviceFrame, any Error>) {
        queue.sync {
            guard !stopped else { return }
            do {
                let frame = try result.get()
                guard let pixels = copy(frame.surface) else { throw DeviceModelError.renderFailed }
                let snapshot = Snapshot(pixels: pixels, placement: frame.placement)
                if encoding { pending = snapshot } else { try submit(snapshot) }
            } catch { fail(error) }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            pending = nil
            stopEncoding()
        }
    }

    private func submit(_ snapshot: Snapshot) throws {
        encoding = true
        if frameID == 0 {
            guard let jpeg = seed(snapshot.pixels) else { throw DeviceModelError.renderFailed }
            try emit(tag: AVCCEnvelope.seedTag, payload: jpeg, placement: snapshot.placement)
        }
        encode(snapshot.pixels) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.completed(result, snapshot: snapshot) }
        }
    }

    private func completed(_ result: Result<H264Encoder.Encoded?, any Error>, snapshot: Snapshot) {
        guard !stopped else { return }
        do {
            if let encoded = try result.get() {
                if let description = encoded.description { deliver(try DeviceAVCCEnvelope.description(description)) }
                try emit(
                    tag: encoded.kind == .keyframe ? AVCCEnvelope.keyframeTag : AVCCEnvelope.deltaTag,
                    payload: encoded.avcc, placement: snapshot.placement)
            }
            encoding = false
            if let next = pending {
                pending = nil
                try submit(next)
            }
        } catch { fail(error) }
    }

    private func emit(tag: UInt8, payload: Data, placement: DeviceFramePlacement?) throws {
        let packet = try DeviceAVCCEnvelope.frame(
            frameID: frameID + 1, placement: placement, tag: tag, payload: payload)
        frameID += 1
        deliver(packet)
    }

    private func fail(_ error: any Error) {
        guard !stopped else { return }
        stopped = true
        pending = nil
        stopEncoding()
        onError(error)
    }
}
