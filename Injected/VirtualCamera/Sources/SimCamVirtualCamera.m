// SimCamVirtualCamera — full capture-graph mock for the iOS simulator.
//
// The simulator has no camera, so AVFoundation exposes no AVCaptureDevice and
// the real capture pipeline (AVCaptureDeviceInput → FigCaptureSource) crashes
// if handed a fabricated device. This module instead substitutes the *entire*
// graph at the public AVFoundation boundary — the real Fig layer is never
// touched — and feeds frames from baguette's shared /tmp/SimCam.bgra buffer,
// so unmodified apps (expo-camera, VisionCamera, AVFoundation directly) see a
// working camera. Same idea as swmansion/SimCam; frames come from the shared
// buffer instead of a socket.

#import "SimCamVirtualCamera.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const kSharedPath = @"/tmp/SimCam.bgra";
static const size_t kHeaderSize = 24;
static const size_t kMaxCanvas = 1280;

// MARK: - Fabricated objects

static AVCaptureDevice *gFakeDevice = nil;
static AVCaptureDeviceFormat *gFakeFormat = nil;
static AVCaptureDeviceInput *gDummyInput = nil;

static void SimCamBuildObjectsOnce(void);

// Fake format. `figCaptureSourceVideoFormat` is a private accessor that
// several AVFoundation entry points (AVCaptureDeviceInput, AVCapturePhotoOutput)
// call and which dereferences a real FigCaptureSource ivar we don't have —
// override it to return NULL so those paths don't crash on the fake.
static CGFloat ffmt_videoMaxZoomFactor(id s, SEL c) { return 1.0; }
static float   ffmt_videoFieldOfView(id s, SEL c) { return 60.0f; }
static void   *ffmt_figNull(id s, SEL c) { return NULL; }
static NSArray *ffmt_emptyArray(id s, SEL c) { return @[]; }

// Fake device.
static NSString *fdev_uniqueID(id s, SEL c) { return @"com.baguette.virtualcam"; }
static NSString *fdev_modelID(id s, SEL c) { return @"BaguetteVirtualCamera"; }
static NSString *fdev_localizedName(id s, SEL c) { return @"Baguette Virtual Camera"; }
static NSString *fdev_manufacturer(id s, SEL c) { return @"baguette"; }
static BOOL fdev_isConnected(id s, SEL c) { return YES; }
static BOOL fdev_hasMediaType(id s, SEL c, NSString *t) { return [t isEqualToString:AVMediaTypeVideo]; }
static NSInteger fdev_position(id s, SEL c) { return AVCaptureDevicePositionBack; }
static NSString *fdev_deviceType(id s, SEL c) { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
static AVCaptureDeviceFormat *fdev_activeFormat(id s, SEL c) { return gFakeFormat; }
static NSArray *fdev_formats(id s, SEL c) { return gFakeFormat ? @[gFakeFormat] : @[]; }
static BOOL fdev_no(id s, SEL c) { return NO; }
static BOOL fdev_modeSupported(id s, SEL c, NSInteger m) { return NO; }
static BOOL fdev_lockForConfiguration(id s, SEL c, NSError **e) { if (e) *e = nil; return YES; }
static void fdev_unlock(id s, SEL c) {}
static CGFloat fdev_zoomOne(id s, SEL c) { return 1.0; }
static void fdev_setZoom(id s, SEL c, CGFloat z) {}

// Dummy input — returned in place of a real AVCaptureDeviceInput so the fake
// device is never handed to the crashing initializer.
static AVCaptureDevice *dinput_device(id s, SEL c) { return gFakeDevice; }
static NSArray *dinput_ports(id s, SEL c) { return @[]; }

// `dispatch_once` because both entry points that build the fakes
// (`defaultDeviceWithMediaType:` and DiscoverySession `devices`) can be
// called from any thread, and apps do hit them concurrently at startup.
// A plain `if (gFakeDevice) return;` lets two threads in at once, and
// the second `objc_allocateClassPair` for an already-registered name
// returns Nil — which `objc_registerClassPair` then dereferences.
static void SimCamBuildObjects(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SimCamBuildObjectsOnce();
    });
}

static void SimCamBuildObjectsOnce(void) {
    Class devCls = NSClassFromString(@"AVCaptureDevice");
    Class fmtCls = NSClassFromString(@"AVCaptureDeviceFormat");
    Class inCls  = NSClassFromString(@"AVCaptureDeviceInput");
    if (!devCls || !fmtCls || !inCls) return;

    Class fFmt = objc_allocateClassPair(fmtCls, "SimCamVCFormat", 0);
    class_addMethod(fFmt, NSSelectorFromString(@"videoMaxZoomFactor"), (IMP)ffmt_videoMaxZoomFactor, "d@:");
    class_addMethod(fFmt, NSSelectorFromString(@"videoFieldOfView"), (IMP)ffmt_videoFieldOfView, "f@:");
    class_addMethod(fFmt, NSSelectorFromString(@"figCaptureSourceVideoFormat"), (IMP)ffmt_figNull, "^v@:");
    class_addMethod(fFmt, NSSelectorFromString(@"videoSupportedFrameRateRanges"), (IMP)ffmt_emptyArray, "@@:");
    objc_registerClassPair(fFmt);
    gFakeFormat = [fFmt alloc];

    Class fDev = objc_allocateClassPair(devCls, "SimCamVCDevice", 0);
    class_addMethod(fDev, @selector(uniqueID), (IMP)fdev_uniqueID, "@@:");
    class_addMethod(fDev, NSSelectorFromString(@"modelID"), (IMP)fdev_modelID, "@@:");
    class_addMethod(fDev, @selector(localizedName), (IMP)fdev_localizedName, "@@:");
    class_addMethod(fDev, NSSelectorFromString(@"manufacturer"), (IMP)fdev_manufacturer, "@@:");
    class_addMethod(fDev, @selector(isConnected), (IMP)fdev_isConnected, "B@:");
    class_addMethod(fDev, @selector(hasMediaType:), (IMP)fdev_hasMediaType, "B@:@");
    class_addMethod(fDev, NSSelectorFromString(@"position"), (IMP)fdev_position, "q@:");
    class_addMethod(fDev, NSSelectorFromString(@"deviceType"), (IMP)fdev_deviceType, "@@:");
    class_addMethod(fDev, NSSelectorFromString(@"activeFormat"), (IMP)fdev_activeFormat, "@@:");
    class_addMethod(fDev, NSSelectorFromString(@"formats"), (IMP)fdev_formats, "@@:");
    class_addMethod(fDev, @selector(hasTorch), (IMP)fdev_no, "B@:");
    class_addMethod(fDev, @selector(hasFlash), (IMP)fdev_no, "B@:");
    class_addMethod(fDev, @selector(isTorchModeSupported:), (IMP)fdev_modeSupported, "B@:q");
    class_addMethod(fDev, @selector(isFocusModeSupported:), (IMP)fdev_modeSupported, "B@:q");
    class_addMethod(fDev, @selector(isExposureModeSupported:), (IMP)fdev_modeSupported, "B@:q");
    class_addMethod(fDev, @selector(lockForConfiguration:), (IMP)fdev_lockForConfiguration, "B@:^@");
    class_addMethod(fDev, @selector(unlockForConfiguration), (IMP)fdev_unlock, "v@:");
    class_addMethod(fDev, NSSelectorFromString(@"videoZoomFactor"), (IMP)fdev_zoomOne, "d@:");
    class_addMethod(fDev, NSSelectorFromString(@"setVideoZoomFactor:"), (IMP)fdev_setZoom, "v@:d");
    class_addMethod(fDev, NSSelectorFromString(@"minAvailableVideoZoomFactor"), (IMP)fdev_zoomOne, "d@:");
    class_addMethod(fDev, NSSelectorFromString(@"maxAvailableVideoZoomFactor"), (IMP)fdev_zoomOne, "d@:");
    objc_registerClassPair(fDev);
    gFakeDevice = [fDev alloc];

    Class fIn = objc_allocateClassPair(inCls, "SimCamVCInput", 0);
    class_addMethod(fIn, @selector(device), (IMP)dinput_device, "@@:");
    class_addMethod(fIn, NSSelectorFromString(@"ports"), (IMP)dinput_ports, "@@:");
    objc_registerClassPair(fIn);
    gDummyInput = [fIn alloc];

    NSLog(@"[SimCamVC] built fake device/format/input");
}

// MARK: - Shared-buffer → CVPixelBuffer

static int gFd = -1;
static void *gMap = NULL;
static size_t gMapSize = 0;
static CVPixelBufferPoolRef gPool = NULL;
static size_t gPoolW = 0, gPoolH = 0;

static CVPixelBufferRef SimCamCopyPixelBuffer(void) {
    if (gMap == NULL) {
        gMapSize = kHeaderSize + kMaxCanvas * kMaxCanvas * 4;
        int fd = open(kSharedPath.UTF8String, O_RDONLY);
        if (fd < 0) return NULL;
        void *m = mmap(NULL, gMapSize, PROT_READ, MAP_SHARED, fd, 0);
        if (m == MAP_FAILED) { close(fd); return NULL; }
        gFd = fd; gMap = m;
    }
    uint32_t seq, width, height;
    memcpy(&seq, gMap, 4);
    memcpy(&width, (uint8_t *)gMap + 8, 4);
    memcpy(&height, (uint8_t *)gMap + 12, 4);
    if (seq == 0 || width == 0 || height == 0 || width > kMaxCanvas || height > kMaxCanvas) return NULL;

    if (gPool == NULL || gPoolW != width || gPoolH != height) {
        if (gPool) { CVPixelBufferPoolRelease(gPool); gPool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &gPool);
        gPoolW = width; gPoolH = height;
    }
    if (!gPool) return NULL;

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gPool, &pb) != kCVReturnSuccess || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
    size_t srcStride = (size_t)width * 4;
    uint8_t *src = (uint8_t *)gMap + kHeaderSize;
    for (size_t row = 0; row < height; row++) {
        memcpy(dst + row * dstStride, src + row * srcStride, srcStride);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// MARK: - Video-data-output delivery

@interface SimCamVCOutputReg : NSObject
@property (nonatomic, weak) AVCaptureVideoDataOutput *output;
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t queue;
@end
@implementation SimCamVCOutputReg
@end

static NSMutableArray<SimCamVCOutputReg *> *gOutputs = nil;
static dispatch_source_t gTimer = NULL;

// `gOutputs` is written from whatever thread the app configures its
// capture graph on and read from the delivery timer's queue, so every
// touch goes through this lock. `gRunningSessions` tracks the sessions
// the app has actually started (by pointer, unretained — we only ever
// compare identity), so delivery follows the session lifecycle instead
// of running forever from the first delegate registration.
static NSLock *gStateLock = nil;
static NSMutableSet<NSValue *> *gRunningSessions = nil;

static void SimCamStateInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStateLock = [NSLock new];
        gOutputs = [NSMutableArray array];
        gRunningSessions = [NSMutableSet set];
    });
}

static void SimCamDeliverTick(void) {
    @autoreleasepool {
        SimCamStateInit();
        [gStateLock lock];
        BOOL idle = (gOutputs.count == 0 || gRunningSessions.count == 0);
        NSArray<SimCamVCOutputReg *> *regs = idle ? nil : [gOutputs copy];
        [gStateLock unlock];
        if (idle) return;

        CVPixelBufferRef pb = SimCamCopyPixelBuffer();
        if (!pb) return;

        CMVideoFormatDescriptionRef fmt = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr || !fmt) {
            CVPixelBufferRelease(pb); return;
        }
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        CMSampleTimingInfo timing = { .duration = kCMTimeInvalid, .presentationTimeStamp = now, .decodeTimeStamp = kCMTimeInvalid };
        CMSampleBufferRef sbuf = NULL;
        OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sbuf);
        CFRelease(fmt);
        CVPixelBufferRelease(pb);
        if (st != noErr || !sbuf) return;

        for (SimCamVCOutputReg *reg in regs) {
            AVCaptureVideoDataOutput *out = reg.output;
            id<AVCaptureVideoDataOutputSampleBufferDelegate> del = reg.delegate;
            if (!out || !del || !reg.queue) continue;
            if (![del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;
            AVCaptureConnection *conn = out.connections.firstObject;
            CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sbuf);
            dispatch_async(reg.queue, ^{
                @try {
                    [del captureOutput:out didOutputSampleBuffer:retained fromConnection:conn];
                } @catch (NSException *e) {
                    NSLog(@"[SimCamVC] delegate threw: %@", e);
                }
                CFRelease(retained);
            });
        }
        CFRelease(sbuf);
    }
}

// The timer runs for the life of the process once armed; `SimCamDeliverTick`
// gates on there being a running session with a registered output, so an
// idle tick costs a lock and a compare. `dispatch_once` because the two
// callers (startRunning, delegate registration) race — an unguarded
// `if (gTimer)` can leave two timers delivering every frame twice.
static void SimCamStartDelivery(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("com.baguette.simcam.delivery", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, (uint64_t)(NSEC_PER_SEC / 30), NSEC_PER_SEC / 60);
        dispatch_source_set_event_handler(gTimer, ^{ SimCamDeliverTick(); });
        dispatch_resume(gTimer);
        NSLog(@"[SimCamVC] frame delivery started (~30fps)");
    });
}

// MARK: - Hooks

static IMP gOrigDefaultForType = NULL;
static IMP gOrigDiscoveryDevices = NULL;
static IMP gOrigInitWithDevice = NULL;
static IMP gOrigCanAddInput = NULL;
static IMP gOrigAddInput = NULL;
static IMP gOrigCanAddOutput = NULL;
static IMP gOrigAddOutput = NULL;
static IMP gOrigSetSBDelegate = NULL;
static IMP gOrigPhotoSettings = NULL;

// `+[AVCapturePhotoSettings photoSettings]` (used by AVCapturePhotoOutput init)
// builds default settings from the current device format, dereferencing the
// fake format's Fig internals. Return codec-only settings that read no device
// format. Sim-only; still-capture is separately faked by SimCamFakePhoto.
static id h_photoSettings(id self, SEL _cmd) {
    return [NSClassFromString(@"AVCapturePhotoSettings")
            performSelector:@selector(photoSettingsWithFormat:)
                 withObject:@{ AVVideoCodecKey: AVVideoCodecTypeJPEG }];
}

static id h_defaultForType(id self, SEL _cmd, NSString *mediaType) {
    id real = ((id (*)(id, SEL, id))gOrigDefaultForType)(self, _cmd, mediaType);
    if (real == nil && [mediaType isEqualToString:AVMediaTypeVideo]) {
        SimCamBuildObjects();
        return gFakeDevice;
    }
    return real;
}

static NSArray *h_discoveryDevices(id self, SEL _cmd) {
    NSArray *real = ((NSArray *(*)(id, SEL))gOrigDiscoveryDevices)(self, _cmd);
    if (real.count == 0) {
        SimCamBuildObjects();
        return gFakeDevice ? @[gFakeDevice] : real;
    }
    return real;
}

typedef id (*InitWithDeviceIMP)(__attribute__((ns_consumed)) id, SEL, AVCaptureDevice *, NSError **)
    __attribute__((ns_returns_retained));

static id h_initWithDevice(__attribute__((ns_consumed)) id self, SEL _cmd, AVCaptureDevice *device, NSError **err)
    __attribute__((ns_returns_retained)) {
    if (device == gFakeDevice) {
        if (err) *err = nil;
        return gDummyInput;  // never run the real (crashing) initializer
    }
    return ((InitWithDeviceIMP)gOrigInitWithDevice)(self, _cmd, device, err);
}

static BOOL h_canAddInput(id self, SEL _cmd, id input) {
    if (input == gDummyInput) return YES;
    return ((BOOL (*)(id, SEL, id))gOrigCanAddInput)(self, _cmd, input);
}

static void h_addInput(id self, SEL _cmd, id input) {
    if (input == gDummyInput) return;  // accept but don't wire the real graph
    ((void (*)(id, SEL, id))gOrigAddInput)(self, _cmd, input);
}

static BOOL h_canAddOutput(id self, SEL _cmd, id output) {
    return YES;  // accept every output; we deliver frames ourselves
}

static void h_addOutput(id self, SEL _cmd, id output) {
    // Never add a real output to the session. If we did, the session's
    // internal `_buildAndRunGraph` tries to start a real capture graph
    // with no source and blocks ~9s ("Timed out waiting for session to
    // start"), stalling the app before it becomes ready. We deliver
    // frames to the video-data-output delegate ourselves, so the output
    // doesn't need to be wired into the (source-less) session.
}

// Never run the real graph — just track the session as running and let
// the delivery timer feed its outputs. Overrides the
// (device-availability-gated) startRunning hook in SimCamInject.m, which
// is why that one never gets a chance to block on a source-less graph.
static IMP gOrigStartRunning2 = NULL;
static void h_startRunning(id self, SEL _cmd) {
    SimCamStateInit();
    [gStateLock lock];
    [gRunningSessions addObject:[NSValue valueWithPointer:(__bridge void *)self]];
    [gStateLock unlock];
    SimCamStartDelivery();
}

// The app stopping its session has to stop the frames: leaving the timer
// feeding a stopped session's delegate burns CPU and hands the app
// buffers it has said it doesn't want.
static void h_stopRunning(id self, SEL _cmd) {
    SimCamStateInit();
    [gStateLock lock];
    [gRunningSessions removeObject:[NSValue valueWithPointer:(__bridge void *)self]];
    [gStateLock unlock];
}

static void h_setSBDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetSBDelegate)(self, _cmd, delegate, queue);
    SimCamStateInit();
    [gStateLock lock];
    // One registration per output: re-registering replaces, and
    // clearing the delegate (the documented way to detach) removes.
    // Appending blindly delivers every frame N times to an output that
    // re-set its delegate, and strands the old one.
    NSMutableArray<SimCamVCOutputReg *> *keep = [NSMutableArray array];
    for (SimCamVCOutputReg *reg in gOutputs) {
        if (reg.output != nil && reg.output != (AVCaptureVideoDataOutput *)self) {
            [keep addObject:reg];  // also drops registrations whose output died
        }
    }
    if (delegate && queue) {
        SimCamVCOutputReg *reg = [SimCamVCOutputReg new];
        reg.output = (AVCaptureVideoDataOutput *)self;
        reg.delegate = delegate;
        reg.queue = queue;
        [keep addObject:reg];
    }
    gOutputs = keep;
    [gStateLock unlock];

    if (delegate && queue) {
        NSLog(@"[SimCamVC] video-data-output delegate registered");
        SimCamStartDelivery();
    } else {
        NSLog(@"[SimCamVC] video-data-output delegate cleared");
    }
}

static void swizzleInstance(Class cls, NSString *sel, IMP newImp, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(sel));
    if (m) *orig = method_setImplementation(m, newImp);
}

void SimCamInstallVirtualCamera(void) {
    Class devCls = NSClassFromString(@"AVCaptureDevice");
    Class discoveryCls = NSClassFromString(@"AVCaptureDeviceDiscoverySession");
    Class inputCls = NSClassFromString(@"AVCaptureDeviceInput");
    Class sessionCls = NSClassFromString(@"AVCaptureSession");
    Class vdoCls = NSClassFromString(@"AVCaptureVideoDataOutput");

    if (devCls) {
        Method m = class_getClassMethod(devCls, NSSelectorFromString(@"defaultDeviceWithMediaType:"));
        if (m) gOrigDefaultForType = method_setImplementation(m, (IMP)h_defaultForType);
    }
    swizzleInstance(discoveryCls, @"devices", (IMP)h_discoveryDevices, &gOrigDiscoveryDevices);
    swizzleInstance(inputCls, @"initWithDevice:error:", (IMP)h_initWithDevice, &gOrigInitWithDevice);
    swizzleInstance(sessionCls, @"canAddInput:", (IMP)h_canAddInput, &gOrigCanAddInput);
    swizzleInstance(sessionCls, @"addInput:", (IMP)h_addInput, &gOrigAddInput);
    swizzleInstance(sessionCls, @"canAddOutput:", (IMP)h_canAddOutput, &gOrigCanAddOutput);
    swizzleInstance(sessionCls, @"addOutput:", (IMP)h_addOutput, &gOrigAddOutput);
    swizzleInstance(sessionCls, @"startRunning", (IMP)h_startRunning, &gOrigStartRunning2);
    { IMP unused = NULL; swizzleInstance(sessionCls, @"stopRunning", (IMP)h_stopRunning, &unused); }
    swizzleInstance(vdoCls, @"setSampleBufferDelegate:queue:", (IMP)h_setSBDelegate, &gOrigSetSBDelegate);

    Class photoSettingsCls = NSClassFromString(@"AVCapturePhotoSettings");
    if (photoSettingsCls) {
        Method m = class_getClassMethod(photoSettingsCls, NSSelectorFromString(@"photoSettings"));
        if (m) gOrigPhotoSettings = method_setImplementation(m, (IMP)h_photoSettings);
    }

    NSLog(@"[SimCamVC] virtual-camera capture graph installed");
}
