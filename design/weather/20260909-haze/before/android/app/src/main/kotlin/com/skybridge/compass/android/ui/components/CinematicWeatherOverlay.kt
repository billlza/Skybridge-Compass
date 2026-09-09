package com.skybridge.compass.android.ui.components

import android.content.res.Resources
import android.graphics.RuntimeShader
import android.util.Log
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.max
import kotlin.math.sin

/**
 * Single-pass AGSL overlay ported from the Mac cinematic weather stack
 * (layered rain/snow, volumetric fog/haze, storm lightning, drifting clouds).
 *
 * Mac spends CPU on thousands of particles. Android minSdk 36 can run this as one GPU
 * fragment program instead: constant cost, no per-drop Canvas calls, and the quantum-glass
 * background still shows through precipitation. Cloudy weather supplies its own opaque sky.
 */
internal object CinematicWeatherAgsl {
    const val TAG = "CinematicWeather"

    val SOURCE = """
uniform float2 iResolution;
uniform float iTime;
uniform float weatherMode;
uniform float quality;
uniform float intensity;
uniform float wind;
uniform float allowFlash;
uniform shader cloudNoiseAtlas;

float cl01(float x) {
    return clamp(x, 0.0, 1.0);
}

float4 over(float4 fg, float4 bg) {
    float outA = fg.w + bg.w * (1.0 - fg.w);
    float3 outRgb = (fg.xyz * fg.w + bg.xyz * bg.w * (1.0 - fg.w)) / max(outA, 0.0001);
    return float4(outRgb, outA);
}

float hash21(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    float n = dot(p3, p3.yzx + float3(33.33, 33.33, 33.33));
    p3 += float3(n, n, n);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i += 1) {
        v += a * valueNoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

float distSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = cl01(dot(pa, ba) / max(dot(ba, ba), 0.0001));
    return length(pa - ba * float2(h, h));
}

float rainLayer(float2 uv, float t, float cols, float rows, float speed, float thickness, float windAmt) {
    float2 st = float2(uv.x * cols + uv.y * windAmt, uv.y * rows);
    st.y -= t * speed;
    float2 cell = floor(st);
    float2 f = fract(st);
    float rnd = hash21(cell);
    float visible = step(0.52, rnd);
    float xOff = (rnd - 0.5) * 0.38;
    float len = 0.40 + hash21(cell + float2(2.1, 0.7)) * 0.42;
    float tail = hash21(cell + float2(0.4, 5.2)) * (1.0 - len) * 0.42;
    float head = tail + len;
    float along = (f.y - tail) / max(len, 0.001);
    float inDrop = step(0.0, along) * (1.0 - step(1.0, along));
    float halfW = thickness * mix(0.55, 1.0, pow(cl01(along), 0.75));
    float dx = abs(f.x - 0.5 - xOff);
    float body = 1.0 - smoothstep(halfW * 0.35, halfW, dx);
    float core = 1.0 - smoothstep(0.0, halfW * 0.28, dx);
    float cap = 1.0 - smoothstep(halfW * 0.65, halfW * 1.12, length(float2(dx, f.y - head)));
    float lum = 0.22 + 0.78 * pow(cl01(along), 0.90);
    float shape = max(body, cap * inDrop);
    return visible * inDrop * (shape * 0.62 + core * 0.55) * lum * (0.40 + 0.60 * rnd);
}

float rainCurtain(float2 uv, float t, float densX, float densY, float speed, float tilt, float sharp) {
    float2 p = float2((uv.x + uv.y * tilt) * densX, uv.y * densY - t * speed);
    float n = valueNoise(p) * valueNoise(p * float2(1.45, 0.48) + float2(3.1, 8.4));
    return pow(cl01(n), sharp);
}

float4 rainClouds(float2 uv, float t, float amp, float storm) {
    float warp = fbm(float2(uv.x * 1.7 + t * 0.018, uv.y * 2.1));
    float2 uvd = uv + float2((warp - 0.5) * 0.12, (warp - 0.5) * 0.05);
    float mass = 0.0;
    for (int i = 0; i < 8; i += 1) {
        float fi = float(i);
        float rnd = hash21(float2(fi * 1.7, 3.3));
        float cx = fract(0.04 + fi * 0.122 + t * (0.007 + rnd * 0.005) + rnd * 0.03);
        float cy = 0.02 + rnd * 0.15 + 0.022 * sin(t * 0.06 + fi * 1.2);
        float rx = 0.22 + rnd * 0.20;
        float ry = rx * (0.38 + rnd * 0.16);
        float2 p = float2((uvd.x - cx) / rx, (uvd.y - cy) / ry);
        mass += exp(-dot(p, p) * (1.25 + storm * 0.18));
    }
    for (int i = 0; i < 5; i += 1) {
        float fi = float(i);
        float rnd = hash21(float2(fi * 2.9, 8.1));
        float cx = fract(0.08 + fi * 0.19 + t * 0.019 + rnd * 0.05);
        float cy = 0.14 + rnd * 0.12;
        float rx = 0.13 + rnd * 0.11;
        float ry = rx * 0.44;
        float2 p = float2((uvd.x - cx) / rx, (uvd.y - cy) / ry);
        mass += 0.70 * exp(-dot(p, p) * 1.55);
    }
    float n = fbm(float2(uvd.x * 2.6 + t * 0.014, uvd.y * 3.0));
    mass *= mix(0.70, 1.22, n);
    float cover = smoothstep(0.42, 1.20, mass) * smoothstep(0.46, 0.06, uv.y);
    float belly = smoothstep(0.20, 0.30, uv.y) * smoothstep(0.42, 0.30, uv.y);
    float lit = cl01(0.18 + n * 0.50 + (0.20 - uv.y) * 1.35);
    float3 underside = mix(float3(0.13, 0.14, 0.19), float3(0.07, 0.07, 0.10), storm);
    float3 body = mix(float3(0.32, 0.35, 0.42), float3(0.18, 0.19, 0.24), storm);
    float3 rim = mix(float3(0.58, 0.62, 0.70), float3(0.34, 0.36, 0.42), storm);
    float3 col = mix(underside, body, lit);
    col = mix(col, underside, belly * 0.55);
    float edge = cover * (1.0 - cover) * 3.4;
    col = mix(col, rim, cl01(edge * 0.70 + lit * 0.18));
    return float4(col, cl01(cover * (0.90 + 0.06 * storm) * amp));
}

float4 glassBeads(float2 uv, float t, float amp) {
    float2 st = float2(uv.x * 5.4, uv.y * 7.2 - t * 0.030);
    float2 cell = floor(st);
    float2 f = fract(st);
    float rnd = hash21(cell + float2(9.2, 1.4));
    float spawn = step(0.86, rnd) * step(0.24, uv.y) * (1.0 - step(0.72, uv.y));
    float2 c = float2(0.40 + rnd * 0.22, 0.36 + hash21(cell + float2(2.2, 4.1)) * 0.28);
    float2 d = (f - c) * float2(1.08, 0.68);
    float r = length(d);
    float rad = 0.075 + rnd * 0.055;
    float drop = 1.0 - smoothstep(rad * 0.50, rad, r);
    float hi = 1.0 - smoothstep(0.0, rad * 0.30, length(d + float2(0.24, 0.30) * rad));
    float3 col = mix(float3(0.58, 0.80, 0.98), float3(1.0, 1.0, 1.0), hi);
    return float4(col, cl01(spawn * drop * (0.18 + 0.48 * hi) * amp));
}

float4 groundHits(float2 uv, float t, float amp, float storm) {
    float navMask = 1.0 - smoothstep(0.76, 0.82, uv.y);
    float splash = 0.0;
    float aspect = iResolution.x / max(iResolution.y, 1.0);
    for (int i = 0; i < 4; i += 1) {
        float cols = 3.5 + float(i) * 1.4;
        float2 id = float2(floor(uv.x * cols + float(i) * 2.4), float(i));
        float rnd = hash21(id + float2(4.4, 9.7));
        float spawn = step(0.80, rnd);
        float life = fract(t * (1.85 + rnd * 0.80) + rnd * 8.0);
        float cx = (id.x + 0.18 + rnd * 0.64) / cols;
        float cy = 0.56 + hash21(id + float2(2.8, 1.1)) * 0.18;
        float2 pr = (uv - float2(cx, cy)) * float2(aspect, 1.0);
        float flash = (1.0 - smoothstep(0.0, 0.0038, length(pr))) * (1.0 - smoothstep(0.0, 0.11, life));
        float up = max(-pr.y, 0.0);
        float spray = (1.0 - smoothstep(0.0, 0.0022, abs(pr.x - (rnd - 0.5) * 0.0035))) *
            (1.0 - smoothstep(0.0, 0.014, up)) * step(0.0, 0.002 - pr.y) * (1.0 - life);
        splash += spawn * (flash * 1.05 + spray * 0.80);
    }
    splash *= navMask * step(0.50, uv.y);
    float3 highlight = mix(float3(0.72, 0.88, 1.0), float3(0.95, 0.98, 1.0), cl01(splash));
    return float4(highlight, cl01(splash * (0.42 + 0.12 * storm) * amp));
}

float snowFlakes(float2 uv, float2 res, float t, float scale, float speed, float size, float sway) {
    float aspect = res.x / max(res.y, 1.0);
    float2 st = float2(uv.x * aspect * scale, uv.y * scale);
    st.x += sin(t * 0.55 + uv.y * 4.2) * sway;
    st.y -= t * speed;
    float2 cell = floor(st);
    float2 f = fract(st) - 0.5;
    float rnd = hash21(cell);
    float2 p = f - float2((rnd - 0.5) * 0.42, (hash21(cell + float2(4.2, 1.8)) - 0.5) * 0.42);
    float r = length(p);
    float radius = size * (0.45 + rnd * 0.85);
    float disc = 1.0 - smoothstep(radius * 0.18, radius, r);
    float an = atan(p.y, p.x);
    float spokes = pow(clamp(abs(cos(an * 3.0)), 0.0, 1.0), 7.0);
    float arms = spokes * (1.0 - smoothstep(radius * 0.12, radius * 1.15, r));
    float crystal = mix(disc, cl01(disc * 0.55 + arms), step(0.55, rnd));
    return crystal * (0.35 + 0.65 * rnd);
}

float lightningFlash(float t) {
    float a = max(0.0, sin(t * 1.63) - 0.88);
    float b = max(0.0, sin(t * 0.37 + 1.7) - 0.94);
    return cl01(a * 9.0 + b * 16.0);
}

float lightningBolt(float2 uv, float t) {
    float seed = floor(t * 0.33);
    float2 a = float2(0.40 + 0.22 * hash21(float2(seed, 1.2)), 0.0);
    float2 b = float2(0.36 + 0.30 * hash21(float2(seed, 2.4)), 0.26);
    float2 c = float2(0.48 + 0.24 * hash21(float2(seed, 3.6)), 0.54);
    float2 d = float2(0.44 + 0.32 * hash21(float2(seed, 4.8)), 0.90);
    float dist = min(distSeg(uv, a, b), min(distSeg(uv, b, c), distSeg(uv, c, d)));
    float core = 1.0 - smoothstep(0.0, 0.0065, dist);
    float glow = 1.0 - smoothstep(0.0, 0.038, dist);
    return core + glow * 0.45;
}

float4 clearSky(float2 uv, float t, float amp) {
    float2 sunPos = float2(0.78, 0.16);
    float2 toSun = uv - sunPos;
    float dist = length(toSun * float2(1.15, 1.0));
    float sunCore = 1.0 - smoothstep(0.0, 0.085, dist);
    float sunGlow = 1.0 - smoothstep(0.0, 0.42, dist);
    float ang = atan(toSun.y, toSun.x);
    float rays = pow(clamp(abs(sin(ang * 7.0 + t * 0.14)), 0.0, 1.0), 9.0);
    rays *= 1.0 - smoothstep(0.0, 0.72, dist);
    float caustic = 0.5 + 0.5 * sin(uv.x * 18.0 + t * 0.35) * sin(uv.y * 11.0 - t * 0.22);
    caustic *= 0.10 * (1.0 - uv.y) * amp;
    float spark = snowFlakes(uv, iResolution, t * 0.25, 18.0, 0.018, 0.018, 0.04);
    float3 col = mix(float3(1.0, 0.78, 0.42), float3(1.0, 0.93, 0.72), cl01(sunGlow));
    float alpha = (sunCore * 0.55 + sunGlow * 0.22 + rays * 0.12 + spark * 0.35 + caustic) * amp;
    return float4(col, cl01(alpha));
}

${CinematicCloudsAgsl.SOURCE}

float4 rainySky(float2 uv, float t, float amp, float windAmt, float storm) {
    float tilt = 0.20 + windAmt * 0.40 + storm * 0.10;
    float dens = 1.0 + storm * 0.28;
    float skyAmt = smoothstep(0.52, 0.0, uv.y) * (0.16 + 0.08 * storm) * amp;
    float3 skyCol = mix(float3(0.40, 0.48, 0.60), float3(0.20, 0.22, 0.28), storm);
    float4 color = float4(skyCol, skyAmt);
    color = over(rainClouds(uv, t, amp, storm), color);
    float under = smoothstep(0.14, 0.32, uv.y);
    float curtain = 0.0;
    curtain += rainCurtain(uv, t, 26.0, 5.2, 1.85 + storm * 0.30, tilt, 4.6) * 0.20;
    curtain += rainCurtain(uv, t, 18.0, 4.0, 2.35 + storm * 0.40, tilt * 1.12, 3.8) * 0.14;
    curtain *= amp * under;
    float3 sheetCol = mix(float3(0.45, 0.70, 0.92), float3(0.70, 0.86, 1.0), cl01(curtain * 1.6));
    color = over(float4(sheetCol, cl01(curtain * 0.42)), color);
    float c0 = 52.0 * dens;
    float c1 = 26.0 * dens;
    float c2 = 12.0 * dens;
    float c3 = 6.5 * dens;
    float rain = 0.0;
    rain += rainLayer(uv, t, c0, 16.0, 1.80 + storm * 0.40, 0.10, tilt * c0) * 0.28;
    rain += rainLayer(uv, t, c1, 9.0, 2.35 + storm * 0.50, 0.085, tilt * c1) * 0.48;
    rain += rainLayer(uv, t, c2, 4.8, 3.05 + storm * 0.60, 0.070, tilt * c2) * 0.82;
    if (quality > 0.5) {
        rain += rainLayer(uv, t, c3, 3.2, 3.55 + storm * 0.70, 0.055, tilt * c3) * 1.05;
    }
    rain *= amp * under;
    color = over(float4(float3(0.32, 0.72, 1.0), cl01(rain * 0.32)), color);
    color = over(float4(float3(0.94, 0.98, 1.0), cl01(rain * 0.58)), color);
    color = over(glassBeads(uv, t, amp), color);
    color = over(groundHits(uv, t, amp, storm), color);
    return color;
}

float4 snowySky(float2 uv, float t, float amp, float windAmt) {
    float2 res = iResolution;
    float far = snowFlakes(uv, res, t, 9.5, 0.055, 0.07, 0.10 + windAmt * 0.08);
    float mid = snowFlakes(uv, res, t, 16.0, 0.09, 0.045, 0.08 + windAmt * 0.10);
    float near = 0.0;
    if (quality > 0.5) {
        near = snowFlakes(uv, res, t, 26.0, 0.13, 0.032, 0.06 + windAmt * 0.12);
    }
    float flakes = (far * 0.35 + mid * 0.55 + near * 0.85) * amp;
    float mounds = valueNoise(float2(uv.x * 7.0, 2.2));
    float ground = smoothstep(0.80 - mounds * 0.07, 1.0, uv.y) * 0.42 * amp;
    float fog = 0.12 * amp * (0.4 + 0.6 * uv.y);
    float3 col = mix(float3(0.78, 0.88, 0.98), float3(1.0, 1.0, 1.0), cl01(flakes * 1.4));
    float alpha = cl01(fog + ground + flakes);
    return float4(col, alpha);
}

float4 foggySky(float2 uv, float t, float amp) {
    float2 p = float2(uv.x * 1.55 + t * 0.028, uv.y * 1.25 + t * 0.016);
    float fogWarp = fbm(p * 1.2) * 0.7;
    float n = fbm(p + float2(fogWarp, fogWarp));
    float fog = smoothstep(0.22, 0.80, n);
    fog *= mix(0.40, 1.0, smoothstep(0.05, 0.92, uv.y));
    float light = 0.12 * (1.0 - uv.y) * amp;
    float grain = 0.0;
    if (quality > 0.5) {
        grain = (hash21(uv * iResolution + float2(t, t * 1.7)) - 0.5) * 0.04;
    }
    float3 col = float3(0.82 + grain, 0.86 + grain, 0.92 + grain);
    float alpha = cl01(fog * 0.70 * amp + light);
    return float4(col, alpha);
}

float4 hazySky(float2 uv, float t, float amp) {
    float2 p = float2(uv.x * 1.4 + t * 0.02, uv.y * 1.15 + t * 0.012);
    float n = fbm(p);
    float haze = smoothstep(0.18, 0.78, n) * mix(0.45, 1.0, uv.y);
    float2 from = uv - float2(0.74, -0.04);
    float dist = length(from);
    float ang = atan(from.y, from.x);
    float rays = pow(clamp(abs(sin(ang * 7.0 + t * 0.11)), 0.0, 1.0), 10.0);
    rays *= (1.0 - smoothstep(0.0, 0.85, dist)) * 0.28 * amp;
    float motes = snowFlakes(uv, iResolution, t * 0.18, 22.0, 0.012, 0.016, 0.03) * 0.45;
    float grain = (hash21(uv * iResolution * 0.7 + float2(t, t * 1.3)) - 0.5) * 0.05 * quality;
    float3 col = float3(0.78 + grain, 0.70 + grain, 0.52 + grain);
    float alpha = cl01(haze * 0.58 * amp + rays + motes * amp);
    return float4(col, alpha);
}

float4 stormySky(float2 uv, float t, float amp, float windAmt) {
    float4 rain = rainySky(uv, t, amp, windAmt, 1.0);
    float flash = 0.0;
    float bolt = 0.0;
    if (allowFlash > 0.5) {
        flash = lightningFlash(t);
        bolt = lightningBolt(uv, t) * flash;
    }
    float3 col = mix(rain.xyz, float3(0.92, 0.95, 1.0), cl01(flash * 0.55 + bolt));
    float alpha = cl01(rain.w + flash * 0.18 + bolt * 0.65);
    return float4(col, alpha);
}

half4 main(float2 fragCoord) {
    float2 res = max(iResolution, float2(1.0, 1.0));
    float2 uv = fragCoord / res;
    float t = iTime;
    float amp = clamp(intensity, 0.28, 1.0);
    float windAmt = clamp(wind, 0.0, 1.0);
    float4 color = float4(0.0, 0.0, 0.0, 0.0);
    if (weatherMode < 0.5) {
        color = clearSky(uv, t, amp);
    } else if (weatherMode < 1.5) {
        color = cloudySky(uv, t, amp, windAmt);
    } else if (weatherMode < 2.5) {
        color = rainySky(uv, t, amp, windAmt, 0.0);
    } else if (weatherMode < 3.5) {
        color = snowySky(uv, t, amp, windAmt);
    } else if (weatherMode < 4.5) {
        color = foggySky(uv, t, amp);
    } else if (weatherMode < 5.5) {
        color = hazySky(uv, t, amp);
    } else {
        color = stormySky(uv, t, amp, windAmt);
    }
    return half4(color.x, color.y, color.z, color.w);
}
""".trimIndent()
}

internal class CinematicWeatherRuntimeEffect(resources: Resources) {
    private val shader: RuntimeShader?
    private val brush: ShaderBrush?

    init {
        val compiled = runCatching { RuntimeShader(CinematicWeatherAgsl.SOURCE) }
            .onFailure { Log.e(CinematicWeatherAgsl.TAG, "AGSL compile failed", it) }
            .getOrNull()
        shader = compiled
        compiled?.setInputBuffer("cloudNoiseAtlas", CinematicCloudsAgsl.densityBuffer(resources))
        brush = compiled?.let { ShaderBrush(it) }
    }

    val isReady: Boolean get() = shader != null && brush != null

    fun drawOn(
        scope: DrawScope,
        timeSeconds: Double,
        condition: IOSWeatherCondition,
        quality: Float,
        intensity: Float,
        wind: Float,
        allowFlash: Boolean,
    ) {
        val shader = shader ?: return
        val brush = brush ?: return
        val mode = CinematicWeatherPolicy.shaderMode(condition)
        if (mode < 0f) return
        val width = scope.size.width
        val height = scope.size.height
        if (width <= 1f || height <= 1f) return
        shader.setFloatUniform("iResolution", width, height)
        shader.setFloatUniform("iTime", timeSeconds.toFloat())
        shader.setFloatUniform("weatherMode", mode)
        shader.setFloatUniform("quality", quality)
        shader.setFloatUniform("intensity", intensity)
        shader.setFloatUniform("wind", wind)
        shader.setFloatUniform("allowFlash", if (allowFlash) 1f else 0f)
        scope.drawRect(brush = brush)
    }
}

/**
 * Visible CPU path used only if AGSL fails to compile. Particle counts stay low; alpha is
 * deliberately much stronger than the old placeholder streaks (those multiplied to ~0.03).
 */
internal fun DrawScope.drawCinematicWeatherFallback(
    condition: IOSWeatherCondition,
    timeSeconds: Double,
    intensity: Float,
    wind: Float,
    allowFlash: Boolean,
) {
    val w = size.width
    val h = size.height
    val t = timeSeconds
    val amp = intensity.coerceIn(0.28f, 1f)
    val windPx = (0.18f + wind * 0.55f) * w * 0.04f
    when (condition) {
        IOSWeatherCondition.Clear -> {
            val sun = Offset(w * 0.78f, h * 0.16f)
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        Color(0xFFFFE7A8).copy(alpha = 0.42f * amp),
                        Color(0xFFFFB347).copy(alpha = 0.16f * amp),
                        Color.Transparent,
                    ),
                    center = sun,
                    radius = minOf(w, h) * 0.42f,
                ),
                radius = minOf(w, h) * 0.42f,
                center = sun,
            )
        }
        IOSWeatherCondition.Cloudy -> {
            for (i in 0 until 6) {
                val drift = ((t * (0.012 + i * 0.003) + i * 0.17) % 1.0).toFloat()
                val cx = ((drift + i * 0.13f) % 1f) * w
                val cy = h * (0.12f + (i % 3) * 0.10f)
                val radius = w * (0.22f + (i % 2) * 0.08f)
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            Color(0xFFD9E2EC).copy(alpha = 0.42f * amp),
                            Color.Transparent,
                        ),
                        center = Offset(cx, cy),
                        radius = radius,
                    ),
                    radius = radius,
                    center = Offset(cx, cy),
                )
            }
        }
        IOSWeatherCondition.Rainy, IOSWeatherCondition.Stormy -> {
            val storm = condition == IOSWeatherCondition.Stormy
            val cloudTint = if (storm) Color(0xFF4A5160) else Color(0xFF8E97A8)
            for (i in 0 until 10) {
                val cx = ((i * 0.14 + (t * 0.012) % 0.2) % 1.0).toFloat() * w
                val cy = h * (0.04f + (i % 4) * 0.07f)
                val radius = w * (0.24f + (i % 3) * 0.08f)
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(cloudTint.copy(alpha = 0.78f * amp), Color.Transparent),
                        center = Offset(cx, cy),
                        radius = radius,
                    ),
                    radius = radius,
                    center = Offset(cx, cy),
                )
            }
            val count = if (storm) 110 else 78
            val baseLen = if (storm) 90f else 64f
            for (i in 0 until count) {
                val seed = i * 0.137
                val speed = 0.22 + (i % 5) * 0.05
                val x = (((seed * 13.7 + t * 0.04 * wind) % 1.0 + 1.0) % 1.0).toFloat() * w
                val y = (((seed + t * speed) % 1.0)).toFloat() * h
                val len = baseLen + (i % 7) * 18f
                val thick = if (i % 9 == 0) 3.4f else if (storm) 1.8f else 1.4f
                drawLine(
                    color = Color(0xFFD7F0FF).copy(alpha = (0.28f + (i % 4) * 0.16f) * amp),
                    start = Offset(x, y),
                    end = Offset(x + windPx * 2.4f + if (storm) 18f else 10f, y + len),
                    strokeWidth = thick,
                    cap = StrokeCap.Round,
                )
            }
            for (i in 0 until 6) {
                val life = ((t * (1.2 + i * 0.11) + i * 0.41) % 1.0).toFloat()
                val cx = ((0.12 + i * 0.15 + (i % 3) * 0.07) % 1.0).toFloat() * w
                val cy = h * (0.64f + ((i * 17) % 5) * 0.03f)
                drawCircle(
                    color = Color.White.copy(alpha = (1f - life) * 0.22f * amp),
                    radius = 2.4f,
                    center = Offset(cx, cy),
                )
            }
            if (storm && allowFlash) {
                val flash = max(0.0, sin(t * 1.63) - 0.88) * 8.0
                if (flash > 0.0) {
                    drawRect(color = Color.White.copy(alpha = (0.14 * flash).toFloat().coerceIn(0f, 0.28f)))
                }
            }
        }
        IOSWeatherCondition.Snowy -> {
            for (i in 0 until 90) {
                val seed = i * 0.211
                val sway = sin(t * (0.6 + (i % 5) * 0.07) + seed) * 0.03
                val x = ((((seed * 7.1) + sway) % 1.0 + 1.0) % 1.0).toFloat() * w
                val y = (((seed + t * (0.04 + (i % 6) * 0.01)) % 1.0)).toFloat() * h
                val r = 2.4f + (i % 5) * 1.3f
                drawCircle(
                    color = Color.White.copy(alpha = (0.42f + (i % 4) * 0.12f) * amp),
                    radius = r,
                    center = Offset(x, y),
                )
            }
        }
        IOSWeatherCondition.Foggy, IOSWeatherCondition.Haze -> {
            val tint = if (condition == IOSWeatherCondition.Haze) Color(0xFFE6C98A) else Color(0xFFE8EEF4)
            for (i in 0 until 8) {
                val cx = ((sin(t * 0.05 + i) * 0.15 + 0.5 + i * 0.08) % 1.0).toFloat() * w
                val cy = h * (0.2f + (i % 4) * 0.18f)
                val radius = minOf(w, h) * (0.28f + (i % 3) * 0.08f)
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(tint.copy(alpha = 0.22f * amp), Color.Transparent),
                        center = Offset(cx, cy),
                        radius = radius,
                    ),
                    radius = radius,
                    center = Offset(cx, cy),
                )
            }
        }
        IOSWeatherCondition.Unknown -> Unit
    }
}
