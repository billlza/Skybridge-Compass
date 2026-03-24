#include <metal_stdlib>
using namespace metal;

// MARK: - Remote Desktop HDR Shader
//
// 色彩管理渲染着色器，用于 ReferenceRenderer 的高保真模式。
//
// 支持路径：
// 1. SDR 直通：纹理采样 → 直出（等效于 pass-through）
// 2. PQ HDR：PQ EOTF → 线性光 → BT.2020→P3 色域映射 → EDR 缩放 → 输出
// 3. HLG HDR：HLG OETF 反转 → 线性光 → 色域映射 → EDR 缩放 → 输出
//
// 设计原则：
// - 所有运算在线性光域进行
// - 色域映射使用简单矩阵变换（BT.2020 → Display P3）
// - EDR 输出值 > 1.0 表示高亮区域
// - 色调映射可选 (Reinhard / ACES / Display-adaptive)

// MARK: - 常量

// PQ (ST 2084) 常量
constant float PQ_m1 = 0.1593017578125;   // 2610 / 16384
constant float PQ_m2 = 78.84375;           // 2523 / 32 * 128
constant float PQ_c1 = 0.8359375;          // 3424 / 4096
constant float PQ_c2 = 18.8515625;         // 2413 / 128
constant float PQ_c3 = 18.6875;            // 2392 / 128

// BT.2020 → Display P3 色域变换矩阵
// 从 BT.2020 线性 RGB 到 Display P3 线性 RGB
constant float3x3 BT2020_TO_P3 = float3x3(
    float3( 1.3457, -0.2556, -0.0511),
    float3(-0.0544,  1.0484,  0.0016),
    float3(-0.0122, -0.0614,  1.0747)
);

// MARK: - 传输函数参数（通过 buffer 传入）

struct HDRUniforms {
    float edrHeadroom;      // EDR headroom (1.0 = SDR, >1.0 = HDR)
    uint  transferFunc;     // 0=sRGB, 1=PQ, 2=HLG, 3=Linear
    uint  toneMappingMode;  // 0=none, 1=reinhard, 2=aces, 3=display
    float maxContentLight;  // 最大内容亮度 (nits)，用于色调映射
};

// MARK: - 顶点

struct HDRVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - 传输函数

// PQ EOTF: 非线性 PQ 信号 → 线性光 (归一化到 0-10000 nits / 10000)
float3 pqEOTF(float3 pq) {
    float3 p = pow(max(pq, 0.0), 1.0 / PQ_m2);
    float3 num = max(p - PQ_c1, 0.0);
    float3 den = PQ_c2 - PQ_c3 * p;
    return pow(num / max(den, 1e-6), 1.0 / PQ_m1);
}

// HLG OETF 反转 (ARIB STD-B67)
float3 hlgEOTF(float3 hlg) {
    float3 result;
    for (int i = 0; i < 3; i++) {
        float e = hlg[i];
        if (e <= 0.5) {
            result[i] = (e * e) / 3.0;
        } else {
            result[i] = (exp((e - 0.55991) / 0.17883) + 0.28467) / 12.0;
        }
    }
    return result;
}

// sRGB gamma 解码 → 线性光
float3 srgbToLinear(float3 srgb) {
    float3 result;
    for (int i = 0; i < 3; i++) {
        float c = srgb[i];
        result[i] = (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    return result;
}

// MARK: - 色调映射

// Reinhard 全局色调映射
float3 toneMapReinhard(float3 linear, float maxLuminance) {
    float lum = dot(linear, float3(0.2126, 0.7152, 0.0722));
    float mapped = lum / (1.0 + lum);
    return linear * (mapped / max(lum, 1e-6));
}

// ACES 近似色调映射 (Narkowicz 2015)
float3 toneMapACES(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// 显示自适应色调映射：根据 EDR headroom 缩放
float3 toneMapDisplay(float3 linear, float edrHeadroom) {
    // 简单线性缩放到 EDR 范围
    // PQ 信号归一化到 [0, 1] 代表 [0, 10000] nits
    // 显示器 SDR 参考白 = 100 nits → 10000/100 = 100x
    // 实际 EDR headroom 通常 2.0-8.0
    float maxOutput = edrHeadroom;
    float3 scaled = linear * maxOutput;
    return scaled;
}

// MARK: - 顶点着色器

vertex HDRVertexOut referenceHDRVertex(uint vertexID [[vertex_id]]) {
    HDRVertexOut out;

    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];

    return out;
}

// MARK: - Fragment 着色器

fragment float4 referenceHDRFragment(
    HDRVertexOut in [[stage_in]],
    texture2d<float, access::sample> frameTexture [[texture(0)]],
    constant HDRUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float4 sample = frameTexture.sample(linearSampler, in.texCoord);
    float3 color = sample.rgb;

    // Step 1: 传输函数 → 线性光
    switch (uniforms.transferFunc) {
        case 0: // sRGB
            color = srgbToLinear(color);
            break;
        case 1: // PQ
            color = pqEOTF(color);
            break;
        case 2: // HLG
            color = hlgEOTF(color);
            break;
        case 3: // Linear (已经是线性光)
        default:
            break;
    }

    // Step 2: 色域变换（仅 PQ/HLG 使用 BT.2020 → Display P3）
    if (uniforms.transferFunc == 1 || uniforms.transferFunc == 2) {
        color = BT2020_TO_P3 * color;
    }

    // Step 3: 色调映射
    switch (uniforms.toneMappingMode) {
        case 0: // none
            break;
        case 1: // reinhard
            color = toneMapReinhard(color, uniforms.maxContentLight);
            break;
        case 2: // aces
            color = toneMapACES(color);
            break;
        case 3: // display-adaptive
            color = toneMapDisplay(color, uniforms.edrHeadroom);
            break;
    }

    // Step 4: 钳位输出
    // EDR 模式下允许 > 1.0 的值（由 CAMetalLayer EDR 处理）
    if (uniforms.edrHeadroom > 1.0) {
        color = max(color, 0.0); // 只钳位负值
    } else {
        color = clamp(color, 0.0, 1.0);
    }

    return float4(color, sample.a);
}
