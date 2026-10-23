#include "USBAccessoryInternal.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct SBAOAHandle {
    pthread_mutex_t mutex;
    SBAOASnapshot state;
    void *driver;
    SBAOADriverOperations operations;
};

SBAOAHandle *SBAOACreateWithDriver(void *driver, const SBAOADriverOperations *ops, SBUSBResult *result) {
    if (!result) return NULL;
    *result = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ALLOCATE);
    if (!driver || !ops || !ops->acquire || !ops->request || !ops->clockMilliseconds || !ops->close || !ops->destroy) return NULL;
    SBAOAHandle *h = calloc(1, sizeof(*h));
    if (!h) { *result = SBUSBResultMake(SB_USB_UNAVAILABLE, SB_USB_PHASE_ALLOCATE); return NULL; }
    int code = pthread_mutex_init(&h->mutex, NULL);
    if (code) { free(h); result->status = SB_USB_NATIVE_FAILURE; result->domain = SB_USB_DOMAIN_POSIX; result->nativeCode = code; return NULL; }
    h->driver = driver; h->operations = *ops;
    *result = SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_ALLOCATE); return h;
}

static bool validNonce(const char *nonce, uint32_t count) {
    if (!nonce || count != 36) return false;
    bool nonzero = false;
    for (unsigned i = 0; i < 36; i++) {
        char c = nonce[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (c != '-') return false; }
        else {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            if (c != '0') nonzero = true;
        }
    }
    return nonzero;
}

static SBUSBResult remaining(SBAOAHandle *h, uint64_t began, SBUSBPhase phase,
                             bool (*authorize)(void *), void *context, uint32_t *timeout) {
    pthread_mutex_lock(&h->mutex); bool retired = h->state.retired; pthread_mutex_unlock(&h->mutex);
    if (retired || !authorize(context)) return SBUSBResultMake(SB_USB_CANCELLED, phase);
    uint64_t now = 0; SBUSBResult result = h->operations.clockMilliseconds(h->driver, &now);
    if (result.status != SB_USB_OK) return result;
    if (now < began || now - began >= 18000) return SBUSBResultMake(SB_USB_TIMED_OUT, phase);
    uint64_t left = 18000 - (now - began);
    *timeout = (uint32_t)(left < 2000 ? left : 2000);
    return SBUSBResultMake(SB_USB_OK, phase);
}

SBUSBResult SBAOARun(SBAOAHandle *h, uint64_t registryID, const char *nonce, uint32_t nonceLength,
                    bool start, bool (*authorize)(void *), void *context) {
    if (!h || !registryID || !authorize || (start ? !validNonce(nonce, nonceLength) : nonce != NULL || nonceLength != 0))
        return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ACCESSORY_QUERY);
    pthread_mutex_lock(&h->mutex);
    if (h->state.started || h->state.retired) {
        pthread_mutex_unlock(&h->mutex); return SBUSBResultMake(SB_USB_ALREADY_STARTED, SB_USB_PHASE_ACCESSORY_QUERY);
    }
    h->state.started = true; h->state.running = true; h->state.deviceRegistryID = registryID;
    pthread_mutex_unlock(&h->mutex);
    uint64_t began = 0; uint32_t timeout = 0;
    SBUSBResult result = h->operations.clockMilliseconds(h->driver, &began);
    if (result.status != SB_USB_OK) goto done;
    result = remaining(h, began, SB_USB_PHASE_SELECT_DEVICE, authorize, context, &timeout);
    if (result.status != SB_USB_OK) goto done;
    result = h->operations.acquire(h->driver, registryID);
    if (result.status != SB_USB_OK) goto done;
    char serial[37] = {0}, uri[80] = {0};
    if (start) {
        memcpy(serial, nonce, 36);
        int size = snprintf(uri, sizeof(uri), "skybridge-usb://attachment/%s", serial);
        if (size <= 0 || (unsigned)size >= sizeof(uri)) { result = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ACCESSORY_IDENTIFICATION); goto done; }
    }
    const char *strings[6] = {"SkyBridge", "SkyBridge USB Link", "SkyBridge USB connection", "1", uri, serial};
    for (unsigned step = 0; step < (start ? 8u : 1u); step++) {
        SBUSBPhase phase = step == 0 ? SB_USB_PHASE_ACCESSORY_QUERY : step == 7 ? SB_USB_PHASE_ACCESSORY_START : SB_USB_PHASE_ACCESSORY_IDENTIFICATION;
        result = remaining(h, began, phase, authorize, context, &timeout);
        if (result.status != SB_USB_OK) goto done;
        uint8_t query[2] = {0};
        uint8_t buffer[256] = {0};
        uint16_t length = 0, index = 0;
        uint8_t request = 51, type = 0xc0;
        void *data = query;
        if (step == 0) length = 2;
        else if (step == 7) { request = 53; type = 0x40; data = NULL; }
        else {
            request = 52; type = 0x40; index = (uint16_t)(step - 1);
            size_t count = strlen(strings[index]) + 1;
            if (count > sizeof(buffer)) { result = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, phase); goto done; }
            memcpy(buffer, strings[index], count); data = buffer; length = (uint16_t)count;
        }
        pthread_mutex_lock(&h->mutex);
        if (step == 7) h->state.startRequested = true;
        else if (step > 0) h->state.identificationAttempted++;
        pthread_mutex_unlock(&h->mutex);
        result = h->operations.request(h->driver, type, request, index, data, length, timeout);
        result.phase = phase;
        if (result.status != SB_USB_OK) goto done;
        if (!result.byteCountKnown || result.bytesTransferred != length) {
            result.status = SB_USB_BAD_RESPONSE; goto done;
        }
        pthread_mutex_lock(&h->mutex);
        if (step == 7) h->state.startCompletionConfirmed = true;
        else if (step > 0) h->state.identificationCompleted++;
        else h->state.protocolVersion = (uint16_t)query[0] | ((uint16_t)query[1] << 8);
        uint16_t version = h->state.protocolVersion;
        pthread_mutex_unlock(&h->mutex);
        if (step == 0 && version != 1 && version != 2) { result.status = SB_USB_UNSUPPORTED_PROTOCOL; goto done; }
        result = remaining(h, began, phase, authorize, context, &timeout);
        if (result.status != SB_USB_OK) goto done;
    }
done:
    pthread_mutex_lock(&h->mutex);
    h->state.running = false; h->state.operationResult = result;
    pthread_mutex_unlock(&h->mutex); return result;
}

SBAOASnapshot SBAOAGetSnapshot(SBAOAHandle *h) {
    if (!h) { SBAOASnapshot state = {0}; state.operationResult = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_NONE); return state; }
    pthread_mutex_lock(&h->mutex); SBAOASnapshot state = h->state; pthread_mutex_unlock(&h->mutex); return state;
}
SBUSBResult SBAOATryClose(SBAOAHandle *h) {
    if (!h) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_CLOSE);
    pthread_mutex_lock(&h->mutex);
    h->state.retired = true;
    if (h->state.running || h->state.closing) { pthread_mutex_unlock(&h->mutex); return SBUSBResultMake(SB_USB_BUSY, SB_USB_PHASE_CLOSE); }
    if (h->state.ownedReferencesReleased) { SBUSBResult result = h->state.closeResult; pthread_mutex_unlock(&h->mutex); return result; }
    h->state.closing = true; pthread_mutex_unlock(&h->mutex);
    bool released = false; SBUSBResult result = h->operations.close(h->driver, &released);
    if (!released && result.status == SB_USB_OK) result = SBUSBResultMake(SB_USB_CLEANUP_UNCONFIRMED, SB_USB_PHASE_RELEASE);
    pthread_mutex_lock(&h->mutex);
    h->state.closing = false; h->state.closeResult = result; h->state.ownedReferencesReleased = released;
    pthread_mutex_unlock(&h->mutex); return result;
}
SBUSBResult SBAOADestroy(SBAOAHandle **owned) {
    if (!owned || !*owned) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_RELEASE);
    SBAOAHandle *h = *owned;
    pthread_mutex_lock(&h->mutex);
    if (h->state.running || h->state.closing || !h->state.ownedReferencesReleased) {
        pthread_mutex_unlock(&h->mutex); return SBUSBResultMake(SB_USB_CLEANUP_UNCONFIRMED, SB_USB_PHASE_RELEASE);
    }
    SBUSBResult result = h->state.closeResult; pthread_mutex_unlock(&h->mutex);
    int code = pthread_mutex_destroy(&h->mutex);
    if (code) { result = SBUSBResultMake(SB_USB_NATIVE_FAILURE, SB_USB_PHASE_RELEASE); result.domain = SB_USB_DOMAIN_POSIX; result.nativeCode = code; return result; }
    h->operations.destroy(h->driver); free(h); *owned = NULL; return result;
}
