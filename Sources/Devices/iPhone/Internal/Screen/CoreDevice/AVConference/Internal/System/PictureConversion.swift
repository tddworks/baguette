import BaguetteDevice
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// AVConference's decoded pictures (`420f`, YUV) as the BGRA surfaces every
/// `Screen` hands on, through a VideoToolbox pixel transfer into
/// IOSurface-backed buffers, cut to the screen as `CleanAperture` says (VideoToolbox's
/// clean-aperture crop, as `VTStreamDecoder` crops the other route). The last few are kept alive: the stream
/// pipeline reads a surface a moment after it is handed on. Integration-only.
final class PictureConversion: @unchecked Sendable {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var recent: [CVPixelBuffer] = []
    private static let heldPictures = 6

    func bgra(_ picture: CVPixelBuffer, croppedTo screen: Size?) -> IOSurface? {
        let coded = Size(width: Double(CVPixelBufferGetWidth(picture)), height: Double(CVPixelBufferGetHeight(picture)))
        let aperture = screen.flatMap { CleanAperture(screen: $0, picture: coded) }
        let (width, height) = (Int(aperture?.width ?? coded.width), Int(aperture?.height ?? coded.height))
        if session == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                     value: kVTScalingMode_CropSourceToCleanAperture)
            }
        }
        // The crop goes on a buffer of our own over the same surface, never
        // on AVConference's: it changes its own buffer's attachments as it
        // displays it, and a crop lost that way scales the padding in.
        var source = picture
        if let aperture, let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue() {
            var ours: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &ours) == kCVReturnSuccess,
                  let wrapped = ours?.takeRetainedValue()
            else { return nil }
            CVBufferSetAttachment(wrapped, kCVImageBufferCleanApertureKey, [
                kCVImageBufferCleanApertureWidthKey: aperture.width,
                kCVImageBufferCleanApertureHeightKey: aperture.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: aperture.horizontalOffset,
                kCVImageBufferCleanApertureVerticalOffsetKey: aperture.verticalOffset,
            ] as CFDictionary, .shouldNotPropagate)
            source = wrapped
        }
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
              VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr,
              let surface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue()
        else { return nil }
        recent.append(output)
        if recent.count > Self.heldPictures { recent.removeFirst(recent.count - Self.heldPictures) }
        return surface
    }

    deinit { if let session { VTPixelTransferSessionInvalidate(session) } }
}
