#!/usr/bin/env python3
"""Export and verify the shared aerosol field for the native weather renderers."""
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
struct HazeAppearance { float3 tint; float grain; };
struct HazeVertex { float4 position [[position]]; float2 uv; };
vertex HazeVertex hazeVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
}
"""
METAL_SUFFIX = """
fragment float4 hazeFragment(HazeVertex stageInput [[stage_in]],
                             constant AtmosphereUniforms &uniforms [[buffer(0)]],
                             constant HazeAppearance &appearance [[buffer(1)]]) {
    return cinematicHaze(stageInput.uv, uniforms.resolution, uniforms.time, uniforms.intensity,
                         uniforms.wind, uniforms.quality, appearance.tint, appearance.grain, float2(0.0));
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-root', type=Path, required=True)
    parser.add_argument('--windows-root', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    path = args.android_root / 'app/src/main/kotlin/com/skybridge/compass/android/ui/components/CinematicHazeAgsl.kt'
    source = read_agsl(path)
    windows_path = args.windows_root / 'windows/Skybridge.WinClient/WeatherBackdropDX.xaml.cs'
    windows = replace_field(windows_path.read_text(), 'AEROSOL FIELD', source)
    outputs = {
        root / 'Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/ShaderAssets/HazeVolume.metal': METAL_PREFIX + source + METAL_SUFFIX,
        windows_path: windows,
    }
    write_outputs(outputs, args.check)


if __name__ == '__main__':
    main()
