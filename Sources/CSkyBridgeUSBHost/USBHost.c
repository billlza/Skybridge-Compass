#include "USBHostInternal.h"
#include <pthread.h>
#include <stdlib.h>

struct SBUSBHandle {
    pthread_mutex_t mutex;
    void *driver;
    SBUSBDriverOperations operations;
    SBUSBSnapshot state;
};

static void retainFailure(SBUSBHandle *handle, SBUSBResult result) {
    if (result.status != SB_USB_OK && handle->state.firstFailure.status == SB_USB_OK)
        handle->state.firstFailure = result;
}

SBUSBHandle *SBUSBCreateWithDriver(void *driver, const SBUSBDriverOperations *operations, SBUSBResult *result) {
    if (!result) return NULL;
    *result = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ALLOCATE);
    if (!driver || !operations || !operations->open || !operations->read || !operations->write ||
        !operations->interrupt || !operations->close || !operations->destroy) return NULL;
    SBUSBHandle *handle = calloc(1, sizeof(*handle));
    if (!handle) { result->status = SB_USB_UNAVAILABLE; return NULL; }
    int code = pthread_mutex_init(&handle->mutex, NULL);
    if (code) {
        free(handle); result->status = SB_USB_NATIVE_FAILURE; result->domain = SB_USB_DOMAIN_POSIX;
        result->nativeCode = code; return NULL;
    }
    handle->driver = driver; handle->operations = *operations;
    *result = SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_ALLOCATE);
    return handle;
}

SBUSBHandle *SBUSBCreate(SBUSBResult *result) { return SBUSBCreateNative(result); }

SBUSBResult SBUSBOpen(SBUSBHandle *handle, uint64_t registryID) {
    if (!handle || !registryID) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_OPEN);
    pthread_mutex_lock(&handle->mutex);
    if (handle->state.retired || handle->state.started) {
        SBUSBStatus status = handle->state.retired ? SB_USB_CANCELLED : SB_USB_ALREADY_STARTED;
        pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(status, SB_USB_PHASE_OPEN);
    }
    handle->state.started = true; handle->state.opening = true;
    pthread_mutex_unlock(&handle->mutex);

    SBUSBDeviceInfo info = {0};
    SBUSBResult result = handle->operations.open(handle->driver, registryID, &info);

    pthread_mutex_lock(&handle->mutex);
    handle->state.opening = false;
    handle->state.device = info;
    if (handle->state.retired && result.status == SB_USB_OK) result.status = SB_USB_CANCELLED;
    if (result.status != SB_USB_OK) { handle->state.retired = true; retainFailure(handle, result); }
    else handle->state.ready = true;
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static SBUSBResult transfer(SBUSBHandle *handle, void *readBuffer, const void *writeBytes,
                            uint32_t count, uint32_t timeout, bool reading) {
    SBUSBPhase phase = reading ? SB_USB_PHASE_READ : SB_USB_PHASE_WRITE;
    if (!handle || (!readBuffer && reading) || (!writeBytes && !reading) || !timeout || timeout > SB_USB_MAX_TIMEOUT_MS ||
        !count || count > SB_USB_TRANSFER_BYTES || (reading && count != SB_USB_TRANSFER_BYTES))
        return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, phase);
    pthread_mutex_lock(&handle->mutex);
    SBUSBStatus status = handle->state.retired ? SB_USB_CANCELLED : !handle->state.ready ? SB_USB_NOT_READY :
        (reading ? handle->state.reading : handle->state.writing) ? SB_USB_BUSY : SB_USB_OK;
    if (status != SB_USB_OK) { pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(status, phase); }
    if (reading) handle->state.reading = true; else handle->state.writing = true;
    pthread_mutex_unlock(&handle->mutex);

    SBUSBResult result = reading ? handle->operations.read(handle->driver, readBuffer, count, timeout) :
                                  handle->operations.write(handle->driver, writeBytes, count, timeout);

    pthread_mutex_lock(&handle->mutex);
    if (reading) handle->state.reading = false; else handle->state.writing = false;
    if (result.status == SB_USB_OK && (!result.byteCountKnown || result.bytesTransferred > count ||
                                     (!reading && result.bytesTransferred != count))) {
        result = SBUSBResultMake(SB_USB_NATIVE_FAILURE, phase);
    }
    if (handle->state.retired && result.status == SB_USB_OK) result.status = SB_USB_CANCELLED;
    if (result.status != SB_USB_OK) { handle->state.retired = true; retainFailure(handle, result); }
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

SBUSBResult SBUSBRead(SBUSBHandle *handle, void *buffer, uint32_t capacity, uint32_t timeout) {
    return transfer(handle, buffer, NULL, capacity, timeout, true);
}
SBUSBResult SBUSBWrite(SBUSBHandle *handle, const void *bytes, uint32_t count, uint32_t timeout) {
    return transfer(handle, NULL, bytes, count, timeout, false);
}

SBUSBResult SBUSBRetire(SBUSBHandle *handle) {
    if (!handle) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ABORT);
    pthread_mutex_lock(&handle->mutex);
    handle->state.retired = true;
    pthread_mutex_unlock(&handle->mutex);
    return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_ABORT);
}

SBUSBResult SBUSBInterrupt(SBUSBHandle *handle) {
    if (!handle) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_ABORT);
    pthread_mutex_lock(&handle->mutex);
    handle->state.retired = true;
    if (handle->state.interrupting || handle->state.closing) {
        pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(SB_USB_BUSY, SB_USB_PHASE_ABORT);
    }
    // Acquisition is still owned by the opening caller. It must return before cleanup can run;
    // no native abort reads driver fields while open is mutating them.
    if (handle->state.opening || !handle->state.ready || handle->state.ownedReferencesReleased) {
        pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_ABORT);
    }
    handle->state.interrupting = true;
    pthread_mutex_unlock(&handle->mutex);
    SBUSBResult result = handle->operations.interrupt(handle->driver);
    pthread_mutex_lock(&handle->mutex);
    handle->state.interrupting = false; retainFailure(handle, result);
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

SBUSBResult SBUSBTryClose(SBUSBHandle *handle) {
    if (!handle) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_CLOSE);
    pthread_mutex_lock(&handle->mutex);
    handle->state.retired = true;
    if (handle->state.opening || handle->state.reading || handle->state.writing ||
        handle->state.interrupting || handle->state.closing) {
        pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(SB_USB_BUSY, SB_USB_PHASE_CLOSE);
    }
    if (handle->state.ownedReferencesReleased) {
        SBUSBResult result = handle->state.closeResult;
        pthread_mutex_unlock(&handle->mutex); return result;
    }
    handle->state.closing = true;
    pthread_mutex_unlock(&handle->mutex);
    bool released = false;
    SBUSBResult result = handle->operations.close(handle->driver, &released);
    if (!released && result.status == SB_USB_OK)
        result = SBUSBResultMake(SB_USB_CLEANUP_UNCONFIRMED, SB_USB_PHASE_RELEASE);
    pthread_mutex_lock(&handle->mutex);
    handle->state.closing = false; handle->state.ready = false;
    handle->state.ownedReferencesReleased = released; handle->state.closeResult = result;
    retainFailure(handle, result);
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

SBUSBSnapshot SBUSBGetSnapshot(SBUSBHandle *handle) {
    if (!handle) {
        SBUSBSnapshot value = {0}; value.retired = true;
        value.firstFailure = SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_NONE); return value;
    }
    pthread_mutex_lock(&handle->mutex); SBUSBSnapshot value = handle->state; pthread_mutex_unlock(&handle->mutex);
    return value;
}

SBUSBResult SBUSBDestroy(SBUSBHandle **owned) {
    if (!owned || !*owned) return SBUSBResultMake(SB_USB_INVALID_ARGUMENT, SB_USB_PHASE_RELEASE);
    SBUSBHandle *handle = *owned;
    pthread_mutex_lock(&handle->mutex);
    if (!handle->state.ownedReferencesReleased || handle->state.opening || handle->state.reading ||
        handle->state.writing || handle->state.interrupting || handle->state.closing) {
        pthread_mutex_unlock(&handle->mutex); return SBUSBResultMake(SB_USB_CLEANUP_UNCONFIRMED, SB_USB_PHASE_RELEASE);
    }
    SBUSBResult closeResult = handle->state.closeResult;
    pthread_mutex_unlock(&handle->mutex);
    int code = pthread_mutex_destroy(&handle->mutex);
    if (code) {
        SBUSBResult result = SBUSBResultMake(SB_USB_NATIVE_FAILURE, SB_USB_PHASE_RELEASE);
        result.domain = SB_USB_DOMAIN_POSIX; result.nativeCode = code; return result;
    }
    handle->operations.destroy(handle->driver); free(handle); *owned = NULL;
    return closeResult;
}
