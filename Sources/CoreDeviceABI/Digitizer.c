#include "CoreDeviceABI.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>

// A UniversalHID DigitizerReport / DigitizerContact is a struct wrapping one
// Foundation.Data: two machine words, passed and returned in registers.
// UniversalHID's own initializers and setters encode the HID descriptor, so
// this file never lays out report bytes itself.
typedef struct { uint64_t lo, hi; } two_words;

typedef void (*report_init_fn)(void *__attribute__((swift_indirect_result)) out,
                               const void *report_type, const void *descriptor_conformance,
                               const void *report_conformance) __attribute__((swiftcall));
typedef two_words (*contact_init_fn)(void) __attribute__((swiftcall));
typedef void (*set_int_fn)(intptr_t, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_byte_fn)(uint8_t, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_double_fn)(double, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_bool_fn)(bool, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_timestamp_fn)(uint64_t, bool, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*put_contact_fn)(uint64_t, uint64_t, intptr_t, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_identity_fn)(uint8_t, intptr_t, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*set_flag_at_fn)(bool, intptr_t, void *__attribute__((swift_context))) __attribute__((swiftcall));
typedef struct { const void *metadata; uintptr_t state; } metadata_response;
typedef metadata_response (*metadata_accessor_fn)(uintptr_t) __attribute__((swiftcall));
// UniversalHIDService.send(report:to:) throws(CoreDeviceError): the typed
// error is written through an indirect slot, its presence flagged in x21.
typedef void (*send_fn)(uint64_t report_lo, uint64_t report_hi, const void *service_id,
                        void *error_slot, const void *self_type, const void *self_conformance,
                        const void *__attribute__((swift_context)) self,
                        void **__attribute__((swift_error_result)) error) __attribute__((swiftcall));

static struct {
    const void *report_type, *contact_type, *error_type;
    const void *report_descriptor_conformance, *report_event_conformance;
    report_init_fn new_report;
    contact_init_fn new_contact;
    set_int_fn contact_index;
    set_double_fn contact_x, contact_y;
    set_bool_fn contact_touching, contact_in_range;
    set_byte_fn report_contact_count;
    put_contact_fn report_put_contact;
    set_identity_fn report_contact_identity;
    set_timestamp_fn report_timestamp;
    set_flag_at_fn swipe_in[5];     // by edge: 1 left, 2 top, 3 bottom, 4 right
    set_flag_at_fn swipe_locked;    // optional: absent on older runtimes
    send_fn send;
} hid;

#define FIND(field, mangled) (hid.field = (__typeof__(hid.field))dlsym(RTLD_DEFAULT, mangled)) != NULL

bool cdabi_digitizer_ready(void) {
    static dispatch_once_t once;
    static bool ready;
    dispatch_once(&once, ^{
        if (!cdabi_load()) return;
        bool found = FIND(report_type, "$s12UniversalHID15DigitizerReportVN")
            & FIND(contact_type, "$s12UniversalHID16DigitizerContactVN")
            & FIND(report_descriptor_conformance, "$s12UniversalHID15DigitizerReportVAA05EventD18DescriptorProtocolAAWP")
            & FIND(report_event_conformance, "$s12UniversalHID15DigitizerReportVAA05EventD8ProtocolAAWP")
            & FIND(new_report, "$s12UniversalHID19EventReportProtocolPA2A0cd10DescriptorE0RzrlExycfC")
            & FIND(new_contact, "$s12UniversalHID16DigitizerContactVACycfC")
            & FIND(contact_index, "$s12UniversalHID16DigitizerContactV5indexSivs")
            & FIND(contact_x, "$s12UniversalHID16DigitizerContactV1xSdvs")
            & FIND(contact_y, "$s12UniversalHID16DigitizerContactV1ySdvs")
            & FIND(contact_touching, "$s12UniversalHID16DigitizerContactV5touchSbvs")
            & FIND(contact_in_range, "$s12UniversalHID16DigitizerContactV5rangeSbvs")
            & FIND(report_contact_count, "$s12UniversalHID15DigitizerReportV12contactCounts5UInt8Vvs")
            & FIND(report_put_contact, "$s12UniversalHID15DigitizerReportV10setContact_7atIndexyAA0cF0V_SitF")
            & FIND(report_contact_identity, "$s12UniversalHID15DigitizerReportV18setContactIdentity_7atIndexys5UInt8V_SitF")
            & FIND(report_timestamp, "$s12UniversalHID15DigitizerReportV15remoteTimestamps6UInt64VSgvs")
            & FIND(swipe_in[1], "$s12UniversalHID15DigitizerReportV20setContactSwipeRight_7atIndexySb_SitF")
            & FIND(swipe_in[2], "$s12UniversalHID15DigitizerReportV19setContactSwipeDown_7atIndexySb_SitF")
            & FIND(swipe_in[3], "$s12UniversalHID15DigitizerReportV17setContactSwipeUp_7atIndexySb_SitF")
            & FIND(swipe_in[4], "$s12UniversalHID15DigitizerReportV19setContactSwipeLeft_7atIndexySb_SitF")
            & FIND(send, "$s10CoreDevice19UniversalHIDServiceP4send6report2toy0C3HID9HIDReportV_AA0D2IDVtAA0aB5ErrorVYKFTj");
        hid.swipe_locked = (set_flag_at_fn)dlsym(RTLD_DEFAULT,
            "$s12UniversalHID15DigitizerReportV21setContactSwipeLocked_7atIndexySb_SitF");
        metadata_accessor_fn error_type = (metadata_accessor_fn)cdabi_symbol("$s10CoreDevice0aB5ErrorVMa");
        if (!found || !error_type) return;
        hid.error_type = error_type(0).metadata;
        // Every call above passes a report or contact as two words: refuse to
        // run against a UniversalHID whose layout has moved.
        ready = cdabi_size_of(hid.report_type) == sizeof(two_words)
            && cdabi_size_of(hid.contact_type) == sizeof(two_words);
    });
    return ready;
}

bool cdabi_send_digitizer_report(const void *capability, uint32_t service_id,
                                 const cdabi_finger *fingers, uint8_t count,
                                 bool touching, uint8_t edge) {
    if (!capability || !fingers || count < 1 || count > 2 || edge > 4) return false;
    if (!cdabi_digitizer_ready()) return false;
    for (uint8_t i = 0; i < count; i++) {
        if (!isfinite(fingers[i].x) || !isfinite(fingers[i].y)) return false;
    }
    // The capability is an existential: its type and conformance sit in the
    // fourth and fifth words, after the three-word inline value buffer.
    const void *self_type = ((const void *const *)capability)[3];
    const void *self_conformance = ((const void *const *)capability)[4];
    if (!self_type || !self_conformance) return false;

    two_words report;
    hid.new_report(&report, hid.report_type, hid.report_descriptor_conformance, hid.report_event_conformance);
    hid.report_contact_count(count, &report);
    for (uint8_t i = 0; i < count; i++) {
        two_words contact = hid.new_contact();
        hid.contact_index(i + 1, &contact);
        hid.contact_x(fmin(1, fmax(0, fingers[i].x)), &contact);
        hid.contact_y(fmin(1, fmax(0, fingers[i].y)), &contact);
        hid.contact_touching(touching, &contact);
        hid.contact_in_range(touching, &contact);
        hid.report_put_contact(contact.lo, contact.hi, i, &report);
        cdabi_destroy(&contact, hid.contact_type);
        hid.report_contact_identity(i + 1, i, &report);
        if (edge) {
            // An edge swipe is the inward direction plus "locked", on every
            // report including the lift, so SpringBoard can finish it.
            if (hid.swipe_locked) hid.swipe_locked(true, i, &report);
            hid.swipe_in[edge](true, i, &report);
        }
    }
    hid.report_timestamp(mach_absolute_time(), false, &report);

    void *error_slot = calloc(1, cdabi_size_of(hid.error_type));
    if (!error_slot) { cdabi_destroy(&report, hid.report_type); return false; }
    uint64_t service = service_id;   // HIDServiceID is resilient: passed by address
    void *failed = NULL;
    hid.send(report.lo, report.hi, &service, error_slot, self_type, self_conformance, capability, &failed);
    cdabi_destroy(&report, hid.report_type);
    if (failed) cdabi_destroy(error_slot, hid.error_type);
    free(error_slot);
    return failed == NULL;
}
