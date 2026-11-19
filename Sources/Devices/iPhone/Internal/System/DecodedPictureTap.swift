import CoreMedia
import CoreVideo
import Foundation
import IOSurface

/// The pictures an in-process `AVCVideoStream` decodes. They go to a
/// layer, not to us; its inner `VCVideoStream` caches the last one when
/// `_shouldCacheRemoteVideoFrame` is set and hands it to
/// `sendLastRemoteVideoFrame:` when asked (`requestLastDecodedFrame`).
/// That method is replaced once per process and never called through: its
/// own work is JPEG-encoding the whole picture for a remote client, ~60
/// times a second here — measured as nearly all of this route's extra CPU.
/// Numbered by change of buffer or of its surface's seed.
/// Integration-only.
final class DecodedPictureTap: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var taps: [ObjectIdentifier: DecodedPictureTap] = [:]
    nonisolated(unsafe) private static var installed = false
    private static let selector = NSSelectorFromString("sendLastRemoteVideoFrame:")

    private let inner: AnyObject
    private let lock = NSLock()
    private var latest: (buffer: CVPixelBuffer, seed: UInt32, sequence: Int)?

    /// Taps `stream` (an `AVCVideoStream`), or nil when it isn't shaped as measured.
    init?(stream: AnyObject) {
        guard let streamIvar = class_getInstanceVariable(type(of: stream), "_opaqueStream"),
              let inner = object_getIvar(stream, streamIvar) as AnyObject?,
              let cache = class_getInstanceVariable(type(of: inner), "_shouldCacheRemoteVideoFrame"),
              Self.installHook(on: type(of: inner))
        else { return nil }
        self.inner = inner
        Unmanaged.passUnretained(inner).toOpaque()
            .storeBytes(of: true, toByteOffset: ivar_getOffset(cache), as: Bool.self)
        Self.lock.withLock { Self.taps[ObjectIdentifier(inner)] = self }
    }

    /// Asks for the newest picture (answered on AVConference's queue) and
    /// returns the newest kept so far.
    func newest() -> (buffer: CVPixelBuffer, sequence: Int)? {
        AVConferenceRuntime.void(inner, "requestLastDecodedFrame")
        return lock.withLock { latest.map { ($0.buffer, $0.sequence) } }
    }

    func close() { Self.lock.withLock { Self.taps[ObjectIdentifier(inner)] = nil } }

    private func keep(_ buffer: CVPixelBuffer) {
        let seed = CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetSeed($0.takeUnretainedValue()) } ?? 0
        lock.withLock {
            if let latest, latest.buffer === buffer, latest.seed == seed { return }
            latest = (buffer, seed, (latest?.sequence ?? 0) + 1)
        }
    }

    private static func installHook(on cls: AnyClass) -> Bool {
        lock.withLock {
            if installed { return true }
            guard let method = class_getInstanceMethod(cls, selector) else { return false }
            let replacement: @convention(block) (AnyObject, CVPixelBuffer?) -> Void = { stream, buffer in
                if let buffer { DecodedPictureTap.tap(for: stream)?.keep(buffer) }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            installed = true
            return true
        }
    }

    private static func tap(for stream: AnyObject) -> DecodedPictureTap? {
        lock.withLock { taps[ObjectIdentifier(stream)] }
    }
}
