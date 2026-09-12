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
struct RainParameters { float storm; float allowFlash; uint glassCount; uint clearCount; float4 glassOptions; };
struct RainVertex { float4 position [[position]]; float2 uv; };
vertex RainVertex rainVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
}
float rainHash(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + float3(33.33, 33.33, 33.33));
    return fract((q.x + q.y) * q.z);
}

float rainNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(rainHash(cell), rainHash(cell + float2(1.0, 0.0)), f.x),
               mix(rainHash(cell + float2(0.0, 1.0)), rainHash(cell + float2(1.0, 1.0)), f.x), f.y);
}

float rainCloudField(float2 p) {
    float value = rainNoise(p) * 0.56;
    value += rainNoise(p * 2.03 + float2(7.1, 2.7)) * 0.28;
    value += rainNoise(p * 4.11 + float2(13.7, 9.2)) * 0.16;
    return value;
}

float3 rainToLinear(float3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}

float3 rainToDisplay(float3 c) {
    c = max(c, float3(0.0, 0.0, 0.0));
    return mix(c * 12.92, 1.055 * pow(c, float3(0.4166667, 0.4166667, 0.4166667)) - 0.055,
               step(0.0031308, c));
}

float3 rainSky(float2 p, float t, float storm) {
    float horizon = smoothstep(-0.32, 0.38, p.y);
    float cloud = rainCloudField(float2(p.x * 2.0 + t * 0.007, p.y * 2.8 - t * 0.004));
    float veil = rainNoise(p * float2(0.8, 3.1) + float2(t * 0.004, 1.7));
    float light = exp(-pow((p.x - 0.24) * 2.6, 2.0) - pow((p.y + 0.10) * 3.2, 2.0));
    float3 color = mix(rainToLinear(float3(0.12, 0.17, 0.20)),
                       rainToLinear(float3(0.29, 0.34, 0.35)), horizon);
    color *= mix(0.48, 1.12, smoothstep(0.18, 0.80, cloud));
    color += rainToLinear(float3(0.28, 0.29, 0.27)) * light * veil * 0.55;
    return color * mix(1.0, 0.68, storm);
}

float rainStreak(float2 p, float t, float2 gridSize, float speed, float slant,
                 float shutter, float width, float pixel, float seed) {
    float2 velocity = float2(slant, speed);
    // Align the cell columns with the velocity, so a long exposure never clips
    // against a vertical cell boundary. Time only advects the falling axis.
    float2 grid = float2(p.x - p.y * slant / speed, p.y - speed * t) * gridSize +
                  float2(seed, seed * 0.37);
    // Independent column phases remove synchronized rows while retaining terminal velocity.
    grid.y += rainHash(float2(floor(grid.x), seed + 83.1)) * 17.0;
    float2 cell = floor(grid);
    float choice = rainHash(cell + float2(seed, 4.7));
    float2 center = float2(0.24 + rainHash(cell) * 0.52,
                          0.42 + rainHash(cell + float2(9.2, 7.6)) * 0.48);
    float2 offset = (fract(grid) - center) / gridSize;
    offset.x += offset.y * slant / speed;
    float2 direction = normalize(velocity);
    float along = dot(offset, direction);
    float across = abs(dot(offset, float2(direction.y, -direction.x)));
    float streakLength = length(velocity) * shutter * mix(0.72, 1.25, choice);
    float radius = width * mix(0.65, 1.2, choice);
    // Prefilter a subpixel filament instead of switching a hard edge on and off.
    // Preserve its integrated brightness as the footprint crosses pixel centers.
    float sigma = max(pixel, width * 2.0);
    float body = exp(-0.5 * across * across / (sigma * sigma)) * radius / sigma;
    float tail = smoothstep(-streakLength, -streakLength * 0.10, along);
    float head = 1.0 - smoothstep(-pixel, pixel, along);
    float exposure = mix(0.35, 1.0, choice) * step(0.18, choice);
    return body * tail * head * exposure;
}

float2 rainWaterWaves(float2 p, float t) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float waves = 0.0;
    float impacts = 0.0;
    for (int y = -1; y <= 1; y += 1) {
        for (int x = -1; x <= 1; x += 1) {
            float2 neighbor = float2(float(x), float(y));
            float seed = rainHash(cell + neighbor);
            float age = fract(t * 0.65 + seed * 11.3);
            float2 center = neighbor + float2(0.2 + seed * 0.6,
                0.2 + rainHash(cell + neighbor + float2(9.4, 3.2)) * 0.6);
            float distance = length(f - center);
            float envelope = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.65, 1.0, age));
            float ringDistance = distance - age * 0.95;
            waves += cos(ringDistance * 48.0) * exp(-abs(ringDistance) * 24.0) * envelope * exp(-age * 2.2);
            impacts += exp(-distance * distance * 850.0) * (1.0 - smoothstep(0.0, 0.12, age));
        }
    }
    return float2(waves, impacts);
}

float4 cinematicRain(float2 uv, float2 viewport, float time, float intensity,
                      float wind, float quality, float storm, float allowFlash,
                      float disperse, float2 flowOffset) {
    float aspect = viewport.x / max(viewport.y, 1.0);
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float pixel = 1.0 / max(viewport.y, 1.0);
    float3 color = rainSky(p, time, storm);
    float fog = exp(-pow((p.y - 0.20) * 5.2, 2.0));
    color = mix(color, rainToLinear(float3(0.26, 0.30, 0.31)), fog * intensity * 0.22);

    float water = smoothstep(0.75, 0.79, uv.y);
    if (water > 0.0) {
        float depth = max(uv.y - 0.71, 0.03);
        float2 plane = float2(p.x / depth * 2.8, 1.6 / depth);
        float2 waves = rainWaterWaves(plane, time);
        float shimmer = rainNoise(plane * 1.8 + float2(time * 0.17, time * 0.06));
        float2 reflection = float2(p.x + waves.x * 0.004,
                                   0.24 - (uv.y - 0.77) * 1.7 + shimmer * 0.009);
        float3 reflected = rainSky(reflection, time, storm);
        float fresnel = mix(0.72, 0.30, smoothstep(0.77, 1.0, uv.y));
        float3 waterColor = mix(rainToLinear(float3(0.035, 0.060, 0.075)), reflected, fresnel);
        waterColor += rainToLinear(float3(0.31, 0.36, 0.38)) *
                      (max(waves.x, 0.0) * 0.30 + waves.y * 0.60) * intensity;
        color = mix(color, waterColor, water);
    }

    float slant = 0.11 + wind * 0.32 + sin(time * 0.11) * 0.012;
    slant *= mix(1.0, 1.45, storm);
    float2 rainPosition = p + flowOffset * float2(aspect, 1.0);
    float streaks = rainStreak(rainPosition, time, float2(110.0, 13.0), 0.48, slant * 0.45,
                               0.035, pixel * 0.20, pixel * 0.70, 7.0) * 0.15;
    streaks += rainStreak(rainPosition, time, float2(64.0, 8.0), 0.87, slant * 0.72,
                          0.035, pixel * 0.27, pixel * 0.70, 19.0) * 0.29;
    streaks += rainStreak(rainPosition, time, float2(31.0, 4.0), 1.38, slant,
                          0.045, pixel * 0.36, pixel * 0.75, 31.0) * 0.42;
    if (quality > 0.65) {
        streaks += rainStreak(rainPosition, time, float2(15.0, 2.0), 1.91, slant * 1.30,
                              0.045, pixel * 0.48, pixel * 1.10, 47.0) * 0.18;
    }
    streaks *= intensity * mix(0.80, 1.30, storm) * disperse;
    color += rainToLinear(float3(0.67, 0.72, 0.76)) * streaks;
    float flashPhase = fract(time / 13.0);
    float flash = exp(-pow((flashPhase - 0.72) * 220.0, 2.0)) +
                  exp(-pow((flashPhase - 0.728) * 330.0, 2.0)) * 0.45;
    color += rainToLinear(float3(0.20, 0.23, 0.26)) * flash * storm * allowFlash;
    float vignette = 1.0 - smoothstep(0.35, 1.15, length(p * float2(0.60, 0.85))) * 0.24;
    color *= vignette;
    return float4(clamp(rainToDisplay(color), 0.0, 1.0), 1.0);
}

float4 rainBead(float2 offset, float radius, float elongation) {
    float2 q = offset / float2(radius, radius * elongation);
    float d = length(q);
    float coverage = 1.0 - smoothstep(0.84, 1.08, d);
    float rim = exp(-pow((d - 0.83) * 10.0, 2.0));
    float highlight = exp(-dot(q + float2(0.30, 0.36), q + float2(0.30, 0.36)) * 20.0);
    float caustic = exp(-pow(q.x * 2.5, 2.0) - pow((q.y - 0.55) * 7.0, 2.0));
    float3 color = mix(float3(0.11, 0.16, 0.18), float3(0.90, 0.95, 0.96),
                       clamp(highlight + caustic * 0.55 + rim * 0.28, 0.0, 1.0));
    return float4(color, coverage * min(0.24 + rim * 0.40 + highlight * 0.65, 1.0));
}

float4 rainWetGlass(float2 uv, float2 viewport, float time, float4 region,
                    float cornerRadius, float intensity) {
    if (region.z <= 0.0 || region.w <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);
    float2 local = (uv - region.xy) * viewport;
    float2 extent = region.zw * viewport;
    float radiusScale = max(viewport.y / 900.0, 0.40);
    float margin = 14.0 * radiusScale;
    if (local.x < -margin || local.y < -margin || local.x > extent.x + margin || local.y > extent.y + margin) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    float seed = rainHash(region.xy * 127.0 + region.zw * 53.0);
    float corner = cornerRadius * viewport.y;
    float4 result = float4(0.0, 0.0, 0.0, 0.0);
    if (local.x > corner && local.x < extent.x - corner && abs(local.y) < margin) {
        float spacing = 43.0 * radiusScale;
        float cell = floor(local.x / spacing);
        float variation = rainHash(float2(cell, seed * 71.0));
        float age = fract(time * 0.019 + variation);
        float radius = (1.4 + age * 2.8) * radiusScale;
        float2 center = float2((cell + 0.2 + variation * 0.6) * spacing, radius * 0.25);
        result = rainBead(local - center, radius, 1.10 + age * 0.40);
        result.w *= smoothstep(0.0, 0.06, age) * (1.0 - smoothstep(0.92, 1.0, age));
    }
    float edge = local.x < extent.x * 0.5 ? 0.0 : extent.x;
    if (abs(local.x - edge) < margin && local.y > corner && local.y < extent.y - corner) {
        float spacing = 82.0 * radiusScale;
        float cell = floor(local.y / spacing);
        float variation = rainHash(float2(cell + edge * 0.13, seed * 97.0));
        float age = fract(time * (0.022 + variation * 0.016) + variation * 7.0);
        float radius = (2.0 + variation * 2.2) * radiusScale;
        float2 center = float2(edge + (edge == 0.0 ? -0.25 : 0.25) * radius,
                               (cell + 0.12 + age * 0.73) * spacing);
        float4 bead = rainBead(local - center, radius, 1.35 + age * 0.95);
        bead.w *= smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.87, 1.0, age));
        if (bead.w > result.w) result = bead;
    }
    // Water gathers under the lower lip, stretches, then detaches under gravity.
    if (local.x > corner && local.x < extent.x - corner && abs(local.y - extent.y) < margin) {
        float spacing = 97.0 * radiusScale;
        float cell = floor(local.x / spacing);
        float variation = rainHash(float2(cell + 17.0, seed * 63.0));
        float age = fract(time * 0.028 + variation * 5.0);
        float radius = (1.5 + sqrt(age) * 2.1) * radiusScale;
        float falling = max(age - 0.80, 0.0);
        float2 center = float2((cell + 0.2 + variation * 0.6) * spacing,
                               extent.y + radius * 0.25 + falling * falling * 220.0 * radiusScale);
        float4 bead = rainBead(local - center, radius, 1.15 + age * 0.85);
        bead.w *= smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.88, 1.0, age));
        if (bead.w > result.w) result = bead;
    }
    result.w *= intensity;
    return result;
}

float4 rainApplyWetGlass(float4 background, float4 wet) {
    return float4(rainToDisplay(mix(rainToLinear(background.rgb), rainToLinear(wet.rgb), wet.w)), background.w);
}
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
