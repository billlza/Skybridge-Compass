#!/usr/bin/env python3
"""Export and verify the shared Apple cloud field against the Android visual baseline."""
import argparse
from pathlib import Path
from PIL import Image

PREFIX = """#include <metal_stdlib>
using namespace metal;

struct CloudUniforms {
    float2 resolution;
    float time;
    float quality;
    float intensity;
    float wind;
    float2 padding;
};
struct CloudVertex { float4 position [[position]]; float2 uv; };
vertex CloudVertex cloudVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
}
float cl01(float x) { return saturate(x); }
float3 toLinearSrgb(float3 color) {
    return mix(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), color));
}
float3 fromLinearSrgb(float3 color) {
    color = max(color, float3(0.0));
    return mix(color * 12.92, 1.055 * pow(color, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), color));
}
constexpr sampler cloudSampler(coord::normalized, address::clamp_to_edge, filter::linear);
struct CloudField {
    texture2d<float> cloudNoiseAtlas;
    float2 iResolution;
    float quality;
"""
SUFFIX = """
};
fragment float4 cloudFragment(CloudVertex stageInput [[stage_in]], constant CloudUniforms &uniforms [[buffer(0)]],
                              texture2d<float> atlas [[texture(0)]]) {
    CloudField field = {atlas, uniforms.resolution, uniforms.quality};
    return field.cloudySky(stageInput.uv, uniforms.time, uniforms.intensity, uniforms.wind);
}
"""

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-root', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    resources = root / 'Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/Resources'
    source = (args.android_root / 'app/src/main/kotlin/com/skybridge/compass/android/ui/components/CinematicCloudsAgsl.kt').read_text()
    source = source.split('val SOURCE = """', 1)[1].split('""".trimIndent()', 1)[0].strip()
    source = source.replace('cloudNoiseAtlas.eval(cloudSliceOrigin(slice) + voxel.xy)',
        'cloudNoiseAtlas.sample(cloudSampler, (cloudSliceOrigin(slice) + voxel.xy) / 528.0)')
    source = source.replace('cloudNoiseAtlas.eval(cloudSliceOrigin(mod(slice + 1.0, 64.0)) + voxel.xy)',
        'cloudNoiseAtlas.sample(cloudSampler, (cloudSliceOrigin(mod(slice + 1.0, 64.0)) + voxel.xy) / 528.0)')
    source = source.replace('mod(', 'fmod(').replace('half3(', 'float3(')
    source = source.replace('Android must not apply color conversion', 'the renderer must not apply color conversion')
    if '.eval(' in source:
        raise ValueError('Untranslated density texture lookup')
    shader = (PREFIX + source + SUFFIX).encode()
    with Image.open(args.android_root / 'app/src/main/res/drawable-nodpi/cloud_noise_volume.png') as image:
        if image.size != (528, 528):
            raise ValueError('Expected a 528 x 528 density atlas')
        density = image.convert('RGBA').tobytes()
    for name, data in [('CloudVolume.metal', shader), ('cloud_noise_volume.rgba', density)]:
        path = resources / name
        if args.check:
            if path.read_bytes() != data:
                raise ValueError(f'{path} differs from the Android cloud field')
        else:
            path.write_bytes(data)
        print(f'{name}: exact match' if args.check else f'{name}: exported')

if __name__ == '__main__':
    main()
