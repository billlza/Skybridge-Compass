#include "PrivateSensorBridgeC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <ctype.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

// Private IOReport symbols used by open-source tooling such as Stats.
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
typedef CFDictionaryRef (*sb_IOReportCopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*sb_IOReportCreateSubscriptionFn)(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*sb_IOReportCreateSamplesFn)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFStringRef (*sb_IOReportChannelGetGroupFn)(CFDictionaryRef);
typedef CFStringRef (*sb_IOReportChannelGetChannelNameFn)(CFDictionaryRef);
typedef CFStringRef (*sb_IOReportChannelGetUnitLabelFn)(CFDictionaryRef);
typedef int64_t (*sb_IOReportSimpleGetIntegerValueFn)(CFDictionaryRef, int32_t);

// IOHID symbols declared in private headers.
typedef struct __IOHIDEvent* IOHIDEventRef;
typedef struct __IOHIDServiceClient* IOHIDServiceClientRef;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define SB_IOHID_EVENT_FIELD_BASE(type) ((type) << 16)
#define SB_IOHID_EVENT_TYPE_TEMPERATURE 15
#define SB_HID_PAGE_APPLE_VENDOR 0xff00
#define SB_HID_USAGE_TEMP_SENSOR 0x0005

static const int SB_HID_CPU_FLAG = 1;
static const int SB_HID_GPU_FLAG = 1 << 1;
static const double SB_MAX_POWER_WATTS = 500.0;

typedef struct {
    double cpu;
    double gpu;
    double ane;
    double ram;
    double package;
    int flags;
} SBPowerEnergyJoules;

static CFMutableDictionaryRef g_energyChannels = NULL;
static IOReportSubscriptionRef g_energySubscription = NULL;
static SBPowerEnergyJoules g_prevEnergyJoules = { NAN, NAN, NAN, NAN, NAN, 0 };
static CFAbsoluteTime g_prevEnergySampleTime = 0;
static void* g_ioreportHandle = NULL;
static sb_IOReportCopyChannelsInGroupFn g_IOReportCopyChannelsInGroup = NULL;
static sb_IOReportCreateSubscriptionFn g_IOReportCreateSubscription = NULL;
static sb_IOReportCreateSamplesFn g_IOReportCreateSamples = NULL;
static sb_IOReportChannelGetGroupFn g_IOReportChannelGetGroup = NULL;
static sb_IOReportChannelGetChannelNameFn g_IOReportChannelGetChannelName = NULL;
static sb_IOReportChannelGetUnitLabelFn g_IOReportChannelGetUnitLabel = NULL;
static sb_IOReportSimpleGetIntegerValueFn g_IOReportSimpleGetIntegerValue = NULL;

static bool sb_load_ioreport_symbols(void) {
    if (g_IOReportCopyChannelsInGroup != NULL) {
        return true;
    }

    if (g_ioreportHandle == NULL) {
        g_ioreportHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        if (g_ioreportHandle == NULL) {
            return false;
        }
    }

    g_IOReportCopyChannelsInGroup = (sb_IOReportCopyChannelsInGroupFn)dlsym(g_ioreportHandle, "IOReportCopyChannelsInGroup");
    g_IOReportCreateSubscription = (sb_IOReportCreateSubscriptionFn)dlsym(g_ioreportHandle, "IOReportCreateSubscription");
    g_IOReportCreateSamples = (sb_IOReportCreateSamplesFn)dlsym(g_ioreportHandle, "IOReportCreateSamples");
    g_IOReportChannelGetGroup = (sb_IOReportChannelGetGroupFn)dlsym(g_ioreportHandle, "IOReportChannelGetGroup");
    g_IOReportChannelGetChannelName = (sb_IOReportChannelGetChannelNameFn)dlsym(g_ioreportHandle, "IOReportChannelGetChannelName");
    g_IOReportChannelGetUnitLabel = (sb_IOReportChannelGetUnitLabelFn)dlsym(g_ioreportHandle, "IOReportChannelGetUnitLabel");
    g_IOReportSimpleGetIntegerValue = (sb_IOReportSimpleGetIntegerValueFn)dlsym(g_ioreportHandle, "IOReportSimpleGetIntegerValue");

    return g_IOReportCopyChannelsInGroup != NULL
        && g_IOReportCreateSubscription != NULL
        && g_IOReportCreateSamples != NULL
        && g_IOReportChannelGetGroup != NULL
        && g_IOReportChannelGetChannelName != NULL
        && g_IOReportChannelGetUnitLabel != NULL
        && g_IOReportSimpleGetIntegerValue != NULL;
}

static bool sb_string_has_suffix(const char* string, const char* suffix) {
    if (string == NULL || suffix == NULL) {
        return false;
    }
    size_t stringLen = strlen(string);
    size_t suffixLen = strlen(suffix);
    if (suffixLen > stringLen) {
        return false;
    }
    return strncasecmp(string + (stringLen - suffixLen), suffix, suffixLen) == 0;
}

static bool sb_string_contains_word(const char* string, const char* word) {
    if (string == NULL || word == NULL || word[0] == '\0') {
        return false;
    }

    const size_t wordLen = strlen(word);
    const char* cursor = string;
    while ((cursor = strcasestr(cursor, word)) != NULL) {
        const char before = cursor == string ? '\0' : cursor[-1];
        const char after = cursor[wordLen];
        const bool beforeBoundary = before == '\0' || !isalnum((unsigned char)before);
        const bool afterBoundary = after == '\0' || !isalnum((unsigned char)after);
        if (beforeBoundary && afterBoundary) {
            return true;
        }
        cursor += wordLen;
    }
    return false;
}

static bool sb_string_has_prefix(const char* string, const char* prefix) {
    if (string == NULL || prefix == NULL) {
        return false;
    }
    return strncasecmp(string, prefix, strlen(prefix)) == 0;
}

static bool sb_energy_totals_has_any(const SBPowerEnergyJoules* totals) {
    return totals != NULL && totals->flags != 0;
}

static void sb_reset_energy_totals(SBPowerEnergyJoules* totals) {
    if (totals == NULL) {
        return;
    }
    totals->cpu = NAN;
    totals->gpu = NAN;
    totals->ane = NAN;
    totals->ram = NAN;
    totals->package = NAN;
    totals->flags = 0;
}

static void sb_add_energy_value(double* value, int* flags, int flag, double joules) {
    if (value == NULL || flags == NULL || !isfinite(joules)) {
        return;
    }
    if ((*flags & flag) == 0 || !isfinite(*value)) {
        *value = 0.0;
    }
    *value += joules;
    *flags |= flag;
}

static int sb_classify_energy_channel(const char* channelName) {
    if (channelName == NULL) {
        return 0;
    }

    if (sb_string_has_prefix(channelName, "ANE")
        || sb_string_contains_word(channelName, "ANE")
        || strcasestr(channelName, "Neural") != NULL) {
        return SB_IOREPORT_POWER_ANE_FLAG;
    }

    if (strcasestr(channelName, "GPU") != NULL
        || strcasestr(channelName, "GFX") != NULL) {
        return SB_IOREPORT_POWER_GPU_FLAG;
    }

    if (strcasestr(channelName, "CPU") != NULL
        || strcasestr(channelName, "ECPU") != NULL
        || strcasestr(channelName, "PCPU") != NULL
        || strcasestr(channelName, "PACC") != NULL
        || strcasestr(channelName, "EACC") != NULL) {
        return SB_IOREPORT_POWER_CPU_FLAG;
    }

    if (sb_string_has_prefix(channelName, "DRAM")
        || sb_string_contains_word(channelName, "RAM")
        || strcasestr(channelName, "Memory") != NULL) {
        return SB_IOREPORT_POWER_RAM_FLAG;
    }

    if (strcasestr(channelName, "Package") != NULL
        || strcasestr(channelName, "SoC") != NULL
        || strcasestr(channelName, "SOC") != NULL
        || strcasestr(channelName, "Combined") != NULL
        || strcasestr(channelName, "System Total") != NULL
        || sb_string_contains_word(channelName, "Total")) {
        return SB_IOREPORT_POWER_PACKAGE_FLAG;
    }

    return 0;
}

static NSDictionary* sb_copy_hid_sensor_values(int32_t page, int32_t usage, int32_t eventType) {
    NSDictionary* matching = @{ @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage) };

    IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (system == NULL) {
        return nil;
    }
    IOHIDEventSystemClientSetMatching(system, (__bridge CFDictionaryRef)matching);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(system);
    if (services == NULL) {
        CFRelease(system);
        return nil;
    }

    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    const CFIndex count = CFArrayGetCount(services);
    for (CFIndex index = 0; index < count; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        if (service == NULL) {
            continue;
        }

        NSString* name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0);
        if (name == nil || event == NULL) {
            if (event != NULL) {
                CFRelease(event);
            }
            continue;
        }

        const double value = (double)IOHIDEventGetFloatValue(event, SB_IOHID_EVENT_FIELD_BASE(eventType));
        CFRelease(event);

        if (!isfinite(value) || value < 0.0 || value > 200.0) {
            continue;
        }
        result[name] = @(value);
    }

    CFRelease(services);
    CFRelease(system);
    return result;
}

static bool sb_pmu_tp_sensor_has_suffix(NSString* lowered, unichar suffix) {
    if (lowered == nil || ![lowered containsString:@"pmu"]) {
        return false;
    }

    for (NSUInteger searchStart = 0; searchStart < lowered.length;) {
        NSRange searchRange = NSMakeRange(searchStart, lowered.length - searchStart);
        NSRange range = [lowered rangeOfString:@"tp" options:0 range:searchRange];
        if (range.location == NSNotFound) {
            break;
        }
        NSUInteger index = range.location + range.length;
        bool sawDigit = false;
        while (index < lowered.length) {
            unichar ch = [lowered characterAtIndex:index];
            if (ch < '0' || ch > '9') {
                break;
            }
            sawDigit = true;
            index += 1;
        }
        if (sawDigit && index < lowered.length && [lowered characterAtIndex:index] == suffix) {
            return true;
        }
        searchStart = range.location + 1;
    }
    return false;
}

static bool sb_is_sensor_battery_name(NSString* lowered) {
    return lowered != nil && ([lowered containsString:@"battery"] || [lowered containsString:@"gas gauge"]);
}

static bool sb_is_cpu_temp_name(NSString* name) {
    if (name == nil) {
        return false;
    }
    NSString* lowered = name.lowercaseString;
    if (sb_is_sensor_battery_name(lowered)) {
        return false;
    }
    if ([lowered hasPrefix:@"pacc mtr temp"] || [lowered hasPrefix:@"eacc mtr temp"]) {
        return true;
    }
    if ([lowered containsString:@"cpu"] || [lowered containsString:@"pcore"] || [lowered containsString:@"ecore"]) {
        return true;
    }
    if ([lowered containsString:@"pmu"]) {
        return [lowered containsString:@"tdie"]
            || [lowered containsString:@" die"]
            || [lowered containsString:@"soc"]
            || sb_pmu_tp_sensor_has_suffix(lowered, 's');
    }
    return false;
}

static bool sb_is_gpu_temp_name(NSString* name) {
    if (name == nil) {
        return false;
    }
    NSString* lowered = name.lowercaseString;
    if (sb_is_sensor_battery_name(lowered)) {
        return false;
    }
    if ([lowered hasPrefix:@"gpu mtr temp"]) {
        return true;
    }
    if ([lowered containsString:@"gpu"] || [lowered containsString:@"gfx"]) {
        return true;
    }
    if ([lowered containsString:@"pmu"]) {
        return sb_pmu_tp_sensor_has_suffix(lowered, 'g');
    }
    return false;
}

int sb_hid_read_temperatures(double* cpu_temp_out, double* gpu_temp_out) {
    if (cpu_temp_out != NULL) {
        *cpu_temp_out = 0.0;
    }
    if (gpu_temp_out != NULL) {
        *gpu_temp_out = 0.0;
    }

    NSDictionary* sensors = sb_copy_hid_sensor_values(
        SB_HID_PAGE_APPLE_VENDOR,
        SB_HID_USAGE_TEMP_SENSOR,
        SB_IOHID_EVENT_TYPE_TEMPERATURE
    );
    if (sensors == nil || sensors.count == 0) {
        return (int)kIOReturnNotFound;
    }

    double cpuSum = 0.0;
    int cpuCount = 0;
    double gpuSum = 0.0;
    int gpuCount = 0;

    for (id key in sensors) {
        id obj = sensors[key];
        if (![key isKindOfClass:[NSString class]] || ![obj isKindOfClass:[NSNumber class]]) {
            continue;
        }

        NSString* name = (NSString*)key;
        double value = ((NSNumber*)obj).doubleValue;
        if (!isfinite(value) || value < -10.0 || value > 130.0) {
            continue;
        }

        if (sb_is_cpu_temp_name(name)) {
            cpuSum += value;
            cpuCount += 1;
        }
        if (sb_is_gpu_temp_name(name)) {
            gpuSum += value;
            gpuCount += 1;
        }
    }

    int flags = 0;
    if (cpuCount > 0 && cpu_temp_out != NULL) {
        *cpu_temp_out = cpuSum / (double)cpuCount;
        flags |= SB_HID_CPU_FLAG;
    }
    if (gpuCount > 0 && gpu_temp_out != NULL) {
        *gpu_temp_out = gpuSum / (double)gpuCount;
        flags |= SB_HID_GPU_FLAG;
    }

    if (flags == 0) {
        return (int)kIOReturnNotFound;
    }
    return flags;
}

static bool sb_energy_value_to_joules(double rawValue, CFStringRef unitRef, double* joules_out) {
    if (joules_out == NULL || !isfinite(rawValue) || unitRef == NULL) {
        return false;
    }

    char unit[32] = {0};
    if (!CFStringGetCString(unitRef, unit, sizeof(unit), kCFStringEncodingUTF8)) {
        return false;
    }

    if (sb_string_has_suffix(unit, "mJ")) {
        *joules_out = rawValue / 1000.0;
        return true;
    }
    if (sb_string_has_suffix(unit, "uJ")
        || sb_string_has_suffix(unit, "\xC2\xB5J")
        || sb_string_has_suffix(unit, "\xCE\xBCJ")) {
        *joules_out = rawValue / 1000000.0;
        return true;
    }
    if (sb_string_has_suffix(unit, "nJ")) {
        *joules_out = rawValue / 1000000000.0;
        return true;
    }
    if (sb_string_has_suffix(unit, "pJ")) {
        *joules_out = rawValue / 1000000000000.0;
        return true;
    }
    if (sb_string_has_suffix(unit, "J")) {
        *joules_out = rawValue;
        return true;
    }

    return false;
}

static bool sb_read_energy_joules(SBPowerEnergyJoules* totals_out) {
    if (totals_out == NULL || g_energyChannels == NULL || g_energySubscription == NULL) {
        return false;
    }
    if (!sb_load_ioreport_symbols()) {
        return false;
    }

    sb_reset_energy_totals(totals_out);

    CFDictionaryRef sample = g_IOReportCreateSamples(g_energySubscription, g_energyChannels, NULL);
    if (sample == NULL) {
        return false;
    }

    CFArrayRef channels = (CFArrayRef)CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    if (channels == NULL) {
        CFRelease(sample);
        return false;
    }

    const CFIndex count = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < count; i++) {
        const void* value = CFArrayGetValueAtIndex(channels, i);
        if (value == NULL) {
            continue;
        }

        CFDictionaryRef channel = (CFDictionaryRef)value;
        CFStringRef groupRef = g_IOReportChannelGetGroup(channel);
        CFStringRef nameRef = g_IOReportChannelGetChannelName(channel);
        if (groupRef == NULL || nameRef == NULL) {
            continue;
        }
        if (CFStringCompare(groupRef, CFSTR("Energy Model"), kCFCompareCaseInsensitive) != kCFCompareEqualTo) {
            continue;
        }

        char channelName[256] = {0};
        if (!CFStringGetCString(nameRef, channelName, sizeof(channelName), kCFStringEncodingUTF8)) {
            continue;
        }

        if (strcasestr(channelName, "Energy") == NULL) {
            continue;
        }

        const int componentFlag = sb_classify_energy_channel(channelName);
        if (componentFlag == 0) {
            continue;
        }

        const int64_t rawValue = g_IOReportSimpleGetIntegerValue(channel, 0);
        CFStringRef unitRef = g_IOReportChannelGetUnitLabel(channel);
        double joules = NAN;
        if (!sb_energy_value_to_joules((double)rawValue, unitRef, &joules)) {
            continue;
        }
        switch (componentFlag) {
        case SB_IOREPORT_POWER_CPU_FLAG:
            sb_add_energy_value(&totals_out->cpu, &totals_out->flags, componentFlag, joules);
            break;
        case SB_IOREPORT_POWER_GPU_FLAG:
            sb_add_energy_value(&totals_out->gpu, &totals_out->flags, componentFlag, joules);
            break;
        case SB_IOREPORT_POWER_ANE_FLAG:
            sb_add_energy_value(&totals_out->ane, &totals_out->flags, componentFlag, joules);
            break;
        case SB_IOREPORT_POWER_RAM_FLAG:
            sb_add_energy_value(&totals_out->ram, &totals_out->flags, componentFlag, joules);
            break;
        case SB_IOREPORT_POWER_PACKAGE_FLAG:
            sb_add_energy_value(&totals_out->package, &totals_out->flags, componentFlag, joules);
            break;
        default:
            break;
        }
    }

    CFRelease(sample);
    return sb_energy_totals_has_any(totals_out);
}

int sb_ioreport_open(void) {
    if (g_energyChannels != NULL && g_energySubscription != NULL) {
        return (int)kIOReturnSuccess;
    }
    if (!sb_load_ioreport_symbols()) {
        return (int)kIOReturnUnsupported;
    }

    CFDictionaryRef copied = g_IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (copied == NULL) {
        return (int)kIOReturnNotFound;
    }

    const CFIndex size = CFDictionaryGetCount(copied);
    CFMutableDictionaryRef mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, copied);
    CFRelease(copied);
    if (mutableChannels == NULL) {
        return (int)kIOReturnNoMemory;
    }

    CFMutableDictionaryRef subscriptionDict = NULL;
    IOReportSubscriptionRef subscription = g_IOReportCreateSubscription(NULL, mutableChannels, &subscriptionDict, 0, NULL);
    if (subscriptionDict != NULL) {
        CFRelease(subscriptionDict);
    }

    if (subscription == NULL) {
        CFRelease(mutableChannels);
        return (int)kIOReturnError;
    }

    g_energyChannels = mutableChannels;
    g_energySubscription = subscription;
    sb_reset_energy_totals(&g_prevEnergyJoules);
    g_prevEnergySampleTime = 0;

    SBPowerEnergyJoules initialEnergy;
    if (sb_read_energy_joules(&initialEnergy)) {
        g_prevEnergyJoules = initialEnergy;
        g_prevEnergySampleTime = CFAbsoluteTimeGetCurrent();
    }

    return (int)kIOReturnSuccess;
}

void sb_ioreport_close(void) {
    if (g_energyChannels != NULL) {
        CFRelease(g_energyChannels);
        g_energyChannels = NULL;
    }
    if (g_energySubscription != NULL) {
        CFRelease(g_energySubscription);
        g_energySubscription = NULL;
    }
    sb_reset_energy_totals(&g_prevEnergyJoules);
    g_prevEnergySampleTime = 0;
}

static bool sb_write_power_delta_if_valid(
    double current,
    double previous,
    double deltaTime,
    double* watts_out
) {
    if (watts_out == NULL || !isfinite(current) || !isfinite(previous) || !isfinite(deltaTime) || deltaTime <= 0.05) {
        return false;
    }
    const double deltaEnergy = current - previous;
    if (!isfinite(deltaEnergy) || deltaEnergy < 0) {
        return false;
    }
    const double watts = deltaEnergy / deltaTime;
    if (!isfinite(watts) || watts < 0 || watts > SB_MAX_POWER_WATTS) {
        return false;
    }
    *watts_out = watts;
    return true;
}

int sb_ioreport_read_power(
    double* cpu_power_watts_out,
    double* gpu_power_watts_out,
    double* ane_power_watts_out,
    double* ram_power_watts_out,
    double* package_power_watts_out,
    int* available_mask_out
) {
    if (cpu_power_watts_out == NULL
        || gpu_power_watts_out == NULL
        || ane_power_watts_out == NULL
        || ram_power_watts_out == NULL
        || package_power_watts_out == NULL
        || available_mask_out == NULL) {
        return (int)kIOReturnBadArgument;
    }
    *cpu_power_watts_out = 0.0;
    *gpu_power_watts_out = 0.0;
    *ane_power_watts_out = 0.0;
    *ram_power_watts_out = 0.0;
    *package_power_watts_out = 0.0;
    *available_mask_out = 0;

    int openStatus = sb_ioreport_open();
    if (openStatus != kIOReturnSuccess) {
        return openStatus;
    }

    SBPowerEnergyJoules currentEnergy;
    if (!sb_read_energy_joules(&currentEnergy)) {
        return (int)kIOReturnNotFound;
    }

    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!sb_energy_totals_has_any(&g_prevEnergyJoules) || g_prevEnergySampleTime <= 0) {
        g_prevEnergyJoules = currentEnergy;
        g_prevEnergySampleTime = now;
        return (int)kIOReturnNotReady;
    }

    const double deltaTime = now - g_prevEnergySampleTime;

    int mask = 0;
    if ((currentEnergy.flags & SB_IOREPORT_POWER_CPU_FLAG) != 0
        && (g_prevEnergyJoules.flags & SB_IOREPORT_POWER_CPU_FLAG) != 0
        && sb_write_power_delta_if_valid(currentEnergy.cpu, g_prevEnergyJoules.cpu, deltaTime, cpu_power_watts_out)) {
        mask |= SB_IOREPORT_POWER_CPU_FLAG;
    }
    if ((currentEnergy.flags & SB_IOREPORT_POWER_GPU_FLAG) != 0
        && (g_prevEnergyJoules.flags & SB_IOREPORT_POWER_GPU_FLAG) != 0
        && sb_write_power_delta_if_valid(currentEnergy.gpu, g_prevEnergyJoules.gpu, deltaTime, gpu_power_watts_out)) {
        mask |= SB_IOREPORT_POWER_GPU_FLAG;
    }
    if ((currentEnergy.flags & SB_IOREPORT_POWER_ANE_FLAG) != 0
        && (g_prevEnergyJoules.flags & SB_IOREPORT_POWER_ANE_FLAG) != 0
        && sb_write_power_delta_if_valid(currentEnergy.ane, g_prevEnergyJoules.ane, deltaTime, ane_power_watts_out)) {
        mask |= SB_IOREPORT_POWER_ANE_FLAG;
    }
    if ((currentEnergy.flags & SB_IOREPORT_POWER_RAM_FLAG) != 0
        && (g_prevEnergyJoules.flags & SB_IOREPORT_POWER_RAM_FLAG) != 0
        && sb_write_power_delta_if_valid(currentEnergy.ram, g_prevEnergyJoules.ram, deltaTime, ram_power_watts_out)) {
        mask |= SB_IOREPORT_POWER_RAM_FLAG;
    }
    if ((currentEnergy.flags & SB_IOREPORT_POWER_PACKAGE_FLAG) != 0
        && (g_prevEnergyJoules.flags & SB_IOREPORT_POWER_PACKAGE_FLAG) != 0
        && sb_write_power_delta_if_valid(currentEnergy.package, g_prevEnergyJoules.package, deltaTime, package_power_watts_out)) {
        mask |= SB_IOREPORT_POWER_PACKAGE_FLAG;
    }

    g_prevEnergyJoules = currentEnergy;
    g_prevEnergySampleTime = now;
    *available_mask_out = mask;

    if (!isfinite(deltaTime) || deltaTime <= 0.05) {
        return (int)kIOReturnNotReady;
    }
    if (mask == 0) {
        return (int)kIOReturnAborted;
    }

    return (int)kIOReturnSuccess;
}

int sb_ioreport_read_gpu_power(double* gpu_power_watts_out) {
    if (gpu_power_watts_out == NULL) {
        return (int)kIOReturnBadArgument;
    }

    double cpu = 0.0;
    double gpu = 0.0;
    double ane = 0.0;
    double ram = 0.0;
    double package = 0.0;
    int mask = 0;
    int status = sb_ioreport_read_power(&cpu, &gpu, &ane, &ram, &package, &mask);
    if (status != kIOReturnSuccess) {
        return status;
    }
    if ((mask & SB_IOREPORT_POWER_GPU_FLAG) == 0) {
        return (int)kIOReturnNotFound;
    }
    *gpu_power_watts_out = gpu;
    return (int)kIOReturnSuccess;
}
