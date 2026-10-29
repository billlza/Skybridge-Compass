#ifndef SKYBRIDGE_BOOT_WITNESS_H
#define SKYBRIDGE_BOOT_WITNESS_H
#include <stdint.h>

/* Boot-scoped identity only; no account data or audio admission is stored here.
 * Every member of the provisioned App Group is part of this clock trust boundary.
 * The lock path is private to the owning app, shared by all its processes.
 * The iOS caller must bind the namespace to its provisioned, trusted App Group.
 * Apple documents shm objects as surviving process exit but not system reboot.
 */
enum sb_boot_kind { SB_BOOT_CREATED = 1, SB_BOOT_EXISTING = 2, SB_BOOT_RECOVERED = 3 };
enum sb_boot_step {
    SB_BOOT_ARGUMENT = 1, SB_BOOT_LOCK_OPEN, SB_BOOT_LOCK_METADATA, SB_BOOT_LOCK_WAIT,
    SB_BOOT_SHM_OPEN, SB_BOOT_SHM_METADATA, SB_BOOT_SHM_SIZE, SB_BOOT_MAP,
    SB_BOOT_RECORD, SB_BOOT_UNMAP, SB_BOOT_CLOSE, SB_BOOT_UNLOCK
};
struct sb_boot_result {
    int kind;
    int step;
    int system_error;
    int cleanup_error;
    uint8_t identifier[16];
};
int sb_boot_read(const char *name, const char *lock_path, struct sb_boot_result *result);
#endif
