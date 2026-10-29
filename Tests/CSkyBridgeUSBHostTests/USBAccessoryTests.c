#include "USBAccessoryInternal.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static const char nonce[] = "12345678-9abc-4def-8abc-123456789abc";
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    atomic_bool allowed;
    unsigned acquired, calls, closed, destroyed, clockCalls;
    int failingStep, shortStep, unknownCountStep, cancelAfter, expireAfter, clockFailureAt;
    uint16_t version;
    SBUSBLinkProfile linkProfile;
    uint64_t now;
    uint32_t lastTimeout;
    bool acquireFailure, released, closeFailure, block, entered, proceed;
} Fixture;
static void init(Fixture *f) {
    memset(f, 0, sizeof(*f));
    CHECK(pthread_mutex_init(&f->mutex, NULL) == 0); CHECK(pthread_cond_init(&f->changed, NULL) == 0);
    atomic_init(&f->allowed, true);
    f->failingStep = f->shortStep = f->unknownCountStep = f->cancelAfter = f->expireAfter = -1;
    f->version = 2; f->linkProfile = SB_USB_LINK_RAW_YAMUX_V1; f->now = 1000; f->released = true;
}
static SBUSBResult failure(SBUSBPhase phase) {
    SBUSBResult r = SBUSBResultMake(SB_USB_NATIVE_FAILURE, phase);
    r.domain = SB_USB_DOMAIN_IORETURN; r.nativeCode = -77; return r;
}
static SBUSBResult acquire(void *context, uint64_t registryID) {
    Fixture *f = context; CHECK(registryID == 123); f->acquired++;
    return f->acquireFailure ? failure(SB_USB_PHASE_PLUGIN) : SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_QUERY_INTERFACE);
}
static bool authorized(void *context) { return atomic_load(&((Fixture *)context)->allowed); }
static SBUSBResult clockRead(void *context, uint64_t *value) {
    Fixture *f = context; f->clockCalls++;
    if (f->clockFailureAt && f->clockCalls == (unsigned)f->clockFailureAt) return failure(SB_USB_PHASE_NONE);
    *value = f->now; return SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_NONE);
}
static SBUSBResult request(void *context, uint8_t type, uint8_t request, uint16_t index,
                           void *data, uint16_t length, uint32_t timeout) {
    Fixture *f = context;
    unsigned step = f->calls++; CHECK(step < 8 && timeout > 0 && timeout <= 2000); f->lastTimeout = timeout;
    CHECK(pthread_mutex_lock(&f->mutex) == 0); f->entered = true; CHECK(pthread_cond_broadcast(&f->changed) == 0);
    struct timespec until; CHECK(clock_gettime(CLOCK_REALTIME, &until) == 0); until.tv_sec += 3;
    while (f->block && !f->proceed) CHECK(pthread_cond_timedwait(&f->changed, &f->mutex, &until) == 0);
    CHECK(pthread_mutex_unlock(&f->mutex) == 0);
    if (step == 0) {
        CHECK(type == 0xc0 && request == 51 && index == 0 && length == 2 && data);
        ((uint8_t *)data)[0] = (uint8_t)f->version; ((uint8_t *)data)[1] = (uint8_t)(f->version >> 8);
    } else if (step == 7) CHECK(type == 0x40 && request == 53 && index == 0 && length == 0 && data == NULL);
    else {
        const char *strings[] = {"SkyBridge", "SkyBridge USB Link", "SkyBridge USB connection",
            f->linkProfile == SB_USB_LINK_EPOCH_V2 ? "2" : "1",
            "skybridge-usb://attachment/12345678-9abc-4def-8abc-123456789abc", nonce};
        CHECK(type == 0x40 && request == 52 && index == step - 1 && length == strlen(strings[index]) + 1 && data);
        CHECK(memcmp(data, strings[index], length) == 0);
    }
    if ((int)step == f->cancelAfter) atomic_store(&f->allowed, false);
    if ((int)step == f->expireAfter) f->now = 19000;
    if ((int)step == f->failingStep) return failure(SB_USB_PHASE_ACCESSORY_QUERY);
    SBUSBResult r = SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_ACCESSORY_QUERY);
    r.byteCountKnown = (int)step != f->unknownCountStep;
    r.bytesTransferred = (int)step == f->shortStep ? (length ? length - 1u : 1u) : length;
    return r;
}
static SBUSBResult closeDriver(void *context, bool *released) {
    Fixture *f = context; f->closed++; *released = f->released;
    return f->closeFailure ? failure(SB_USB_PHASE_RELEASE) : SBUSBResultMake(SB_USB_OK, SB_USB_PHASE_RELEASE);
}
static void destroy(void *context) { ((Fixture *)context)->destroyed++; }
static const SBAOADriverOperations ops = {acquire, request, clockRead, closeDriver, destroy};
static SBAOAHandle *create(Fixture *f) {
    SBUSBResult r; SBAOAHandle *h = SBAOACreateWithDriver(f, &ops, &r); CHECK(h && r.status == SB_USB_OK); return h;
}
static void dispose(SBAOAHandle **h, Fixture *f) {
    CHECK(SBAOATryClose(*h).status == SB_USB_OK); CHECK(SBAOAGetSnapshot(*h).ownedReferencesReleased);
    CHECK(SBAOADestroy(h).status == SB_USB_OK && !*h && f->destroyed == 1);
    CHECK(pthread_cond_destroy(&f->changed) == 0); CHECK(pthread_mutex_destroy(&f->mutex) == 0);
}
static SBUSBResult run(SBAOAHandle *h, Fixture *f, bool start) {
    return SBAOARun(h, 123, start ? nonce : NULL, start ? 36 : 0, start, authorized, f);
}
static unsigned cases;
static void passed(const char *name) { printf("PASS %s\n", name); cases++; }

static void success(void) {
    for (unsigned start = 0; start < 2; start++) for (unsigned version = 1; version <= 2; version++) {
        Fixture f; init(&f); f.version = (uint16_t)version; SBAOAHandle *h = create(&f);
        CHECK(run(h, &f, start).status == SB_USB_OK);
        SBAOASnapshot s = SBAOAGetSnapshot(h);
        CHECK(s.started && !s.running && s.protocolVersion == version && s.deviceRegistryID == 123);
        CHECK(s.requestedLinkProfile == (start ? SB_USB_LINK_RAW_YAMUX_V1 : SB_USB_LINK_QUERY_ONLY));
        CHECK(f.calls == (start ? 8u : 1u) && f.acquired == 1);
        CHECK(s.identificationAttempted == (start ? 6 : 0) && s.identificationCompleted == s.identificationAttempted);
        CHECK(s.startRequested == (bool)start && s.startCompletionConfirmed == (bool)start);
        CHECK(run(h, &f, start).status == SB_USB_ALREADY_STARTED);
        dispose(&h, &f); passed(start ? "start-v1-or-v2" : "query-only-v1-or-v2");
    }
}
static void explicitProfiles(void) {
    for (unsigned profile = 1; profile <= 2; profile++) for (unsigned version = 1; version <= 2; version++) {
        Fixture f; init(&f); f.version = (uint16_t)version; f.linkProfile = (SBUSBLinkProfile)profile;
        SBAOAHandle *h = create(&f);
        CHECK(SBAOARunWithProfile(h, 123, nonce, 36, f.linkProfile, authorized, &f).status == SB_USB_OK);
        SBAOASnapshot s = SBAOAGetSnapshot(h);
        CHECK(s.requestedLinkProfile == f.linkProfile && s.protocolVersion == version);
        CHECK(s.identificationCompleted == 6 && s.startCompletionConfirmed && f.calls == 8);
        dispose(&h, &f); passed("explicit-application-profile-independent-of-aoa-version");
    }
    for (int profile = -1; profile <= 3; profile += 4) {
        Fixture f; init(&f); SBAOAHandle *h = create(&f);
        CHECK(SBAOARunWithProfile(h, 123, nonce, 36, (SBUSBLinkProfile)profile, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
        CHECK(!SBAOAGetSnapshot(h).started && f.acquired == 0 && f.calls == 0);
        dispose(&h, &f); passed("unknown-profile-rejected-before-acquisition");
    }
    Fixture f; init(&f); SBAOAHandle *h = create(&f);
    CHECK(SBAOARunWithProfile(h, 123, NULL, 0, SB_USB_LINK_EPOCH_V2, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBAOARunWithProfile(h, 123, nonce, 36, SB_USB_LINK_QUERY_ONLY, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(!SBAOAGetSnapshot(h).started && f.acquired == 0 && f.calls == 0);
    dispose(&h, &f); passed("profile-cannot-substitute-query-or-attachment-nonce");
}
static void failures(void) {
    for (unsigned profile = 1; profile <= 2; profile++)
    for (int step = 0; step < 8; step++) for (unsigned kind = 0; kind < 4; kind++) {
        Fixture f; init(&f); f.linkProfile = (SBUSBLinkProfile)profile;
        if (kind == 0) f.failingStep = step;
        if (kind == 1) f.shortStep = step;
        if (kind == 2) f.unknownCountStep = step;
        if (kind == 3) f.cancelAfter = step;
        SBAOAHandle *h = create(&f);
        SBUSBResult r = SBAOARunWithProfile(h, 123, nonce, 36, f.linkProfile, authorized, &f);
        CHECK(r.status == (kind == 0 ? SB_USB_NATIVE_FAILURE : kind == 3 ? SB_USB_CANCELLED : SB_USB_BAD_RESPONSE));
        CHECK(f.calls == (unsigned)step + 1 && f.acquired == 1);
        SBAOASnapshot s = SBAOAGetSnapshot(h);
        CHECK(s.requestedLinkProfile == f.linkProfile);
        unsigned writes = step > 6 ? 6u : (unsigned)step;
        CHECK(s.identificationAttempted == writes);
        CHECK(s.identificationCompleted == writes - (step > 0 && step < 7 && kind != 3 ? 1u : 0u));
        CHECK(s.startRequested == (step == 7) && s.startCompletionConfirmed == (step == 7 && kind == 3));
        if (kind == 0) CHECK(r.domain == SB_USB_DOMAIN_IORETURN && r.nativeCode == -77);
        CHECK(s.operationResult.status == r.status); dispose(&h, &f); passed("exact-request-failure-or-cancellation");
    }
    for (unsigned version = 0; version < 3; version++) {
        Fixture f; init(&f); f.version = version == 0 ? 0 : version == 1 ? 3 : 256;
        SBAOAHandle *h = create(&f); CHECK(run(h, &f, true).status == SB_USB_UNSUPPORTED_PROTOCOL);
        CHECK(f.calls == 1); dispose(&h, &f); passed("unsupported-or-wrong-endian-protocol");
    }
}
static void acquisitionAndBudgets(void) {
    for (unsigned kind = 0; kind < 5; kind++) {
        Fixture f; init(&f);
        if (kind == 0) atomic_store(&f.allowed, false);
        if (kind == 1) f.acquireFailure = true;
        if (kind == 2) f.expireAfter = 0;
        if (kind == 3) f.expireAfter = 7;
        if (kind == 4) f.clockFailureAt = 2;
        SBAOAHandle *h = create(&f); SBUSBResult r = run(h, &f, true); CHECK(r.status != SB_USB_OK);
        CHECK(f.calls == (kind == 2 ? 1u : kind == 3 ? 8u : 0u));
        CHECK(SBAOAGetSnapshot(h).startCompletionConfirmed == (kind == 3));
        dispose(&h, &f); passed("bounded-acquisition-and-clock-failure");
    }
}
static void malformed(void) {
    const char *invalid[] = {"00000000-0000-0000-0000-000000000000", "12345678-9ABC-4def-8abc-123456789abc",
        "123456789abc-4def-8abc-123456789abc-", "12345678-9abc-4def-8abc-123456789abz"};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        Fixture f; init(&f); SBAOAHandle *h = create(&f);
        CHECK(SBAOARun(h, 123, invalid[i], 36, true, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
        CHECK(!SBAOAGetSnapshot(h).started && f.acquired == 0 && f.calls == 0);
        dispose(&h, &f); passed("malformed-attachment-nonce");
    }
    Fixture f; init(&f); SBAOAHandle *h = create(&f);
    CHECK(SBAOARun(h, 0, nonce, 36, true, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBAOARun(h, 123, nonce, 35, true, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBAOARun(h, 123, nonce, 36, false, authorized, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBAOARun(h, 123, nonce, 36, true, NULL, &f).status == SB_USB_INVALID_ARGUMENT);
    CHECK(!SBAOAGetSnapshot(h).started && f.calls == 0); dispose(&h, &f); passed("invalid-call-does-not-acquire");
}
typedef struct { SBAOAHandle *h; Fixture *fixture; SBUSBResult result; } Job;
static void *worker(void *opaque) { Job *job = opaque; job->result = run(job->h, job->fixture, true); return NULL; }
static void concurrentClose(void) {
    Fixture f; init(&f); f.block = true; SBAOAHandle *h = create(&f); Job job = {h, &f, {0}}; pthread_t thread;
    CHECK(pthread_create(&thread, NULL, worker, &job) == 0);
    CHECK(pthread_mutex_lock(&f.mutex) == 0);
    struct timespec until; CHECK(clock_gettime(CLOCK_REALTIME, &until) == 0); until.tv_sec += 3;
    while (!f.entered) CHECK(pthread_cond_timedwait(&f.changed, &f.mutex, &until) == 0);
    CHECK(pthread_mutex_unlock(&f.mutex) == 0);
    CHECK(SBAOAGetSnapshot(h).running);
    CHECK(run(h, &f, true).status == SB_USB_ALREADY_STARTED);
    CHECK(SBAOATryClose(h).status == SB_USB_BUSY);
    CHECK(SBAOADestroy(&h).status == SB_USB_CLEANUP_UNCONFIRMED && h);
    CHECK(f.closed == 0 && f.destroyed == 0);
    CHECK(pthread_mutex_lock(&f.mutex) == 0); f.proceed = true; CHECK(pthread_cond_broadcast(&f.changed) == 0);
    CHECK(pthread_mutex_unlock(&f.mutex) == 0); CHECK(pthread_join(thread, NULL) == 0);
    CHECK(job.result.status == SB_USB_CANCELLED && f.calls == 1); dispose(&h, &f); passed("close-cannot-destroy-active-worker");
}
static void cleanup(void) {
    Fixture f; init(&f); SBAOAHandle *h = create(&f); CHECK(run(h, &f, true).status == SB_USB_OK);
    f.released = false;
    CHECK(SBAOATryClose(h).status == SB_USB_CLEANUP_UNCONFIRMED);
    CHECK(SBAOADestroy(&h).status == SB_USB_CLEANUP_UNCONFIRMED && h && f.destroyed == 0);
    f.released = true; dispose(&h, &f); passed("retain-unconfirmed-native-release");
    init(&f); h = create(&f); CHECK(run(h, &f, true).status == SB_USB_OK); f.closeFailure = true;
    CHECK(SBAOATryClose(h).status == SB_USB_NATIVE_FAILURE);
    CHECK(SBAOAGetSnapshot(h).ownedReferencesReleased && SBAOAGetSnapshot(h).startCompletionConfirmed);
    CHECK(SBAOADestroy(&h).status == SB_USB_NATIVE_FAILURE && !h && f.destroyed == 1);
    CHECK(pthread_cond_destroy(&f.changed) == 0); CHECK(pthread_mutex_destroy(&f.mutex) == 0); passed("release-error-is-not-success");
}
int main(void) {
    success(); explicitProfiles(); failures(); acquisitionAndBudgets(); malformed(); concurrentClose(); cleanup();
    SBUSBResult r; SBAOAHandle *native = SBAOACreate(&r); CHECK(native && r.status == SB_USB_OK);
    Fixture f; init(&f);
    CHECK(SBAOARun(native, UINT64_MAX, NULL, 0, false, authorized, &f).status == SB_USB_UNAVAILABLE);
    CHECK(SBAOATryClose(native).status == SB_USB_OK && SBAOAGetSnapshot(native).ownedReferencesReleased);
    CHECK(SBAOADestroy(&native).status == SB_USB_OK && !native);
    CHECK(pthread_cond_destroy(&f.changed) == 0); CHECK(pthread_mutex_destroy(&f.mutex) == 0); passed("native-absent-registry-release");
    printf("PASS %u accessory boundary cases\n", cases); return 0;
}
