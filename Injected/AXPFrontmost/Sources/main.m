// AXPFrontmost — asks the simulator's own accessibility server which app is
// in front, through AccessibilityPlatformTranslation's AXPTranslator, and
// prints `{"pid":<n>}`. Connecting as an accessibility client in the guest
// also wakes a freshly launched app's tree for the host's next read.
//
//   AXPFrontmost frontmost
#import <Foundation/Foundation.h>
#import "Frontmost.h"

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "frontmost") == 0) return printFrontmostApplication();
    fprintf(stderr, "usage: AXPFrontmost frontmost\n");
    return 2;
  }
}
