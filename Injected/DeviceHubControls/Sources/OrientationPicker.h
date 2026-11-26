#pragma once
#import <Foundation/Foundation.h>

// Native enum values Device Hub's orientation-picker-control takes.
static BOOL isPickerOrientation(NSString *value) {
  return [@[@"portrait", @"pud", @"landscape-left", @"landscape-right"] containsObject:value];
}

// One picker value to `send`: usage error 2, dispatch error 1.
static int dispatchPickerOrientation(NSString *value, BOOL (^send)(const char *)) {
  if (!isPickerOrientation(value)) return 2;
  return send(value.UTF8String) ? 0 : 1;
}
