#include "PrivateSensorBridgeC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static io_connect_t g_smc_conn = IO_OBJECT_NULL;

static uint32_t sb_key_to_uint32(const char key[4]) {
    return (uint32_t)((uint8_t) key[0] << 24) |
           (uint32_t)((uint8_t) key[1] << 16) |
           (uint32_t)((uint8_t) key[2] << 8) |
           (uint32_t)((uint8_t) key[3]);
}

static void sb_uint32_to_key(uint32_t value, char out[5]) {
    out[0] = (char) ((value >> 24) & 0xff);
    out[1] = (char) ((value >> 16) & 0xff);
    out[2] = (char) ((value >> 8) & 0xff);
    out[3] = (char) (value & 0xff);
    out[4] = '\0';
}

static kern_return_t sb_smc_call(SMCKeyData_t *input, SMCKeyData_t *output) {
    if (g_smc_conn == IO_OBJECT_NULL) {
        return kIOReturnNotOpen;
    }

    size_t in_size = sizeof(SMCKeyData_t);
    size_t out_size = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(
        g_smc_conn,
        KERNEL_INDEX_SMC,
        input,
        in_size,
        output,
        &out_size
    );
}

int sb_smc_open(void) {
    if (g_smc_conn != IO_OBJECT_NULL) {
        return (int) kIOReturnSuccess;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return (int) kIOReturnNotFound;
    }

    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &g_smc_conn);
    IOObjectRelease(service);
    return (int) status;
}

void sb_smc_close(void) {
    if (g_smc_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_smc_conn);
        g_smc_conn = IO_OBJECT_NULL;
    }
}

static kern_return_t sb_smc_read_raw(const char *key, SMCKeyData_t *output, char type_out[5]) {
    if (key == NULL || strlen(key) < 4) {
        return kIOReturnBadArgument;
    }

    int open_status = sb_smc_open();
    if (open_status != kIOReturnSuccess) {
        return (kern_return_t) open_status;
    }

    SMCKeyData_t input;
    memset(&input, 0, sizeof(SMCKeyData_t));
    memset(output, 0, sizeof(SMCKeyData_t));

    input.key = sb_key_to_uint32(key);
    input.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t status = sb_smc_call(&input, output);
    if (status != kIOReturnSuccess) {
        return status;
    }

    SMCKeyData_t value_in;
    SMCKeyData_t value_out;
    memset(&value_in, 0, sizeof(SMCKeyData_t));
    memset(&value_out, 0, sizeof(SMCKeyData_t));

    value_in.key = input.key;
    value_in.keyInfo.dataSize = output->keyInfo.dataSize;
    value_in.data8 = SMC_CMD_READ_BYTES;

    status = sb_smc_call(&value_in, &value_out);
    if (status != kIOReturnSuccess) {
        return status;
    }

    *output = value_out;
    sb_uint32_to_key(output->keyInfo.dataType, type_out);
    return kIOReturnSuccess;
}

static kern_return_t sb_decode_value(const SMCKeyData_t *data, const char type[5], double *value_out) {
    if (data == NULL || value_out == NULL) {
        return kIOReturnBadArgument;
    }

    uint32_t data_size = data->keyInfo.dataSize;

    if (strncmp(type, "sp78", 4) == 0 && data_size >= 2) {
        int16_t raw = (int16_t) (((uint16_t) data->bytes[0] << 8) | (uint16_t) data->bytes[1]);
        *value_out = (double) raw / 256.0;
        return kIOReturnSuccess;
    }

    if (strncmp(type, "fpe2", 4) == 0 && data_size >= 2) {
        uint16_t raw = (uint16_t) (((uint16_t) data->bytes[0] << 8) | (uint16_t) data->bytes[1]);
        *value_out = (double) raw / 4.0;
        return kIOReturnSuccess;
    }

    if (strncmp(type, "flt ", 4) == 0 && data_size >= 4) {
        uint32_t raw = ((uint32_t) data->bytes[0] << 24) |
                       ((uint32_t) data->bytes[1] << 16) |
                       ((uint32_t) data->bytes[2] << 8) |
                       ((uint32_t) data->bytes[3]);
        uint32_t host = CFSwapInt32BigToHost(raw);
        float f;
        memcpy(&f, &host, sizeof(float));
        if (isfinite(f)) {
            *value_out = (double) f;
            return kIOReturnSuccess;
        }
        return kIOReturnError;
    }

    if (strncmp(type, "ui16", 4) == 0 && data_size >= 2) {
        uint16_t raw = (uint16_t) (((uint16_t) data->bytes[0] << 8) | (uint16_t) data->bytes[1]);
        *value_out = (double) raw;
        return kIOReturnSuccess;
    }

    if (strncmp(type, "si16", 4) == 0 && data_size >= 2) {
        int16_t raw = (int16_t) (((uint16_t) data->bytes[0] << 8) | (uint16_t) data->bytes[1]);
        *value_out = (double) raw;
        return kIOReturnSuccess;
    }

    if (strncmp(type, "ui8 ", 4) == 0 && data_size >= 1) {
        *value_out = (double) data->bytes[0];
        return kIOReturnSuccess;
    }

    if (data_size == 2) {
        uint16_t raw = (uint16_t) (((uint16_t) data->bytes[0] << 8) | (uint16_t) data->bytes[1]);
        *value_out = (double) raw;
        return kIOReturnSuccess;
    }

    if (data_size == 1) {
        *value_out = (double) data->bytes[0];
        return kIOReturnSuccess;
    }

    return kIOReturnUnsupported;
}

int sb_smc_read_key(const char *key, double *value_out, char type_out[5]) {
    if (type_out == NULL || value_out == NULL) {
        return (int) kIOReturnBadArgument;
    }

    SMCKeyData_t output;
    char type[5] = {0, 0, 0, 0, 0};
    kern_return_t status = sb_smc_read_raw(key, &output, type);
    if (status != kIOReturnSuccess) {
        return (int) status;
    }

    status = sb_decode_value(&output, type, value_out);
    if (status != kIOReturnSuccess) {
        return (int) status;
    }

    memcpy(type_out, type, 5);
    return (int) kIOReturnSuccess;
}

int sb_smc_read_key_at_index(int index, char key_out[5]) {
    if (index < 0 || key_out == NULL) {
        return (int) kIOReturnBadArgument;
    }

    int open_status = sb_smc_open();
    if (open_status != kIOReturnSuccess) {
        return open_status;
    }

    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(SMCKeyData_t));
    memset(&output, 0, sizeof(SMCKeyData_t));

    input.data8 = SMC_CMD_READ_INDEX;
    input.data32 = (uint32_t) index;

    kern_return_t status = sb_smc_call(&input, &output);
    if (status != kIOReturnSuccess) {
        return (int) status;
    }

    sb_uint32_to_key(output.key, key_out);
    return (int) kIOReturnSuccess;
}

int sb_smc_read_fan_count(int *count_out) {
    if (count_out == NULL) {
        return (int) kIOReturnBadArgument;
    }

    double value = 0;
    char type[5];
    int status = sb_smc_read_key("FNum", &value, type);
    if (status != kIOReturnSuccess) {
        return status;
    }

    if (!isfinite(value) || value < 0 || value > 64) {
        return (int) kIOReturnError;
    }

    *count_out = (int) llround(value);
    return (int) kIOReturnSuccess;
}

int sb_smc_read_fan_speed(int index, double *rpm_out) {
    if (rpm_out == NULL || index < 0 || index > 9) {
        return (int) kIOReturnBadArgument;
    }

    char key[5];
    snprintf(key, sizeof(key), "F%dAc", index);

    char type[5];
    double value = 0;
    int status = sb_smc_read_key(key, &value, type);
    if (status != kIOReturnSuccess) {
        return status;
    }

    if (!isfinite(value) || value < 0 || value > 20000) {
        return (int) kIOReturnError;
    }

    *rpm_out = value;
    return (int) kIOReturnSuccess;
}
