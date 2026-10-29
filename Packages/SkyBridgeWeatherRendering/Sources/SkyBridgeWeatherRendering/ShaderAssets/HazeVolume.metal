#include <metal_stdlib>
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
float hazeHash(float3 p) {
    p = fract(p * 0.1031);
    float hashOffset = dot(p, p.zyx + float3(31.32, 31.32, 31.32));
    p += float3(hashOffset, hashOffset, hashOffset);
    return fract((p.x + p.y) * p.z);
}

float hazeNoise(float3 p) {
    float3 cell = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float nearPlane = mix(
        mix(hazeHash(cell), hazeHash(cell + float3(1.0, 0.0, 0.0)), f.x),
        mix(hazeHash(cell + float3(0.0, 1.0, 0.0)), hazeHash(cell + float3(1.0, 1.0, 0.0)), f.x), f.y);
    float farPlane = mix(
        mix(hazeHash(cell + float3(0.0, 0.0, 1.0)), hazeHash(cell + float3(1.0, 0.0, 1.0)), f.x),
        mix(hazeHash(cell + float3(0.0, 1.0, 1.0)), hazeHash(cell + float3(1.0, 1.0, 1.0)), f.x), f.y);
    return mix(nearPlane, farPlane, f.z);
}

float3 hazeToLinear(float3 color) {
    return mix(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(float3(0.04045, 0.04045, 0.04045), color));
}

float3 hazeToDisplay(float3 color) {
    color = max(color, float3(0.0, 0.0, 0.0));
    return mix(color * 12.92, 1.055 * pow(color, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(float3(0.0031308, 0.0031308, 0.0031308), color));
}

float3 hazeViewRay(float2 uv, float2 viewport) {
    return normalize(float3((uv.x - 0.5) * viewport.x / viewport.y, 0.61 - uv.y, 1.5));
}

float hazeTerrainHeight(float x, float seed) {
    float broad = hazeNoise(float3(x * 0.46, seed, 0.7));
    float detail = hazeNoise(float3(x * 1.31, seed + 8.3, 0.2));
    float ridge = abs(hazeNoise(float3(x * 3.7, seed + 21.4, 1.3)) - 0.5);
    return broad * 0.62 + detail * 0.26 + ridge * 0.24;
}

float4 cinematicHaze(float2 uv, float2 viewport, float time, float intensity, float wind,
                     float quality, float3 tint, float grainAmount, float2 flowOffset) {
    float amount = clamp(intensity, 0.0, 1.0);
    float3 ray = hazeViewRay(uv, viewport);
    float3 sunDirection = normalize(float3(0.10, 0.41, 1.5));
    float alignment = max(dot(ray, sunDirection), 0.0);
    float halo = exp((alignment - 1.0) * 46.0);
    float sunDisc = smoothstep(0.999975, 0.999991, alignment);

    // Dense aerosols mute blue light first. The distant sun shares the scattering direction.
    float3 warmLight = hazeToLinear(mix(float3(0.93, 0.84, 0.69), tint, 0.22));
    float3 upperSky = hazeToLinear(float3(0.25, 0.32, 0.38));
    float3 horizon = hazeToLinear(mix(float3(0.60, 0.57, 0.50), tint, 0.25));
    float3 sky = mix(upperSky, horizon, smoothstep(0.03, 0.64, uv.y));
    sky += warmLight * (halo * 0.23 + sunDisc * 1.4);

    // Quiet distant terrain gives the aerosol a measurable depth reference. Each ridge
    // terminates the same atmosphere ray at its actual distance; no screen-space fog blobs.
    float rayLength = 18.0;
    for (int ridgeIndex = 0; ridgeIndex < 3; ridgeIndex += 1) {
        float ridge = float(ridgeIndex);
        float planeDepth = 16.0 - ridge * 5.0;
        float hitDistance = planeDepth / ray.z;
        float x = ray.x * hitDistance;
        float height = hazeTerrainHeight(x, 4.7 + ridge * 13.3) * (2.1 - ridge * 0.38) - ridge * 0.40;
        float y = 1.1 + ray.y * hitDistance;
        float coverage = 1.0 - smoothstep(-0.025, 0.025, y - height);
        float3 terrain = hazeToLinear(mix(float3(0.20, 0.27, 0.31), float3(0.085, 0.13, 0.17), ridge * 0.5));
        float surfaceDetail = hazeNoise(float3(x * 3.8, y * 5.1, 9.0 + ridge));
        terrain *= mix(0.76, 1.15, surfaceDetail);
        sky = mix(sky, terrain, coverage);
        rayLength = mix(rayLength, hitDistance, coverage);
    }

    float3 transmittance = float3(1.0, 1.0, 1.0);
    float3 scatteredLight = float3(0.0, 0.0, 0.0);
    float g = 0.68;
    float phase = (1.0 - g * g) / (12.5663706 * pow(1.0 + g * g - 2.0 * g * alignment, 1.5));
    float3 drift = float3(time * (0.018 + clamp(wind, 0.0, 1.0) * 0.038), 0.0, time * 0.009);
    drift += float3(flowOffset.x * 4.0, -flowOffset.y * 4.0, 0.0);
    float stepLength = rayLength / (quality > 0.65 ? 24.0 : 12.0);
    for (int stepIndex = 0; stepIndex < 24; stepIndex += 1) {
        if (quality <= 0.65 && stepIndex >= 12) break;
        float distance = (float(stepIndex) + 0.5) * stepLength;
        float3 position = float3(0.0, 1.1, 0.0) + ray * distance;
        float field = hazeNoise(position * float3(0.38, 0.55, 0.31) + drift);
        float layer = exp(-max(position.y - 0.2, 0.0) * 0.36);
        float density = mix(0.045, 0.24, amount) * layer * mix(0.62, 1.38, field);
        float3 extinction = density * float3(0.78, 0.95, 1.22);
        float3 segment = exp(-extinction * stepLength);
        float3 lightPosition = position + sunDirection * max((7.0 - position.y) / sunDirection.y, 0.0);
        float lightVeil = hazeNoise(lightPosition * float3(0.30, 0.19, 0.30) + drift * 0.42);
        float sunVisibility = exp(-density * (2.5 + distance * 0.22) - smoothstep(0.32, 0.76, lightVeil) * 2.0);
        float3 ambient = hazeToLinear(float3(0.37, 0.40, 0.43));
        float3 lighting = ambient * 0.42 + warmLight * phase * sunVisibility * 2.0;
        scatteredLight += transmittance * (float3(1.0, 1.0, 1.0) - segment) * lighting;
        transmittance *= segment;
    }

    float3 color = sky * transmittance + scatteredLight;
    // A quiet foreground preserves the existing dashboard's light text and controls.
    color = mix(color, hazeToLinear(float3(0.065, 0.085, 0.12)), smoothstep(0.57, 1.0, uv.y) * 0.91);
    float2 edge = float2((uv.x - 0.5) * viewport.x / viewport.y, uv.y - 0.46);
    color *= 1.0 - 0.10 * smoothstep(0.2, 0.95, length(edge));
    float grain = (hazeNoise(float3(uv * viewport * 0.52, time * 0.4)) - 0.5) * 0.003;
    float grainOffset = grain * grainAmount * quality;
    color = hazeToDisplay(color) + float3(grainOffset, grainOffset, grainOffset);
    return float4(clamp(color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), 1.0);
}
fragment float4 hazeFragment(HazeVertex stageInput [[stage_in]],
                             constant AtmosphereUniforms &uniforms [[buffer(0)]],
                             constant HazeAppearance &appearance [[buffer(1)]]) {
    return cinematicHaze(stageInput.uv, uniforms.resolution, uniforms.time, uniforms.intensity,
                         uniforms.wind, uniforms.quality, appearance.tint, appearance.grain, float2(0.0));
}
