// CoreDevice.framework (Xcode's private device stack) ships no Swift module.
// This target is the only code in baguette that speaks its Swift ABI: Swift
// sees plain functions here, never a mangled symbol. Everything is resolved
// with dlopen at runtime, so a Mac without CoreDevice simply reports it absent.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Load CoreDevice and resolve every symbol this target calls. False when the
/// framework or any symbol is missing — nothing below may be called then.
bool cdabi_load(void);

/// A CoreDevice / UniversalHID symbol (type metadata, a conformance), or NULL.
void *cdabi_symbol(const char *mangled_name);

/// Size of a value of the type `metadata` describes (its value witness).
size_t cdabi_size_of(const void *metadata);

/// Destroy a value of the type `metadata` describes, in place.
void cdabi_destroy(void *value, const void *metadata);

/// Retain a Swift bridge object (a native Set / Array buffer).
void cdabi_retain_bridge_object(void *object);

/// One finger, as a fraction of the panel (0…1) in its native orientation.
typedef struct { double x, y; } cdabi_finger;

/// Whether a digitizer report can be built: the UniversalHID symbols resolve
/// and its report types still have the two-word layout this file assumes.
bool cdabi_digitizer_ready(void);

/// Send one digitizer report — `count` fingers (1 or 2) touching, or lifting
/// — to touchscreen service `service_id` through an opened Universal HID
/// capability (`capability`: the existential CoreDevice wrote). `edge`:
/// 0 none, 1 left, 2 top, 3 bottom, 4 right, marking a swipe in from it.
bool cdabi_send_digitizer_report(const void *capability, uint32_t service_id,
                                 const cdabi_finger *fingers, uint8_t count,
                                 bool touching, uint8_t edge);
