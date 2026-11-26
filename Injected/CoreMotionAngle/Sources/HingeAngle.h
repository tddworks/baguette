#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>

// `read-angle` / `watch-angle`: a valid sample is one `angle <degrees>` line
// to the host; a sample the guest flags invalid is no reading.
static inline BOOL reportHingeSample(FILE *output, double degrees, BOOL valid) {
  if (!valid) return NO;
  fprintf(output, "angle %g\n", degrees);
  fflush(output);
  return YES;
}

int printHingeAngles(BOOL watch);
