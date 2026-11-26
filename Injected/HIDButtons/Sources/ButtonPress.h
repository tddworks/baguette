#pragma once
#import <Foundation/Foundation.h>

// `button <page> <usage> <ms> [<page> <usage>]…`, the words after the verb.
// Trailing pairs are modifiers: down in order before the key, up in reverse
// after it, so a shifted letter or a Cmd chord types as on a keyboard.
// Whatever went down is released even when a press is refused.
static int pressButton(NSArray<NSString *> *words, BOOL (^key)(unsigned page, unsigned usage, BOOL down),
                       void (^hold)(unsigned ms)) {
  if (words.count < 3 || (words.count - 3) % 2) return 2;
  unsigned values[words.count];
  for (NSUInteger i = 0; i < words.count; i++) {
    const char *text = words[i].UTF8String;
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 0);
    if (end == text || *end != '\0') return 2;
    values[i] = (unsigned)value;
  }
  NSUInteger modifiers = (words.count - 3) / 2;
  BOOL ok = YES;
  for (NSUInteger m = 0; m < modifiers; m++) ok = key(values[3 + 2 * m], values[4 + 2 * m], YES) && ok;
  ok = key(values[0], values[1], YES) && ok;
  hold(values[2]);
  ok = key(values[0], values[1], NO) && ok;
  for (NSUInteger m = modifiers; m > 0; m--) ok = key(values[1 + 2 * m], values[2 + 2 * m], NO) && ok;
  return ok ? 0 : 1;
}
