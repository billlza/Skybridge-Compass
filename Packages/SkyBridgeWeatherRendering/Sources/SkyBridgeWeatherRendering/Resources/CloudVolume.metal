#include <metal_stdlib>
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
float2 cloudSliceOrigin(float z) {
    return float2(fmod(z, 8.0), floor(z / 8.0)) * 66.0 + float2(1.5);
}

float3 cloudVolume(float3 p) {
    // Two bilinear samples reconstruct a periodic trilinear volume. The input is a data
    // buffer, so the renderer must not apply color conversion to these density channels.
    float3 voxel = fract(p) * 64.0;
    float slice = floor(voxel.z);
    float3 near = float3(cloudNoiseAtlas.sample(cloudSampler, (cloudSliceOrigin(slice) + voxel.xy) / 528.0).rgb);
    float3 far = float3(cloudNoiseAtlas.sample(cloudSampler, (cloudSliceOrigin(fmod(slice + 1.0, 64.0)) + voxel.xy) / 528.0).rgb);
    return mix(near, far, fract(voxel.z));
}

float cloudDensity(float3 p, float detail) {
    float3 field = cloudVolume(p * 0.22);
    float shape = field.r * 0.60 + field.b * 0.40;
    float body = shape - 0.445;
    float erosion = 0.5;
    if (detail > 0.65) {
        erosion = cloudVolume(p * 0.63 + float3(0.17, 0.31, 0.73)).g;
    }
    body -= (1.0 - erosion) * 0.15 * (1.0 - smoothstep(0.0, 0.20, body));
    float base = smoothstep(0.0, 0.10, p.y);
    float top = 1.0 - smoothstep(0.48, 0.90, p.y);
    return max(body, 0.0) * 20.0 * base * top;
}

float3 cloudViewRay(float2 uv) {
    // A fixed vertical field of view preserves the volume's proportions on wide screens.
    float aspect = iResolution.x / max(iResolution.y, 1.0);
    float3 forward = normalize(float3(0.0, 0.65, 1.0));
    float3 cameraUp = float3(0.0, forward.z, -forward.y);
    float2 film = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);
    return normalize(forward + float3(film.x, 0.0, 0.0) + cameraUp * film.y);
}

float4 cloudySky(float2 uv, float t, float amp, float windAmt) {
    float3 ray = cloudViewRay(uv);
    float3 sun = normalize(float3(0.65, 0.62, 0.44));
    float sunlight = pow(cl01(dot(ray, sun)), 18.0);
    float3 sky = mix(float3(0.12, 0.23, 0.36), float3(0.38, 0.49, 0.58), cl01(uv.y * 1.1));
    sky += float3(0.20, 0.17, 0.11) * sunlight;
    sky = float3(toLinearSrgb(float3(sky)));

    float start = 2.4 / ray.y;
    float end = min(3.3 / ray.y, 24.0);
    float steps = quality > 0.65 ? 48.0 : 24.0;
    float stepSize = (end - start) / steps;
    // Stratified, screen-stable offsets break up visible march planes without temporal flicker.
    float jitter = fract(52.9829189 * fract(dot(floor(uv * iResolution), float2(0.06711056, 0.00583715))));
    // Translate one continuous volume. Never wrap individual clouds across a screen edge.
    float3 drift = float3(-t * mix(0.012, 0.035, windAmt), 0.0, -t * 0.004);
    float transmittance = 1.0;
    float3 radiance = float3(0.0);
    for (int i = 0; i < 48; i += 1) {
        if (float(i) >= steps || start >= end) break;
        float distance = start + (float(i) + jitter) * stepSize;
        float3 p = ray * distance + float3(2.8, -2.4, 1.4) + drift;
        float density = cloudDensity(p, quality);
        if (density > 0.001) {
            // Beer-Lambert extinction gives an opaque belly and translucent thin edges.
            float nearDensity = cloudDensity(p + sun * 0.14, quality);
            float shadow = nearDensity * 0.65;
            shadow += cloudDensity(p + sun * 0.55, 0.0) * 0.35;
            float direct = exp(-shadow * 1.4);
            float ambient = mix(0.48, 0.78, smoothstep(0.0, 0.9, p.y));
            float3 light = float3(0.32, 0.40, 0.50) * ambient;
            light += float3(toLinearSrgb(float3(0.98, 0.94, 0.85))) * direct * 0.58;
            light += float3(0.065, 0.075, 0.085) * (1.0 - exp(-density * 1.4));
            light += float3(0.15, 0.14, 0.12) * cl01((density - nearDensity) * 0.45);
            float aerial = 1.0 - exp(-distance * 0.055);
            light = mix(light, sky, aerial);
            float opacity = 1.0 - exp(-density * stepSize * mix(1.8, 2.8, amp));
            radiance += transmittance * opacity * light;
            transmittance *= 1.0 - opacity;
            if (transmittance < 0.015) break;
        }
    }
    float3 color = float3(fromLinearSrgb(float3(radiance + transmittance * sky)));
    // Keep the navigation and body text on a quiet, deep-blue atmospheric foreground.
    float foreground = smoothstep(0.38, 1.0, uv.y);
    color = mix(color, float3(0.035, 0.065, 0.115), foreground * 0.94);
    float vignette = 1.0 - 0.14 * pow(abs(uv.x - 0.5) * 2.0, 2.0);
    return float4(color * vignette, 1.0);
}
};
fragment float4 cloudFragment(CloudVertex stageInput [[stage_in]], constant CloudUniforms &uniforms [[buffer(0)]],
                              texture2d<float> atlas [[texture(0)]]) {
    CloudField field = {atlas, uniforms.resolution, uniforms.quality};
    return field.cloudySky(stageInput.uv, uniforms.time, uniforms.intensity, uniforms.wind);
}
