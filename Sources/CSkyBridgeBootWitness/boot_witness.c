#include "boot_witness.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SB_BOOT_READY UINT64_C(0x5342424f4f540001)
#define SB_BOOT_MAX_NAME 31
#define SB_BOOT_LOCK_NS UINT64_C(1000000000)
struct sb_boot_record {
    _Atomic uint64_t ready;
    uint8_t identifier[16];
    uint8_t digest[32];
    uint8_t reserved[8];
};
_Static_assert(sizeof(struct sb_boot_record) == 64, "unexpected witness layout");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "shared commit marker must be lock-free");

static int fail(struct sb_boot_result *result, int step, int error) {
    result->kind = 0;
    result->step = step;
    result->system_error = error;
    memset(result->identifier, 0, sizeof(result->identifier));
    return -1;
}
static void cleanup_failure(struct sb_boot_result *result, int step, int error) {
    if (result->system_error == 0) {
        (void)fail(result, step, error);
    } else if (result->cleanup_error == 0) {
        result->cleanup_error = error;
    }
}
static bool private_object(const struct stat *metadata) {
    return metadata->st_uid == geteuid() && (metadata->st_mode & 0777) == 0600;
}
static bool valid_name(const char *name) {
    if (name == NULL) return false;
    size_t size = strnlen(name, SB_BOOT_MAX_NAME + 1);
    if (size == 0 || size > SB_BOOT_MAX_NAME) return false;
    bool has_separator = false;
    for (size_t i = 0; i < size; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c == '/') {
            if (has_separator || i == 0 || i + 1 == size) return false;
            has_separator = true;
            continue;
        }
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-')) return false;
    }
    return true;
}
static int acquire_lock(int descriptor) {
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return EIO;
    uint64_t start = mach_continuous_time();
    for (;;) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) return 0;
        int error = errno;
        if (error != EWOULDBLOCK && error != EAGAIN && error != EINTR) return error;
        uint64_t current = mach_continuous_time();
        if (current < start) return EIO;
        __uint128_t elapsed = (__uint128_t)(current - start) * scale.numer / scale.denom;
        if (elapsed >= SB_BOOT_LOCK_NS) return ETIMEDOUT;
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 2000000 };
        if (nanosleep(&delay, NULL) != 0 && errno != EINTR) return errno;
    }
}

int sb_boot_read(const char *name, const char *lock_path, struct sb_boot_result *result) {
    if (result == NULL) { errno = EINVAL; return -1; }
    memset(result, 0, sizeof(*result));
    if (!valid_name(name) || lock_path == NULL || lock_path[0] != '/' ||
        strnlen(lock_path, PATH_MAX) == PATH_MAX) return fail(result, SB_BOOT_ARGUMENT, EINVAL);

    int lock_fd = -1, memory_fd = -1;
    bool locked = false, created = false;
    void *mapping = MAP_FAILED;
    lock_fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock_fd < 0) return fail(result, SB_BOOT_LOCK_OPEN, errno);
    struct stat lock_metadata;
    if (fstat(lock_fd, &lock_metadata) != 0) {
        (void)fail(result, SB_BOOT_LOCK_METADATA, errno); goto cleanup;
    }
    if (!S_ISREG(lock_metadata.st_mode) || lock_metadata.st_nlink != 1 || !private_object(&lock_metadata)) {
        (void)fail(result, SB_BOOT_LOCK_METADATA, EACCES); goto cleanup;
    }
    int error = acquire_lock(lock_fd);
    if (error != 0) { (void)fail(result, SB_BOOT_LOCK_WAIT, error); goto cleanup; }
    locked = true;

    memory_fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (memory_fd >= 0) {
        created = true;
    } else {
        error = errno;
        if (error != EEXIST) { (void)fail(result, SB_BOOT_SHM_OPEN, error); goto cleanup; }
        memory_fd = shm_open(name, O_RDWR, 0);
        if (memory_fd < 0) { (void)fail(result, SB_BOOT_SHM_OPEN, errno); goto cleanup; }
    }
    struct stat metadata;
    if (fstat(memory_fd, &metadata) != 0) {
        (void)fail(result, SB_BOOT_SHM_METADATA, errno); goto cleanup;
    }
    if (!private_object(&metadata)) {
        (void)fail(result, SB_BOOT_SHM_METADATA, EACCES); goto cleanup;
    }
    /* Darwin reports the backing allocation rounded to a native page, not the
     * requested 64-byte record length. Request and validate one complete page.
     */
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size < (long)sizeof(struct sb_boot_record)) {
        (void)fail(result, SB_BOOT_SHM_SIZE, EINVAL); goto cleanup;
    }
    if (metadata.st_size == 0) {
        if (ftruncate(memory_fd, (off_t)page_size) != 0) {
            (void)fail(result, SB_BOOT_SHM_SIZE, errno); goto cleanup;
        }
    } else if (metadata.st_size != (off_t)page_size) {
        (void)fail(result, SB_BOOT_SHM_SIZE, EILSEQ); goto cleanup;
    }
    mapping = mmap(NULL, sizeof(struct sb_boot_record), PROT_READ | PROT_WRITE, MAP_SHARED, memory_fd, 0);
    if (mapping == MAP_FAILED) { (void)fail(result, SB_BOOT_MAP, errno); goto cleanup; }
    struct sb_boot_record *record = mapping;
    uint64_t ready = atomic_load_explicit(&record->ready, memory_order_acquire);
    if (ready == 0) {
        /* An initializer died before its release-store. A NEW identifier retires
         * any old checkpoint; this is an observed recovery, not restored evidence.
         * No initialized record is overwritten or silently repaired.
         */
        uint8_t identifier[16];
        arc4random_buf(identifier, sizeof(identifier));
        identifier[6] = (identifier[6] & 0x0f) | 0x40;
        identifier[8] = (identifier[8] & 0x3f) | 0x80;
        memcpy(record->identifier, identifier, sizeof(identifier));
        if (CC_SHA256(identifier, sizeof(identifier), record->digest) == NULL) {
            (void)fail(result, SB_BOOT_RECORD, EIO); goto cleanup;
        }
        memset(record->reserved, 0, sizeof(record->reserved));
        atomic_store_explicit(&record->ready, SB_BOOT_READY, memory_order_release);
        result->kind = created ? SB_BOOT_CREATED : SB_BOOT_RECOVERED;
    } else if (ready == SB_BOOT_READY) {
        result->kind = SB_BOOT_EXISTING;
    } else {
        (void)fail(result, SB_BOOT_RECORD, EILSEQ); goto cleanup;
    }
    uint8_t digest[32], reserved[8] = {0};
    if (CC_SHA256(record->identifier, sizeof(record->identifier), digest) == NULL ||
        memcmp(digest, record->digest, sizeof(digest)) != 0 ||
        memcmp(reserved, record->reserved, sizeof(reserved)) != 0 ||
        (record->identifier[6] & 0xf0) != 0x40 || (record->identifier[8] & 0xc0) != 0x80) {
        (void)fail(result, SB_BOOT_RECORD, EILSEQ); goto cleanup;
    }
    memcpy(result->identifier, record->identifier, sizeof(result->identifier));

cleanup:
    if (mapping != MAP_FAILED && munmap(mapping, sizeof(struct sb_boot_record)) != 0) {
        cleanup_failure(result, SB_BOOT_UNMAP, errno);
    }
    /* close() is never blindly retried after EINTR: the descriptor may already
     * be retired and reused. A cleanup failure cannot return a successful read.
     */
    if (memory_fd >= 0 && close(memory_fd) != 0) cleanup_failure(result, SB_BOOT_CLOSE, errno);
    if (locked && flock(lock_fd, LOCK_UN) != 0) cleanup_failure(result, SB_BOOT_UNLOCK, errno);
    if (close(lock_fd) != 0) cleanup_failure(result, SB_BOOT_CLOSE, errno);
    return result->system_error == 0 ? 0 : -1;
}
