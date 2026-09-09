#!/usr/bin/env python3
"""Export and verify the shared aerosol field for the native weather renderers."""
import argparse
from pathlib import Path

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
                         uniforms.wind, uniforms.quality, appearance.tint, appearance.grain);
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
    source = path.read_text().split('val SOURCE = """', 1)[1].split('""".trimIndent()', 1)[0].strip()
    if '"' in source or not source.isascii():
        raise ValueError('The shared shader must be ASCII with no embedded string literals')
    hlsl = source.replace('fract(', 'frac(').replace('mix(', 'lerp(')
    windows = 'namespace Skybridge.WinClient;\n\ninternal static class CinematicHazeShader\n{\n    internal const string Source = @"\n' + hlsl + '\n";\n}\n'
    outputs = {
        root / 'Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/Resources/HazeVolume.metal': METAL_PREFIX + source + METAL_SUFFIX,
        args.windows_root / 'windows/Skybridge.WinClient/CinematicHazeShader.cs': windows,
    }
    for output, text in outputs.items():
        if args.check:
            if output.read_text() != text:
                raise ValueError(f'{output} differs from the shared aerosol field')
        else:
            output.write_text(text)
        print(f'{output.name}: ' + ('exact match' if args.check else 'exported'))


if __name__ == '__main__':
    main()
