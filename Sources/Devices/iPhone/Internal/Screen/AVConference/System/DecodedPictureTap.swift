import CoreFoundation
import CoreVideo
import Foundation

/// The pictures an in-process `AVCVideoStream` decodes, the moment each is
/// decoded. Its inner `VCVideoStream` gives its video receiver a table of
/// two C callbacks (`-videoReceiverDelegateFunctions`, read when the stream
/// starts); the second, `_VCVideoStream_DidReceiveRemoteFrame(stream,
/// pixelBuffer, time, attributes, …)`, runs once per decoded picture, after
/// AVConference's jitter buffer. That getter is replaced once per process to
/// put a wrapper in that slot: it calls the original with the same six
/// arguments, then hands the buffer to the stream's handler. The table is two
/// pointers returned in two registers — `CFRange`'s shape, as Swift can
/// receive it. Measured in docs/features/real-devices/design.md.
/// Integration-only.
final class DecodedPictureTap: @unchecked Sendable {
    typealias Handler = @Sendable (CVPixelBuffer) -> Void
    private typealias RemoteFrame = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Table = @convention(c) (AnyObject, Selector) -> CFRange

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [UnsafeMutableRawPointer: Handler] = [:]
    nonisolated(unsafe) private static var originalTable: IMP?
    nonisolated(unsafe) private static var originalRemoteFrame: RemoteFrame?

    private let inner: UnsafeMutableRawPointer

    /// Taps `stream` (an `AVCVideoStream`, before it starts), or nil when it
    /// isn't shaped as measured.
    init?(stream: AnyObject, handler: @escaping Handler) {
        guard let ivar = class_getInstanceVariable(type(of: stream), "_opaqueStream"),
              let inner = object_getIvar(stream, ivar) as AnyObject?,
              Self.install(on: type(of: inner))
        else { return nil }
        self.inner = Unmanaged.passUnretained(inner).toOpaque()
        Self.lock.withLock { Self.handlers[self.inner] = handler }
    }

    func close() { Self.lock.withLock { Self.handlers[inner] = nil } }

    private static let wrapper: RemoteFrame = { stream, buffer, time, attributes, fourth, fifth in
        DecodedPictureTap.lock.withLock { DecodedPictureTap.originalRemoteFrame }?(
            stream, buffer, time, attributes, fourth, fifth)
        guard let stream, let buffer,
              let handler = DecodedPictureTap.lock.withLock({ DecodedPictureTap.handlers[stream] })
        else { return }
        handler(Unmanaged<CVPixelBuffer>.fromOpaque(buffer).takeUnretainedValue())
    }

    private static let table: Table = { object, selector in
        guard let original = DecodedPictureTap.lock.withLock({ DecodedPictureTap.originalTable }) else { return CFRange() }
        var functions = unsafeBitCast(original, to: Table.self)(object, selector)
        guard let remoteFrame = UnsafeRawPointer(bitPattern: functions.length) else { return functions }
        DecodedPictureTap.lock.withLock {
            if DecodedPictureTap.originalRemoteFrame == nil {
                DecodedPictureTap.originalRemoteFrame = unsafeBitCast(remoteFrame, to: RemoteFrame.self)
            }
        }
        functions.length = unsafeBitCast(DecodedPictureTap.wrapper, to: Int.self)
        return functions
    }

    private static func install(on cls: AnyClass) -> Bool {
        lock.withLock {
            if originalTable != nil { return true }
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString("videoReceiverDelegateFunctions"))
            else { return false }
            originalTable = method_setImplementation(method, unsafeBitCast(table, to: IMP.self))
            return true
        }
    }
}
