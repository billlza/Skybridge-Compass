#ifndef SKYBRIDGE_USB_HOST_INTERNAL_H
#define SKYBRIDGE_USB_HOST_INTERNAL_H
#include "include/SkyBridgeUSBHost.h"

// Private native-driver seam, also consumed by isolated fault-injection tests. No alternate
// driver factory is exposed through the product's public Clang module.
typedef struct {
    SBUSBResult (*open)(void *, uint64_t, SBUSBDeviceInfo *);
    SBUSBResult (*read)(void *, void *, uint32_t, uint32_t);
    SBUSBResult (*write)(void *, const void *, uint32_t, uint32_t);
    SBUSBResult (*interrupt)(void *);
    // Report reference release separately from an explicit native close error. An unknown
    // release outcome must leave the driver owned; it must never be destroyed as a success.
    SBUSBResult (*close)(void *, bool *ownedReferencesReleased);
    void (*destroy)(void *);
} SBUSBDriverOperations;

__attribute__((visibility("hidden")))
// Driver ownership transfers only if this factory returns a non-null handle.
SBUSBHandle *SBUSBCreateWithDriver(void *driver, const SBUSBDriverOperations *operations, SBUSBResult *result);
__attribute__((visibility("hidden")))
SBUSBHandle *SBUSBCreateNative(SBUSBResult *result);

static inline SBUSBResult SBUSBResultMake(SBUSBStatus status, SBUSBPhase phase) {
    SBUSBResult result = {0}; result.status = status; result.phase = phase; return result;
}
#endif
