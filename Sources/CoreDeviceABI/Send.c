#include "CoreDeviceABI.h"
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdlib.h>

typedef struct { const void *metadata; uintptr_t state; } metadata_response;
typedef metadata_response (*metadata_accessor_fn)(uintptr_t) __attribute__((swiftcall));
typedef void (*destroy_fn)(void *, const void *) __attribute__((swiftcall));
typedef void (*send_fn)(uint64_t report_lo, uint64_t report_hi, const void *service_id,
                        void *error_slot, const void *self_type, const void *self_conformance,
                        const void *__attribute__((swift_context)) self,
                        void **__attribute__((swift_error_result)) failed) __attribute__((swiftcall));

static void *const *value_witnesses(const void *metadata) {
    return ptrauth_strip(((void *const *)metadata)[-1], ptrauth_key_process_independent_data);
}

bool cdabi_send_report(uint64_t report_lo, uint64_t report_hi, uint32_t service_id,
                       const void *capability) {
    static send_fn send;
    static metadata_accessor_fn error_type_of;
    if (!send) send = (send_fn)dlsym(RTLD_DEFAULT,
        "$s10CoreDevice19UniversalHIDServiceP4send6report2toy0C3HID9HIDReportV_AA0D2IDVtAA0aB5ErrorVYKFTj");
    if (!error_type_of) error_type_of = (metadata_accessor_fn)dlsym(RTLD_DEFAULT, "$s10CoreDevice0aB5ErrorVMa");
    if (!send || !error_type_of || !capability) return false;

    // The capability is an existential: its type and conformance follow
    // the three-word inline buffer.
    const void *self_type = ((const void *const *)capability)[3];
    const void *self_conformance = ((const void *const *)capability)[4];
    if (!self_type || !self_conformance) return false;

    const void *error_type = error_type_of(0).metadata;
    void *error_slot = calloc(1, (size_t)value_witnesses(error_type)[8]);
    if (!error_slot) return false;
    uint64_t service = service_id;   // HIDServiceID is resilient: by address
    void *failed = NULL;
    send(report_lo, report_hi, &service, error_slot, self_type, self_conformance, capability, &failed);
    if (failed) {
        void *entry = ptrauth_strip(value_witnesses(error_type)[1], ptrauth_key_function_pointer);
        destroy_fn destroy = ptrauth_sign_unauthenticated(entry, ptrauth_key_function_pointer, 0);
        destroy(error_slot, error_type);
    }
    free(error_slot);
    return failed == NULL;
}
