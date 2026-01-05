#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct GlobalHazeUniforms {
    float2 resolution;
    float2 mousePosition;
    int isMouseActive;
    float hazeIntensity;
    float disperseRadius;
    float disperseStrength;
    float time;
    //新增全局透明度（0=完全透明，1=完全不透明），由交互驱散系统控制
    float globalOpacity;
};

// 顶点着色器
vertex VertexOut globalHazeVertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    
    // 全屏四边形的顶点和纹理坐标
    float2 positions[4] = {
        float2(-1.0, -1.0),  // 左下
        float2( 1.0, -1.0),  // 右下
        float2(-1.0,  1.0),  // 左上
        float2( 1.0,  1.0)   // 右上
    };
    
    float2 texCoords[4] = {
        float2(0.0, 1.0),    // 左下
        float2(1.0, 1.0),    // 右下
        float2(0.0, 0.0),    // 左上
        float2(1.0, 0.0)     // 右上
    };
    
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    
    return out;
}

// 噪声函数
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    
    float2 u = f * f * (3.0 - 2.0 * f);
    
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// 分形噪声
float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    
    for (int i = 0; i < 5; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return value;
}

// 片段着色器
fragment float4 globalHazeFragmentShader(VertexOut in [[stage_in]],
                                        constant GlobalHazeUniforms& uniforms [[buffer(0)]]) {
    float2 uv = in.texCoord;
    float2 mousePos = uniforms.mousePosition;
    bool isMouseActive = uniforms.isMouseActive != 0;
    float time = uniforms.time;
    
    // 创建动态雾霾效果
    float2 p = uv * 8.0 + time * 0.1;
    float haze = fbm(p) * 0.7 + fbm(p * 2.0) * 0.3;
    
    // 添加缓慢的流动效果
    float2 flow = float2(sin(time * 0.2), cos(time * 0.15)) * 0.5;
    haze += fbm(uv * 6.0 + flow) * 0.4;
    
    // 基础雾霾强度
    float hazeAlpha = haze * uniforms.hazeIntensity;
    
    // 鼠标驱散效果
    if (isMouseActive) {
        float2 mouseUV = mousePos;
        float distanceToMouse = length(uv - mouseUV);
        
        // 中文注释：将像素半径转换为UV空间半径，避免使用固定常量导致不同分辨率下驱散范围异常
        float radiusUV = uniforms.disperseRadius;
        // 计算驱散强度（距离越近，驱散越强），并进行二次方增强边缘梯度
        float disperseEffect = clamp(1.0 - (distanceToMouse / max(radiusUV, 1e-5)), 0.0, 1.0);
        disperseEffect = pow(disperseEffect, 2.0); // 增强驱散效果
        
        // 应用驱散效果
        hazeAlpha *= (1.0 - disperseEffect * uniforms.disperseStrength);
        
        // 添加驱散边缘的涡流效果
        if (disperseEffect > 0.1) {
            float angle = atan2(uv.y - mouseUV.y, uv.x - mouseUV.x);
            float swirl = sin(angle * 8.0 + time * 4.0) * disperseEffect * 0.3;
            hazeAlpha += swirl * 0.2;
        }
    }
    
    // 中文注释：应用全局驱散透明度，整体降低雾霾不透明度，从而露出底层背景
    hazeAlpha *= uniforms.globalOpacity;

    // 确保透明度在合理范围内
    hazeAlpha = clamp(hazeAlpha, 0.0, 0.9);
    
    // 雾霾颜色 - 灰白色带一点蓝色调
    float3 hazeColor = float3(0.8, 0.85, 0.9);
    
    // 添加一些颜色变化
    hazeColor += float3(haze * 0.1, haze * 0.05, haze * 0.15);
    
    return float4(hazeColor, hazeAlpha);
}