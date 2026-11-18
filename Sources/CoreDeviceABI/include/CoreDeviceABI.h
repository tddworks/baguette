// The one CoreDevice call Swift can't spell. UniversalHIDService.send(report:to:)
// throws(CoreDeviceError): its typed error comes back through a slot passed
// before the service's type metadata, an argument order no Swift declaration
// lowers to. Everything else about CoreDevice is Swift (CoreDeviceFramework).
#pragma once
#include <stdbool.h>
#include <stdint.h>

/// Send a UniversalHID report — the two words of its Data — to service
/// `service_id`, through an opened Universal HID capability (`capability`:
/// the existential CoreDevice wrote). True when CoreDevice took it.
bool cdabi_send_report(uint64_t report_lo, uint64_t report_hi, uint32_t service_id,
                       const void *capability);
