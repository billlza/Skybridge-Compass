#include "SkyBridgeAudioOutput.h"
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    void *user;
    OSStatus (*create)(void *, AudioDeviceID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
    OSStatus (*start)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*stop)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*destroy)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*addListener)(void *, AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
    OSStatus (*removeListener)(void *, AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
} HALOperations;

enum { MaximumPropertyListeners = 512 };
typedef struct { AudioObjectID object; AudioObjectPropertyAddress address; } PropertyWatch;

struct SBAudioOutputContext {
    SBAudioOutputConfiguration configuration;
    uint8_t *storage;
    size_t capacityBytes;
    _Atomic(uint64_t) writtenFrames;
    _Atomic(uint64_t) readFrames;
    _Atomic(uint32_t) fault;
    _Atomic(uint32_t) callbacksInFlight;
    atomic_bool active;
    atomic_bool inputFinished;
    atomic_bool timelineInvalid;
    _Atomic(uint64_t) lastSourceEndBits;
    _Atomic(uint32_t) paddingFrames;
    /* Written before release-publishing inputFinished, immutable thereafter. */
    uint32_t maximumPaddingFrames;
    /* IOProc consumer-only; consumerEntered excludes overlapping callbacks. */
    bool hasOutputTime;
    double nextOutputSampleTime;
    uint64_t previousOutputHostTime;
    atomic_flag consumerEntered;
    /* Control-executor-only fields, immutable to the callback after Attach. */
    HALOperations hal;
    AudioDeviceID device;
    AudioDeviceIOProcID ioProc;
    OSStatus lastHALStatus;
    bool registered;
    bool startAttempted;
    bool retired;
    PropertyWatch watches[MaximumPropertyListeners];
    uint32_t watchCount;
#ifdef SB_AUDIO_OUTPUT_TESTING
    void (*renderHook)(void *);
    void *renderHookUser;
#endif
};

static OSStatus nativeCreate(void *user, AudioDeviceID device, AudioDeviceIOProc callback,
                             void *context, AudioDeviceIOProcID *identifier) {
    (void)user;
    return AudioDeviceCreateIOProcID(device, callback, context, identifier);
}
static OSStatus nativeStart(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    (void)user; return AudioDeviceStart(device, identifier);
}
static OSStatus nativeStop(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    (void)user; return AudioDeviceStop(device, identifier);
}
static OSStatus nativeDestroy(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    (void)user; return AudioDeviceDestroyIOProcID(device, identifier);
}
static OSStatus nativeAddListener(void *user, AudioObjectID object, const AudioObjectPropertyAddress *address,
                                  AudioObjectPropertyListenerProc callback, void *context) {
    (void)user; return AudioObjectAddPropertyListener(object, address, callback, context);
}
static OSStatus nativeRemoveListener(void *user, AudioObjectID object, const AudioObjectPropertyAddress *address,
                                     AudioObjectPropertyListenerProc callback, void *context) {
    (void)user; return AudioObjectRemovePropertyListener(object, address, callback, context);
}

static SBAudioOutputResult checkOwner(const SBAudioOutputContext *context, SBAudioOutputOwner owner) {
    if (context == NULL) return SBAudioOutputInvalidArgument;
    if (context->configuration.owner.high != owner.high || context->configuration.owner.low != owner.low)
        return SBAudioOutputWrongOwner;
    return SBAudioOutputOK;
}

static void recordFault(SBAudioOutputContext *context, SBAudioOutputFault reason) {
    uint32_t expected = SBAudioOutputFaultNone;
    (void)atomic_compare_exchange_strong_explicit(&context->fault, &expected, (uint32_t)reason,
                                                 memory_order_acq_rel, memory_order_acquire);
    atomic_store_explicit(&context->active, false, memory_order_release);
}

static OSStatus propertyChanged(AudioObjectID object, UInt32 count,
                                 const AudioObjectPropertyAddress *addresses, void *user) {
    (void)object; (void)count; (void)addresses;
    SBAudioOutputContext *context = user;
    if (context == NULL) return noErr;
    atomic_fetch_add_explicit(&context->callbacksInFlight, 1, memory_order_acq_rel);
    recordFault(context, SBAudioOutputFaultDeviceChanged);
    atomic_fetch_sub_explicit(&context->callbacksInFlight, 1, memory_order_release);
    return noErr;
}

/* All v1 one-byte samples are unsigned PCM8. HAL's zero bytes are not its silence value. */
static void silenceUnsigned8IfKnown(const SBAudioOutputContext *context, AudioBufferList *output) {
    if (context->configuration.bytesPerFrame != context->configuration.channels ||
        output == NULL || output->mNumberBuffers != 1) return;
    AudioBuffer *buffer = &output->mBuffers[0];
    if (buffer->mData != NULL && buffer->mNumberChannels == context->configuration.channels &&
        buffer->mDataByteSize % context->configuration.bytesPerFrame == 0 &&
        buffer->mDataByteSize / context->configuration.bytesPerFrame <= context->configuration.maximumCallbackFrames)
        memset(buffer->mData, 0x80, buffer->mDataByteSize);
}

/* Error/retired/underflow silence is never counted as submitted source frames. */
static OSStatus render(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime, void *user) {
    (void)now; (void)input; (void)inputTime;
    SBAudioOutputContext *context = user;
    if (context == NULL) return noErr;
    atomic_fetch_add_explicit(&context->callbacksInFlight, 1, memory_order_acq_rel);
    if (atomic_flag_test_and_set_explicit(&context->consumerEntered, memory_order_acquire)) {
        recordFault(context, SBAudioOutputFaultConcurrentCallback);
        atomic_fetch_sub_explicit(&context->callbacksInFlight, 1, memory_order_release);
        return noErr;
    }
#ifdef SB_AUDIO_OUTPUT_TESTING
    if (context->renderHook != NULL) context->renderHook(context->renderHookUser);
#endif
    bool submitted = false;
    if (!atomic_load_explicit(&context->active, memory_order_acquire) ||
        atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone) goto done;
    if (device != context->device) { recordFault(context, SBAudioOutputFaultDeviceMismatch); goto done; }
    if (output == NULL || output->mNumberBuffers != 1) {
        recordFault(context, SBAudioOutputFaultOutputLayoutChanged); goto done;
    }
    AudioBuffer *buffer = &output->mBuffers[0];
    const uint32_t bytesPerFrame = context->configuration.bytesPerFrame;
    if (buffer->mData == NULL || buffer->mNumberChannels != context->configuration.channels ||
        buffer->mDataByteSize == 0 || buffer->mDataByteSize % bytesPerFrame != 0) {
        recordFault(context, SBAudioOutputFaultOutputLayoutChanged); goto done;
    }
    const uint64_t frames = buffer->mDataByteSize / bytesPerFrame;
    if (frames > context->configuration.maximumCallbackFrames) {
        recordFault(context, SBAudioOutputFaultOutputLayoutChanged); goto done;
    }
    const uint64_t read = atomic_load_explicit(&context->readFrames, memory_order_relaxed);
    const bool finished = atomic_load_explicit(&context->inputFinished, memory_order_acquire);
    const uint64_t written = atomic_load_explicit(&context->writtenFrames, memory_order_acquire);
    if (written < read || (!finished && written - read < frames)) {
        recordFault(context, SBAudioOutputFaultUnderrun); goto done;
    }
    const uint64_t sourceFrames = written - read < frames ? written - read : frames;
    const uint32_t padding = (uint32_t)(frames - sourceFrames);
    const uint32_t oldPadding = atomic_load_explicit(&context->paddingFrames, memory_order_relaxed);
    if (padding > 0 && (oldPadding > context->maximumPaddingFrames ||
        padding > context->maximumPaddingFrames - oldPadding)) {
        recordFault(context, SBAudioOutputFaultPaddingLimit); goto done;
    }
    /* Timestamps describe hardware handoff, not acoustic/DAC proof. Keep evidence even before
     * EOF: the final full source block may already have been submitted when EOF arrives. Missing
     * or discontinuous evidence is sticky; ordinary unsealed playback may continue, but cannot
     * subsequently claim a drain. Bound floating-point arithmetic to exact integer-frame range. */
    const AudioTimeStampFlags required = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    bool validTime = outputTime != NULL && (outputTime->mFlags & required) == required &&
        isfinite(outputTime->mSampleTime) && fabs(outputTime->mSampleTime) <= 9007199254740991.0 - (double)frames;
    if (validTime && context->hasOutputTime)
        validTime = outputTime->mSampleTime == context->nextOutputSampleTime &&
                    outputTime->mHostTime > context->previousOutputHostTime;
    if (!validTime) atomic_store_explicit(&context->timelineInvalid, true, memory_order_release);
    if (finished && atomic_load_explicit(&context->timelineInvalid, memory_order_acquire)) {
        recordFault(context, SBAudioOutputFaultInvalidTimeline); goto done;
    }
    if (validTime) {
        context->hasOutputTime = true;
        context->nextOutputSampleTime = outputTime->mSampleTime + (double)frames;
        context->previousOutputHostTime = outputTime->mHostTime;
    }
    const size_t readByteOffset = (size_t)(read % context->configuration.capacityFrames) * bytesPerFrame;
    const size_t byteCount = (size_t)sourceFrames * bytesPerFrame;
    const size_t first = byteCount < context->capacityBytes - readByteOffset
        ? byteCount : context->capacityBytes - readByteOffset;
    /* Retire can race with an already admitted callback; successful Stop quiesces that callback. */
    memcpy(buffer->mData, context->storage + readByteOffset, first);
    if (first < byteCount) memcpy((uint8_t *)buffer->mData + first, context->storage, byteCount - first);
    if (padding > 0) {
        memset((uint8_t *)buffer->mData + byteCount,
               bytesPerFrame == context->configuration.channels ? 0x80 : 0,
               (size_t)padding * bytesPerFrame);
        atomic_store_explicit(&context->paddingFrames, oldPadding + padding, memory_order_release);
    }
    if (sourceFrames > 0 && validTime) {
        double end = outputTime->mSampleTime + (double)sourceFrames;
        uint64_t bits; memcpy(&bits, &end, sizeof(bits));
        atomic_store_explicit(&context->lastSourceEndBits, bits, memory_order_relaxed);
    }
    /* Publish the timestamp before the corresponding source count. Once EOF's count is reached,
     * that timestamp cannot change again, so an acquire of readFrames gives a coherent endpoint. */
    atomic_store_explicit(&context->readFrames, read + sourceFrames, memory_order_release);
    submitted = true;
done:
    if (!submitted && device == context->device) silenceUnsigned8IfKnown(context, output);
    atomic_flag_clear_explicit(&context->consumerEntered, memory_order_release);
    atomic_fetch_sub_explicit(&context->callbacksInFlight, 1, memory_order_release);
    return noErr; /* AudioDeviceIOProc return values are unused; control-plane Service handles faults. */
}

static SBAudioOutputResult create(SBAudioOutputConfiguration configuration, HALOperations hal,
                                  SBAudioOutputContext **outContext) {
    if (outContext == NULL) return SBAudioOutputInvalidArgument;
    *outContext = NULL;
    if ((configuration.owner.high == 0 && configuration.owner.low == 0) ||
        configuration.bytesPerFrame == 0 || configuration.bytesPerFrame > UINT16_MAX ||
        configuration.channels == 0 || configuration.channels > UINT16_MAX ||
        configuration.bytesPerFrame % configuration.channels != 0 ||
        configuration.capacityFrames == 0 || configuration.maximumCallbackFrames == 0 ||
        configuration.maximumCallbackFrames > configuration.capacityFrames ||
        (uint64_t)configuration.capacityFrames * configuration.bytesPerFrame > SBAudioOutputMaximumCapacityBytes ||
        hal.create == NULL || hal.start == NULL || hal.stop == NULL || hal.destroy == NULL ||
        hal.addListener == NULL || hal.removeListener == NULL)
        return SBAudioOutputInvalidArgument;
    const uint32_t sampleBytes = configuration.bytesPerFrame / configuration.channels;
    if (sampleBytes != 1 && sampleBytes != 2 && sampleBytes != 3 && sampleBytes != 4 && sampleBytes != 8)
        return SBAudioOutputInvalidArgument;
    SBAudioOutputContext *context = calloc(1, sizeof(*context));
    if (context == NULL) return SBAudioOutputAllocationFailed;
    context->configuration = configuration;
    context->capacityBytes = (size_t)configuration.capacityFrames * configuration.bytesPerFrame;
    atomic_init(&context->writtenFrames, 0); atomic_init(&context->readFrames, 0);
    atomic_init(&context->fault, SBAudioOutputFaultNone); atomic_init(&context->callbacksInFlight, 0);
    atomic_init(&context->active, false); context->consumerEntered = (atomic_flag)ATOMIC_FLAG_INIT;
    atomic_init(&context->inputFinished, false); atomic_init(&context->timelineInvalid, false);
    atomic_init(&context->lastSourceEndBits, 0); atomic_init(&context->paddingFrames, 0);
    if (!atomic_is_lock_free(&context->writtenFrames) || !atomic_is_lock_free(&context->readFrames) ||
        !atomic_is_lock_free(&context->fault) || !atomic_is_lock_free(&context->callbacksInFlight) ||
        !atomic_is_lock_free(&context->active) || !atomic_is_lock_free(&context->inputFinished) ||
        !atomic_is_lock_free(&context->timelineInvalid) || !atomic_is_lock_free(&context->lastSourceEndBits) ||
        !atomic_is_lock_free(&context->paddingFrames)) {
        free(context); return SBAudioOutputAtomicsNotLockFree;
    }
    context->storage = malloc(context->capacityBytes);
    if (context->storage == NULL) { free(context); return SBAudioOutputAllocationFailed; }
    context->hal = hal;
    *outContext = context;
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputCreate(SBAudioOutputConfiguration configuration,
                                       SBAudioOutputContext **outContext) {
    HALOperations operations = { NULL, nativeCreate, nativeStart, nativeStop, nativeDestroy, nativeAddListener, nativeRemoveListener };
    return create(configuration, operations, outContext);
}

SBAudioOutputResult SBAudioOutputWatchProperty(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                              AudioObjectID object, AudioObjectPropertyAddress address) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (context->retired || atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    if (context->startAttempted || context->watchCount >= MaximumPropertyListeners || object == kAudioObjectUnknown)
        return SBAudioOutputInvalidState;
    for (uint32_t index = 0; index < context->watchCount; index++) {
        PropertyWatch watch = context->watches[index];
        if (watch.object == object && watch.address.mSelector == address.mSelector &&
            watch.address.mScope == address.mScope && watch.address.mElement == address.mElement)
            return SBAudioOutputInvalidState;
    }
    context->lastHALStatus = context->hal.addListener(context->hal.user, object, &address, propertyChanged, context);
    if (context->lastHALStatus != noErr) return SBAudioOutputHALAddListenerFailed;
    context->watches[context->watchCount++] = (PropertyWatch){object, address};
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputAttach(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                       AudioDeviceID device) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (context->retired || atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    if (device == kAudioObjectUnknown) return SBAudioOutputInvalidArgument;
    if (context->registered || context->startAttempted) return SBAudioOutputInvalidState;
    context->device = device;
    AudioDeviceIOProcID identifier = NULL;
    context->lastHALStatus = context->hal.create(context->hal.user, device, render, context, &identifier);
    /* Retain a returned registration even on a malformed/failing backend result. */
    if (identifier != NULL) { context->ioProc = identifier; context->registered = true; }
    if (context->lastHALStatus != noErr || identifier == NULL) {
        recordFault(context, SBAudioOutputFaultCreateFailed);
        context->retired = true;
        return SBAudioOutputHALCreateFailed;
    }
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputEnqueue(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                        const void *bytes, size_t byteCount) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (context->retired || atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    if (atomic_load_explicit(&context->inputFinished, memory_order_acquire)) return SBAudioOutputInvalidState;
    const uint32_t frameBytes = context->configuration.bytesPerFrame;
    if (bytes == NULL || byteCount == 0 || byteCount % frameBytes != 0) {
        recordFault(context, SBAudioOutputFaultInvalidInput); return SBAudioOutputIncompleteFrame;
    }
    const uint64_t frames = byteCount / frameBytes;
    const uint64_t written = atomic_load_explicit(&context->writtenFrames, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&context->readFrames, memory_order_acquire);
    const uint64_t maximumFrames = (uint64_t)INT64_MAX / frameBytes;
    if (frames > maximumFrames || written > maximumFrames - frames) {
        recordFault(context, SBAudioOutputFaultCounterOverflow); return SBAudioOutputCounterOverflow;
    }
    if (written < read || written - read > context->configuration.capacityFrames ||
        frames > context->configuration.capacityFrames - (written - read)) {
        recordFault(context, SBAudioOutputFaultQueueOverflow); return SBAudioOutputQueueFull;
    }
    const size_t offset = (size_t)(written % context->configuration.capacityFrames) * frameBytes;
    const size_t first = byteCount < context->capacityBytes - offset ? byteCount : context->capacityBytes - offset;
    memcpy(context->storage + offset, bytes, first);
    if (first < byteCount) memcpy(context->storage, (const uint8_t *)bytes + first, byteCount - first);
    if (atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    atomic_store_explicit(&context->writtenFrames, written + frames, memory_order_release);
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputFinishInput(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                           uint64_t expectedSourceFrames, uint32_t maximumPaddingFrames) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (expectedSourceFrames != atomic_load_explicit(&context->writtenFrames, memory_order_acquire))
        return SBAudioOutputSourceCountMismatch;
    if (context->retired || atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    if (maximumPaddingFrames < context->configuration.maximumCallbackFrames) return SBAudioOutputInvalidArgument;
    if (atomic_load_explicit(&context->inputFinished, memory_order_acquire))
        return context->maximumPaddingFrames == maximumPaddingFrames ? SBAudioOutputOK : SBAudioOutputInvalidState;
    context->maximumPaddingFrames = maximumPaddingFrames;
    atomic_store_explicit(&context->inputFinished, true, memory_order_release);
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputStart(SBAudioOutputContext *context, SBAudioOutputOwner owner) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (context->retired || atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    if (!context->registered || context->startAttempted) return SBAudioOutputInvalidState;
    const uint64_t written = atomic_load_explicit(&context->writtenFrames, memory_order_acquire);
    const uint64_t read = atomic_load_explicit(&context->readFrames, memory_order_acquire);
    if (written <= read || (written - read < context->configuration.maximumCallbackFrames &&
        !atomic_load_explicit(&context->inputFinished, memory_order_acquire))) return SBAudioOutputInsufficientPrefill;
    context->startAttempted = true;
    atomic_store_explicit(&context->active, true, memory_order_release);
    context->lastHALStatus = context->hal.start(context->hal.user, context->device, context->ioProc);
    if (context->lastHALStatus != noErr) {
        recordFault(context, SBAudioOutputFaultStartFailed); context->retired = true;
        return SBAudioOutputHALStartFailed;
    }
    if (atomic_load_explicit(&context->fault, memory_order_acquire) != SBAudioOutputFaultNone)
        return SBAudioOutputRetired;
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputRetire(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                       SBAudioOutputFault reason) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (reason <= SBAudioOutputFaultNone || reason > SBAudioOutputFaultPaddingLimit)
        return SBAudioOutputInvalidArgument;
    recordFault(context, reason); context->retired = true;
    return SBAudioOutputOK;
}

static SBAudioOutputResult stop(SBAudioOutputContext *context, SBAudioOutputOwner owner, bool afterDrain) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (afterDrain && (!atomic_load_explicit(&context->inputFinished, memory_order_acquire) ||
        atomic_load_explicit(&context->readFrames, memory_order_acquire) !=
        atomic_load_explicit(&context->writtenFrames, memory_order_acquire))) return SBAudioOutputInvalidState;
    context->retired = true;
    if (!afterDrain) recordFault(context, SBAudioOutputFaultStopped);
    if (context->startAttempted) {
        /* During a clean Stop, callbacks admitted before HAL quiesces still render/count bounded
         * EOF padding. Disarming first would introduce an uncounted prezeroed tail buffer. */
        context->lastHALStatus = context->hal.stop(context->hal.user, context->device, context->ioProc);
        if (context->lastHALStatus != noErr) {
            recordFault(context, SBAudioOutputFaultStopped);
            return SBAudioOutputHALStopFailed;
        }
        context->startAttempted = false;
    }
    atomic_store_explicit(&context->active, false, memory_order_release);
    if (context->registered) {
        context->lastHALStatus = context->hal.destroy(context->hal.user, context->device, context->ioProc);
        if (context->lastHALStatus != noErr) return SBAudioOutputHALDestroyFailed;
        context->registered = false;
        context->ioProc = NULL;
    }
    while (context->watchCount > 0) {
        PropertyWatch *watch = &context->watches[context->watchCount - 1];
        context->lastHALStatus = context->hal.removeListener(context->hal.user, watch->object, &watch->address, propertyChanged, context);
        if (context->lastHALStatus != noErr) return SBAudioOutputHALRemoveListenerFailed;
        context->watchCount--;
    }
    if (atomic_load_explicit(&context->callbacksInFlight, memory_order_acquire) != 0)
        return SBAudioOutputCallbackInFlight;
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputStop(SBAudioOutputContext *context, SBAudioOutputOwner owner) {
    return stop(context, owner, false);
}
SBAudioOutputResult SBAudioOutputStopAfterDrain(SBAudioOutputContext *context, SBAudioOutputOwner owner) {
    return stop(context, owner, true);
}

SBAudioOutputResult SBAudioOutputService(SBAudioOutputContext *context, SBAudioOutputOwner owner) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (atomic_load_explicit(&context->fault, memory_order_acquire) == SBAudioOutputFaultNone)
        return SBAudioOutputOK;
    return SBAudioOutputStop(context, owner);
}

SBAudioOutputResult SBAudioOutputGetSnapshot(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                            SBAudioOutputSnapshot *outSnapshot) {
    SBAudioOutputResult result = checkOwner(context, owner); if (result != SBAudioOutputOK) return result;
    if (outSnapshot == NULL) return SBAudioOutputInvalidArgument;
    const uint64_t written = atomic_load_explicit(&context->writtenFrames, memory_order_acquire);
    const uint64_t read = atomic_load_explicit(&context->readFrames, memory_order_acquire);
    const uint64_t endBits = atomic_load_explicit(&context->lastSourceEndBits, memory_order_relaxed);
    double end; memcpy(&end, &endBits, sizeof(end));
    *outSnapshot = (SBAudioOutputSnapshot) {
        .acceptedFrames = written, .submittedFrames = read, .queuedFrames = written - read,
        .callbacksInFlight = atomic_load_explicit(&context->callbacksInFlight, memory_order_acquire),
        .registeredListeners = context->watchCount,
        .fault = (SBAudioOutputFault)atomic_load_explicit(&context->fault, memory_order_acquire),
        .lastHALStatus = context->lastHALStatus,
        .active = atomic_load_explicit(&context->active, memory_order_acquire),
        .registered = context->registered, .startAttempted = context->startAttempted,
        .inputFinished = atomic_load_explicit(&context->inputFinished, memory_order_acquire),
        .sourceTimelineValid = read > 0 && !atomic_load_explicit(&context->timelineInvalid, memory_order_acquire),
        .lastSourceEndSampleTime = end,
        .trailingPaddingFrames = atomic_load_explicit(&context->paddingFrames, memory_order_acquire)
    };
    return SBAudioOutputOK;
}

SBAudioOutputResult SBAudioOutputDestroy(SBAudioOutputContext **context, SBAudioOutputOwner owner) {
    if (context == NULL) return SBAudioOutputInvalidArgument;
    if (*context == NULL) return SBAudioOutputOK;
    SBAudioOutputResult result = checkOwner(*context, owner); if (result != SBAudioOutputOK) return result;
    if ((*context)->registered || (*context)->startAttempted || (*context)->watchCount != 0 ||
        atomic_load_explicit(&(*context)->active, memory_order_acquire))
        return SBAudioOutputInvalidState;
    if (atomic_load_explicit(&(*context)->callbacksInFlight, memory_order_acquire) != 0)
        return SBAudioOutputCallbackInFlight;
    free((*context)->storage); free(*context); *context = NULL;
    return SBAudioOutputOK;
}

#ifdef SB_AUDIO_OUTPUT_TESTING
SBAudioOutputResult SBAudioOutputCreateForTesting(SBAudioOutputConfiguration configuration,
                                                 SBAudioOutputTestHAL hal,
                                                 SBAudioOutputContext **outContext) {
    HALOperations operations = { hal.user, hal.create, hal.start, hal.stop, hal.destroy, hal.addListener, hal.removeListener };
    return create(configuration, operations, outContext);
}
SBAudioOutputResult SBAudioOutputSetEmptyCursorForTesting(SBAudioOutputContext *context, uint64_t frames) {
    if (context == NULL || context->registered || context->startAttempted ||
        atomic_load(&context->writtenFrames) != 0 || frames > (uint64_t)INT64_MAX / context->configuration.bytesPerFrame)
        return SBAudioOutputInvalidArgument;
    atomic_store(&context->writtenFrames, frames); atomic_store(&context->readFrames, frames);
    return SBAudioOutputOK;
}
SBAudioOutputResult SBAudioOutputSetRenderHookForTesting(SBAudioOutputContext *context,
                                                        void (*hook)(void *), void *user) {
    if (context == NULL || context->registered || context->startAttempted) return SBAudioOutputInvalidState;
    context->renderHook = hook; context->renderHookUser = user;
    return SBAudioOutputOK;
}
#endif
