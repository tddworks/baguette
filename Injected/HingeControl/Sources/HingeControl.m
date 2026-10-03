// HingeControl — drives iPhone Duo's hinge (and its orientation picker)
// from inside the simulator, the way Device Hub does.
//
// Device Hub speaks CoreDevice's UniversalHID to the guest daemon
// `dtuhidd`, which owns a virtual HID service it calls `avpCustom`
// (usage page 0xFF61, usage 0x5B) and dispatches every pose command on it
// as a vendor-defined IOHIDEvent whose payload is a keyed record:
//   {provider: "com.apple.Virtualization.VirtualMachines",
//    source: "hinge-slider-control", type: "range", value: <degrees>}
// for the hinge, and {source: "orientation-picker-control", type: "enum",
// value: "portrait"} for the picker. The runtime's consumer of those
// events does not care which process's service they came from — so this
// tool, spawned in the guest by `simctl spawn`, registers a service of the
// same shape with the private HID.framework and dispatches the same
// events. Measured against Device Hub with a HID event monitor in the
// guest; the encoder below reproduces its payload byte for byte.
//
// Record layout: `d3 00 00 00`, then items of [u24 aux][u8 type], the
// top bit of `type` marking a container's last entry. 0x01 dictionary
// (aux = entry count), 0x08 key (NUL-terminated, aux = length incl NUL),
// 0x09 string (aux = length), 0x04 double (aux = 0x3f, 8 bytes LE).
// Every item is padded to 4 bytes.
//
// The hardware keys go the same way. dtuhidd also owns a
// `mainScreenButtons` service (usage page 0x0B, usage 0x01, built-in),
// and Device Hub's volume, power and camera-control buttons are plain
// keyboard IOHIDEvents on it — consumer page 0x0C usages 0xE9 / 0xEA /
// 0x30, and Apple's vendor keyboard page 0xFF00 usage 0x66 — held a
// quarter second. SpringBoard takes them only from a service of that
// shape: the legacy Indigo press reaches backboardd on a touchscreen
// service and is ignored. A second service here presses them.
//
//   HingeControl angle <degrees>
//   HingeControl sweep <from> <to> <milliseconds>     (60 Hz, ease-out)
//   HingeControl orientation <portrait|pud|landscape-left|landscape-right>
//   HingeControl button <usagePage> <usage> <milliseconds>
//   HingeControl serve        — the same verbs, one per line on stdin,
//                               until EOF, each answered `done <status>`;
//                               baguette keeps one of these per device so
//                               a pose costs no spawn.
//
// Any verb may follow `--deadline <unix-seconds>`: past it, a helper not yet
// ready to act exits 3 without acting. A helper prints `pid <n>` before it
// starts, so its owner can stop it after a timeout.
#import <Foundation/Foundation.h>
#import "HingeProtocol.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import "Frontmost.h"

typedef void *IOHIDEventRef;
static IOHIDEventRef (*IOHIDEventCreateVendorDefinedEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint8_t *, CFIndex, uint32_t);
static IOHIDEventRef (*IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);

// --- payload -----------------------------------------------------------
// [u24 aux][u8 type | 0x80 on the container's last entry]; keys are
// NUL-terminated (type 8), strings not (type 9), doubles (type 4, aux 0x3f);
// every item is padded to 4 bytes; the whole thing starts with d3 00 00 00.
static void putHeader(NSMutableData *d, uint32_t aux, uint8_t type) {
  uint8_t h[4] = { aux & 0xff, (aux >> 8) & 0xff, (aux >> 16) & 0xff, type };
  [d appendBytes:h length:4];
}
static void pad4(NSMutableData *d) { while (d.length % 4) { uint8_t z = 0; [d appendBytes:&z length:1]; } }
static void putKey(NSMutableData *d, const char *k) {
  size_t n = strlen(k) + 1; putHeader(d, (uint32_t)n, 0x08); [d appendBytes:k length:n]; pad4(d);
}
static void putString(NSMutableData *d, const char *s, BOOL last) {
  size_t n = strlen(s); putHeader(d, (uint32_t)n, 0x09 | (last ? 0x80 : 0)); [d appendBytes:s length:n]; pad4(d);
}
static void putDouble(NSMutableData *d, double v, BOOL last) {
  putHeader(d, 0x3f, 0x04 | (last ? 0x80 : 0)); [d appendBytes:&v length:8];
}
static NSData *hingePayload(double degrees) {
  NSMutableData *d = [NSMutableData data];
  uint8_t magic[4] = { 0xd3, 0, 0, 0 }; [d appendBytes:magic length:4];
  putHeader(d, 4, 0x81);
  putKey(d, "provider"); putString(d, "com.apple.Virtualization.VirtualMachines", NO);
  putKey(d, "source");   putString(d, "hinge-slider-control", NO);
  putKey(d, "type");     putString(d, "range", NO);
  putKey(d, "value");    putDouble(d, degrees, YES);
  return d;
}
static NSData *orientationPayload(const char *value) {
  NSMutableData *d = [NSMutableData data];
  uint8_t magic[4] = { 0xd3, 0, 0, 0 }; [d appendBytes:magic length:4];
  putHeader(d, 4, 0x81);
  putKey(d, "provider"); putString(d, "com.apple.Virtualization.VirtualMachines", NO);
  putKey(d, "source");   putString(d, "orientation-picker-control", NO);
  putKey(d, "type");     putString(d, "enum", NO);
  putKey(d, "value");    putString(d, value, YES);
  return d;
}

// --- the virtual service's delegate -------------------------------------
@interface ServiceDelegate : NSObject
@property (nonatomic, strong) NSDictionary *properties;
@end
@implementation ServiceDelegate
- (id)propertyForKey:(NSString *)key forService:(id)service {
  id v = self.properties[key];
  return v;
}
- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
  return YES;
}
- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service { return nil; }
- (BOOL)setOutputEvent:(id)event forService:(id)service { return YES; }
- (void)notification:(uint32_t)type withProperty:(NSDictionary *)prop forService:(id)service {
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    // A read-only AX query: answered before any HID framework is loaded
    // or an input service registered, so it leaves the guest untouched.
    if (argc == 2 && strcmp(argv[1], "frontmost") == 0) return printFrontmostApplication();
    int first = 1;
    double deadline = INFINITY;
    if (argc > 1 && strcmp(argv[1], "--deadline") == 0) {
      if (argc < 3 || !parseHingeDeadline(argv[2], &deadline)) {
        fprintf(stderr, "--deadline requires a Unix time in seconds\n");
        return 2;
      }
      first = 3;
    }
    if (argc - first < 1) { fprintf(stderr, "usage: HingeControl frontmost | [--deadline <unix-seconds>] angle <deg> | sweep <from> <to> <ms> | orientation <portrait|pud|landscape-left|landscape-right> | button <page> <usage> <ms> | serve\n"); return 2; }
    if (strcmp(argv[first], "orientation") == 0 &&
        (argc - first != 2 || !isHingeOrientation(@(argv[first + 1])))) {
      fprintf(stderr, "orientation requires portrait, pud, landscape-left or landscape-right\n");
      return 2;
    }
    if (hingeDeadlinePassed(deadline)) {
      fprintf(stderr, "deadline passed; nothing done\n");
      return HingeDeadlinePassedStatus;
    }
    printf("pid %d\n", getpid());
    fflush(stdout);
    dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW);
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    IOHIDEventCreateVendorDefinedEvent = dlsym(iokit, "IOHIDEventCreateVendorDefinedEvent");
    IOHIDEventCreateKeyboardEvent = dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
    if (!IOHIDEventCreateVendorDefinedEvent || !IOHIDEventCreateKeyboardEvent) { fprintf(stderr, "no IOHIDEventCreate*Event\n"); return 1; }
    Class S = NSClassFromString(@"HIDVirtualEventService");
    dispatch_queue_t q = dispatch_queue_create("HingeControl", DISPATCH_QUEUE_SERIAL);
    // A virtual service of the given usage, activated; nil if it did not.
    id (^serviceOf)(unsigned, unsigned, NSString *, BOOL) = ^id(unsigned page, unsigned usage, NSString *product, BOOL builtIn) {
      id service = [[S alloc] init];
      ServiceDelegate *delegate = [ServiceDelegate new];
      NSMutableDictionary *props = [@{
        @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage),
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @(page), @"DeviceUsage": @(usage)}],
        @"Transport": @"CoreDevice", @"Product": product,
        @"VendorID": @0, @"ProductID": @0, @"VersionNumber": @0, @"ReportInterval": @8000,
      } mutableCopy];
      if (builtIn) props[@"Built-In"] = @YES;
      delegate.properties = props;
      objc_setAssociatedObject(service, "delegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDelegate:"), delegate);
      ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDispatchQueue:"), q);
      ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("activate"));
      uint64_t sid = ((uint64_t (*)(id, SEL))objc_msgSend)(service, sel_registerName("serviceID"));
      return sid ? service : nil;
    };
    id service = serviceOf(0xFF61, 0x5B, @"baguette HingeControl", NO);
    id buttons = serviceOf(0x0B, 0x01, @"baguette HingeControl buttons", YES);
    if (!service || !buttons) { fprintf(stderr, "HID service did not activate\n"); return 1; }
    usleep(300 * 1000);   // let the event system enumerate them
    if (hingeDeadlinePassed(deadline)) {
      ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("cancel"));
      ((void (*)(id, SEL))objc_msgSend)(buttons, sel_registerName("cancel"));
      fprintf(stderr, "deadline passed before the helper was ready; nothing done\n");
      return HingeDeadlinePassedStatus;
    }

    BOOL (*dispatch)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    // One key, down then up, as Device Hub's buttons press it.
    BOOL (^press)(unsigned, unsigned, unsigned) = ^BOOL(unsigned page, unsigned usage, unsigned ms) {
      IOHIDEventRef down = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, true, 0);
      BOOL downOK = dispatch(buttons, sel_registerName("dispatchEvent:"), (__bridge id)down);
      CFRelease(down);
      usleep(ms * 1000);
      IOHIDEventRef up = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, false, 0);
      BOOL upOK = dispatch(buttons, sel_registerName("dispatchEvent:"), (__bridge id)up);
      CFRelease(up);
      return downOK && upOK;
    };
    BOOL (^send)(NSData *) = ^BOOL(NSData *payload) {
      IOHIDEventRef ev = IOHIDEventCreateVendorDefinedEvent(kCFAllocatorDefault, mach_absolute_time(), 0xFF61, 0x5B, 0,
        (uint8_t *)payload.bytes, payload.length, 0);
      BOOL ok = dispatch(service, sel_registerName("dispatchEvent:"), (__bridge id)ev);
      CFRelease(ev);
      return ok;
    };
    // One command: `angle D`, `sweep F T MS`, `orientation NAME` or `button P U MS`.
    // Exit status: 0 success, 1 dispatch failure, 2 invalid arguments.
    int (^perform)(NSArray<NSString *> *) = ^int(NSArray<NSString *> *words) {
      NSString *verb = words.firstObject ?: @"";
      if ([verb isEqualToString:@"angle"] && words.count >= 2) {
        return send(hingePayload(words[1].doubleValue)) ? 0 : 1;
      } else if ([verb isEqualToString:@"sweep"] && words.count >= 4) {
        double from = words[1].doubleValue, to = words[2].doubleValue, ms = words[3].doubleValue;
        int frames = (int)(ms / 16.667); if (frames < 1) frames = 1;
        for (int i = 1; i <= frames; i++) {
          double p = (double)i / frames, e = 1 - pow(1 - p, 3);
          if (!send(hingePayload(from + (to - from) * e))) return 1;
          usleep(16667);
        }
      } else if ([verb isEqualToString:@"orientation"] && words.count == 2) {
        return dispatchHingeOrientation(words[1], ^BOOL(const char *value) {
          return send(orientationPayload(value));
        });
      } else if ([verb isEqualToString:@"button"] && words.count >= 4) {
        return press((unsigned)strtoul(words[1].UTF8String, NULL, 0), (unsigned)strtoul(words[2].UTF8String, NULL, 0),
              (unsigned)strtoul(words[3].UTF8String, NULL, 0)) ? 0 : 1;
      } else {
        return 2;
      }
      return 0;
    };
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (int i = first; i < argc; i++) [words addObject:[NSString stringWithUTF8String:argv[i]]];
    int status = 0;
    if ([words.firstObject isEqualToString:@"serve"]) {
      // Commands line by line until stdin closes — the owner's exit.
      serveHingeCommands(stdin, stdout, perform);
    } else {
      status = perform(words);
      if (status) fprintf(stderr, "%s\n", status == 2 ? "bad arguments" : "dispatch failed");
    }
    usleep(300 * 1000);
    ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("cancel"));
    ((void (*)(id, SEL))objc_msgSend)(buttons, sel_registerName("cancel"));
    usleep(100 * 1000);
    return status;
  }
  return 0;
}
