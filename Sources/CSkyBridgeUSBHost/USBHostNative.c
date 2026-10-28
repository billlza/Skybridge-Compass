#include "USBHostInternal.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

typedef struct {
    IOUSBInterfaceInterface190 **client;
    bool opened;
    UInt8 inputPipe, outputPipe;
    SBUSBResult releaseFailure;
    // A failed IOObjectRelease has no demonstrated cleanup receipt. Retain the numeric
    // references for diagnosis, without guessing that another release is safe. Selection
    // stops at the first such failure, leaving at most child/iterator/interface/device.
    io_object_t unreleasedObjects[4];
    unsigned unreleasedCount;
} NativeDriver;

static SBUSBResult ioResult(SBUSBPhase phase, IOReturn code) {
    SBUSBResult result = SBUSBResultMake(code == kIOReturnSuccess ? SB_USB_OK : SB_USB_NATIVE_FAILURE, phase);
    result.domain = SB_USB_DOMAIN_IORETURN; result.nativeCode = code; return result;
}

static void releaseObject(NativeDriver *driver, io_object_t *object) {
    if (!*object) return;
    IOReturn code = IOObjectRelease(*object);
    if (code != kIOReturnSuccess) {
        if (driver->unreleasedCount < 4) driver->unreleasedObjects[driver->unreleasedCount] = *object;
        driver->unreleasedCount++;
        if (driver->releaseFailure.status == SB_USB_OK)
            driver->releaseFailure = ioResult(SB_USB_PHASE_RELEASE, code);
    }
    *object = IO_OBJECT_NULL;
}

static bool propertyNumber(io_service_t service, CFStringRef key, uint16_t *value) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int64_t number = -1;
    bool valid = raw && CFGetTypeID(raw) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)raw, kCFNumberSInt64Type, &number) && number >= 0 && number <= UINT16_MAX;
    if (raw) CFRelease(raw);
    if (valid) *value = (uint16_t)number;
    return valid;
}

static SBUSBResult selectInterface(NativeDriver *driver, io_service_t device, io_service_t *selected) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn code = IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator);
    if (code != kIOReturnSuccess) {
        releaseObject(driver, &iterator);
        return ioResult(SB_USB_PHASE_SELECT_INTERFACE, code);
    }
    unsigned examined = 0, matches = 0;
    io_service_t child;
    while ((child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint16_t number = UINT16_MAX;
        if (IOObjectConformsTo(child, "IOUSBHostInterface") && propertyNumber(child, CFSTR("bInterfaceNumber"), &number) && number == 0) {
            matches++;
            if (!*selected) { *selected = child; child = IO_OBJECT_NULL; }
        }
        releaseObject(driver, &child);
        if (driver->releaseFailure.status != SB_USB_OK) break;
        if (++examined > 256) break;
    }
    bool validIterator = IOIteratorIsValid(iterator);
    releaseObject(driver, &iterator);
    if (driver->releaseFailure.status != SB_USB_OK) return driver->releaseFailure;
    if (!validIterator) return ioResult(SB_USB_PHASE_SELECT_INTERFACE, kIOReturnNoDevice);
    if (examined > 256 || matches != 1) return SBUSBResultMake(SB_USB_NOT_ACCESSORY, SB_USB_PHASE_SELECT_INTERFACE);
    return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_SELECT_INTERFACE);
}

static SBUSBResult nativeOpen(void *opaque, uint64_t registryID, SBUSBDeviceInfo *info) {
    NativeDriver *driver = opaque;
    io_service_t device = IO_OBJECT_NULL, interface = IO_OBJECT_NULL;
    IOCFPlugInInterface **plugin = NULL;
    SBUSBResult result = SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_SELECT_DEVICE);
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(registryID);
    if (!matching) return result;
    device = IOServiceGetMatchingService(kIOMainPortDefault, matching); // consumes matching
    if (!device) return result;
    uint64_t actualID = 0;
    IOReturn code = IORegistryEntryGetRegistryEntryID(device, &actualID);
    if (code != kIOReturnSuccess) { result = ioResult(SB_USB_PHASE_SELECT_DEVICE, code); goto done; }
    if (actualID != registryID || !IOObjectConformsTo(device, "IOUSBHostDevice") ||
        !propertyNumber(device, CFSTR("idVendor"), &info->vendorID) ||
        !propertyNumber(device, CFSTR("idProduct"), &info->productID) || info->vendorID != 0x18d1 ||
        (info->productID != 0x2d00 && info->productID != 0x2d01)) {
        result = SBUSBResultMake(SB_USB_NOT_ACCESSORY, SB_USB_PHASE_SELECT_DEVICE); goto done;
    }
    info->deviceRegistryID = actualID;
    result = selectInterface(driver, device, &interface);
    if (result.status != SB_USB_OK) goto done;
    code = IORegistryEntryGetRegistryEntryID(interface, &info->interfaceRegistryID);
    if (code != kIOReturnSuccess) { result = ioResult(SB_USB_PHASE_SELECT_INTERFACE, code); goto done; }
    SInt32 score = 0;
    code = IOCreatePlugInInterfaceForService(interface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (code != kIOReturnSuccess || !plugin) {
        result = ioResult(SB_USB_PHASE_PLUGIN, code == kIOReturnSuccess ? kIOReturnInternalError : code); goto done;
    }
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&driver->client);
    // Release only our COM reference. IODestroyPlugInInterface can stop a service.
    (*plugin)->Release(plugin); plugin = NULL;
    if (query != 0 || !driver->client) {
        result = SBUSBResultMake(SB_USB_NATIVE_FAILURE, SB_USB_PHASE_QUERY_INTERFACE);
        result.domain = query ? SB_USB_DOMAIN_HRESULT : SB_USB_DOMAIN_IORETURN;
        result.nativeCode = query ? (int32_t)query : kIOReturnInternalError; goto done;
    }
    UInt8 interfaceClass = 0, number = 0, endpoints = 0;
    code = (*driver->client)->GetInterfaceClass(driver->client, &interfaceClass);
    if (code == kIOReturnSuccess) code = (*driver->client)->GetInterfaceNumber(driver->client, &number);
    if (code == kIOReturnSuccess) code = (*driver->client)->GetNumEndpoints(driver->client, &endpoints);
    if (code != kIOReturnSuccess) { result = ioResult(SB_USB_PHASE_DESCRIPTOR, code); goto done; }
    if (interfaceClass != 0xff || number != 0 || endpoints != 2) {
        result = SBUSBResultMake(SB_USB_NOT_ACCESSORY, SB_USB_PHASE_DESCRIPTOR); goto done;
    }
    code = (*driver->client)->USBInterfaceOpen(driver->client);
    result = ioResult(SB_USB_PHASE_OPEN, code);
    if (code != kIOReturnSuccess) goto done;
    driver->opened = true;
    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
        UInt8 direction = 0, endpoint = 0, type = 0, interval = 0;
        UInt16 packetSize = 0;
        code = (*driver->client)->GetPipeProperties(driver->client, pipe, &direction, &endpoint, &type, &packetSize, &interval);
        if (code != kIOReturnSuccess) { result = ioResult(SB_USB_PHASE_PIPES, code); goto done; }
        if (type != kUSBBulk || !endpoint || endpoint > 15 || !packetSize ||
            (direction != kUSBIn && direction != kUSBOut) ||
            (direction == kUSBIn ? driver->inputPipe != 0 : driver->outputPipe != 0)) {
            result = SBUSBResultMake(SB_USB_NOT_ACCESSORY, SB_USB_PHASE_PIPES); goto done;
        }
        if (direction == kUSBIn) {
            driver->inputPipe = pipe; info->inputEndpoint = (uint8_t)(endpoint | 0x80); info->inputPacketSize = packetSize;
        } else { driver->outputPipe = pipe; info->outputEndpoint = endpoint; info->outputPacketSize = packetSize; }
    }
    result = SBUSBResultMake(driver->inputPipe && driver->outputPipe ? SB_USB_OK : SB_USB_NOT_ACCESSORY, SB_USB_PHASE_PIPES);
done:
    if (plugin) (*plugin)->Release(plugin);
    releaseObject(driver, &interface); releaseObject(driver, &device);
    if (result.status == SB_USB_OK && driver->releaseFailure.status != SB_USB_OK) result = driver->releaseFailure;
    // Any partially acquired client stays owned until the generic lifecycle permits close.
    return result;
}

static SBUSBResult nativeRead(void *opaque, void *buffer, uint32_t capacity, uint32_t timeout) {
    NativeDriver *driver = opaque; UInt32 size = capacity;
    IOReturn code = (*driver->client)->ReadPipeTO(driver->client, driver->inputPipe, buffer, &size, timeout, timeout);
    SBUSBResult result = ioResult(SB_USB_PHASE_READ, code);
    if (code == kIOReturnSuccess) {
        if (size > capacity) return ioResult(SB_USB_PHASE_READ, kIOReturnOverrun);
        result.bytesTransferred = size; result.byteCountKnown = true;
    }
    return result;
}
static SBUSBResult nativeWrite(void *opaque, const void *bytes, uint32_t count, uint32_t timeout) {
    NativeDriver *driver = opaque;
    // The legacy write signature accepts void*, but this operation only reads the caller's
    // buffer synchronously. It does not retain the pointer or change source audio bytes.
    IOReturn code = (*driver->client)->WritePipeTO(driver->client, driver->outputPipe, (void *)bytes, count, timeout, timeout);
    SBUSBResult result = ioResult(SB_USB_PHASE_WRITE, code);
    // WritePipeTO has no partial-count output: only successful completion supplies a count.
    if (code == kIOReturnSuccess) { result.bytesTransferred = count; result.byteCountKnown = true; }
    return result;
}
static SBUSBResult nativeInterrupt(void *opaque) {
    NativeDriver *driver = opaque;
    IOReturn input = (*driver->client)->AbortPipe(driver->client, driver->inputPipe);
    IOReturn output = (*driver->client)->AbortPipe(driver->client, driver->outputPipe);
    return ioResult(SB_USB_PHASE_ABORT, input != kIOReturnSuccess ? input : output);
}
static SBUSBResult nativeClose(void *opaque, bool *released) {
    NativeDriver *driver = opaque;
    SBUSBResult result = SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_CLOSE);
    if (driver->client) {
        if (driver->opened) result = ioResult(SB_USB_PHASE_CLOSE, (*driver->client)->USBInterfaceClose(driver->client));
        driver->opened = false;
        // The explicit close error is retained. Release still drops the reference we own;
        // its returned COM reference count is not an IOReturn and cannot be retried as one.
        (*driver->client)->Release(driver->client); driver->client = NULL;
    }
    if (result.status == SB_USB_OK && driver->releaseFailure.status != SB_USB_OK) result = driver->releaseFailure;
    *released = driver->unreleasedCount == 0;
    return result;
}
static void nativeDestroy(void *opaque) { free(opaque); }

SBUSBHandle *SBUSBCreateNative(SBUSBResult *result) {
    if (!result) return NULL;
    NativeDriver *driver = calloc(1, sizeof(*driver));
    if (!driver) { *result = SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_ALLOCATE); return NULL; }
    const SBUSBDriverOperations operations = { nativeOpen, nativeRead, nativeWrite, nativeInterrupt, nativeClose, nativeDestroy };
    SBUSBHandle *handle = SBUSBCreateWithDriver(driver, &operations, result);
    if (!handle) free(driver);
    return handle;
}
