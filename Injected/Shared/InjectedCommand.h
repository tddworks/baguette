#pragma once
// What every program baguette spawns in the guest shares with its host: the
// `--deadline` that keeps a late start from acting, and `serve`, which plays
// commands one per line so a kept child costs no spawn per command.
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

// `--deadline <unix-seconds>` precedes the verb: a program not ready to act
// by then exits with this status and does nothing, so a host that stopped
// waiting knows a late start cannot move the device.
static const int InjectedDeadlinePassedStatus = 3;

static BOOL parseInjectedDeadline(const char *text, double *deadline) {
  char *end = NULL;
  double value = strtod(text, &end);
  if (end == text || *end != '\0' || !isfinite(value)) return NO;
  *deadline = value;
  return YES;
}

static BOOL injectedDeadlinePassed(double deadline) {
  return [NSDate date].timeIntervalSince1970 > deadline;
}

// Reads `[--deadline <unix-seconds>]` from argv; *first is the verb's index.
// Returns NO (and says why) when the flag is malformed.
static BOOL readInjectedDeadline(int argc, char **argv, int *first, double *deadline) {
  *first = 1;
  *deadline = INFINITY;
  if (argc > 1 && strcmp(argv[1], "--deadline") == 0) {
    if (argc < 3 || !parseInjectedDeadline(argv[2], deadline)) {
      fprintf(stderr, "--deadline requires a Unix time in seconds\n");
      return NO;
    }
    *first = 3;
  }
  return YES;
}

// Plays commands one per line until EOF. Each is answered with
// `done <status>` once played: 0 success, 1 dispatch failure, 2 invalid.
static void serveInjectedCommands(FILE *input, FILE *output, int (^perform)(NSArray<NSString *> *)) {
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, input) > 0) {
    NSString *text = [[NSString stringWithUTF8String:line]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) continue;
    int status = perform([text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    if (status) fprintf(stderr, "%s: %s\n", status == 2 ? "bad line" : "dispatch failed", text.UTF8String);
    fprintf(output, "done %d\n", status);
    fflush(output);
  }
  free(line);
}

// Runs the verb in argv[first...] once, or serves lines when it is `serve`.
static int runInjectedCommand(int argc, char **argv, int first, int (^perform)(NSArray<NSString *> *)) {
  NSMutableArray<NSString *> *words = [NSMutableArray array];
  for (int i = first; i < argc; i++) [words addObject:[NSString stringWithUTF8String:argv[i]]];
  if ([words.firstObject isEqualToString:@"serve"]) {
    // Commands line by line until stdin closes: the owner's exit.
    serveInjectedCommands(stdin, stdout, perform);
    return 0;
  }
  int status = perform(words);
  if (status) fprintf(stderr, "%s\n", status == 2 ? "bad arguments" : "dispatch failed");
  return status;
}
