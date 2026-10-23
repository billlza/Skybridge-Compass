// Private lifecycle fault injection. No fixture here proves device/driver behaviour.
#include "USBHostInternal.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
enum Call { OPEN, READ, WRITE, ABORT, CLOSE, CALLS };
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    unsigned blocked, entered, proceed, counts[CALLS], destroyed;
    SBUSBResult results[CALLS];
    bool released;
} Fixture;

static struct timespec deadline(void) {
    struct timespec result; CHECK(clock_gettime(CLOCK_REALTIME, &result) == 0);
    result.tv_sec += 3; return result;
}
static void initialize(Fixture *fixture) {
    memset(fixture, 0, sizeof(*fixture));
    CHECK(pthread_mutex_init(&fixture->mutex, NULL) == 0);
    CHECK(pthread_cond_init(&fixture->changed, NULL) == 0);
    SBUSBPhase phases[] = {SB_USB_PHASE_OPEN, SB_USB_PHASE_READ, SB_USB_PHASE_WRITE, SB_USB_PHASE_ABORT, SB_USB_PHASE_CLOSE};
    for (unsigned i = 0; i < CALLS; i++) fixture->results[i] = SBUSBResultMake(SB_USB_OK, phases[i]);
    fixture->results[READ].byteCountKnown = true; fixture->results[READ].bytesTransferred = 7;
    fixture->results[WRITE].byteCountKnown = true; fixture->results[WRITE].bytesTransferred = 7;
    fixture->released = true;
}
static void finish(Fixture *fixture) {
    CHECK(fixture->destroyed == 1);
    CHECK(pthread_cond_destroy(&fixture->changed) == 0);
    CHECK(pthread_mutex_destroy(&fixture->mutex) == 0);
}
static SBUSBResult enter(Fixture *fixture, enum Call call) {
    CHECK(pthread_mutex_lock(&fixture->mutex) == 0);
    fixture->counts[call]++; fixture->entered |= 1u << call;
    CHECK(pthread_cond_broadcast(&fixture->changed) == 0);
    struct timespec until = deadline();
    while ((fixture->blocked & (1u << call)) && !(fixture->proceed & (1u << call)))
        CHECK(pthread_cond_timedwait(&fixture->changed, &fixture->mutex, &until) == 0);
    SBUSBResult result = fixture->results[call];
    CHECK(pthread_mutex_unlock(&fixture->mutex) == 0); return result;
}
static void awaitEntry(Fixture *fixture, enum Call call) {
    CHECK(pthread_mutex_lock(&fixture->mutex) == 0);
    struct timespec until = deadline();
    while (!(fixture->entered & (1u << call)))
        CHECK(pthread_cond_timedwait(&fixture->changed, &fixture->mutex, &until) == 0);
    CHECK(pthread_mutex_unlock(&fixture->mutex) == 0);
}
static void permit(Fixture *fixture, enum Call call) {
    CHECK(pthread_mutex_lock(&fixture->mutex) == 0);
    fixture->proceed |= 1u << call; CHECK(pthread_cond_broadcast(&fixture->changed) == 0);
    CHECK(pthread_mutex_unlock(&fixture->mutex) == 0);
}
static SBUSBResult openFixture(void *opaque, uint64_t registryID, SBUSBDeviceInfo *device) {
    CHECK(registryID == 123); device->deviceRegistryID = registryID;
    device->interfaceRegistryID = 456; device->vendorID = 0x18d1; device->productID = 0x2d01;
    return enter(opaque, OPEN);
}
static SBUSBResult readFixture(void *opaque, void *buffer, uint32_t count, uint32_t timeout) {
    CHECK(count == SB_USB_TRANSFER_BYTES && timeout == 1250);
    SBUSBResult result = enter(opaque, READ); memset(buffer, 0x6b, count); return result;
}
static SBUSBResult writeFixture(void *opaque, const void *buffer, uint32_t count, uint32_t timeout) {
    CHECK(count == 7 && timeout == 1250 && ((const uint8_t *)buffer)[0] == 0xa3);
    return enter(opaque, WRITE);
}
static SBUSBResult abortFixture(void *opaque) { return enter(opaque, ABORT); }
static SBUSBResult closeFixture(void *opaque, bool *released) {
    SBUSBResult result = enter(opaque, CLOSE); *released = ((Fixture *)opaque)->released; return result;
}
static void destroyFixture(void *opaque) { ((Fixture *)opaque)->destroyed++; }
static const SBUSBDriverOperations operations = {openFixture, readFixture, writeFixture, abortFixture, closeFixture, destroyFixture};
static SBUSBHandle *create(Fixture *fixture) {
    SBUSBResult result; SBUSBHandle *handle = SBUSBCreateWithDriver(fixture, &operations, &result);
    CHECK(handle && result.status == SB_USB_OK); return handle;
}
static SBUSBHandle *opened(Fixture *fixture) {
    SBUSBHandle *handle = create(fixture); CHECK(SBUSBOpen(handle, 123).status == SB_USB_OK); return handle;
}
static void dispose(SBUSBHandle **handle, Fixture *fixture) {
    CHECK(SBUSBTryClose(*handle).status == SB_USB_OK);
    CHECK(SBUSBGetSnapshot(*handle).ownedReferencesReleased);
    CHECK(SBUSBDestroy(handle).status == SB_USB_OK && !*handle); finish(fixture);
}
typedef struct { SBUSBHandle *handle; enum Call call; SBUSBResult result; } Job;
static void *run(void *opaque) {
    Job *job = opaque; uint8_t bytes[SB_USB_TRANSFER_BYTES]; memset(bytes, 0xa3, sizeof(bytes));
    switch (job->call) {
        case OPEN: job->result = SBUSBOpen(job->handle, 123); break;
        case READ: job->result = SBUSBRead(job->handle, bytes, sizeof(bytes), 1250); break;
        case WRITE: job->result = SBUSBWrite(job->handle, bytes, 7, 1250); break;
        case ABORT: job->result = SBUSBInterrupt(job->handle); break;
        case CLOSE: job->result = SBUSBTryClose(job->handle); break;
        default: CHECK(false);
    }
    return NULL;
}
static pthread_t start(Job *job) { pthread_t thread; CHECK(pthread_create(&thread, NULL, run, job) == 0); return thread; }
static void joined(pthread_t thread) { CHECK(pthread_join(thread, NULL) == 0); }
static void errorFor(Fixture *fixture, enum Call call, int code) {
    fixture->results[call].status = SB_USB_NATIVE_FAILURE; fixture->results[call].nativeCode = code;
    fixture->results[call].domain = SB_USB_DOMAIN_IORETURN;
    fixture->results[call].byteCountKnown = false; fixture->results[call].bytesTransferred = 0;
}

static void arguments(void) {
    Fixture fixture; initialize(&fixture); SBUSBResult result;
    CHECK(!SBUSBCreateWithDriver(&fixture, NULL, &result) && result.status == SB_USB_INVALID_ARGUMENT);
    SBUSBDriverOperations invalid = operations; invalid.close = NULL;
    CHECK(!SBUSBCreateWithDriver(&fixture, &invalid, &result)); CHECK(!fixture.destroyed);
    SBUSBHandle *handle = create(&fixture); uint8_t bytes[SB_USB_TRANSFER_BYTES] = {0};
    CHECK(SBUSBOpen(handle, 0).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBRead(handle, bytes, sizeof(bytes), 1250).status == SB_USB_NOT_READY);
    CHECK(SBUSBOpen(handle, 123).status == SB_USB_OK);
    CHECK(SBUSBOpen(handle, 123).status == SB_USB_ALREADY_STARTED);
    CHECK(SBUSBRead(handle, bytes, 1, 1250).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBRead(handle, bytes, sizeof(bytes), 0).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBRead(handle, bytes, sizeof(bytes), SB_USB_MAX_TIMEOUT_MS + 1).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBWrite(handle, bytes, sizeof(bytes) + 1, 1250).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBWrite(handle, NULL, 1, 1250).status == SB_USB_INVALID_ARGUMENT);
    CHECK(SBUSBWrite(handle, bytes, 0, 1250).status == SB_USB_INVALID_ARGUMENT);
    CHECK(!SBUSBGetSnapshot(handle).retired && !fixture.counts[READ] && !fixture.counts[WRITE]);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_CLEANUP_UNCONFIRMED && handle);
    dispose(&handle, &fixture);
}
static void zeroPacket(void) {
    Fixture fixture; initialize(&fixture); fixture.results[READ].bytesTransferred = 0;
    SBUSBHandle *handle = opened(&fixture); uint8_t bytes[SB_USB_TRANSFER_BYTES];
    SBUSBResult result = SBUSBRead(handle, bytes, sizeof(bytes), 1250);
    CHECK(result.status == SB_USB_OK && result.byteCountKnown && result.bytesTransferred == 0);
    CHECK(!SBUSBGetSnapshot(handle).retired); dispose(&handle, &fixture);
}
static void failureCounts(void) {
    for (unsigned mode = 0; mode < 5; mode++) {
        Fixture fixture; initialize(&fixture); enum Call call = mode == 3 ? WRITE : READ;
        if (mode == 0) errorFor(&fixture, READ, -17);
        if (mode == 1) fixture.results[READ].byteCountKnown = false;
        if (mode == 2) fixture.results[READ].bytesTransferred = SB_USB_TRANSFER_BYTES + 1;
        if (mode == 3) fixture.results[WRITE].bytesTransferred = 6;
        if (mode == 4) errorFor(&fixture, READ, -18);
        SBUSBHandle *handle = opened(&fixture); Job job = { .handle = handle, .call = call }; run(&job);
        CHECK(job.result.status == SB_USB_NATIVE_FAILURE);
        CHECK(SBUSBGetSnapshot(handle).retired); run(&job); CHECK(job.result.status == SB_USB_CANCELLED);
        CHECK(fixture.counts[call] == 1); dispose(&handle, &fixture);
    }
}
static void openingCancellation(void) {
    Fixture fixture; initialize(&fixture); fixture.blocked = 1u << OPEN; SBUSBHandle *handle = create(&fixture);
    Job job = { .handle = handle, .call = OPEN }; pthread_t thread = start(&job); awaitEntry(&fixture, OPEN);
    CHECK(SBUSBGetSnapshot(handle).opening); CHECK(SBUSBInterrupt(handle).status == SB_USB_OK);
    CHECK(!fixture.counts[ABORT]); CHECK(SBUSBTryClose(handle).status == SB_USB_BUSY);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_CLEANUP_UNCONFIRMED && handle);
    permit(&fixture, OPEN); joined(thread); CHECK(job.result.status == SB_USB_CANCELLED);
    CHECK(!SBUSBGetSnapshot(handle).ready); CHECK(SBUSBOpen(handle, 123).status == SB_USB_CANCELLED);
    dispose(&handle, &fixture); CHECK(fixture.counts[CLOSE] == 1);
}
static void simultaneousIO(void) {
    Fixture fixture; initialize(&fixture); fixture.blocked = (1u << READ) | (1u << WRITE);
    SBUSBHandle *handle = opened(&fixture);
    Job reader = { .handle = handle, .call = READ }, writer = { .handle = handle, .call = WRITE };
    pthread_t r = start(&reader), w = start(&writer); awaitEntry(&fixture, READ); awaitEntry(&fixture, WRITE);
    SBUSBSnapshot snapshot = SBUSBGetSnapshot(handle); CHECK(snapshot.reading && snapshot.writing);
    Job duplicate = { .handle = handle, .call = READ }; run(&duplicate); CHECK(duplicate.result.status == SB_USB_BUSY);
    duplicate.call = WRITE; run(&duplicate); CHECK(duplicate.result.status == SB_USB_BUSY);
    CHECK(SBUSBInterrupt(handle).status == SB_USB_OK); CHECK(SBUSBTryClose(handle).status == SB_USB_BUSY);
    permit(&fixture, READ); joined(r); CHECK(reader.result.status == SB_USB_CANCELLED);
    CHECK(SBUSBTryClose(handle).status == SB_USB_BUSY && !fixture.counts[CLOSE]);
    permit(&fixture, WRITE); joined(w); CHECK(writer.result.status == SB_USB_CANCELLED);
    CHECK(writer.result.byteCountKnown && writer.result.bytesTransferred == 7); // bytes may have left, never success
    dispose(&handle, &fixture);
}
static void abortOwnership(void) {
    Fixture fixture; initialize(&fixture); fixture.blocked = 1u << ABORT;
    SBUSBHandle *handle = opened(&fixture); Job job = { .handle = handle, .call = ABORT };
    pthread_t thread = start(&job); awaitEntry(&fixture, ABORT);
    CHECK(SBUSBInterrupt(handle).status == SB_USB_BUSY); CHECK(SBUSBTryClose(handle).status == SB_USB_BUSY);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_CLEANUP_UNCONFIRMED && handle);
    permit(&fixture, ABORT); joined(thread); CHECK(job.result.status == SB_USB_OK); dispose(&handle, &fixture);
}
static void closingOwnership(void) {
    Fixture fixture; initialize(&fixture); fixture.blocked = 1u << CLOSE;
    SBUSBHandle *handle = opened(&fixture); Job job = { .handle = handle, .call = CLOSE };
    pthread_t thread = start(&job); awaitEntry(&fixture, CLOSE);
    CHECK(SBUSBGetSnapshot(handle).closing && !SBUSBGetSnapshot(handle).ownedReferencesReleased);
    CHECK(SBUSBInterrupt(handle).status == SB_USB_BUSY); CHECK(SBUSBTryClose(handle).status == SB_USB_BUSY);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_CLEANUP_UNCONFIRMED && handle);
    permit(&fixture, CLOSE); joined(thread); CHECK(job.result.status == SB_USB_OK);
    dispose(&handle, &fixture); CHECK(fixture.counts[CLOSE] == 1);
}
static void closeFailureReleased(void) {
    Fixture fixture; initialize(&fixture); errorFor(&fixture, CLOSE, -27);
    SBUSBHandle *handle = opened(&fixture); SBUSBResult result = SBUSBTryClose(handle);
    CHECK(result.status == SB_USB_NATIVE_FAILURE && result.nativeCode == -27);
    CHECK(SBUSBGetSnapshot(handle).ownedReferencesReleased);
    CHECK(SBUSBTryClose(handle).nativeCode == -27 && fixture.counts[CLOSE] == 1);
    CHECK(SBUSBDestroy(&handle).nativeCode == -27 && !handle); finish(&fixture);
}
static void releaseUnconfirmed(void) {
    Fixture fixture; initialize(&fixture); fixture.released = false;
    SBUSBHandle *handle = opened(&fixture);
    CHECK(SBUSBTryClose(handle).status == SB_USB_CLEANUP_UNCONFIRMED);
    CHECK(!SBUSBGetSnapshot(handle).ownedReferencesReleased);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_CLEANUP_UNCONFIRMED && handle && !fixture.destroyed);
    // Only this fixture models an explicitly successful later cleanup; production cannot
    // guess that a failed IOObjectRelease is safe to repeat.
    fixture.released = true; dispose(&handle, &fixture);
}
static void originalFailure(void) {
    Fixture fixture; initialize(&fixture); errorFor(&fixture, READ, -31); errorFor(&fixture, ABORT, -32); errorFor(&fixture, CLOSE, -33);
    SBUSBHandle *handle = opened(&fixture); Job job = { .handle = handle, .call = READ }; run(&job);
    CHECK(SBUSBInterrupt(handle).nativeCode == -32); CHECK(SBUSBTryClose(handle).nativeCode == -33);
    SBUSBSnapshot snapshot = SBUSBGetSnapshot(handle);
    CHECK(snapshot.firstFailure.nativeCode == -31 && snapshot.closeResult.nativeCode == -33);
    CHECK(snapshot.ownedReferencesReleased); CHECK(SBUSBDestroy(&handle).nativeCode == -33 && !handle); finish(&fixture);
}
static void partialAcquisition(void) {
    Fixture fixture; initialize(&fixture); errorFor(&fixture, OPEN, -41); SBUSBHandle *handle = create(&fixture);
    CHECK(SBUSBOpen(handle, 123).nativeCode == -41); CHECK(SBUSBGetSnapshot(handle).retired);
    dispose(&handle, &fixture); CHECK(fixture.counts[CLOSE] == 1);
}
static void closeBeforeOpen(void) {
    Fixture fixture; initialize(&fixture); SBUSBHandle *handle = create(&fixture);
    CHECK(SBUSBInterrupt(handle).status == SB_USB_OK); CHECK(SBUSBOpen(handle, 123).status == SB_USB_CANCELLED);
    dispose(&handle, &fixture); CHECK(!fixture.counts[OPEN] && !fixture.counts[ABORT]);
}
static void retireAdmission(void) {
    Fixture fixture; initialize(&fixture); SBUSBHandle *handle = opened(&fixture);
    CHECK(SBUSBRetire(handle).status == SB_USB_OK && fixture.counts[ABORT] == 0);
    Job job = { .handle = handle, .call = WRITE }; run(&job); CHECK(job.result.status == SB_USB_CANCELLED);
    CHECK(fixture.counts[WRITE] == 0); dispose(&handle, &fixture);
}
static void nativeAbsentDevice(void) {
    SBUSBResult result; SBUSBHandle *handle = SBUSBCreate(&result); CHECK(handle && result.status == SB_USB_OK);
    result = SBUSBOpen(handle, UINT64_MAX);
    CHECK(result.status == SB_USB_UNAVAILABLE && result.phase == SB_USB_PHASE_SELECT_DEVICE);
    CHECK(SBUSBTryClose(handle).status == SB_USB_OK); CHECK(SBUSBGetSnapshot(handle).ownedReferencesReleased);
    CHECK(SBUSBDestroy(&handle).status == SB_USB_OK && !handle);
}

int main(void) {
    struct { const char *name; void (*test)(void); } tests[] = {
        {"arguments_and_single_use", arguments}, {"zero_length_packet", zeroPacket},
        {"invalid_counts_and_io_failure", failureCounts}, {"cancel_during_open", openingCancellation},
        {"concurrent_read_write_and_stop", simultaneousIO}, {"abort_reference_ownership", abortOwnership},
        {"close_reference_ownership", closingOwnership}, {"close_error_after_release", closeFailureReleased},
        {"unconfirmed_release_retained", releaseUnconfirmed}, {"original_failure_preserved", originalFailure},
        {"partial_acquisition_cleanup", partialAcquisition}, {"close_before_open", closeBeforeOpen},
        {"retirement_closes_native_admission", retireAdmission},
        {"native_absent_registry_entry", nativeAbsentDevice}
    };
    for (unsigned i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) { tests[i].test(); printf("PASS %s\n", tests[i].name); }
    printf("PASS %zu cases; native device data not tested\n", sizeof(tests) / sizeof(tests[0]));
    return 0;
}
