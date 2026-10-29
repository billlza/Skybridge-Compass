#include <metal_stdlib>
using namespace metal;

// MARK: - Remote Desktop Pass-through Shader
//
// 极简全屏三角形 + 纹理采样，GPU 时间 < 0.1ms/frame。
// 用于 FluidRenderer 的显示驱动渲染——解码帧零处理直出屏幕。
//
// 设计：
// - 使用 3 顶点全屏三角形（无需 vertex buffer）
// - Fragment 只做一次 texture sample
// - 不走 CIContext、不走 compute kernel，最小 GPU 占用

// MARK: - 顶点输出

struct FluidVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - 全屏三角形顶点着色器
//
// 三角形覆盖整个 NDC 空间 [-1, 1]：
//   v0 = (-1, -1)  →  texCoord (0, 1)
//   v1 = ( 3, -1)  →  texCoord (2, 1)
//   v2 = (-1,  3)  →  texCoord (0, -1)
// 裁剪后恰好覆盖 [0,1] x [0,1] 的纹理空间。

vertex FluidVertexOut fluidPassthroughVertex(uint vertexID [[vertex_id]]) {
    FluidVertexOut out;

    // 全屏三角形——不需要 vertex buffer
    float2 positions[3] = {
        float2(-1.0, -1.0),  // 左下
        float2( 3.0, -1.0),  // 右下（超出裁剪区域）
        float2(-1.0,  3.0)   // 左上（超出裁剪区域）
    };

    // 纹理坐标：Metal 纹理原点在左上 (0,0)
    float2 texCoords[3] = {
        float2(0.0, 1.0),  // 左下 → 纹理左下
        float2(2.0, 1.0),  // 右下延伸
        float2(0.0, -1.0)  // 左上延伸
    };

    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];

    return out;
}

// MARK: - 纹理采样 Fragment 着色器
//
// 单次 texture sample 直出，无任何后处理。

fragment float4 fluidPassthroughFragment(
    FluidVertexOut in [[stage_in]],
    texture2d<float, access::sample> frameTexture [[texture(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    return frameTexture.sample(linearSampler, in.texCoord);
}
