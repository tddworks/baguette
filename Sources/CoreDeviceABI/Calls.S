// Swift-ABI calls into CoreDevice that Swift declares with @_silgen_name.
// Each entry jumps to the address cdabi_load() resolved, leaving every
// register as the caller set it — self, indirect results, async context —
// so the Swift caller and CoreDevice agree without a C hop in between.
#if defined(__aarch64__)
.macro JUMP_TO entry, address
.text
.p2align 2
.globl _\entry
_\entry:
    adrp x16, _\address@PAGE
    ldr x16, [x16, _\address@PAGEOFF]
    br x16
.endmacro
#elif defined(__x86_64__)
.macro JUMP_TO entry, address
.text
.globl _\entry
_\entry:
    jmp *_\address(%rip)
.endmacro
#endif

JUMP_TO cdabi_manager_shared,         cdabi_manager_shared_address
JUMP_TO cdabi_service_connection,     cdabi_service_connection_address
JUMP_TO cdabi_manager_init,           cdabi_manager_init_address
JUMP_TO cdabi_manager_devices,        cdabi_manager_devices_address
JUMP_TO cdabi_manager_ready,          cdabi_manager_ready_address
JUMP_TO cdabi_visibility_classes,     cdabi_visibility_classes_address
JUMP_TO cdabi_device_identifier,      cdabi_device_identifier_address
JUMP_TO cdabi_device_capability,      cdabi_device_capability_address

// An async function is called through its descriptor (Swift names it
// `<function>Tu`): a relative pointer to
// the entry, and the size of the async context the caller must allocate.
// cdabi_load() copies CoreDevice's own context size into the second word.
.data
.p2align 2
.globl _cdabi_device_capabilityTu
_cdabi_device_capabilityTu:
.long _cdabi_device_capability - _cdabi_device_capabilityTu
.long 0
