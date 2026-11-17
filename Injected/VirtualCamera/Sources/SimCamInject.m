// SimCamInject.dylib — iOS-Simulator dylib loaded into apps via the lldb hook
// installed by SimCamMac (or DYLD_INSERT_LIBRARIES). Pipes Mac webcam frames
// from `/tmp/SimCam.bgra` into the simulator's AVFoundation surface.
//
// V1 hook: `-[AVCaptureVideoPreviewLayer setSession:]`. When any layer gets a
// session, attach a `SimCamPreviewLayerDriver` (associated object). The driver
// runs a CADisplayLink that updates the layer's `contents` with our latest
// BGRA frame as a CGImage. AVCaptureSession's own internal rendering is
// effectively a no-op in the simulator (no real camera), so our `setContents:`
// wins.
//
// This deliberately does NOT swizzle UIImagePickerController. The picker's
// preview rendering goes through private CAM* views in iOS 26, not a public
// AVCaptureVideoPreviewLayer — and modern camera apps don't use the picker
// anyway. They use AVFoundation directly (often via SwiftUI wrappers).
//
// Future hooks (deferred):
//   - AVCaptureVideoDataOutput.setSampleBufferDelegate:queue: → CMSampleBuffer
//     delivery for apps doing custom frame processing.
//   - AVCapturePhotoOutput.capturePhotoWithSettings:delegate: → still capture.
//   - AVCaptureMovieFileOutput.startRecordingToOutputFileURL:... → recording.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SimCamPreviewLayerDriver.h"
#import "SimCamSharedFrameReader.h"
#import "SimCamFakePhoto.h"
#import "SimCamVirtualCamera.h"

@interface SimCamInjectMarker : NSObject
@end
@implementation SimCamInjectMarker
@end

static IMP gOriginalSetSession = NULL;
static IMP gOriginalCapturePhoto = NULL;
static IMP gOriginalStartRunning = NULL;
static IMP gOriginalStopRunning = NULL;
static IMP gOriginalIsSourceTypeAvailable = NULL;
static const void *kSimCamDriverKey = &kSimCamDriverKey;
static const void *kSimCamShutterWrappedDelegateKey = &kSimCamShutterWrappedDelegateKey;

/// Aspect (width / height) of the picker's `CAMPreviewView` rect, captured
/// during the walker. Used at shutter time to center-crop the captured
/// frame in Fill mode so the saved photo matches what the viewfinder
/// showed. Defaults to 3:4 (the iOS Camera Photo-mode standard) until
/// the walker has run.
static CGFloat gSimCamPreviewAspect = 3.0 / 4.0;

#pragma mark - Shutter handler

/// Reads `/tmp/SimCam.bgra` and dispatches the captured frame to the
/// `UIImagePickerController.delegate`'s standard
/// `imagePickerController:didFinishPickingMediaWithInfo:` callback.
@interface SimCamShutterHandler : NSObject
+ (void)deliverFrameToPicker:(UIImagePickerController *)picker;
@end

/// Returns a center-cropped copy of `image` matching `targetAspect`
/// (width/height). Used when the Mac HUD's Fit mode is set to Fill so
/// the captured photo matches the live preview's cropped framing — the
/// live layer was cropping via `kCAGravityResizeAspectFill`, but the raw
/// delivered image is uncropped, so without this the saved photo
/// letterboxed again on the iOS app side.
static UIImage *SimCamCenterCropToAspect(UIImage *image, CGFloat targetAspect) {
    CGImageRef src = image.CGImage;
    if (src == NULL || targetAspect <= 0) return image;
    CGFloat w = (CGFloat)CGImageGetWidth(src);
    CGFloat h = (CGFloat)CGImageGetHeight(src);
    if (w <= 0 || h <= 0) return image;
    CGFloat sourceAspect = w / h;
    CGRect cropRect;
    if (sourceAspect > targetAspect) {
        // Source wider than target → crop horizontally.
        CGFloat newW = h * targetAspect;
        cropRect = CGRectMake((w - newW) / 2.0, 0, newW, h);
    } else {
        // Source taller than target → crop vertically.
        CGFloat newH = w / targetAspect;
        cropRect = CGRectMake(0, (h - newH) / 2.0, w, newH);
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(src, cropRect);
    if (cropped == NULL) return image;
    UIImage *result = [UIImage imageWithCGImage:cropped];
    CGImageRelease(cropped);
    return result;
}

/// Returns a horizontally flipped copy of `image`, or `image` itself if
/// flipping fails. Used when the Mac HUD's Mirror setting is on so the
/// captured photo matches what the user saw in the (mirrored) viewfinder.
static UIImage *SimCamMirrorImage(UIImage *image) {
    CGImageRef src = image.CGImage;
    if (src == NULL) return image;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        NULL, w, h, 8, 0, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) return image;
    CGContextTranslateCTM(ctx, w, 0);
    CGContextScaleCTM(ctx, -1, 1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (out == NULL) return image;
    UIImage *result = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    return result;
}

@implementation SimCamShutterHandler
+ (void)deliverFrameToPicker:(UIImagePickerController *)picker {
    if (picker == nil) return;
    SimCamSharedFrameReader *reader =
        [[SimCamSharedFrameReader alloc] initWithPath:@"/tmp/SimCam.bgra"];
    UIImage *image = [reader latestImage];
    NSLog(@"[SimCamInject] shutter tapped, frame=%@", image ? @"ok" : @"nil");
    if (image == nil) return;
    if (reader.latestFlags & kSimCamFlagFillGravity) {
        image = SimCamCenterCropToAspect(image, gSimCamPreviewAspect);
    }
    if (reader.latestFlags & kSimCamFlagMirror) {
        image = SimCamMirrorImage(image);
    }
    id<UIImagePickerControllerDelegate, UINavigationControllerDelegate> delegate = picker.delegate;
    if ([delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
        NSDictionary<UIImagePickerControllerInfoKey, id> *info = @{
            UIImagePickerControllerOriginalImage: image,
            UIImagePickerControllerMediaType: @"public.image",
        };
        [delegate imagePickerController:picker didFinishPickingMediaWithInfo:info];
    }
}
@end

#pragma mark - Shutter delegate wrapper

/// Wraps Apple's `CAMDynamicShutterControlDelegate`. In the simulator the
/// shutter is always disabled (no real camera), so every tap fires
/// `shutterControlTouchAttemptedWhileDisabled:`. We catch that selector,
/// deliver the frame to the picker delegate once per session, and forward
/// every other selector to the original delegate.
@interface SimCamShutterDelegateWrapper : NSObject
@property (nonatomic, weak) id originalDelegate;
@property (nonatomic, weak) UIImagePickerController *picker;
@property (nonatomic, assign) BOOL hasDelivered;
@end

@implementation SimCamShutterDelegateWrapper
- (void)shutterControlTouchAttemptedWhileDisabled:(id)control {
    if (self.hasDelivered) {
        NSLog(@"[SimCamInject] shutter tap dropped — hasDelivered already YES (picker=%@)", self.picker);
        return;
    }
    self.hasDelivered = YES;
    NSLog(@"[SimCamInject] intercepted shutterControlTouchAttemptedWhileDisabled");
    [SimCamShutterHandler deliverFrameToPicker:self.picker];
}
- (void)dynamicShutterControlDidShortPress:(id)control {
    if (self.hasDelivered) {
        NSLog(@"[SimCamInject] short-press dropped — hasDelivered already YES");
        return;
    }
    self.hasDelivered = YES;
    NSLog(@"[SimCamInject] intercepted dynamicShutterControlDidShortPress");
    [SimCamShutterHandler deliverFrameToPicker:self.picker];
}
- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.originalDelegate respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel {
    if ([self.originalDelegate respondsToSelector:sel]) return self.originalDelegate;
    return nil;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    return [(NSObject *)self.originalDelegate methodSignatureForSelector:sel];
}
@end

/// Stashed during the picker's view-tree walk so the walker can hand the
/// shutter wrapper a picker reference without changing its signature.
static __weak UIImagePickerController *gSimCamCurrentPicker = nil;

static void simcam_attachDriver(CALayer *layer) {
    if (layer == nil) return;
    if (objc_getAssociatedObject(layer, kSimCamDriverKey) != nil) return;
    SimCamPreviewLayerDriver *driver =
            [[SimCamPreviewLayerDriver alloc] initWithLayer:layer];
    objc_setAssociatedObject(layer, kSimCamDriverKey, driver,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[SimCamInject] preview-layer driver attached to %@", layer);
}

static void simcam_setSession(id self, SEL _cmd, id session) {
    ((void (*)(id, SEL, id))gOriginalSetSession)(self, _cmd, session);
    if (session != nil) {
        simcam_attachDriver((CALayer *)self);
    }
}

#pragma mark - Capture orientation

/// A real iPhone camera hands back "sensor" pixels: always landscape, with the
/// rotation needed to display them upright carried in EXIF (portrait = 6/"Right",
/// upside-down = 8/"Left", landscape-left = 1/"Up", landscape-right = 3/"Down").
/// Apps either honour that EXIF or, like NativeScript's ui-cameraview, ignore
/// it and re-derive the same rotation from `UIDevice.orientation`. baguette's
/// frame is already upright, so handing it over unrotated with EXIF 1 makes the
/// second kind of app rotate an upright picture by 90° (seen as a sideways
/// capture while the preview looked fine). Instead rotate the pixels *away* by
/// the amount the app will rotate them back, and stamp the matching EXIF, so
/// both kinds of app end up upright — as on a device.
///
/// Must run on the main thread (UIDevice / UIApplication).
static UIDeviceOrientation SimCamResolvedDeviceOrientation(void) {
    UIDeviceOrientation d = UIDevice.currentDevice.orientation;
    if (d == UIDeviceOrientationFaceUp || d == UIDeviceOrientationFaceDown) {
        d = UIDeviceOrientationPortrait;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            switch (((UIWindowScene *)scene).interfaceOrientation) {
                case UIInterfaceOrientationPortraitUpsideDown: d = UIDeviceOrientationPortraitUpsideDown; break;
                // Interface and device landscape are mirror images of each other.
                case UIInterfaceOrientationLandscapeLeft:      d = UIDeviceOrientationLandscapeRight; break;
                case UIInterfaceOrientationLandscapeRight:     d = UIDeviceOrientationLandscapeLeft; break;
                default:                                        d = UIDeviceOrientationPortrait; break;
            }
            break;
        }
    }
    return d;
}

/// Returns the sensor-layout image for `upright` and the EXIF orientation that
/// displays it upright again. `.unknown` (an app that never started device
/// orientation notifications) maps to "no rotation", which is also what such
/// apps assume.
static UIImage *SimCamSensorImage(UIImage *upright, int *exifOut) {
    UIImageOrientation drawAs = UIImageOrientationUp;  // inverse of what the app applies
    int exif = 1;
    switch (SimCamResolvedDeviceOrientation()) {
        case UIDeviceOrientationPortrait:           exif = 6; drawAs = UIImageOrientationLeft;  break;
        case UIDeviceOrientationPortraitUpsideDown: exif = 8; drawAs = UIImageOrientationRight; break;
        case UIDeviceOrientationLandscapeRight:     exif = 3; drawAs = UIImageOrientationDown;  break;
        default: break;  // landscape-left / unknown: sensor orientation, EXIF 1
    }
    *exifOut = exif;
    if (drawAs == UIImageOrientationUp || upright.CGImage == NULL) return upright;

    UIImage *oriented = [UIImage imageWithCGImage:upright.CGImage scale:1 orientation:drawAs];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    CGSize size = oriented.size;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [oriented drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

static void simcam_capturePhoto(id self,
        SEL _cmd,
        AVCapturePhotoSettings *settings,
        id<AVCapturePhotoCaptureDelegate> delegate) {
    // Bypass the original — iOS Simulator's AVCapturePhotoOutput has nothing
    // real to capture from, so calling through would error. Synthesize a
    // photo from the latest /tmp/SimCam.bgra frame and dispatch the delegate.

    SimCamSharedFrameReader *reader =
            [[SimCamSharedFrameReader alloc] initWithPath:@"/tmp/SimCam.bgra"];
    UIImage *latest = [reader latestImage];
    if (latest != nil && (reader.latestFlags & kSimCamFlagMirror)) {
        latest = SimCamMirrorImage(latest);
    }
    BOOL haveImage = (latest.CGImage != NULL);

    AVCapturePhotoOutput *output = (AVCapturePhotoOutput *)self;
    NSError *error = haveImage
            ? nil
            : [NSError errorWithDomain:@"SimCamInject"
                                  code:1
                              userInfo:@{NSLocalizedDescriptionKey:
                                      @"No frames available — start SimCam Mac and click Start Streaming."}];

    // Dispatch the standard capture sequence on the main queue. AVFoundation
    // normally fires these on the session queue; main is fine for sim-only
    // and matches what most app code expects. The photo is built here too:
    // choosing its orientation reads UIDevice / UIApplication.
    dispatch_async(dispatch_get_main_queue(), ^{
        SimCamFakePhoto *photo = nil;
        if (haveImage) {
            int exif = 1;
            UIImage *sensor = SimCamSensorImage(latest, &exif);
            photo = [[SimCamFakePhoto alloc] initWithCGImage:sensor.CGImage exifOrientation:exif];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) {
            [delegate captureOutput:output willCapturePhotoForResolvedSettings:(id)settings];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) {
            [delegate captureOutput:output didCapturePhotoForResolvedSettings:(id)settings];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            [delegate captureOutput:output didFinishProcessingPhoto:photo error:error];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
            [delegate captureOutput:output didFinishCaptureForResolvedSettings:(id)settings error:error];
        }
    });
    NSLog(@"[SimCamInject] capturePhoto delivered to delegate=%@ image=%@",
            delegate, haveImage ? @"ok" : @"nil");
}

#pragma mark - AVCaptureSession

/// In the simulator there is no capture device, so `initializeCaptureSessionInput`
/// adds no inputs. The real `-[AVCaptureSession startRunning]` on such a session
/// can block the caller's (usually serial) session queue waiting for hardware
/// that never arrives — which stalls any app that fires its "camera ready"
/// signal only *after* startRunning returns (expo-camera's `onCameraReady`,
/// dispatched right after `updateCameraIsActive()`, is the canonical case).
/// The app then keeps a loading cover over the preview forever.
///
/// baguette paints the preview from the shared buffer regardless of whether the
/// session is "running", so when there is no video device we skip the blocking
/// original and let the queue proceed — the ready callback fires and the app
/// reveals the preview. With a real device (including Mac-camera passthrough)
/// we call through untouched.
///
/// NOTE: superseded and currently unreachable. `SimCamInstallVirtualCamera()`
/// runs last in `simcam_install` and re-swizzles `startRunning` to
/// `h_startRunning`, which never chains to the IMP it replaced (this one).
/// Kept because this file is vendored from SimCam — see VENDORED_FROM.md —
/// and deleting it would complicate re-syncing upstream. Read the
/// device-availability check below as history, not as live behaviour: the
/// virtual camera fabricates a device, so the `nil` test would no longer
/// mean "no camera" even if this did run.
static void simcam_startRunning(id self, SEL _cmd) {
    if ([AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] == nil) {
        NSLog(@"[SimCamInject] startRunning: no capture device — skipping blocking start so onCameraReady can fire");
        return;
    }
    ((void (*)(id, SEL))gOriginalStartRunning)(self, _cmd);
}

#pragma mark - UIImagePickerController

/// Class-method swizzle: report `.camera` (= 1) as available so apps that
/// gate on `+[UIImagePickerController isSourceTypeAvailable:]` can proceed
/// to set `.sourceType = .camera` without `Source type 1 not available`.
static BOOL simcam_isSourceTypeAvailable(id self, SEL _cmd, NSInteger sourceType) {
    if (sourceType == UIImagePickerControllerSourceTypeCamera) return YES;
    return ((BOOL (*)(id, SEL, NSInteger))gOriginalIsSourceTypeAvailable)(self, _cmd, sourceType);
}

/// Walks the picker's view tree once it's on screen. Logs each view's
/// class + layer class + frame (so we can see what Apple is using for the
/// preview surface in the simulator) and attaches our shared-buffer
/// driver to any view whose class name looks preview-related.
static void simcam_dumpAndAttach(UIView *root, NSInteger depth) {
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    NSString *cls = NSStringFromClass([root class]);
    NSString *layerCls = NSStringFromClass([root.layer class]);
    NSLog(@"[SimCamInject][picker] %@%@ (layer:%@) frame=%@",
            indent, cls, layerCls, NSStringFromCGRect(root.frame));

    NSString *clsLower = [cls lowercaseString];
    NSString *layerLower = [layerCls lowercaseString];
    BOOL looksLikePreview =
            [clsLower containsString:@"preview"] ||
                    [clsLower containsString:@"cam"] ||
                    [clsLower containsString:@"viewfinder"] ||
                    [layerLower containsString:@"preview"] ||
                    [layerLower containsString:@"avcapture"];

    if (looksLikePreview &&
            objc_getAssociatedObject(root.layer, kSimCamDriverKey) == nil &&
            root.bounds.size.width > 100 &&
            root.bounds.size.height > 100) {
        simcam_attachDriver(root.layer);
        NSLog(@"[SimCamInject] attached preview driver to picker view: %@", cls);
    }

    // Stash CAMPreviewView's aspect — that's the rect users actually see
    // through. Capture-time crop in Fill mode targets this aspect so the
    // saved photo matches the live viewfinder framing (WYSIWYG).
    if ([cls isEqualToString:@"CAMPreviewView"] && root.bounds.size.height > 1) {
        CGFloat a = root.bounds.size.width / root.bounds.size.height;
        if (a > 0.1 && a < 10) gSimCamPreviewAspect = a;
    }

    // CAMSnapshotView sits as a full-screen sibling of CAMPreviewView and
    // covers it with a gray "viewfinder closed" snapshot. With Fit-mode
    // letterbox, that gray cover bled in above/below the real preview
    // rect. Hiding it lets the actual preview show through cleanly.
    if ([cls isEqualToString:@"CAMSnapshotView"] && !root.hidden) {
        root.hidden = YES;
        NSLog(@"[SimCamInject] hid CAMSnapshotView to clear gray cover");
    }

    // Shutter — Apple's CAMDynamicShutterControl is a UIControl that's
    // always `enabled=NO` in the simulator (no real camera). Apple's
    // gesture pipeline still fires `shutterControlTouchAttemptedWhileDisabled:`
    // on the delegate per tap; we wrap the delegate to catch that and
    // deliver a frame to the picker delegate. UIKit hit-testing /
    // gesture-priority can't be won here — only the delegate level.
    //
    // Apple reuses the same CAMDynamicShutterControl instance across
    // picker presentations. If our wrapper is already attached, refresh
    // its picker reference and clear `hasDelivered` so the next shot
    // works. Without this, the second presentation would early-return
    // silently inside the wrapper (hasDelivered=YES from the first shot)
    // and the user would see "Disabled shutter button was tapped" with
    // no intercept log — which is exactly the symptom we hit.
    if ([cls isEqualToString:@"CAMDynamicShutterControl"] && gSimCamCurrentPicker != nil) {
        @try {
            SimCamShutterDelegateWrapper *existing =
                objc_getAssociatedObject(root, kSimCamShutterWrappedDelegateKey);
            if (existing != nil) {
                existing.picker = gSimCamCurrentPicker;
                existing.hasDelivered = NO;
                // Re-seat ourselves as the delegate in case Apple replaced it
                // while the picker was offscreen.
                id currentDelegate = [root valueForKey:@"delegate"];
                if (currentDelegate != existing) {
                    existing.originalDelegate = currentDelegate;
                    [root setValue:existing forKey:@"delegate"];
                    NSLog(@"[SimCamInject] re-seated existing shutter wrapper (orig: %@)",
                          NSStringFromClass([currentDelegate class]));
                } else {
                    NSLog(@"[SimCamInject] refreshed existing shutter wrapper for new picker");
                }
            } else {
                id origDelegate = [root valueForKey:@"delegate"];
                SimCamShutterDelegateWrapper *wrapper =
                    [[SimCamShutterDelegateWrapper alloc] init];
                wrapper.originalDelegate = origDelegate;
                wrapper.picker = gSimCamCurrentPicker;
                objc_setAssociatedObject(root, kSimCamShutterWrappedDelegateKey, wrapper,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [root setValue:wrapper forKey:@"delegate"];
                NSLog(@"[SimCamInject] hijacked %@.delegate (orig: %@)",
                      cls, NSStringFromClass([origDelegate class]));
            }
        } @catch (NSException *e) {
            NSLog(@"[SimCamInject] failed to hijack shutter delegate: %@", e);
        }
    }

    for (UIView *child in root.subviews) {
        simcam_dumpAndAttach(child, depth + 1);
    }
}

static IMP gOriginalPickerViewDidAppear = NULL;
static void simcam_picker_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOriginalPickerViewDidAppear)(self, _cmd, animated);
    if (![self isKindOfClass:[UIImagePickerController class]]) return;
    UIImagePickerController *picker = (UIImagePickerController *)self;
    if (picker.sourceType != UIImagePickerControllerSourceTypeCamera) return;
    NSLog(@"[SimCamInject] === picker viewDidAppear, dumping tree ===");
    gSimCamCurrentPicker = picker;
    simcam_dumpAndAttach(picker.view, 0);
    gSimCamCurrentPicker = nil;
    NSLog(@"[SimCamInject] === end picker tree ===");
}

__attribute__((constructor))
static void simcam_install(void) {
    @autoreleasepool {
        if (NSClassFromString(@"UIApplication") == nil) {
            return;  // Not a UIKit process — bail.
        }
        if (objc_getClass("SimCamInjectInstalled") != nil) {
            return;  // Already installed.
        }

        Class previewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
        if (previewLayerClass == nil) {
            NSLog(@"[SimCamInject] AVCaptureVideoPreviewLayer not available; nothing to do");
            return;
        }

        Method setSession = class_getInstanceMethod(
                previewLayerClass, NSSelectorFromString(@"setSession:"));
        if (setSession) {
            gOriginalSetSession = method_setImplementation(setSession, (IMP)simcam_setSession);
        } else {
            NSLog(@"[SimCamInject] -[AVCaptureVideoPreviewLayer setSession:] not found");
        }

        Class photoOutputClass = NSClassFromString(@"AVCapturePhotoOutput");
        if (photoOutputClass) {
            Method capturePhoto = class_getInstanceMethod(
                    photoOutputClass, NSSelectorFromString(@"capturePhotoWithSettings:delegate:"));
            if (capturePhoto) {
                gOriginalCapturePhoto =
                        method_setImplementation(capturePhoto, (IMP)simcam_capturePhoto);
            }
        }

        // Keep a device-less session's -startRunning from blocking the
        // session queue, so apps that gate "camera ready" on it proceed.
        Class sessionClass = NSClassFromString(@"AVCaptureSession");
        if (sessionClass) {
            Method startRunning = class_getInstanceMethod(
                    sessionClass, NSSelectorFromString(@"startRunning"));
            if (startRunning) {
                gOriginalStartRunning =
                        method_setImplementation(startRunning, (IMP)simcam_startRunning);
                NSLog(@"[SimCamInject] AVCaptureSession startRunning: hooked");
            }
        }

        // UIImagePickerController hooks: make `.camera` source type usable
        // in the simulator and install our own viewfinder UI on appear.
        Class pickerClass = NSClassFromString(@"UIImagePickerController");
        if (pickerClass) {
            // 1. Class method: isSourceTypeAvailable: → YES for .camera.
            //    Without this, `setSourceType: .camera` throws
            //    `NSInvalidArgumentException ('Source type 1 not available')`.
            Method isAvail = class_getClassMethod(
                    pickerClass, NSSelectorFromString(@"isSourceTypeAvailable:"));
            if (isAvail) {
                gOriginalIsSourceTypeAvailable =
                        method_setImplementation(isAvail, (IMP)simcam_isSourceTypeAvailable);
            }

            // Walk the picker's view tree at viewDidAppear: so we can find
            // the preview surface Apple's chrome uses internally (its class
            // name varies per iOS version) and inject our shared-buffer
            // driver there. Use class_addMethod to add an override on
            // UIImagePickerController specifically, so we don't taint
            // UIViewController for every other VC in the process.
            SEL didAppear = NSSelectorFromString(@"viewDidAppear:");
            Method m = class_getInstanceMethod(pickerClass, didAppear);
            if (m) {
                gOriginalPickerViewDidAppear = method_getImplementation(m);
                const char *types = method_getTypeEncoding(m);
                if (!class_addMethod(pickerClass, didAppear,
                        (IMP)simcam_picker_viewDidAppear, types)) {
                    method_setImplementation(m, (IMP)simcam_picker_viewDidAppear);
                }
            }
            NSLog(@"[SimCamInject] UIImagePickerController hooks installed");
        }

        Class marker = objc_allocateClassPair([NSObject class], "SimCamInjectInstalled", 0);
        if (marker != Nil) {
            objc_registerClassPair(marker);
        }

        NSLog(@"[SimCamInject] AVCaptureVideoPreviewLayer setSession: hooked");

        // Full virtual-camera graph: fabricated device + dummy input + session
        // interception + CMSampleBuffer delivery, so unmodified capture apps
        // see a working camera on a device-less simulator.
        SimCamInstallVirtualCamera();
    }
}
