#include "PrivateSensorBridgeC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
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

static CFMutableDictionaryRef g_energyChannels = NULL;
static IOReportSubscriptionRef g_energySubscription = NULL;
static double g_prevGPUEnergyJoules = NAN;
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

static bool sb_is_cpu_temp_name(NSString* name) {
    if (name == nil) {
        return false;
    }
    NSString* lowered = name.lowercaseString;
    if ([lowered hasPrefix:@"pacc mtr temp"] || [lowered hasPrefix:@"eacc mtr temp"]) {
        return true;
    }
    return [lowered containsString:@"cpu"] || [lowered containsString:@"pcore"] || [lowered containsString:@"ecore"];
}

static bool sb_is_gpu_temp_name(NSString* name) {
    if (name == nil) {
        return false;
    }
    NSString* lowered = name.lowercaseString;
    if ([lowered hasPrefix:@"gpu mtr temp"]) {
        return true;
    }
    return [lowered containsString:@"gpu"] || [lowered containsString:@"gfx"];
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

static double sb_energy_value_to_joules(double rawValue, CFStringRef unitRef) {
    char unit[32] = {0};
    if (unitRef != NULL) {
        CFStringGetCString(unitRef, unit, sizeof(unit), kCFStringEncodingUTF8);
    }

    if (sb_string_has_suffix(unit, "mJ")) {
        return rawValue / 1000.0;
    }
    if (sb_string_has_suffix(unit, "uJ")) {
        return rawValue / 1000000.0;
    }
    if (sb_string_has_suffix(unit, "nJ")) {
        return rawValue / 1000000000.0;
    }
    if (sb_string_has_suffix(unit, "J")) {
        return rawValue;
    }

    // Some platforms omit unit labels. Treat values as milli-joules as a conservative default.
    return rawValue / 1000.0;
}

static bool sb_read_gpu_energy_joules(double* joules_out) {
    if (joules_out == NULL || g_energyChannels == NULL || g_energySubscription == NULL) {
        return false;
    }
    if (!sb_load_ioreport_symbols()) {
        return false;
    }

    CFDictionaryRef sample = g_IOReportCreateSamples(g_energySubscription, g_energyChannels, NULL);
    if (sample == NULL) {
        return false;
    }

    CFArrayRef channels = (CFArrayRef)CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    if (channels == NULL) {
        CFRelease(sample);
        return false;
    }

    double gpuEnergyJ = 0.0;
    bool found = false;

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

        if (strcasestr(channelName, "GPU") == NULL || strcasestr(channelName, "Energy") == NULL) {
            continue;
        }

        const int64_t rawValue = g_IOReportSimpleGetIntegerValue(channel, 0);
        CFStringRef unitRef = g_IOReportChannelGetUnitLabel(channel);
        gpuEnergyJ += sb_energy_value_to_joules((double)rawValue, unitRef);
        found = true;
    }

    CFRelease(sample);

    if (!found || !isfinite(gpuEnergyJ)) {
        return false;
    }

    *joules_out = gpuEnergyJ;
    return true;
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
    g_prevGPUEnergyJoules = NAN;
    g_prevEnergySampleTime = 0;

    double initialEnergy = 0.0;
    if (sb_read_gpu_energy_joules(&initialEnergy)) {
        g_prevGPUEnergyJoules = initialEnergy;
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
    g_prevGPUEnergyJoules = NAN;
    g_prevEnergySampleTime = 0;
}

int sb_ioreport_read_gpu_power(double* gpu_power_watts_out) {
    if (gpu_power_watts_out == NULL) {
        return (int)kIOReturnBadArgument;
    }
    *gpu_power_watts_out = 0.0;

    int openStatus = sb_ioreport_open();
    if (openStatus != kIOReturnSuccess) {
        return openStatus;
    }

    double currentEnergy = 0.0;
    if (!sb_read_gpu_energy_joules(&currentEnergy)) {
        return (int)kIOReturnNotFound;
    }

    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!isfinite(g_prevGPUEnergyJoules) || g_prevEnergySampleTime <= 0) {
        g_prevGPUEnergyJoules = currentEnergy;
        g_prevEnergySampleTime = now;
        return (int)kIOReturnNotReady;
    }

    const double deltaEnergy = currentEnergy - g_prevGPUEnergyJoules;
    const double deltaTime = now - g_prevEnergySampleTime;

    g_prevGPUEnergyJoules = currentEnergy;
    g_prevEnergySampleTime = now;

    if (!isfinite(deltaEnergy) || !isfinite(deltaTime) || deltaTime <= 0.05) {
        return (int)kIOReturnNotReady;
    }
    if (deltaEnergy < 0) {
        return (int)kIOReturnAborted;
    }

    const double watts = deltaEnergy / deltaTime;
    if (!isfinite(watts) || watts < 0 || watts > 300) {
        return (int)kIOReturnError;
    }

    *gpu_power_watts_out = watts;
    return (int)kIOReturnSuccess;
}
