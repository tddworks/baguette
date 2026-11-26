// HIDButtons — presses iPhone Duo's hardware buttons and keyboard keys from
// inside the simulator, on a HID buttons service.
//
// dtuhidd owns a `mainScreenButtons` service (usage page 0x0B, usage 0x01,
// built-in), and Device Hub's volume, power and camera-control buttons are
// plain keyboard IOHIDEvents on it: consumer page 0x0C usages 0xE9 / 0xEA /
// 0x30, and Apple's vendor keyboard page 0xFF00 usage 0x66, held a quarter
// second. SpringBoard takes them only from a service of that shape: the
// legacy Indigo press reaches backboardd on a touchscreen service and is
// ignored. iPhone Duo takes its keyboard keys only from here too. This
// program, spawned in the guest by `simctl spawn`, registers a service of
// that shape and presses them.
//
//   HIDButtons button <usagePage> <usage> <milliseconds> [<usagePage> <usage>]…
//                       — trailing pairs are modifiers held around the key
//   HIDButtons serve    — the same, one per line on stdin, until EOF, each
//                         answered `done <status>`
//
// Each may follow `--deadline <unix-seconds>`: past it, a program not yet
// ready to act exits 3 without acting. It prints `pid <n>` before it starts,
// so its owner can stop it after a timeout.
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import "InjectedCommand.h"
#import "VirtualHIDService.h"
#import "ButtonPress.h"

static IOHIDEventRef (*IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);

int main(int argc, char **argv) {
  @autoreleasepool {
    int first;
    double deadline;
    if (!readInjectedDeadline(argc, argv, &first, &deadline)) return 2;
    if (argc - first < 1) {
      fprintf(stderr, "usage: HIDButtons [--deadline <unix-seconds>] button <page> <usage> <ms> [<page> <usage>]... | serve\n");
      return 2;
    }
    if (injectedDeadlinePassed(deadline)) {
      fprintf(stderr, "deadline passed; nothing done\n");
      return InjectedDeadlinePassedStatus;
    }
    printf("pid %d\n", getpid());
    fflush(stdout);
    IOHIDEventCreateKeyboardEvent = loadIOHIDEventFunction("IOHIDEventCreateKeyboardEvent");
    if (!IOHIDEventCreateKeyboardEvent) { fprintf(stderr, "no IOHIDEventCreateKeyboardEvent\n"); return 1; }
    dispatch_queue_t queue = dispatch_queue_create("HIDButtons", DISPATCH_QUEUE_SERIAL);
    id buttons = activateVirtualHIDService(0x0B, 0x01, @"baguette HIDButtons", YES, queue);
    if (!buttons) { fprintf(stderr, "HID service did not activate\n"); return 1; }
    usleep(300 * 1000);   // let the event system enumerate it
    if (injectedDeadlinePassed(deadline)) {
      cancelVirtualHIDService(buttons);
      fprintf(stderr, "deadline passed before the program was ready; nothing done\n");
      return InjectedDeadlinePassedStatus;
    }

    BOOL (^key)(unsigned, unsigned, BOOL) = ^BOOL(unsigned page, unsigned usage, BOOL down) {
      return dispatchOnVirtualHIDService(buttons, IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0));
    };
    void (^hold)(unsigned) = ^(unsigned ms) { usleep(ms * 1000); };
    int status = runInjectedCommand(argc, argv, first, ^int(NSArray<NSString *> *words) {
      if (![words.firstObject isEqualToString:@"button"]) return 2;
      return pressButton([words subarrayWithRange:NSMakeRange(1, words.count - 1)], key, hold);
    });
    usleep(300 * 1000);
    cancelVirtualHIDService(buttons);
    usleep(100 * 1000);
    return status;
  }
}
