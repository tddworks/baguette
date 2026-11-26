/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * Adapted from facebook/idb, SimulatorFrameworkBridge/Runtime/AccessibilityRuntime.m
 * (1c5c81f6cbe3a31986eda66349fd22a2f9b47858), under the MIT license.
 * See LICENSE.idb in this directory.
 */
#import "Frontmost.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <unistd.h>

@interface NSObject (FrontmostTranslation)
+ (id)sharediOSInstance;
- (id)frontmostApplicationWithDisplayId:(unsigned int)displayID bridgeDelegateToken:(NSString *)token;
- (id)processTranslatorRequest:(id)request;
@end

@interface FrontmostDelegate : NSObject
@property (nonatomic, weak) NSObject *translator;
@end

@implementation FrontmostDelegate
- (id (^)(id))accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  NSObject *translator = self.translator;
  return ^id(id request) { return [translator processTranslatorRequest:request]; };
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token { return rect; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }
@end

int printFrontmostApplication(void) {
  __block atomic_bool completed = false;
  // Independent of the main queue: even a blocked AX callback must exit.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (!atomic_exchange_explicit(&completed, true, memory_order_relaxed)) {
      dprintf(STDERR_FILENO, "frontmost query timed out after 4 seconds\n");
      _Exit(1);
    }
  });
  // Query off main, while dispatch_main services AX's initialization callbacks.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSNumber *pid = nil;
      NSString *failure = nil;
      @try {
        if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW)) {
          failure = [NSString stringWithUTF8String:dlerror()];
        } else {
          Class translatorClass = objc_lookUpClass("AXPTranslator");
          if (![translatorClass respondsToSelector:@selector(sharediOSInstance)]) {
            failure = @"AXPTranslator.sharediOSInstance is unavailable";
          } else {
            NSObject *translator = [translatorClass sharediOSInstance];
            FrontmostDelegate * __attribute__((objc_precise_lifetime)) delegate = [FrontmostDelegate new];
            delegate.translator = translator;
            [translator setValue:delegate forKey:@"bridgeTokenDelegate"];
            [translator setValue:@YES forKey:@"supportsDelegateTokens"];
            id application = [translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:@"frontmost"];
            pid = [application valueForKey:@"pid"];
            if (![pid isKindOfClass:NSNumber.class] || pid.intValue <= 0) {
              failure = @"the guest window server returned no frontmost application";
            }
          }
        }
      } @catch (NSException *exception) {
        failure = exception.reason ?: exception.name;
      }
      // Only one terminal path writes a response; the deadline can race success.
      if (atomic_exchange_explicit(&completed, true, memory_order_relaxed)) return;
      if (failure) {
        dprintf(STDERR_FILENO, "frontmost query failed: %s\n", failure.UTF8String);
        _Exit(1);
      }
      dprintf(STDOUT_FILENO, "\n{\"pid\":%d}\n", pid.intValue);
      _Exit(0);
    }
  });
  dispatch_main();
}
