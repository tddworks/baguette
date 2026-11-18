#import "SimCamFakePhoto.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

@implementation SimCamFakePhoto {
    CGImageRef _cgImage;
    int _exifOrientation;
    CMTime _timestamp;
}

- (instancetype)initWithCGImage:(CGImageRef)cgImage {
    return [self initWithCGImage:cgImage exifOrientation:1];
}

- (instancetype)initWithCGImage:(CGImageRef)cgImage exifOrientation:(int)exifOrientation {
    // AVCapturePhoto declares -init NS_UNAVAILABLE, so we route through
    // objc_msgSendSuper to bypass the static check. The actual NSObject init
    // chain still runs at runtime.
    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass([self class]),
    };
    self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superInfo, @selector(init));
    if (self) {
        if (cgImage) _cgImage = CGImageRetain(cgImage);
        _timestamp = CMClockGetTime(CMClockGetHostTimeClock());
        _exifOrientation = (exifOrientation >= 1 && exifOrientation <= 8) ? exifOrientation : 1;
    }
    return self;
}

- (void)dealloc {
    if (_cgImage) CGImageRelease(_cgImage);
}

- (CGImageRef)CGImageRepresentation {
    return _cgImage;
}

- (NSDictionary<NSString *, id> *)metadata {
    if (_cgImage == NULL) return @{};
    NSNumber *width = @(CGImageGetWidth(_cgImage));
    NSNumber *height = @(CGImageGetHeight(_cgImage));
    return @{
        (__bridge NSString *)kCGImagePropertyOrientation: @(_exifOrientation),
        (__bridge NSString *)kCGImagePropertyPixelWidth: width,
        (__bridge NSString *)kCGImagePropertyPixelHeight: height,
        (__bridge NSString *)kCGImagePropertyExifDictionary: @{
            (__bridge NSString *)kCGImagePropertyExifPixelXDimension: width,
            (__bridge NSString *)kCGImagePropertyExifPixelYDimension: height,
        },
    };
}

- (NSData *)fileDataRepresentation {
    if (_cgImage == NULL) return nil;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, (CFStringRef)@"public.jpeg", 1, NULL);
    if (dest == NULL) return nil;
    NSDictionary *props = @{
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(0.9),
        (__bridge NSString *)kCGImagePropertyOrientation: @(_exifOrientation),
    };
    CGImageDestinationAddImage(dest, _cgImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}

// The fake is a bare AVCapturePhoto subclass with no backing capture state, so
// every property it does not override reads uninitialised internals and
// crashes (NextLevel's didFinishProcessingPhoto reads `portraitEffectsMatte`
// unconditionally and died with EXC_BAD_ACCESS inside `-[AVCapturePhoto
// portraitEffectsMatte]`). Answer the optional ones with "not present".

- (AVPortraitEffectsMatte *)portraitEffectsMatte { return nil; }
- (AVDepthData *)depthData { return nil; }
- (AVCameraCalibrationData *)cameraCalibrationData { return nil; }
- (AVSemanticSegmentationMatte *)semanticSegmentationMatteForType:(AVSemanticSegmentationMatteType)type { return nil; }
- (CVPixelBufferRef)pixelBuffer { return NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return NULL; }
- (NSDictionary<NSString *, id> *)embeddedThumbnailPhotoFormat { return nil; }
- (BOOL)isRawPhoto { return NO; }
- (NSInteger)photoCount { return 1; }
- (NSInteger)sequenceCount { return 1; }
- (AVCaptureBracketedStillImageSettings *)bracketSettings { return nil; }
// Stamped once at capture so repeated reads describe the same moment.
- (CMTime)timestamp { return _timestamp; }

@end
