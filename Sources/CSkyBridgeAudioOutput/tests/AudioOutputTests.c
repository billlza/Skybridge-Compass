/* Standalone C tests. Compile with SB_AUDIO_OUTPUT_TESTING; never attach to real hardware. */
#include "SkyBridgeAudioOutput.h"
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #value); exit(1); } } while (0)
static const SBAudioOutputOwner OWNER = { 0x0011223344556677ULL, 0x8899aabbccddeeffULL };
static const SBAudioOutputOwner OTHER = { 0x0011223344556677ULL, 0x8899aabbccddee00ULL };

typedef struct {
    AudioDeviceIOProc callback;
    void *context;
    OSStatus createError, startError, stopError, destroyError;
    bool missingIdentifier, identifierOnFailure;
    unsigned creates, starts, stops, destroys;
    AudioDeviceID lastDevice;
    AudioObjectPropertyListenerProc listener;
    void *listenerContext;
    OSStatus addListenerError, removeListenerError;
    unsigned addedListeners, removedListeners;
    bool renderDuringStop;
} FakeHAL;

static OSStatus fakeCreate(void *user, AudioDeviceID device, AudioDeviceIOProc callback,
                           void *context, AudioDeviceIOProcID *identifier) {
    FakeHAL *fake = user; fake->creates++; fake->lastDevice = device;
    if ((!fake->createError || fake->identifierOnFailure) && !fake->missingIdentifier) {
        *identifier = callback; fake->callback = callback; fake->context = context;
    }
    return fake->createError;
}
static OSStatus fakeStart(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    FakeHAL *fake = user; CHECK(identifier == fake->callback); CHECK(device == fake->lastDevice);
    fake->starts++; return fake->startError;
}
static OSStatus fakeStop(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    FakeHAL *fake = user; CHECK(identifier == fake->callback); CHECK(device == fake->lastDevice);
    if (fake->renderDuringStop) {
        uint8_t bytes[12] = {0};
        AudioBufferList output = {.mNumberBuffers = 1, .mBuffers = {{2, 12, bytes}}};
        AudioBufferList input = {.mNumberBuffers = 0};
        AudioTimeStamp stamp = {.mSampleTime = 106, .mHostTime = 4000, .mFlags = kAudioTimeStampSampleHostTimeValid};
        CHECK(fake->callback(device, &stamp, &input, &stamp, &output, &stamp, fake->context) == noErr);
    }
    fake->stops++; return fake->stopError;
}
static OSStatus fakeDestroy(void *user, AudioDeviceID device, AudioDeviceIOProcID identifier) {
    FakeHAL *fake = user; CHECK(identifier == fake->callback); CHECK(device == fake->lastDevice);
    fake->destroys++; return fake->destroyError;
}
static OSStatus fakeAddListener(void *user, AudioObjectID object, const AudioObjectPropertyAddress *address,
                                AudioObjectPropertyListenerProc callback, void *context) {
    (void)object; (void)address; FakeHAL *fake = user;
    if (fake->addListenerError != 0) return fake->addListenerError;
    fake->listener = callback; fake->listenerContext = context; fake->addedListeners++; return noErr;
}
static OSStatus fakeRemoveListener(void *user, AudioObjectID object, const AudioObjectPropertyAddress *address,
                                   AudioObjectPropertyListenerProc callback, void *context) {
    (void)object; (void)address; FakeHAL *fake = user;
    CHECK(fake->listener == callback && fake->listenerContext == context);
    if (fake->removeListenerError != 0) return fake->removeListenerError;
    fake->removedListeners++; return noErr;
}
static SBAudioOutputTestHAL operations(FakeHAL *fake) {
    return (SBAudioOutputTestHAL){ fake, fakeCreate, fakeStart, fakeStop, fakeDestroy, fakeAddListener, fakeRemoveListener };
}
static SBAudioOutputConfiguration configuration(uint32_t frames, uint32_t callbackFrames) {
    return (SBAudioOutputConfiguration){ OWNER, 6, 2, frames, callbackFrames };
}
static SBAudioOutputContext *make(FakeHAL *fake, uint32_t frames, uint32_t callbackFrames) {
    SBAudioOutputContext *context = NULL;
    CHECK(SBAudioOutputCreateForTesting(configuration(frames, callbackFrames), operations(fake), &context) == SBAudioOutputOK);
    CHECK(context != NULL); return context;
}
static SBAudioOutputSnapshot snapshot(SBAudioOutputContext *context) {
    SBAudioOutputSnapshot result;
    CHECK(SBAudioOutputGetSnapshot(context, OWNER, &result) == SBAudioOutputOK); return result;
}
static void closeContext(SBAudioOutputContext **context) {
    CHECK(SBAudioOutputStop(*context, OWNER) == SBAudioOutputOK);
    CHECK(SBAudioOutputDestroy(context, OWNER) == SBAudioOutputOK); CHECK(*context == NULL);
}
static void invoke(FakeHAL *fake, void *buffer, uint32_t byteCount, uint32_t channels, AudioDeviceID device) {
    AudioBufferList list = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = channels, .mDataByteSize = byteCount, .mData = buffer }} };
    AudioTimeStamp time = {0}; AudioBufferList input = {.mNumberBuffers = 0};
    CHECK(fake->callback(device, &time, &input, &time, &list, &time, fake->context) == noErr);
    CHECK(list.mBuffers[0].mDataByteSize == byteCount);
}
static void invokeAt(FakeHAL *fake, void *buffer, uint32_t byteCount, uint32_t channels,
                     double sampleTime, uint64_t hostTime, AudioTimeStampFlags flags) {
    AudioBufferList list = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = channels, .mDataByteSize = byteCount, .mData = buffer }} };
    AudioTimeStamp time = {.mSampleTime = sampleTime, .mHostTime = hostTime, .mFlags = flags};
    AudioBufferList input = {.mNumberBuffers = 0};
    CHECK(fake->callback(91, &time, &input, &time, &list, &time, fake->context) == noErr);
    CHECK(list.mBuffers[0].mDataByteSize == byteCount);
}
static void attachAndStart(SBAudioOutputContext *context) {
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputOK);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputOK);
}

static void boundsAndOwner(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = NULL;
    SBAudioOutputConfiguration bad[] = {
        {{0,0},6,2,8,2}, {OWNER,0,2,8,2}, {OWNER,6,0,8,2}, {OWNER,3,2,8,2},
        {OWNER,10,2,8,2}, {OWNER,6,2,0,1}, {OWNER,6,2,8,0}, {OWNER,6,2,8,9},
        {OWNER,6,2,UINT32_MAX,2}, {OWNER,65536,2,1,1}, {OWNER,6,65536,1,1}
    };
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++) {
        CHECK(SBAudioOutputCreateForTesting(bad[i], operations(&fake), &context) == SBAudioOutputInvalidArgument);
        CHECK(context == NULL);
    }
    context = make(&fake, 8, 2);
    uint8_t bytes[12] = {1};
    CHECK(SBAudioOutputEnqueue(context, OTHER, bytes, sizeof(bytes)) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputAttach(context, OTHER, 91) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputStart(context, OTHER) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputRetire(context, OTHER, SBAudioOutputFaultOwnerRevoked) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputStop(context, OTHER) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputDestroy(&context, OTHER) == SBAudioOutputWrongOwner);
    CHECK(snapshot(context).fault == SBAudioOutputFaultNone);
    CHECK(snapshot(context).acceptedFrames == 0);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, sizeof(bytes)) == SBAudioOutputOK);
    attachAndStart(context);
    CHECK(fake.lastDevice == 91); CHECK(fake.creates == 1); CHECK(fake.starts == 1);
    closeContext(&context);
    CHECK(fake.stops == 1 && fake.destroys == 1);
}

static void exactBytesWrapAndCopies(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 5, 2);
    uint8_t first[24], expectedFirst[24], second[18], output[12];
    for (unsigned i = 0; i < sizeof(first); i++) first[i] = (uint8_t)(i * 17 + 1);
    memcpy(expectedFirst, first, sizeof(first));
    for (unsigned i = 0; i < sizeof(second); i++) second[i] = (uint8_t)(i * 43 + 3);
    CHECK(SBAudioOutputEnqueue(context, OWNER, first, sizeof(first)) == SBAudioOutputOK);
    memset(first, 0, sizeof(first)); /* Native queue owns a copy. */
    attachAndStart(context);
    invoke(&fake, output, sizeof(output), 2, 91); CHECK(memcmp(output, expectedFirst, 12) == 0);
    CHECK(SBAudioOutputEnqueue(context, OWNER, second, sizeof(second)) == SBAudioOutputOK);
    invoke(&fake, output, sizeof(output), 2, 91); CHECK(memcmp(output, expectedFirst + 12, 12) == 0);
    invoke(&fake, output, sizeof(output), 2, 91); CHECK(memcmp(output, second, 12) == 0);
    invoke(&fake, output, 6, 2, 91); CHECK(memcmp(output, second + 12, 6) == 0);
    SBAudioOutputSnapshot status = snapshot(context);
    CHECK(status.acceptedFrames == 7 && status.submittedFrames == 7 && status.queuedFrames == 0);
    CHECK(status.fault == SBAudioOutputFaultNone);
    closeContext(&context);
}

static void invalidInputAndOverflow(void) {
    uint8_t bytes[60] = {0}; FakeHAL fake = {0};
    SBAudioOutputContext *context = make(&fake, 8, 2);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 11) == SBAudioOutputIncompleteFrame);
    CHECK(snapshot(context).fault == SBAudioOutputFaultInvalidInput);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 12) == SBAudioOutputRetired);
    closeContext(&context);
    context = make(&fake, 8, 2);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 48) == SBAudioOutputOK);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 6) == SBAudioOutputQueueFull);
    CHECK(snapshot(context).acceptedFrames == 8 && snapshot(context).submittedFrames == 0);
    CHECK(snapshot(context).fault == SBAudioOutputFaultQueueOverflow);
    closeContext(&context);
    context = make(&fake, 8, 2);
    CHECK(SBAudioOutputSetEmptyCursorForTesting(context, (uint64_t)INT64_MAX / 6) == SBAudioOutputOK);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 6) == SBAudioOutputCounterOverflow);
    CHECK(snapshot(context).fault == SBAudioOutputFaultCounterOverflow);
    closeContext(&context);
    context = make(&fake, 8, 2);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, SIZE_MAX - SIZE_MAX % 6) == SBAudioOutputCounterOverflow);
    CHECK(snapshot(context).acceptedFrames == 0);
    closeContext(&context);
}

static void underrunIsNotSubmittedAndServiceStops(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
    uint8_t source[18]; memset(source, 0x91, sizeof(source)); uint8_t output[12];
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputOK);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputInsufficientPrefill); CHECK(fake.starts == 0);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, sizeof(source)) == SBAudioOutputOK);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputOK);
    invoke(&fake, output, 12, 2, 91); CHECK(memcmp(output, source, 12) == 0);
    memset(output, 0, sizeof(output)); invoke(&fake, output, 12, 2, 91);
    for (unsigned i = 0; i < sizeof(output); i++) CHECK(output[i] == 0);
    SBAudioOutputSnapshot state = snapshot(context);
    CHECK(state.fault == SBAudioOutputFaultUnderrun && state.submittedFrames == 2 && state.queuedFrames == 1 && !state.active);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, 12) == SBAudioOutputRetired);
    CHECK(SBAudioOutputService(context, OWNER) == SBAudioOutputOK);
    CHECK(fake.stops == 1 && fake.destroys == 1);
    CHECK(snapshot(context).fault == SBAudioOutputFaultUnderrun);
    closeContext(&context); CHECK(fake.stops == 1 && fake.destroys == 1);
}

static void changedOutputAndRetirement(void) {
    for (unsigned kind = 0; kind < 5; kind++) {
        FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
        uint8_t source[24] = {1}, output[24] = {0};
        CHECK(SBAudioOutputEnqueue(context, OWNER, source, 24) == SBAudioOutputOK); attachAndStart(context);
        if (kind == 0) invoke(&fake, output, 12, 1, 91);
        if (kind == 1) invoke(&fake, output, 11, 2, 91);
        if (kind == 2) invoke(&fake, output, 18, 2, 91);
        if (kind == 3) invoke(&fake, output, 12, 2, 92);
        if (kind == 4) {
            CHECK(SBAudioOutputRetire(context, OWNER, SBAudioOutputFaultOwnerRevoked) == SBAudioOutputOK);
            invoke(&fake, output, 12, 2, 91);
        }
        CHECK(snapshot(context).submittedFrames == 0); CHECK(!snapshot(context).active);
        CHECK(snapshot(context).fault == (kind == 3 ? SBAudioOutputFaultDeviceMismatch :
            (kind == 4 ? SBAudioOutputFaultOwnerRevoked : SBAudioOutputFaultOutputLayoutChanged)));
        CHECK(SBAudioOutputService(context, OWNER) == SBAudioOutputOK); closeContext(&context);
    }
}

static void unsigned8FaultSilenceIsBiasedAndUncounted(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = NULL;
    SBAudioOutputConfiguration config = {OWNER, 1, 1, 4, 2};
    CHECK(SBAudioOutputCreateForTesting(config, operations(&fake), &context) == SBAudioOutputOK);
    uint8_t source[2] = {1, 255}, output[2] = {0};
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, 2) == SBAudioOutputOK); attachAndStart(context);
    invoke(&fake, output, 2, 1, 91); CHECK(memcmp(source, output, 2) == 0);
    memset(output, 0, 2); invoke(&fake, output, 2, 1, 91);
    CHECK(output[0] == 0x80 && output[1] == 0x80);
    CHECK(snapshot(context).fault == SBAudioOutputFaultUnderrun && snapshot(context).submittedFrames == 2);
    closeContext(&context);
}

static void cleanupFailuresRetainResourcesAndRetry(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2); uint8_t bytes[12] = {1};
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, sizeof(bytes)) == SBAudioOutputOK); attachAndStart(context);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputInvalidState);
    fake.stopError = -51;
    CHECK(SBAudioOutputStop(context, OWNER) == SBAudioOutputHALStopFailed);
    CHECK(snapshot(context).registered && snapshot(context).startAttempted && !snapshot(context).active);
    CHECK(snapshot(context).lastHALStatus == -51 && fake.destroys == 0);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputInvalidState);
    fake.stopError = 0; fake.destroyError = -52;
    CHECK(SBAudioOutputStop(context, OWNER) == SBAudioOutputHALDestroyFailed);
    CHECK(snapshot(context).registered && !snapshot(context).startAttempted);
    CHECK(snapshot(context).lastHALStatus == -52);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputInvalidState);
    fake.destroyError = 0; closeContext(&context);
    CHECK(fake.stops == 2 && fake.destroys == 2);
}

static void failedStartAndPartialCreateAreStillCleaned(void) {
    FakeHAL fake = {.startError = -61}; SBAudioOutputContext *context = make(&fake, 8, 2);
    uint8_t bytes[12] = {0}; CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 12) == SBAudioOutputOK);
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputOK);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputHALStartFailed);
    CHECK(snapshot(context).fault == SBAudioOutputFaultStartFailed && snapshot(context).lastHALStatus == -61);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputRetired);
    closeContext(&context); CHECK(fake.stops == 1 && fake.destroys == 1);
    fake = (FakeHAL){.createError = -62, .identifierOnFailure = true}; context = make(&fake, 8, 2);
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputHALCreateFailed);
    CHECK(snapshot(context).registered && snapshot(context).fault == SBAudioOutputFaultCreateFailed);
    CHECK(SBAudioOutputService(context, OWNER) == SBAudioOutputOK); closeContext(&context);
    CHECK(fake.stops == 0 && fake.destroys == 1);
    fake = (FakeHAL){.missingIdentifier = true}; context = make(&fake, 8, 2);
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputHALCreateFailed);
    CHECK(!snapshot(context).registered); closeContext(&context); CHECK(fake.destroys == 0);
}

static void propertyFaultDisarmsAndListenerCleanupRetainsContext(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2); uint8_t source[12] = {1}, output[12] = {0};
    AudioObjectPropertyAddress property = { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CHECK(SBAudioOutputWatchProperty(context, OTHER, 91, property) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputWatchProperty(context, OWNER, 91, property) == SBAudioOutputOK);
    CHECK(SBAudioOutputWatchProperty(context, OWNER, 91, property) == SBAudioOutputInvalidState);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, 12) == SBAudioOutputOK); attachAndStart(context);
    CHECK(fake.listener(91, 1, &property, fake.listenerContext) == noErr);
    invoke(&fake, output, 12, 2, 91);
    CHECK(snapshot(context).fault == SBAudioOutputFaultDeviceChanged && snapshot(context).submittedFrames == 0);
    CHECK(snapshot(context).registeredListeners == 1);
    fake.removeListenerError = -71;
    CHECK(SBAudioOutputService(context, OWNER) == SBAudioOutputHALRemoveListenerFailed);
    CHECK(!snapshot(context).registered && snapshot(context).registeredListeners == 1);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputInvalidState);
    fake.removeListenerError = 0; closeContext(&context);
    CHECK(fake.addedListeners == 1 && fake.removedListeners == 1);
}

typedef struct { atomic_bool entered; atomic_bool release; } Pause;
static void pauseBeforeRender(void *user) {
    Pause *pause = user; atomic_store_explicit(&pause->entered, true, memory_order_release);
    while (!atomic_load_explicit(&pause->release, memory_order_acquire)) sched_yield();
}
static void *invokeThread(void *user) {
    uint8_t output[12] = {0}; invoke(user, output, 12, 2, 91);
    for (unsigned i = 0; i < sizeof(output); i++) CHECK(output[i] == 0);
    return NULL;
}
static void inFlightCallbackCannotBeFreed(void) {
    Pause pause; atomic_init(&pause.entered, false); atomic_init(&pause.release, false);
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2); uint8_t bytes[12] = {1};
    CHECK(SBAudioOutputSetRenderHookForTesting(context, pauseBeforeRender, &pause) == SBAudioOutputOK);
    CHECK(SBAudioOutputEnqueue(context, OWNER, bytes, 12) == SBAudioOutputOK); attachAndStart(context);
    pthread_t thread; CHECK(pthread_create(&thread, NULL, invokeThread, &fake) == 0);
    while (!atomic_load_explicit(&pause.entered, memory_order_acquire)) sched_yield();
    CHECK(snapshot(context).callbacksInFlight == 1);
    CHECK(SBAudioOutputStop(context, OWNER) == SBAudioOutputCallbackInFlight);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputCallbackInFlight);
    atomic_store_explicit(&pause.release, true, memory_order_release); CHECK(pthread_join(thread, NULL) == 0);
    CHECK(snapshot(context).submittedFrames == 0); closeContext(&context);
}

typedef struct {
    FakeHAL *fake;
    atomic_uint produced;
    atomic_uint consumed;
} SPSC;
enum { ROUNDS = 12000, FRAMES = 2, CHUNK = FRAMES * 6 };
static void fillChunk(uint8_t *bytes, unsigned sequence) {
    for (unsigned i = 0; i < CHUNK; i++) bytes[i] = (uint8_t)(sequence * 71 + i * 29);
}
static void *consumeThread(void *user) {
    SPSC *run = user;
    for (unsigned sequence = 0; sequence < ROUNDS; sequence++) {
        while (atomic_load_explicit(&run->produced, memory_order_acquire) <= sequence) sched_yield();
        uint8_t actual[CHUNK], expected[CHUNK]; fillChunk(expected, sequence);
        invoke(run->fake, actual, CHUNK, 2, 91); CHECK(memcmp(actual, expected, CHUNK) == 0);
        atomic_store_explicit(&run->consumed, sequence + 1, memory_order_release);
    }
    return NULL;
}
static void concurrentSPSCWrapIsExact(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, FRAMES);
    uint8_t chunk[CHUNK]; fillChunk(chunk, 0); CHECK(SBAudioOutputEnqueue(context, OWNER, chunk, CHUNK) == SBAudioOutputOK);
    attachAndStart(context);
    SPSC run = {.fake = &fake}; atomic_init(&run.produced, 1); atomic_init(&run.consumed, 0);
    pthread_t consumer; CHECK(pthread_create(&consumer, NULL, consumeThread, &run) == 0);
    for (unsigned sequence = 1; sequence < ROUNDS; sequence++) {
        while (sequence - atomic_load_explicit(&run.consumed, memory_order_acquire) >= 4) sched_yield();
        fillChunk(chunk, sequence); CHECK(SBAudioOutputEnqueue(context, OWNER, chunk, CHUNK) == SBAudioOutputOK);
        atomic_store_explicit(&run.produced, sequence + 1, memory_order_release);
    }
    CHECK(pthread_join(consumer, NULL) == 0);
    SBAudioOutputSnapshot state = snapshot(context);
    CHECK(state.acceptedFrames == ROUNDS * FRAMES && state.submittedFrames == ROUNDS * FRAMES);
    CHECK(state.queuedFrames == 0 && state.fault == SBAudioOutputFaultNone); closeContext(&context);
}

static void finiteTailPreservesSourceAndCountsOnlyActualPadding(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
    uint8_t source[18], output[12];
    for (unsigned i = 0; i < sizeof(source); i++) source[i] = (uint8_t)(i * 13 + 1);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, sizeof(source)) == SBAudioOutputOK);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 3, 8) == SBAudioOutputOK);
    attachAndStart(context);
    invokeAt(&fake, output, 12, 2, 100, 1000, kAudioTimeStampSampleHostTimeValid);
    CHECK(memcmp(output, source, 12) == 0);
    memset(output, 0x77, sizeof(output));
    invokeAt(&fake, output, 12, 2, 102, 2000, kAudioTimeStampSampleHostTimeValid);
    CHECK(memcmp(output, source + 12, 6) == 0);
    for (unsigned i = 6; i < 12; i++) CHECK(output[i] == 0);
    SBAudioOutputSnapshot state = snapshot(context);
    CHECK(state.acceptedFrames == 3 && state.submittedFrames == 3 && state.queuedFrames == 0);
    CHECK(state.trailingPaddingFrames == 1 && state.lastSourceEndSampleTime == 103 && state.sourceTimelineValid);
    memset(output, 0x77, sizeof(output));
    invokeAt(&fake, output, 12, 2, 104, 3000, kAudioTimeStampSampleHostTimeValid);
    for (unsigned i = 0; i < 12; i++) CHECK(output[i] == 0);
    state = snapshot(context);
    CHECK(state.submittedFrames == 3 && state.trailingPaddingFrames == 3 && state.lastSourceEndSampleTime == 103);
    fake.renderDuringStop = true;
    CHECK(SBAudioOutputStopAfterDrain(context, OWNER) == SBAudioOutputOK);
    CHECK(snapshot(context).fault == SBAudioOutputFaultNone);
    CHECK(snapshot(context).trailingPaddingFrames == 5 && snapshot(context).submittedFrames == 3);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputOK);
}

static void sealedShortUnsignedInputAndEmptyInput(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = NULL;
    SBAudioOutputConfiguration config = {OWNER, 2, 2, 8, 2};
    CHECK(SBAudioOutputCreateForTesting(config, operations(&fake), &context) == SBAudioOutputOK);
    uint8_t source[2] = {0x00, 0xff}, output[4];
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, 2) == SBAudioOutputOK);
    CHECK(SBAudioOutputFinishInput(context, OTHER, 1, 8) == SBAudioOutputWrongOwner);
    CHECK(SBAudioOutputFinishInput(context, OWNER, UINT64_MAX, 8) == SBAudioOutputSourceCountMismatch);
    CHECK(!snapshot(context).inputFinished && snapshot(context).fault == SBAudioOutputFaultNone);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 1, 8) == SBAudioOutputOK);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 1, 8) == SBAudioOutputOK);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, 2) == SBAudioOutputInvalidState);
    CHECK(snapshot(context).acceptedFrames == 1 && snapshot(context).fault == SBAudioOutputFaultNone);
    attachAndStart(context);
    invokeAt(&fake, output, 4, 2, 10, 100, kAudioTimeStampSampleHostTimeValid);
    CHECK(output[0] == 0 && output[1] == 255 && output[2] == 128 && output[3] == 128);
    CHECK(snapshot(context).submittedFrames == 1 && snapshot(context).trailingPaddingFrames == 1);
    closeContext(&context);
    fake = (FakeHAL){0}; context = make(&fake, 8, 2);
    CHECK(SBAudioOutputAttach(context, OWNER, 91) == SBAudioOutputOK);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 0, 8) == SBAudioOutputOK);
    CHECK(SBAudioOutputStart(context, OWNER) == SBAudioOutputInsufficientPrefill);
    CHECK(fake.starts == 0 && !snapshot(context).sourceTimelineValid);
    CHECK(SBAudioOutputStopAfterDrain(context, OWNER) == SBAudioOutputOK);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputOK);
    CHECK(fake.stops == 0 && fake.destroys == 1);
}

static void lateEOFRetainsFinalFullSourceTimestamp(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
    uint8_t source[12] = {1}, output[12];
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, sizeof(source)) == SBAudioOutputOK);
    attachAndStart(context);
    invokeAt(&fake, output, 12, 2, 100, 1000, kAudioTimeStampSampleHostTimeValid);
    CHECK(snapshot(context).lastSourceEndSampleTime == 102 && snapshot(context).sourceTimelineValid);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 2, 8) == SBAudioOutputOK);
    invokeAt(&fake, output, 12, 2, 102, 2000, kAudioTimeStampSampleHostTimeValid);
    CHECK(snapshot(context).lastSourceEndSampleTime == 102 && snapshot(context).submittedFrames == 2);
    CHECK(snapshot(context).trailingPaddingFrames == 2);
    CHECK(SBAudioOutputStopAfterDrain(context, OWNER) == SBAudioOutputOK);
    CHECK(snapshot(context).fault == SBAudioOutputFaultNone);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputOK);
}

static void invalidTimelineAndBoundedPaddingNeverBecomeSuccess(void) {
    for (unsigned kind = 0; kind < 5; kind++) {
        FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
        uint8_t source[12] = {1}, output[12] = {0};
        CHECK(SBAudioOutputEnqueue(context, OWNER, source, sizeof(source)) == SBAudioOutputOK);
        CHECK(SBAudioOutputFinishInput(context, OWNER, 2, 2) == SBAudioOutputOK);
        attachAndStart(context);
        if (kind == 0) invokeAt(&fake, output, 12, 2, 100, 100, 0);
        else if (kind == 1) invokeAt(&fake, output, 12, 2, NAN, 100, kAudioTimeStampSampleHostTimeValid);
        else {
            invokeAt(&fake, output, 12, 2, 100, 100, kAudioTimeStampSampleHostTimeValid);
            if (kind == 2) invokeAt(&fake, output, 12, 2, 101, 200, kAudioTimeStampSampleHostTimeValid);
            if (kind == 3) invokeAt(&fake, output, 12, 2, 102, 99, kAudioTimeStampSampleHostTimeValid);
            if (kind == 4) {
                invokeAt(&fake, output, 12, 2, 102, 200, kAudioTimeStampSampleHostTimeValid);
                invokeAt(&fake, output, 12, 2, 104, 300, kAudioTimeStampSampleHostTimeValid);
            }
        }
        CHECK(snapshot(context).fault == (kind == 4 ? SBAudioOutputFaultPaddingLimit : SBAudioOutputFaultInvalidTimeline));
        CHECK(snapshot(context).trailingPaddingFrames == (kind == 4 ? 2 : 0));
        closeContext(&context);
    }
}

static void cleanStopPreservesDeviceFaultAndStopFailureObligation(void) {
    FakeHAL fake = {0}; SBAudioOutputContext *context = make(&fake, 8, 2);
    uint8_t source[12] = {1}, output[12];
    AudioObjectPropertyAddress property = {kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    CHECK(SBAudioOutputWatchProperty(context, OWNER, 91, property) == SBAudioOutputOK);
    CHECK(SBAudioOutputEnqueue(context, OWNER, source, sizeof(source)) == SBAudioOutputOK);
    CHECK(SBAudioOutputFinishInput(context, OWNER, 2, 8) == SBAudioOutputOK);
    attachAndStart(context);
    invokeAt(&fake, output, 12, 2, 100, 100, kAudioTimeStampSampleHostTimeValid);
    CHECK(fake.listener(91, 1, &property, fake.listenerContext) == noErr);
    fake.stopError = -51;
    CHECK(SBAudioOutputStopAfterDrain(context, OWNER) == SBAudioOutputHALStopFailed);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputInvalidState);
    fake.stopError = 0;
    CHECK(SBAudioOutputStopAfterDrain(context, OWNER) == SBAudioOutputOK);
    CHECK(snapshot(context).fault == SBAudioOutputFaultDeviceChanged);
    CHECK(SBAudioOutputDestroy(&context, OWNER) == SBAudioOutputOK);
}

int main(void) {
    boundsAndOwner(); exactBytesWrapAndCopies(); invalidInputAndOverflow();
    underrunIsNotSubmittedAndServiceStops(); changedOutputAndRetirement(); unsigned8FaultSilenceIsBiasedAndUncounted();
    cleanupFailuresRetainResourcesAndRetry(); failedStartAndPartialCreateAreStillCleaned();
    propertyFaultDisarmsAndListenerCleanupRetainsContext();
    inFlightCallbackCannotBeFreed(); concurrentSPSCWrapIsExact();
    finiteTailPreservesSourceAndCountsOnlyActualPadding(); sealedShortUnsignedInputAndEmptyInput();
    lateEOFRetainsFinalFullSourceTimestamp(); invalidTimelineAndBoundedPaddingNeverBecomeSuccess();
    cleanStopPreservesDeviceFaultAndStopFailureObligation();
    puts("PASS: 16 native audio suites; fake HAL only; 12000 concurrent SPSC transfers");
    return 0;
}
