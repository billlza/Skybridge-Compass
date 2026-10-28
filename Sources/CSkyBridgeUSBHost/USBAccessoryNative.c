#include "USBAccessoryInternal.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>

typedef struct {
    io_service_t service;
    IOUSBDeviceInterface182 **client;
    SBUSBResult releaseFailure;
} NativeAccessory;

static SBUSBResult resultIO(SBUSBPhase phase, IOReturn code) {
    SBUSBResult r = SBUSBResultMake(code == kIOReturnSuccess ? SB_USB_OK : SB_USB_NATIVE_FAILURE, phase);
    r.domain = SB_USB_DOMAIN_IORETURN; r.nativeCode = code; return r;
}
static bool numberProperty(io_service_t service, CFStringRef key, uint16_t *value) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int64_t number = -1;
    bool valid = raw && CFGetTypeID(raw) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)raw, kCFNumberSInt64Type, &number) && number >= 0 && number <= UINT16_MAX;
    if (raw) CFRelease(raw);
    if (valid) *value = (uint16_t)number;
    return valid;
}
static SBUSBResult acquireNative(void *opaque, uint64_t registryID) {
    NativeAccessory *d = opaque;
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(registryID);
    if (!matching) return SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_SELECT_DEVICE);
    d->service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!d->service) return SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_SELECT_DEVICE);
    uint64_t actual = 0; uint16_t vendor = 0, product = 0;
    IOReturn code = IORegistryEntryGetRegistryEntryID(d->service, &actual);
    if (code != kIOReturnSuccess) return resultIO(SB_USB_PHASE_SELECT_DEVICE, code);
    if (actual != registryID || !IOObjectConformsTo(d->service, "IOUSBHostDevice") ||
        !numberProperty(d->service, CFSTR("idVendor"), &vendor) || !numberProperty(d->service, CFSTR("idProduct"), &product))
        return SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_SELECT_DEVICE);
    // Never rewrite the identity/mode of an already-active accessory attachment.
    if (vendor == 0x18d1 && (product == 0x2d00 || product == 0x2d01))
        return SBUSBResultMake(SB_USB_ALREADY_STARTED, SB_USB_PHASE_SELECT_DEVICE);
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    code = IOCreatePlugInInterfaceForService(d->service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (code != kIOReturnSuccess || !plugin) {
        if (plugin) (*plugin)->Release(plugin);
        return resultIO(SB_USB_PHASE_PLUGIN, code == kIOReturnSuccess ? kIOReturnInternalError : code);
    }
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&d->client);
    (*plugin)->Release(plugin);
    if (query != 0) {
        SBUSBResult r = SBUSBResultMake(SB_USB_NATIVE_FAILURE, SB_USB_PHASE_QUERY_INTERFACE);
        r.domain = SB_USB_DOMAIN_HRESULT; r.nativeCode = (int32_t)query; return r;
    }
    if (!d->client) return resultIO(SB_USB_PHASE_QUERY_INTERFACE, kIOReturnInternalError);
    return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_QUERY_INTERFACE);
}
static SBUSBResult requestNative(void *opaque, uint8_t type, uint8_t request, uint16_t index,
                                 void *bytes, uint16_t length, uint32_t timeout) {
    NativeAccessory *d = opaque;
    IOUSBDevRequestTO value = {0};
    value.bmRequestType = type; value.bRequest = request; value.wIndex = index;
    value.pData = bytes; value.wLength = length;
    value.noDataTimeout = timeout; value.completionTimeout = timeout;
    // DeviceRequestTO does not require USBDeviceOpen. This path never claims an
    // interface or selects the debug interface, even when ADB happens to be enabled.
    IOReturn code = (*d->client)->DeviceRequestTO(d->client, &value);
    SBUSBResult r = resultIO(SB_USB_PHASE_ACCESSORY_QUERY, code);
    if (code == kIOReturnSuccess) { r.byteCountKnown = true; r.bytesTransferred = value.wLenDone; }
    return r;
}
static SBUSBResult clockNative(void *opaque, uint64_t *value) {
    (void)opaque;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        SBUSBResult r = SBUSBResultMake(SB_USB_NATIVE_FAILURE, SB_USB_PHASE_NONE);
        r.domain = SB_USB_DOMAIN_POSIX; r.nativeCode = errno; return r;
    }
    *value = (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
    return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_NONE);
}
static SBUSBResult closeNative(void *opaque, bool *released) {
    NativeAccessory *d = opaque;
    if (d->client) { (*d->client)->Release(d->client); d->client = NULL; }
    if (d->service && d->releaseFailure.status == SB_USB_OK) {
        IOReturn code = IOObjectRelease(d->service);
        if (code == kIOReturnSuccess) d->service = IO_OBJECT_NULL;
        else d->releaseFailure = resultIO(SB_USB_PHASE_RELEASE, code);
    }
    // Do not retry an IOObjectRelease whose ownership outcome is unconfirmed.
    *released = !d->client && !d->service;
    return d->releaseFailure.status != SB_USB_OK ? d->releaseFailure : SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_RELEASE);
}
static void destroyNative(void *opaque) { free(opaque); }
SBAOAHandle *SBAOACreate(SBUSBResult *result) {
    if (!result) return NULL;
    NativeAccessory *driver = calloc(1, sizeof(*driver));
    if (!driver) { *result = SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_ALLOCATE); return NULL; }
    const SBAOADriverOperations ops = {acquireNative, requestNative, clockNative, closeNative, destroyNative};
    SBAOAHandle *h = SBAOACreateWithDriver(driver, &ops, result);
    if (!h) free(driver);
    return h;
}
