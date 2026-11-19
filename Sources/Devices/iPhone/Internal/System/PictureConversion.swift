import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// AVConference's decoded pictures (`420f`, YUV) as the BGRA surfaces every
/// `Screen` hands on, through a VideoToolbox pixel transfer into
/// IOSurface-backed buffers. The last few are kept alive: the stream
/// pipeline reads a surface a moment after it is handed on. Integration-only.
final class PictureConversion: @unchecked Sendable {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var recent: [CVPixelBuffer] = []
    private static let heldPictures = 6

    func bgra(_ picture: CVPixelBuffer) -> IOSurface? {
        let (width, height) = (CVPixelBufferGetWidth(picture), CVPixelBufferGetHeight(picture))
        if session == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let session, let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              VTPixelTransferSessionTransferImage(session, from: picture, to: output) == noErr,
              let surface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue()
        else { return nil }
        recent.append(output)
        if recent.count > Self.heldPictures { recent.removeFirst(recent.count - Self.heldPictures) }
        return surface
    }

    deinit { if let session { VTPixelTransferSessionInvalidate(session) } }
}
