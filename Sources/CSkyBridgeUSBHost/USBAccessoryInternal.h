#ifndef SKYBRIDGE_USB_ACCESSORY_INTERNAL_H
#define SKYBRIDGE_USB_ACCESSORY_INTERNAL_H
#include "USBHostInternal.h"

// Private fault-injection seam. There is no device/interface open, seizure, USB
// reset or ADB callback. Request sequencing and bounds remain in the real owner.
typedef struct {
    SBUSBResult (*acquire)(void *, uint64_t);
    SBUSBResult (*request)(void *, uint8_t, uint8_t, uint16_t, void *, uint16_t, uint32_t);
    SBUSBResult (*clockMilliseconds)(void *, uint64_t *);
    SBUSBResult (*close)(void *, bool *);
    void (*destroy)(void *);
} SBAOADriverOperations;
__attribute__((visibility("hidden")))
SBAOAHandle *SBAOACreateWithDriver(void *, const SBAOADriverOperations *, SBUSBResult *);
#endif
