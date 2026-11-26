#pragma once
// A virtual HID service registered in the guest with the private
// HID.framework (`HIDVirtualEventService`), shaped like one dtuhidd owns, so
// the runtime takes the events dispatched on it as that service's. Used by
// DeviceHubControls (an `avpCustom`-shaped service) and HIDButtons (a
// `mainScreenButtons`-shaped one).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void *IOHIDEventRef;

@interface VirtualHIDServiceDelegate : NSObject
@property (nonatomic, strong) NSDictionary *properties;
@end
@implementation VirtualHIDServiceDelegate
- (id)propertyForKey:(NSString *)key forService:(id)service { return self.properties[key]; }
- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service { return YES; }
- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service { return nil; }
- (BOOL)setOutputEvent:(id)event forService:(id)service { return YES; }
- (void)notification:(uint32_t)type withProperty:(NSDictionary *)prop forService:(id)service {}
@end

// Loads HID.framework and IOKit; NULL when IOKit has no such symbol.
static void *loadIOHIDEventFunction(const char *name) {
  dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW);
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  return dlsym(iokit, name);
}

// A virtual service of the given usage, activated; nil if it did not.
static id activateVirtualHIDService(unsigned page, unsigned usage, NSString *product, BOOL builtIn, dispatch_queue_t queue) {
  Class S = NSClassFromString(@"HIDVirtualEventService");
  if (!S) return nil;
  id service = [[S alloc] init];
  VirtualHIDServiceDelegate *delegate = [VirtualHIDServiceDelegate new];
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
  ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDispatchQueue:"), queue);
  ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("activate"));
  uint64_t sid = ((uint64_t (*)(id, SEL))objc_msgSend)(service, sel_registerName("serviceID"));
  return sid ? service : nil;
}

static BOOL dispatchOnVirtualHIDService(id service, IOHIDEventRef event) {
  BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("dispatchEvent:"), (__bridge id)event);
  CFRelease(event);
  return ok;
}

static void cancelVirtualHIDService(id service) {
  ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("cancel"));
}
