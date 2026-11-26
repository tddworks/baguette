// CoreMotionAngle — reads iPhone Duo's hinge angle from inside the
// simulator, through CoreMotion's CMAngleManager, as the guest's own
// device-info daemon does. Reads only: it registers no HID service and moves
// nothing.
//
//   CoreMotionAngle read-angle   — prints the angle, `angle <degrees>`, and exits
//   CoreMotionAngle watch-angle  — prints every sample the same way until stopped
#import <Foundation/Foundation.h>
#import "HingeAngle.h"

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "read-angle") == 0) return printHingeAngles(NO);
    if (argc == 2 && strcmp(argv[1], "watch-angle") == 0) return printHingeAngles(YES);
    fprintf(stderr, "usage: CoreMotionAngle read-angle | watch-angle\n");
    return 2;
  }
}
