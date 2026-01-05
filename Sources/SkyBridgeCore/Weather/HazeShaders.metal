#include <metal_stdlib>
using namespace metal;

struct ClearZone { float2 center; float radius; float strength; };
struct HazeUniforms {
    float2 resolution;
    float  time;
    float  intensity;
    float  globalOpacity;
    float4 tint;
    int    zoneCount;
    int    qualityLevel;  // 质量等级 (0=节能, 1=平衡, 2=极致)
    float  noiseScale;    // 噪声缩放
};

// 超高质量哈希函数 - 完全消除伪影
static inline float hash21(float2 p) {
    // 使用更复杂的哈希算法减少重复模式
    p = fract(p * float2(443.8975, 397.2973));
    p += dot(p.xy, p.yx + 19.19);
    return fract(p.x * p.y * (p.x + p.y));
}

// ✅ 已注释：未使用的函数
// static inline float2 hash22(float2 p) {
//     p = fract(p * float2(443.8975, 397.2973));
//     p += dot(p.xy, p.yx + 19.19);
//     return fract(float2(p.x * p.y, p.x + p.y) * p.x);
// }

// 超平滑噪声函数 - 使用三次插值消除块状效果
static inline float smoothNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    
    // 获取四个角的哈希值
    float a = hash21(i + float2(0.0, 0.0));
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    
    // 使用更平滑的插值函数 - 七次Hermite插值
    float2 u = f * f * f * (f * (f * (f * (-20.0 * f + 70.0) - 84.0) + 35.0));
    
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 旋转噪声 - 消除方向性伪影
static inline float rotatedNoise(float2 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    float2x2 rot = float2x2(c, -s, s, c);
    return smoothNoise(rot * p);
}

// 超高质量分形噪声 - 多方向采样消除马赛克
static inline float ultraSmoothFbm(float2 p, int octaves, float time) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    // 多方向采样减少方向性伪影
    for (int i = 0; i < octaves; ++i) {
        float angle = float(i) * 0.7854; // 45度递增
        
        // 主噪声
        float n1 = rotatedNoise(p * frequency, angle);
        // 偏移噪声消除网格对齐
        float n2 = rotatedNoise(p * frequency + float2(100.0, 200.0), angle + 1.57);
        
        float noise_val = (n1 + n2) * 0.5;
        value += amplitude * noise_val;
        maxValue += amplitude;
        
        frequency *= 2.02; // 稍微不规则避免重复
        amplitude *= 0.48;
    }
    
    return value / maxValue; // 归一化
}

// 体积雾霾噪声 - 模拟真实大气散射
static inline float volumetricHaze(float2 p, float time, int quality) {
    // 大尺度气团运动
    float2 wind1 = float2(time * 0.02, time * 0.015);
    float2 wind2 = float2(-time * 0.025, time * 0.018);
    
    // 多层大气结构
    float layer1 = ultraSmoothFbm(p * 0.5 + wind1, 4 + quality, time);
    float layer2 = ultraSmoothFbm(p * 1.2 + wind2, 5 + quality, time) * 0.7;
    float layer3 = ultraSmoothFbm(p * 2.8 + wind1 * 0.5, 6 + quality, time) * 0.4;
    
    if (quality >= 2) {
        // 极致质量：添加微细节层
        float microLayer = ultraSmoothFbm(p * 8.0 + wind2 * 0.3, 4, time) * 0.15;
        return layer1 + layer2 + layer3 + microLayer;
    } else {
        return layer1 + layer2 + layer3;
    }
}

// 高级域变形 - 创造自然流动效果
static inline float2 advancedWarp(float2 p, float time, int quality) {
    float2 q = p;
    
    // 基础变形
    q += 0.4 * float2(
        smoothNoise(p + float2(0.0, time * 0.1)),
        smoothNoise(p + float2(5.2, -time * 0.08))
    );
    
    if (quality >= 1) {
        // 二级变形
        q += 0.2 * float2(
            smoothNoise(q * 1.8 + float2(1.7, time * 0.06)),
            smoothNoise(q * 1.6 + float2(9.2, -time * 0.05))
        );
    }
    
    if (quality >= 2) {
        // 三级变形（极致质量）
        q += 0.1 * float2(
            smoothNoise(q * 3.2 + float2(2.8, time * 0.03)),
            smoothNoise(q * 2.9 + float2(7.1, -time * 0.04))
        );
    }
    
    return q;
}

// 抗锯齿采样 - 多重采样消除锯齿
static inline float antiAliasedSample(float2 uv, float2 resolution, float time, int quality) {
    if (quality < 2) {
        // 标准采样
        float2 p = advancedWarp(uv * 4.0, time, quality);
        return volumetricHaze(p, time, quality);
    } else {
        // 4x超采样抗锯齿
        float2 pixelSize = 1.0 / resolution;
        float2 offsets[4] = {
            float2(-0.25, -0.25) * pixelSize,
            float2( 0.25, -0.25) * pixelSize,
            float2(-0.25,  0.25) * pixelSize,
            float2( 0.25,  0.25) * pixelSize
        };
        
        float total = 0.0;
        for (int i = 0; i < 4; ++i) {
            float2 sampleUV = uv + offsets[i];
            float2 p = advancedWarp(sampleUV * 4.0, time, quality);
            total += volumetricHaze(p, time, quality);
        }
        return total * 0.25;
    }
}

// 顶点着色器 - 全屏三角形
vertex float4 hazeVertex(uint vid [[vertex_id]]) {
    float2 pos;
    if (vid == 0) {
        pos = float2(-1.0, -1.0);
    } else if (vid == 1) {
        pos = float2(3.0, -1.0);
    } else {
        pos = float2(-1.0, 3.0);
    }
    return float4(pos, 0.0, 1.0);
}

fragment float4 hazeFragment(float4 position [[position]],
                             constant HazeUniforms& uniforms [[buffer(0)]],
                             constant ClearZone* zones [[buffer(1)]]) {
    float2 frag = position.xy;
    float2 uv = frag / uniforms.resolution;
    
    // 使用抗锯齿采样获得超高质量渲染
    float density = antiAliasedSample(uv, uniforms.resolution, uniforms.time, uniforms.qualityLevel);
    
    // 确保密度在合理范围内并应用强度
    density = clamp(density * uniforms.intensity, 0.0, 1.0);
    
    // 添加边缘软化 - 减少硬边缘
    float2 edgeFade = smoothstep(0.0, 0.1, uv) * smoothstep(0.0, 0.1, 1.0 - uv);
    density *= edgeFade.x * edgeFade.y;

    // 高质量清除区域处理
    float clearMask = 0.0;
    int count = min(uniforms.zoneCount, 32);
    for (int i = 0; i < count; ++i) {
        float2 c = zones[i].center / uniforms.resolution;
        float r = zones[i].radius / max(uniforms.resolution.x, uniforms.resolution.y);
        float d = distance(uv, c);
        
        // 使用更平滑的衰减函数
        float falloff = 1.0 - smoothstep(0.0, r, d);
        falloff = falloff * falloff * (3.0 - 2.0 * falloff); // 三次平滑
        
        clearMask = max(clearMask, zones[i].strength * falloff);
    }

    // 计算最终雾霾透明度
    float fogAlpha = density * uniforms.globalOpacity * (1.0 - clearMask);
    
    // 改进的颜色混合 - 更自然的雾霾色彩
    float3 fogColor = uniforms.tint.rgb;
    
    // 添加深度感和体积感
    float depthVariation = 0.85 + 0.15 * smoothNoise(uv * 2.0 + uniforms.time * 0.02);
    fogColor *= depthVariation;
    
    // 添加轻微的色彩变化增强真实感
    float colorShift = smoothNoise(uv * 1.5 + uniforms.time * 0.01) * 0.1;
    fogColor.rgb += float3(colorShift * 0.1, colorShift * 0.05, -colorShift * 0.05);
    
    return float4(fogColor * fogAlpha, fogAlpha);
}
