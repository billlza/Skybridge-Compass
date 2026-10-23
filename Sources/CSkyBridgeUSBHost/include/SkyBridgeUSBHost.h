#ifndef SKYBRIDGE_USB_HOST_H
#define SKYBRIDGE_USB_HOST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SB_USB_TRANSFER_BYTES 16384u
#define SB_USB_MAX_TIMEOUT_MS 60000u

typedef struct SBUSBHandle SBUSBHandle;
typedef enum {
    SB_USB_OK = 0, SB_USB_INVALID_ARGUMENT, SB_USB_UNAVAILABLE, SB_USB_NOT_ACCESSORY,
    SB_USB_NATIVE_FAILURE, SB_USB_CANCELLED, SB_USB_BUSY, SB_USB_NOT_READY,
    SB_USB_ALREADY_STARTED, SB_USB_CLEANUP_UNCONFIRMED,
    SB_USB_TIMED_OUT, SB_USB_BAD_RESPONSE, SB_USB_UNSUPPORTED_PROTOCOL
} SBUSBStatus;
typedef enum {
    SB_USB_PHASE_NONE = 0, SB_USB_PHASE_ALLOCATE, SB_USB_PHASE_SELECT_DEVICE,
    SB_USB_PHASE_SELECT_INTERFACE, SB_USB_PHASE_PLUGIN, SB_USB_PHASE_QUERY_INTERFACE,
    SB_USB_PHASE_DESCRIPTOR, SB_USB_PHASE_OPEN, SB_USB_PHASE_PIPES,
    SB_USB_PHASE_READ, SB_USB_PHASE_WRITE, SB_USB_PHASE_ABORT,
    SB_USB_PHASE_CLOSE, SB_USB_PHASE_RELEASE,
    SB_USB_PHASE_ACCESSORY_QUERY, SB_USB_PHASE_ACCESSORY_IDENTIFICATION,
    SB_USB_PHASE_ACCESSORY_START
} SBUSBPhase;
typedef enum { SB_USB_DOMAIN_NONE = 0, SB_USB_DOMAIN_IORETURN, SB_USB_DOMAIN_HRESULT, SB_USB_DOMAIN_POSIX } SBUSBDomain;
typedef struct {
    SBUSBStatus status;
    SBUSBPhase phase;
    SBUSBDomain domain;
    int32_t nativeCode;
    uint32_t bytesTransferred;
    bool byteCountKnown;
} SBUSBResult;
typedef struct {
    uint64_t deviceRegistryID, interfaceRegistryID;
    uint16_t vendorID, productID, inputPacketSize, outputPacketSize;
    uint8_t inputEndpoint, outputEndpoint;
} SBUSBDeviceInfo;
typedef struct {
    bool started, opening, ready, retired, reading, writing, interrupting, closing;
    bool ownedReferencesReleased;
    SBUSBResult firstFailure, closeResult;
    SBUSBDeviceInfo device;
} SBUSBSnapshot;

/// Own the handle before opening. The registry entry selects one current physical generation;
/// USB descriptors/permission do not establish product identity or account authority.
SBUSBHandle *SBUSBCreate(SBUSBResult *result);
SBUSBResult SBUSBOpen(SBUSBHandle *handle, uint64_t deviceRegistryID);
/// One reader and one writer, maximum 16 KiB per transfer. Read capacity MUST be 16 KiB;
/// the caller retains unread packet bytes. A successful zero read is a USB packet boundary,
/// not EOF. All reads/writes have explicit finite native timeouts.
SBUSBResult SBUSBRead(SBUSBHandle *handle, void *buffer, uint32_t capacity, uint32_t timeoutMilliseconds);
SBUSBResult SBUSBWrite(SBUSBHandle *handle, const void *bytes, uint32_t count, uint32_t timeoutMilliseconds);
/// Bounded logical retirement only; makes later native admission fail without doing I/O.
SBUSBResult SBUSBRetire(SBUSBHandle *handle);
/// Retires before interrupting both pipes. Abort completion is not worker/cleanup completion.
/// Repeated calls may repeat an interrupt if a previous interrupt failed or raced native I/O.
SBUSBResult SBUSBInterrupt(SBUSBHandle *handle);
/// Never closes/releases while open, I/O or abort calls remain active. Returns BUSY in that case.
/// The native close result remains observable even after owned references have been released;
/// a released-with-error outcome is not successful close or successful data transfer.
SBUSBResult SBUSBTryClose(SBUSBHandle *handle);
SBUSBSnapshot SBUSBGetSnapshot(SBUSBHandle *handle);
/// Only after the external owner has joined every caller and prevents any future entry.
/// An unconfirmed cleanup returns without freeing; the same handle stays owned for retry.
/// After confirmed reference release, destruction nulls the handle even if it returns the
/// retained native close error. Do not retry destruction or release through the old pointer.
SBUSBResult SBUSBDestroy(SBUSBHandle **handle);

typedef struct SBAOAHandle SBAOAHandle;
typedef struct {
    bool started, running, closing, retired, ownedReferencesReleased;
    uint64_t deviceRegistryID;
    uint16_t protocolVersion;
    uint8_t identificationAttempted, identificationCompleted;
    bool startRequested, startCompletionConfirmed;
    SBUSBResult operationResult, closeResult;
} SBAOASnapshot;

/// Device-control-only owner. Does not open/seize any device/interface, touch ADB,
/// reset USB, or establish a product session. Own before Run and retain until cleanup.
SBAOAHandle *SBAOACreate(SBUSBResult *result);
/// Single-use synchronous worker operation. Query sends only request 51. Start sends
/// 51, six fixed product-identification strings, then 53 ONCE. Start requires exactly
/// 36 canonical lowercase nonzero UUID bytes; query requires no nonce. A bounded,
/// thread-safe callback supplies the captured attempt authority/cancellation state.
/// The caller retains callback context through return. An overall 18-second budget
/// includes acquisition and at most two seconds per native request. Acquisition/release
/// have no OS hard timeout: observers must not abandon a still-running worker.
SBUSBResult SBAOARun(SBAOAHandle *handle, uint64_t deviceRegistryID,
                    const char *nonce, uint32_t nonceLength, bool startAccessory,
                    bool (*shouldContinue)(void *), void *context);
/// Stop facts remain available even on failure/cancellation after request 53. A
/// completed start request is not proof of re-enumeration, native I/O or authentication.
SBAOASnapshot SBAOAGetSnapshot(SBAOAHandle *handle);
SBUSBResult SBAOATryClose(SBAOAHandle *handle);
/// Only after every caller is joined. Unconfirmed release retains the same handle.
SBUSBResult SBAOADestroy(SBAOAHandle **handle);

#ifdef __cplusplus
}
#endif
#endif
