#import "SimCamFakePhoto.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#import <objc/runtime.h>

@implementation SimCamFakePhoto {
    CGImageRef _cgImage;
}

- (instancetype)initWithCGImage:(CGImageRef)cgImage {
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
        (__bridge NSString *)kCGImagePropertyOrientation: @1,
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
    };
    CGImageDestinationAddImage(dest, _cgImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}

@end
