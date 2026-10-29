#ifndef PRIVATE_SENSOR_BRIDGE_H
#define PRIVATE_SENSOR_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

int sb_smc_open(void);
void sb_smc_close(void);
int sb_smc_read_key(const char *key, double *value_out, char type_out[5]);
int sb_smc_read_key_at_index(int index, char key_out[5]);
int sb_smc_read_fan_count(int *count_out);
int sb_smc_read_fan_speed(int index, double *rpm_out);
int sb_hid_read_temperatures(double *cpu_temp_out, double *gpu_temp_out);
int sb_ioreport_open(void);
void sb_ioreport_close(void);
int sb_ioreport_read_power(
    double *cpu_power_watts_out,
    double *gpu_power_watts_out,
    double *ane_power_watts_out,
    double *ram_power_watts_out,
    double *package_power_watts_out,
    int *available_mask_out
);
int sb_ioreport_read_gpu_power(double *gpu_power_watts_out);

#define SB_IOREPORT_POWER_CPU_FLAG 1
#define SB_IOREPORT_POWER_GPU_FLAG (1 << 1)
#define SB_IOREPORT_POWER_ANE_FLAG (1 << 2)
#define SB_IOREPORT_POWER_RAM_FLAG (1 << 3)
#define SB_IOREPORT_POWER_PACKAGE_FLAG (1 << 4)

#ifdef __cplusplus
}
#endif

#endif
