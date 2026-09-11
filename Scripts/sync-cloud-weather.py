#!/usr/bin/env python3
"""Export the accepted Android cloud field and density atlas for Direct3D 12."""
import argparse
import re
from pathlib import Path

from PIL import Image


def hlsl(source: str) -> str:
    source = source.split('val SOURCE = """', 1)[1].split('""".trimIndent()', 1)[0].strip()
    source = source.replace(
        'cloudNoiseAtlas.eval(cloudSliceOrigin(slice) + voxel.xy)',
        'cloudNoiseAtlas.SampleLevel(cloudSampler, (cloudSliceOrigin(slice) + voxel.xy) / 528.0, 0)')
    source = source.replace(
        'cloudNoiseAtlas.eval(cloudSliceOrigin(mod(slice + 1.0, 64.0)) + voxel.xy)',
        'cloudNoiseAtlas.SampleLevel(cloudSampler, (cloudSliceOrigin(mod(slice + 1.0, 64.0)) + voxel.xy) / 528.0, 0)')
    source = source.replace('mix(', 'lerp(').replace('fract(', 'frac(').replace('mod(', 'fmod(')
    source = source.replace('half3(', 'float3(').replace('iResolution', 'resolution')
    # AGSL/Metal permit a scalar splat constructor; FXC requires every component.
    source = re.sub(r'\bfloat([234])\(([-+]?[0-9]+(?:\.[0-9]*)?)\)',
                    lambda match: 'float' + match[1] + '(' + ', '.join([match[2]] * int(match[1])) + ')', source)
    source = source.replace('float3 near =', 'float3 nearSlice =').replace('float3 far =', 'float3 farSlice =')
    source = source.replace('lerp(near, far,', 'lerp(nearSlice, farSlice,')
    source = source.replace('float windAmt) {', 'float windAmt, float quality) {')
    source = source.replace('Android must not apply color conversion', 'the renderer must not apply color conversion')
    if '.eval(' in source or not source.isascii():
        raise ValueError('Cloud source contains an unsupported texture lookup or non-ASCII HLSL')
    return '''Texture2D<float4> cloudNoiseAtlas : register(t1);
SamplerState cloudSampler : register(s1);
float cl01(float x) { return saturate(x); }
float3 toLinearSrgb(float3 color) {
    return lerp(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(float3(0.04045, 0.04045, 0.04045), color));
}
float3 fromLinearSrgb(float3 color) {
    color = max(color, float3(0.0, 0.0, 0.0));
    return lerp(color * 12.92, 1.055 * pow(color, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(float3(0.0031308, 0.0031308, 0.0031308), color));
}
''' + source + '\n'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-root', required=True, type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    renderer = root / 'windows/Skybridge.WinClient/WeatherBackdropDX.xaml.cs'
    source = (args.android_root / 'app/src/main/kotlin/com/skybridge/compass/android/ui/components/CinematicCloudsAgsl.kt').read_text()
    text = renderer.read_text()
    begin, end = '// BEGIN CLOUD OPTICS\n', '// END CLOUD OPTICS'
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError('Expected one bounded cloud shader section')
    start = text.index(begin) + len(begin)
    finish = text.index(end, start)
    exported = text[:start] + hlsl(source) + text[finish:]
    with Image.open(args.android_root / 'app/src/main/res/drawable-nodpi/cloud_noise_volume.png') as image:
        if image.size != (528, 528):
            raise ValueError('Cloud atlas dimensions differ from the shared volume contract')
        rgba = image.convert('RGBA').tobytes()
    outputs = {renderer: exported.encode(), root / 'windows/Skybridge.WinClient/Resources/cloud_noise_volume.rgba': rgba}
    for path, data in outputs.items():
        if args.check:
            if path.read_bytes() != data:
                raise ValueError(f'{path.name} differs from the Android cloud field')
        else:
            path.write_bytes(data)
        print(path.name + (': exact match' if args.check else ': exported'))


if __name__ == '__main__':
    main()
