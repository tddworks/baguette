#include "CoreDeviceABI.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <ptrauth.h>

// Addresses Calls.S jumps to.
void *cdabi_manager_shared_address, *cdabi_service_connection_address;
void *cdabi_manager_init_address, *cdabi_manager_devices_address;
void *cdabi_manager_ready_address, *cdabi_visibility_classes_address;
void *cdabi_device_identifier_address, *cdabi_device_capability_address;
extern int32_t cdabi_device_capabilityTu[2];

static void *framework;

static const char *const kFrameworkPath =
    "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice";

static bool bind(void **address, const char *mangled_name) {
    *address = dlsym(framework, mangled_name);
    return *address != NULL;
}

bool cdabi_load(void) {
    static dispatch_once_t once;
    static bool loaded;
    dispatch_once(&once, ^{
        framework = dlopen(kFrameworkPath, RTLD_NOW | RTLD_GLOBAL);
        if (!framework) return;
        // DeviceManager.shared, CoreDeviceService.sharedConnection,
        // DeviceManager(serviceConnection:allowedDeviceVisibilityClasses:),
        // DeviceManager.allDevices(), DeviceManager.fullyInitialized,
        // DeviceVisibilityClass.allCases, RemoteDevice.deviceIdentifier,
        // RemoteDevice.getImplementation(for:) async throws.
        bool bound = bind(&cdabi_manager_shared_address, "$s10CoreDevice0B7ManagerC6sharedACvgZ")
            & bind(&cdabi_service_connection_address, "$s10CoreDevice0aB7ServiceV16sharedConnectionAA0abcE0_pvgZ")
            & bind(&cdabi_manager_init_address, "$s10CoreDevice0B7ManagerC17serviceConnection07allowedB17VisibilityClassesAcA0ab7ServiceE0_p_ShyAA0bG5ClassOGtcfC")
            & bind(&cdabi_manager_devices_address, "$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF")
            & bind(&cdabi_manager_ready_address, "$s10CoreDevice0B7ManagerC16fullyInitializedSbvgTj")
            & bind(&cdabi_visibility_classes_address, "$s10CoreDevice0B15VisibilityClassO8allCasesSayACGvgZ")
            & bind(&cdabi_device_identifier_address, "$s10CoreDevice06RemoteB0C16deviceIdentifier10Foundation4UUIDVvgTj")
            & bind(&cdabi_device_capability_address, "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTj");
        const int32_t *async_descriptor = dlsym(framework,
            "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTjTu");
        if (!bound || !async_descriptor) return;
        // The caller allocates the callee's async context from this size; a
        // guessed size corrupts the task's allocator.
        cdabi_device_capabilityTu[1] = async_descriptor[1];
        loaded = true;
    });
    return loaded;
}

void *cdabi_symbol(const char *mangled_name) {
    return cdabi_load() ? dlsym(framework, mangled_name) : NULL;
}

// A type's value witness table sits one word before its metadata.
static void *const *value_witnesses(const void *metadata) {
    return ptrauth_strip(((void *const *)metadata)[-1], ptrauth_key_process_independent_data);
}

size_t cdabi_size_of(const void *metadata) {
    return (size_t)value_witnesses(metadata)[8];
}

typedef void (*destroy_fn)(void *, const void *) __attribute__((swiftcall));

void cdabi_destroy(void *value, const void *metadata) {
    void *entry = ptrauth_strip(value_witnesses(metadata)[1], ptrauth_key_function_pointer);
    destroy_fn destroy = ptrauth_sign_unauthenticated(entry, ptrauth_key_function_pointer, 0);
    destroy(value, metadata);
}

void cdabi_retain_bridge_object(void *object) {
    typedef void *(*retain_fn)(void *);
    static retain_fn retain;
    if (!retain) retain = (retain_fn)dlsym(RTLD_DEFAULT, "swift_bridgeObjectRetain");
    retain(object);
}
