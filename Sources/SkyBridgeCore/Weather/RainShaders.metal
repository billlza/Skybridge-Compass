//
//  RainShaders.metal
//  SkyBridgeCore
//
//  Metal 4 雨天着色器 - 120 FPS高性能渲染
//  Created: 2025-10-19
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 数据结构

struct RainParticle {
    float3 position;
    float3 velocity;
    float size;
    float opacity;
};

struct WaterDropParticle {
    float2 position;
    float size;
    float slideSpeed;
    float refraction;
    float highlight;
};

struct CloudParticle {
    float3 position;
    float size;
    float density;
    float driftSpeed;
};

struct RippleParticle {
    float2 position;
    float radius;
    float maxRadius;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
    float4 color;
};

// MARK: - Compute Shader（粒子更新）

kernel void updateRainParticles(device RainParticle* particles [[buffer(0)]],
                                constant float& deltaTime [[buffer(1)]],
                                uint id [[thread_position_in_grid]])
{
    // 更新雨滴位置
    particles[id].position += particles[id].velocity * deltaTime * 60.0; // 归一化到60fps
    
    // 重力加速
    particles[id].velocity.y -= 0.001 * deltaTime * 60.0;
    
    // 超出底部时重置
    if (particles[id].position.y < -1.0) {
        particles[id].position.y = 1.0;
        particles[id].position.x = fract(sin(float(id) * 12.9898) * 43758.5453) * 2.0 - 1.0;
        particles[id].velocity.y = -0.03;
    }
}

kernel void updateWaterDrops(device WaterDropParticle* drops [[buffer(0)]],
                             constant float& deltaTime [[buffer(1)]],
                             uint id [[thread_position_in_grid]])
{
    // 水珠缓慢下滑
    drops[id].position.y -= drops[id].slideSpeed * deltaTime * 60.0;
    
    // 到达底部重置
    if (drops[id].position.y < -1.0) {
        drops[id].position.y = 1.0;
        drops[id].position.x = fract(sin(float(id) * 78.233) * 43758.5453) * 2.0 - 1.0;
    }
    
    // 高光闪烁效果
    drops[id].highlight = 0.5 + 0.5 * sin(float(id) * 0.1 + deltaTime * 2.0);
}

// MARK: - Vertex Shader

vertex VertexOut rainVertexShader(uint vertexID [[vertex_id]],
                                  constant RainParticle* particles [[buffer(0)]],
                                  constant float4x4& mvpMatrix [[buffer(1)]])
{
    VertexOut out;
    
    // 获取粒子数据
    RainParticle particle = particles[vertexID / 6]; // 每个粒子6个顶点（2个三角形）
    
    // 计算四边形顶点位置
    int corner = vertexID % 6;
    float2 offset = float2(0);
    
    switch(corner) {
        case 0: offset = float2(-1, -1); break;
        case 1: offset = float2( 1, -1); break;
        case 2: offset = float2(-1,  1); break;
        case 3: offset = float2(-1,  1); break;
        case 4: offset = float2( 1, -1); break;
        case 5: offset = float2( 1,  1); break;
    }
    
    // 应用粒子大小
    offset *= particle.size;
    
    // 计算最终位置
    float3 worldPos = particle.position + float3(offset.x, offset.y, 0);
    out.position = mvpMatrix * float4(worldPos, 1.0);
    
    // 纹理坐标
    out.texCoord = offset * 0.5 + 0.5;
    out.opacity = particle.opacity;
    out.color = float4(1, 1, 1, 1);
    
    return out;
}

vertex VertexOut waterDropVertexShader(uint vertexID [[vertex_id]],
                                       constant WaterDropParticle* drops [[buffer(0)]],
                                       constant float4x4& mvpMatrix [[buffer(1)]])
{
    VertexOut out;
    
    WaterDropParticle drop = drops[vertexID / 6];
    
    // 计算椭圆形水珠
    int corner = vertexID % 6;
    float2 offset = float2(0);
    
    switch(corner) {
        case 0: offset = float2(-1, -1.5); break;
        case 1: offset = float2( 1, -1.5); break;
        case 2: offset = float2(-1,  1.5); break;
        case 3: offset = float2(-1,  1.5); break;
        case 4: offset = float2( 1, -1.5); break;
        case 5: offset = float2( 1,  1.5); break;
    }
    
    offset *= drop.size;
    
    float3 worldPos = float3(drop.position, 0.0) + float3(offset.x, offset.y, 0);
    out.position = mvpMatrix * float4(worldPos, 1.0);
    
    out.texCoord = offset * 0.5 + 0.5;
    out.opacity = 0.8;
    
    // 水珠颜色（带高光）
    out.color = float4(1, 1, 1, drop.highlight);
    
    return out;
}

// MARK: - Fragment Shader

fragment float4 rainFragmentShader(VertexOut in [[stage_in]])
{
    // 雨滴形状（拉长的椭圆）
    float2 uv = in.texCoord * 2.0 - 1.0;
    float dist = length(uv * float2(1.0, 3.0));
    
    // 平滑边缘
    float alpha = smoothstep(1.0, 0.8, dist) * in.opacity;
    
    return float4(in.color.rgb, alpha);
}

fragment float4 waterDropFragmentShader(VertexOut in [[stage_in]])
{
    // 水珠形状（椭圆）
    float2 uv = in.texCoord * 2.0 - 1.0;
    float dist = length(uv * float2(1.0, 1.5));
    
    // 水珠主体
    float dropAlpha = smoothstep(1.0, 0.7, dist);
    
    // 渐变光泽效果
    float gradient = 1.0 - uv.y * 0.5;
    
    // 顶部高光
    float2 highlightPos = uv - float2(0.0, 0.3);
    float highlight = exp(-length(highlightPos) * 8.0) * in.color.a;
    
    // 折射边缘
    float edge = smoothstep(0.95, 1.0, dist);
    
    // 合成最终颜色
    float3 waterColor = mix(
        float3(0.9, 0.95, 1.0) * gradient,  // 水珠主体（淡蓝色）
        float3(1.0),                         // 高光
        highlight
    );
    
    float finalAlpha = dropAlpha * in.opacity * (0.3 + edge * 0.3);
    
    return float4(waterColor, finalAlpha);
}

fragment float4 cloudFragmentShader(VertexOut in [[stage_in]])
{
    // 云朵柔软边缘
    float2 uv = in.texCoord * 2.0 - 1.0;
    float dist = length(uv);
    
    // 多层噪声模拟云朵质感
    float noise = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    float cloudDensity = smoothstep(1.0, 0.3, dist) * (0.8 + noise * 0.2);
    
    // 深灰色云朵
    float3 cloudColor = float3(0.2, 0.25, 0.3);
    
    return float4(cloudColor, cloudDensity * in.opacity);
}

fragment float4 rippleFragmentShader(VertexOut in [[stage_in]])
{
    // 同心圆涟漪
    float2 uv = in.texCoord * 2.0 - 1.0;
    float dist = length(uv);
    
    // 涟漪圆环
    float ripple = abs(dist - 0.5);
    float ring = smoothstep(0.1, 0.0, ripple);
    
    // 渐隐效果
    float fade = 1.0 - dist;
    
    return float4(1, 1, 1, ring * fade * in.opacity * 0.4);
}

// MARK: - MetalFX 兼容的后处理

kernel void applyGlassRefraction(texture2d<float, access::read> inTexture [[texture(0)]],
                                 texture2d<float, access::write> outTexture [[texture(1)]],
                                 constant WaterDropParticle* drops [[buffer(0)]],
                                 constant uint& dropCount [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    float2 uv = float2(gid) / float2(inTexture.get_width(), inTexture.get_height());
    float2 distortion = float2(0);
    
    // 对每个水珠计算折射扰动
    for (uint i = 0; i < dropCount; i++) {
        float2 dropPos = (drops[i].position * 0.5 + 0.5); // 转换到0-1空间
        float2 toPixel = uv - dropPos;
        float dist = length(toPixel);
        
        if (dist < drops[i].size) {
            // 折射强度
            float refraction = drops[i].refraction * (1.0 - dist / drops[i].size);
            distortion += toPixel * refraction * 0.05;
        }
    }
    
    // 应用扰动采样
    float2 distortedUV = saturate(uv + distortion);
    uint2 samplePos = uint2(distortedUV * float2(inTexture.get_width(), inTexture.get_height()));
    
    float4 color = inTexture.read(samplePos);
    outTexture.write(color, gid);
}

