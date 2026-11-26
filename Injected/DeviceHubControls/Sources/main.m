// DeviceHubControls — plays Device Hub's controls for iPhone Duo from inside
// the simulator: the hinge slider and the orientation picker.
//
// Device Hub speaks CoreDevice's UniversalHID to the guest daemon `dtuhidd`,
// which owns a virtual HID service it calls `avpCustom` (usage page 0xFF61,
// usage 0x5B) and dispatches every control as a vendor-defined IOHIDEvent
// whose payload is a keyed record:
//   {provider: "com.apple.Virtualization.VirtualMachines",
//    source: "hinge-slider-control", type: "range", value: <degrees>}
// for the hinge, and {source: "orientation-picker-control", type: "enum",
// value: "portrait"} for the picker. The runtime's consumer of those events
// does not care which process's service they came from, so this program,
// spawned in the guest by `simctl spawn`, registers a service of the same
// shape and dispatches the same events. Measured against Device Hub with a
// HID event monitor in the guest; the encoder below reproduces its payload
// byte for byte.
//
// Record layout: `d3 00 00 00`, then items of [u24 aux][u8 type], the top bit
// of `type` marking a container's last entry. 0x01 dictionary (aux = entry
// count), 0x08 key (NUL-terminated, aux = length incl NUL), 0x09 string
// (aux = length), 0x04 double (aux = 0x3f, 8 bytes LE). Every item is padded
// to 4 bytes.
//
//   DeviceHubControls angle <degrees>
//   DeviceHubControls sweep <from> <to> <milliseconds>     (60 Hz, ease-out)
//   DeviceHubControls orientation <portrait|pud|landscape-left|landscape-right>
//   DeviceHubControls serve   — the same verbs, one per line on stdin, until
//                               EOF, each answered `done <status>`
//
// Each may follow `--deadline <unix-seconds>`: past it, a program not yet
// ready to act exits 3 without acting. It prints `pid <n>` before it starts,
// so its owner can stop it after a timeout.
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import "InjectedCommand.h"
#import "VirtualHIDService.h"
#import "OrientationPicker.h"

static IOHIDEventRef (*IOHIDEventCreateVendorDefinedEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint8_t *, CFIndex, uint32_t);

// --- payload -----------------------------------------------------------
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
static NSMutableData *controlPayload(const char *source, const char *type) {
  NSMutableData *d = [NSMutableData data];
  uint8_t magic[4] = { 0xd3, 0, 0, 0 }; [d appendBytes:magic length:4];
  putHeader(d, 4, 0x81);
  putKey(d, "provider"); putString(d, "com.apple.Virtualization.VirtualMachines", NO);
  putKey(d, "source");   putString(d, source, NO);
  putKey(d, "type");     putString(d, type, NO);
  putKey(d, "value");
  return d;
}
static NSData *hingePayload(double degrees) {
  NSMutableData *d = controlPayload("hinge-slider-control", "range");
  putDouble(d, degrees, YES);
  return d;
}
static NSData *orientationPayload(const char *value) {
  NSMutableData *d = controlPayload("orientation-picker-control", "enum");
  putString(d, value, YES);
  return d;
}


int main(int argc, char **argv) {
  @autoreleasepool {
    int first;
    double deadline;
    if (!readInjectedDeadline(argc, argv, &first, &deadline)) return 2;
    if (argc - first < 1) {
      fprintf(stderr, "usage: DeviceHubControls [--deadline <unix-seconds>] angle <deg> | sweep <from> <to> <ms> | orientation <portrait|pud|landscape-left|landscape-right> | serve\n");
      return 2;
    }
    if (strcmp(argv[first], "orientation") == 0 &&
        (argc - first != 2 || !isPickerOrientation(@(argv[first + 1])))) {
      fprintf(stderr, "orientation requires portrait, pud, landscape-left or landscape-right\n");
      return 2;
    }
    if (injectedDeadlinePassed(deadline)) {
      fprintf(stderr, "deadline passed; nothing done\n");
      return InjectedDeadlinePassedStatus;
    }
    printf("pid %d\n", getpid());
    fflush(stdout);
    IOHIDEventCreateVendorDefinedEvent = loadIOHIDEventFunction("IOHIDEventCreateVendorDefinedEvent");
    if (!IOHIDEventCreateVendorDefinedEvent) { fprintf(stderr, "no IOHIDEventCreateVendorDefinedEvent\n"); return 1; }
    dispatch_queue_t queue = dispatch_queue_create("DeviceHubControls", DISPATCH_QUEUE_SERIAL);
    id service = activateVirtualHIDService(0xFF61, 0x5B, @"baguette DeviceHubControls", NO, queue);
    if (!service) { fprintf(stderr, "HID service did not activate\n"); return 1; }
    usleep(300 * 1000);   // let the event system enumerate it
    if (injectedDeadlinePassed(deadline)) {
      cancelVirtualHIDService(service);
      fprintf(stderr, "deadline passed before the program was ready; nothing done\n");
      return InjectedDeadlinePassedStatus;
    }

    BOOL (^send)(NSData *) = ^BOOL(NSData *payload) {
      return dispatchOnVirtualHIDService(service, IOHIDEventCreateVendorDefinedEvent(
        kCFAllocatorDefault, mach_absolute_time(), 0xFF61, 0x5B, 0, (uint8_t *)payload.bytes, payload.length, 0));
    };
    // Exit status: 0 success, 1 dispatch failure, 2 invalid arguments.
    int status = runInjectedCommand(argc, argv, first, ^int(NSArray<NSString *> *words) {
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
        return 0;
      } else if ([verb isEqualToString:@"orientation"] && words.count == 2) {
        return dispatchPickerOrientation(words[1], ^BOOL(const char *value) {
          return send(orientationPayload(value));
        });
      }
      return 2;
    });
    usleep(300 * 1000);
    cancelVirtualHIDService(service);
    usleep(100 * 1000);
    return status;
  }
}
