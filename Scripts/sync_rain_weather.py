#!/usr/bin/env python3
"""Export and verify rain optics for the native weather renderers."""
import argparse
from pathlib import Path

from weather_shader_export import read_agsl, replace_field, write_outputs

METAL_PREFIX = """#include <metal_stdlib>
using namespace metal;
struct AtmosphereUniforms {
    float2 resolution;
    float time;
    float quality;
    float intensity;
    float wind;
    float2 padding;
};
struct RainParameters { float storm; float allowFlash; uint glassCount; uint clearCount; float4 glassOptions; };
struct RainVertex { float4 position [[position]]; float2 uv; };
vertex RainVertex rainVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
}
"""
METAL_SUFFIX = """
float rainClearMask(float2 uv, float2 resolution, uint count, constant float4 *zones) {
    float mask = 1.0;
    for (uint index = 0; index < count; index++) {
        float4 zone = zones[index];
        float distance = length((uv - zone.xy) * float2(resolution.x / resolution.y, 1.0));
        mask *= 1.0 - (1.0 - smoothstep(0.0, zone.z, distance)) * zone.w;
    }
    return mask;
}

fragment float4 rainFragment(RainVertex input [[stage_in]],
                             constant AtmosphereUniforms &u [[buffer(0)]],
                             constant RainParameters &rain [[buffer(1)]],
                             constant float4 *glass [[buffer(2)]],
                             constant float4 *clearZones [[buffer(3)]]) {
    float disperse = rainClearMask(input.uv, u.resolution, rain.clearCount, clearZones);
    return cinematicRain(input.uv, u.resolution, u.time, u.intensity, u.wind,
                          u.quality, rain.storm, rain.allowFlash, disperse, float2(0.0));
}

struct RainGlassVertex { float4 position [[position]]; float2 uv; uint region [[flat]]; };
vertex RainGlassVertex rainGlassVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                       constant AtmosphereUniforms &u [[buffer(0)]],
                                       constant float4 *glass [[buffer(2)]]) {
    uint region = instance / 4;
    uint edge = instance % 4;
    float4 rect = glass[region * 2];
    float2 margin = float2(14.0 * max(u.resolution.y / 900.0, 0.4)) / u.resolution;
    // Four non-overlapping strips. The untouched glass interior costs no fragments.
    float2 low = rect.xy - margin;
    float2 high = rect.xy + rect.zw + margin;
    if (edge == 0) high.y = rect.y + min(margin.y, rect.w * 0.5);
    if (edge == 1) low.y = rect.y + max(rect.w - margin.y, rect.w * 0.5);
    if (edge >= 2) {
        low.y = rect.y + min(margin.y, rect.w * 0.5);
        high.y = rect.y + max(rect.w - margin.y, rect.w * 0.5);
        if (edge == 2) high.x = rect.x + min(margin.x, rect.z * 0.5);
        else low.x = rect.x + max(rect.z - margin.x, rect.z * 0.5);
    }
    constexpr float2 corners[] = {float2(0,0), float2(1,0), float2(0,1),
                                  float2(0,1), float2(1,0), float2(1,1)};
    float2 uv = mix(low, high, corners[id]);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv, region};
}

fragment float4 rainGlassFragment(RainGlassVertex input [[stage_in]],
                                  constant AtmosphereUniforms &u [[buffer(0)]],
                                  constant RainParameters &rain [[buffer(1)]],
                                  constant float4 *glass [[buffer(2)]],
                                  constant float4 *clearZones [[buffer(3)]]) {
    float disperse = rainClearMask(input.uv, u.resolution, rain.clearCount, clearZones);
    float4 wet = rainWetGlass(input.uv, u.resolution, u.time, glass[input.region * 2],
                              glass[input.region * 2 + 1].x, u.intensity * disperse);
    wet.w *= rain.glassOptions.x;
    return float4(wet.rgb * wet.w, wet.w);
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-root', type=Path, required=True)
    parser.add_argument('--windows-root', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = read_agsl(args.android_root / 'app/src/main/kotlin/com/skybridge/compass/android/ui/components/CinematicRainAgsl.kt')
    windows = args.windows_root / 'windows/Skybridge.WinClient/WeatherBackdropDX.xaml.cs'
    write_outputs({
        root / 'Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/ShaderAssets/RainVolume.metal': METAL_PREFIX + source + METAL_SUFFIX,
        windows: replace_field(windows.read_text(), 'RAIN OPTICS', source),
    }, args.check)


if __name__ == '__main__':
    main()
