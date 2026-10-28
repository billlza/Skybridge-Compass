#ifndef SKYBRIDGE_AUDIO_OUTPUT_H
#define SKYBRIDGE_AUDIO_OUTPUT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A native realtime bridge, not a decoder, converter, mixer or authorization gate. */
typedef struct SBAudioOutputContext SBAudioOutputContext;
typedef struct { uint64_t high; uint64_t low; } SBAudioOutputOwner;

typedef enum {
    SBAudioOutputOK = 0,
    SBAudioOutputInvalidArgument,
    SBAudioOutputWrongOwner,
    SBAudioOutputAllocationFailed,
    SBAudioOutputAtomicsNotLockFree,
    SBAudioOutputInvalidState,
    SBAudioOutputRetired,
    SBAudioOutputQueueFull,
    SBAudioOutputIncompleteFrame,
    SBAudioOutputCounterOverflow,
    SBAudioOutputInsufficientPrefill,
    SBAudioOutputHALCreateFailed,
    SBAudioOutputHALStartFailed,
    SBAudioOutputHALStopFailed,
    SBAudioOutputHALDestroyFailed,
    SBAudioOutputCallbackInFlight,
    SBAudioOutputHALAddListenerFailed,
    SBAudioOutputHALRemoveListenerFailed,
    SBAudioOutputSourceCountMismatch
} SBAudioOutputResult;

typedef enum {
    SBAudioOutputFaultNone = 0,
    SBAudioOutputFaultUnderrun,
    SBAudioOutputFaultOutputLayoutChanged,
    SBAudioOutputFaultDeviceMismatch,
    SBAudioOutputFaultConcurrentCallback,
    SBAudioOutputFaultQueueOverflow,
    SBAudioOutputFaultInvalidInput,
    SBAudioOutputFaultCounterOverflow,
    SBAudioOutputFaultStopped,
    SBAudioOutputFaultDeviceChanged,
    SBAudioOutputFaultStartFailed,
    SBAudioOutputFaultCreateFailed,
    SBAudioOutputFaultOwnerRevoked,
    SBAudioOutputFaultInvalidTimeline,
    SBAudioOutputFaultPaddingLimit
} SBAudioOutputFault;

typedef struct {
    SBAudioOutputOwner owner;
    uint32_t bytesPerFrame;
    uint32_t channels;
    uint32_t capacityFrames;
    uint32_t maximumCallbackFrames;
} SBAudioOutputConfiguration;

typedef struct {
    uint64_t acceptedFrames;
    uint64_t submittedFrames; /* Copied into HAL buffers, never proof of physical playback. */
    uint64_t queuedFrames;
    uint32_t callbacksInFlight;
    uint32_t registeredListeners;
    SBAudioOutputFault fault;
    OSStatus lastHALStatus;
    bool active;
    bool registered;
    bool startAttempted;
    bool inputFinished;
    bool sourceTimelineValid;
    uint32_t trailingPaddingFrames; /* Actual HAL padding submissions, excluded from source counters. */
    double lastSourceEndSampleTime; /* Exclusive end, in this IOProc device's sample timeline. */
} SBAudioOutputSnapshot;

enum { SBAudioOutputMaximumCapacityBytes = 1048576 };

/*
 * All control calls, including Enqueue/Snapshot/Destroy, belong to ONE serialized owner executor.
 * Only the HAL callback runs concurrently. The queue is single-producer/single-consumer; clients
 * must not concurrently mutate the input buffer while Enqueue copies it. No context is reusable
 * after retirement, fault or failed Start. No allocation/lock/Swift/Objective-C occurs in IOProc.
 */
SBAudioOutputResult SBAudioOutputCreate(SBAudioOutputConfiguration configuration,
                                       SBAudioOutputContext **outContext);

/* Registers the C IOProc only. Caller must first verify the exact endpoint and native format. */
SBAudioOutputResult SBAudioOutputAttach(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                       AudioDeviceID device);
/* Bounded C property listeners immediately disarm rendering on a change; no Swift/ARC callback. */
SBAudioOutputResult SBAudioOutputWatchProperty(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                              AudioObjectID object, AudioObjectPropertyAddress address);
SBAudioOutputResult SBAudioOutputEnqueue(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                        const void *bytes, size_t byteCount);
/* Seal the source count. A count/owner mismatch does not mutate the context. Idempotent for the
 * identical count and padding bound. Only sealed input permits a short final callback and silence
 * after the source. The explicit padding budget bounds callbacks even if control polling stalls. */
SBAudioOutputResult SBAudioOutputFinishInput(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                           uint64_t expectedSourceFrames, uint32_t maximumPaddingFrames);
/* Requires maximumCallbackFrames of prefill unless nonempty input has been sealed. Effectful. */
SBAudioOutputResult SBAudioOutputStart(SBAudioOutputContext *context, SBAudioOutputOwner owner);

/* First terminal fault wins. This disarms rendering; it does not call HAL or free resources. */
SBAudioOutputResult SBAudioOutputRetire(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                       SBAudioOutputFault reason);
/*
 * Retires, stops (including a failed Start attempt), unregisters, then verifies callback quiescence.
 * Failure retains every resource still owned. Retry on the same owner; never free on failure.
 */
SBAudioOutputResult SBAudioOutputStop(SBAudioOutputContext *context, SBAudioOutputOwner owner);
/* Control must FIRST prove HAL device progress past the final source timestamp plus reported
 * latency (or explicitly identify an unstarted empty stream). This only quiesces resources without
 * manufacturing a Stopped fault; it does NOT itself prove playback. Concurrent device faults
 * remain visible. Requires sealed and fully submitted source; failures retain resources. */
SBAudioOutputResult SBAudioOutputStopAfterDrain(SBAudioOutputContext *context, SBAudioOutputOwner owner);
/* Must be serviced by the owner control plane; a nonzero callback fault stops the exact IOProc. */
SBAudioOutputResult SBAudioOutputService(SBAudioOutputContext *context, SBAudioOutputOwner owner);
SBAudioOutputResult SBAudioOutputGetSnapshot(SBAudioOutputContext *context, SBAudioOutputOwner owner,
                                            SBAudioOutputSnapshot *outSnapshot);
/* Does not implicitly stop. Rejects registered/active/in-flight contexts; nulls pointer on success. */
SBAudioOutputResult SBAudioOutputDestroy(SBAudioOutputContext **context, SBAudioOutputOwner owner);

#ifdef SB_AUDIO_OUTPUT_TESTING
/* Pure-memory HAL substitute; never included in the product build. */
typedef struct {
    void *user;
    OSStatus (*create)(void *, AudioDeviceID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
    OSStatus (*start)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*stop)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*destroy)(void *, AudioDeviceID, AudioDeviceIOProcID);
    OSStatus (*addListener)(void *, AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
    OSStatus (*removeListener)(void *, AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
} SBAudioOutputTestHAL;
SBAudioOutputResult SBAudioOutputCreateForTesting(SBAudioOutputConfiguration configuration,
                                                 SBAudioOutputTestHAL hal,
                                                 SBAudioOutputContext **outContext);
/* Allows overflow boundary tests without transferring exabytes; only before attach/enqueue. */
SBAudioOutputResult SBAudioOutputSetEmptyCursorForTesting(SBAudioOutputContext *context,
                                                         uint64_t frames);
SBAudioOutputResult SBAudioOutputSetRenderHookForTesting(SBAudioOutputContext *context,
                                                        void (*hook)(void *), void *user);
#endif

#ifdef __cplusplus
}
#endif
#endif
