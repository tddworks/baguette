// Reads iPhone Duo's hinge as the guest's own device-info daemon does,
// through CoreMotion's private CMAngleManager: its first sample is the
// current angle, then one arrives per change — every frame of a sweep.
#import "HingeAngle.h"
#import <dlfcn.h>

@interface NSObject (HingeAngle)
+ (BOOL)isAvailable;
// The handler's second argument is not an object; only the sample is taken.
- (void)startAngleUpdatesToQueue:(NSOperationQueue *)queue handler:(void (^)(id angle))handler;
- (void)stopAngleUpdates;
- (float)angleDegrees;
- (BOOL)isAngleValid;
@end

// The current angle and exit 0, or exit 1 when no valid sample arrives in a
// second (one lands in ~20 ms; a guest whose SpringBoard restarted sends
// none); `watch` prints every sample until the host stops it.
int printHingeAngles(BOOL watch) {
  dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW);
  Class manager = NSClassFromString(@"CMAngleManager");
  if (!manager || ![manager isAvailable]) {
    fprintf(stderr, "no hinge on this device\n");
    return 1;
  }
  id angles = [manager new];
  NSOperationQueue *queue = [NSOperationQueue new];
  queue.maxConcurrentOperationCount = 1;
  dispatch_semaphore_t first = dispatch_semaphore_create(0);
  __block BOOL reported = NO;
  [angles startAngleUpdatesToQueue:queue handler:^(id angle) {
    if (reported) return;
    if (reportHingeSample(stdout, [angle angleDegrees], [angle isAngleValid]) && !watch) {
      reported = YES;
      dispatch_semaphore_signal(first);
    }
  }];
  if (watch) dispatch_main();
  BOOL silent = dispatch_semaphore_wait(first, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0;
  [angles stopAngleUpdates];
  if (silent) fprintf(stderr, "no hinge sample in 1 second\n");
  return silent ? 1 : 0;
}
