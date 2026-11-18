#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// `AVCapturePhoto` subclass we hand to `AVCapturePhotoCaptureDelegate` from
/// our swizzled `capturePhotoWithSettings:delegate:`. Wraps a `CGImage` (built
/// from the latest `/tmp/SimCam.bgra` frame) and overrides the two methods
/// app code typically calls on a returned photo:
/// - `CGImageRepresentation`
/// - `fileDataRepresentation` (we encode JPEG on demand)
@interface SimCamFakePhoto : AVCapturePhoto

- (instancetype)initWithCGImage:(CGImageRef)cgImage;

/// `exifOrientation` is the EXIF / CGImagePropertyOrientation (1...8) to
/// report in `metadata` and write into the JPEG from `fileDataRepresentation`.
/// The pixels in `cgImage` are expected to already be in "sensor" layout for
/// that orientation, as on a real device (see `simcam_capturePhoto`).
- (instancetype)initWithCGImage:(CGImageRef)cgImage exifOrientation:(int)exifOrientation;

@end

NS_ASSUME_NONNULL_END
