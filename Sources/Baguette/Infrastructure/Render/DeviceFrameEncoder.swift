import Foundation
import IOSurface

/// Encode on the render callback's serial queue, before the scene reuses its
/// surface ring. Stop may arrive on another queue; incomplete work is discarded.
final class DeviceFrameEncoder: @unchecked Sendable {
    private let encode: @Sendable (IOSurface) -> Data?
    private let deliver: @Sendable (Data) -> Void
    private let onError: @Sendable (any Error) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var frameID = 0

    init(
        encode: @escaping @Sendable (IOSurface) -> Data?,
        deliver: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.encode = encode
        self.deliver = deliver
        self.onError = onError
    }

    func receive(_ result: Result<DeviceFrame, any Error>) {
        guard !lock.withLock({ stopped }) else { return }
        do {
            let frame = try result.get()
            guard let jpeg = encode(frame.surface) else { throw DeviceModelError.renderFailed }
            try lock.withLock {
                guard !stopped else { return }
                let packet = try DeviceFrameEnvelope.encode(
                    frameID: frameID + 1, placement: frame.placement, jpeg: jpeg)
                frameID += 1
                deliver(packet)
            }
        } catch {
            let report = lock.withLock {
                guard !stopped else { return false }
                stopped = true
                return true
            }
            if report { onError(error) }
        }
    }

    func stop() { lock.withLock { stopped = true } }
}
