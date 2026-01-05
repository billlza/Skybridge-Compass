#include <metal_stdlib>
using namespace metal;

// MARK: - 数据结构

/// 天气粒子结构
struct WeatherParticle {
    float3 position;
    float3 velocity;
    float4 color;
    float size;
    float life;
    float maxLife;
    int type; // 0=雨滴，1=雪花，2=云朵，3=雾气
};

/// 粒子Uniform数据
struct ParticleUniformData {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float time;
    float deltaTime;
};

/// 天气参数数据
struct WeatherParametersData {
    int weatherType;
    float intensity;
    float temperature;
    float humidity;
    float windSpeed;
    float windDirection;
    float visibility;
};

/// 鼠标交互数据
struct MouseInteractionData {
    float2 mousePosition;
    float influenceRadius;
    float repelForce;
    float blurRadius;
};

/// 时间数据
struct TimeData {
    float time;
    float deltaTime;
};

/// 顶点输出结构
struct VertexOut {
    float4 position [[position]];
    float4 color;
    float size [[point_size]];
    float2 texCoord;
    int particleType;
};

// MARK: - 工具函数

/// 生成噪声函数
float noise(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/// 2D噪声函数
float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    
    float a = noise(i);
    float b = noise(i + float2(1.0, 0.0));
    float c = noise(i + float2(0.0, 1.0));
    float d = noise(i + float2(1.0, 1.0));
    
    float2 u = f * f * (3.0 - 2.0 * f);
    
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

/// 计算粒子风力影响
float3 calculateParticleWindForce(float3 position, float windSpeed, float windDirection, float time) {
    // 基础风力方向
    float3 windDir = float3(cos(windDirection), 0.0, sin(windDirection));
    
    // 添加湍流效果
    float turbulence = noise2D(position.xz * 0.01 + time * 0.1) * 0.5 + 0.5;
    
    // 计算最终风力
    float3 windForce = windDir * windSpeed * (0.5 + turbulence * 0.5);
    
    return windForce;
}

/// 计算鼠标交互力
float3 calculateMouseInteraction(float3 particlePos, float2 mousePos, float influenceRadius, float repelForce) {
    float2 particleScreen = particlePos.xy;
    float2 toMouse = particleScreen - mousePos;
    float distance = length(toMouse);
    
    if (distance < influenceRadius && distance > 0.0) {
        float influence = 1.0 - (distance / influenceRadius);
        influence = influence * influence; // 平方衰减
        
        float3 repelDirection = normalize(float3(toMouse, 0.0));
        return repelDirection * repelForce * influence;
    }
    
    return float3(0.0);
}

// MARK: - 计算着色器

/// 天气粒子更新计算着色器
kernel void weather_particle_update(device WeatherParticle* particles [[buffer(0)]],
                                   constant WeatherParametersData& weatherParams [[buffer(1)]],
                                   constant MouseInteractionData& mouseData [[buffer(2)]],
                                   constant TimeData& timeData [[buffer(3)]],
                                   uint id [[thread_position_in_grid]]) {
    
    if (id >= 10000) return; // 最大粒子数限制
    
    WeatherParticle particle = particles[id];
    
    // 检查粒子生命周期
    particle.life -= timeData.deltaTime;
    if (particle.life <= 0.0) {
        // 重新生成粒子
        particle.position = float3(
            (noise(float2(id * 0.1, timeData.time * 0.01)) - 0.5) * 1000.0,
            1000.0,
            (noise(float2(id * 0.2, timeData.time * 0.02)) - 0.5) * 200.0
        );
        particle.life = particle.maxLife;
    }
    
    // 计算重力
    float3 gravity = float3(0.0, -9.8, 0.0);
    
    // 计算风力
    float3 windForce = calculateParticleWindForce(particle.position, weatherParams.windSpeed, weatherParams.windDirection, timeData.time);
    
    // 计算鼠标交互力
    float3 mouseForce = calculateMouseInteraction(particle.position, mouseData.mousePosition, mouseData.influenceRadius, mouseData.repelForce);
    
    // 根据粒子类型应用不同的物理效果
    float3 totalForce = gravity;
    
    switch (particle.type) {
        case 0: // 雨滴
            totalForce += windForce * 0.3;
            totalForce += mouseForce * 0.5;
            break;
            
        case 1: // 雪花
            totalForce *= 0.1; // 雪花受重力影响较小
            totalForce += windForce * 0.8;
            totalForce += mouseForce * 0.8;
            // 添加飘动效果
            totalForce.x += sin(timeData.time * 2.0 + particle.position.y * 0.01) * 2.0;
            totalForce.z += cos(timeData.time * 1.5 + particle.position.x * 0.01) * 1.5;
            break;
            
        case 2: // 云朵
            totalForce = windForce * 0.2;
            totalForce += mouseForce * 0.3;
            totalForce.y = sin(timeData.time * 0.5 + particle.position.x * 0.005) * 0.5;
            break;
            
        case 3: // 雾气
            totalForce = windForce * 0.1;
            totalForce += mouseForce * 1.2; // 雾气对鼠标交互更敏感
            // 添加缓慢的上升运动
            totalForce.y += 0.5;
            // 添加随机漂移
            totalForce.x += (noise(particle.position.xz * 0.01 + timeData.time * 0.1) - 0.5) * 1.0;
            totalForce.z += (noise(particle.position.zx * 0.01 + timeData.time * 0.15) - 0.5) * 1.0;
            break;
    }
    
    // 更新速度和位置
    particle.velocity += totalForce * timeData.deltaTime;
    
    // 添加阻力
    float drag = 0.98;
    if (particle.type == 3) { // 雾气阻力更大
        drag = 0.95;
    }
    particle.velocity *= drag;
    
    // 更新位置
    particle.position += particle.velocity * timeData.deltaTime;
    
    // 边界检查和重置
    if (particle.position.y < -100.0 || particle.position.x < -600.0 || particle.position.x > 600.0) {
        particle.position = float3(
            (noise(float2(id * 0.3, timeData.time * 0.03)) - 0.5) * 1000.0,
            1000.0,
            (noise(float2(id * 0.4, timeData.time * 0.04)) - 0.5) * 200.0
        );
        particle.velocity = float3(0.0);
        particle.life = particle.maxLife;
    }
    
    // 更新透明度基于生命周期
    float lifeRatio = particle.life / particle.maxLife;
    particle.color.a *= lifeRatio;
    
    // 根据天气强度调整颜色
    particle.color.rgb *= (0.5 + weatherParams.intensity * 0.5);
    
    // 写回粒子数据
    particles[id] = particle;
}

// MARK: - 顶点着色器

/// 天气粒子顶点着色器
vertex VertexOut weather_particle_vertex(const device WeatherParticle* particles [[buffer(0)]],
                                        constant ParticleUniformData& uniforms [[buffer(1)]],
                                        uint vertexID [[vertex_id]]) {
    
    WeatherParticle particle = particles[vertexID];
    
    VertexOut out;
    
    // 变换到屏幕空间
    float4 worldPosition = float4(particle.position, 1.0);
    float4 viewPosition = uniforms.viewMatrix * worldPosition;
    out.position = uniforms.projectionMatrix * viewPosition;
    
    // 传递颜色和大小
    out.color = particle.color;
    out.size = particle.size;
    out.particleType = particle.type;
    
    // 纹理坐标（用于点精灵）
    out.texCoord = float2(0.0);
    
    return out;
}

// MARK: - 片段着色器

/// 天气粒子片段着色器
fragment float4 weather_particle_fragment(VertexOut in [[stage_in]],
                                         float2 pointCoord [[point_coord]]) {
    
    float4 color = in.color;
    
    // 计算到中心的距离
    float2 coord = pointCoord - 0.5;
    float distance = length(coord);
    
    // 根据粒子类型应用不同的渲染效果
    switch (in.particleType) {
        case 0: { // 雨滴
            // 椭圆形雨滴
            float2 ellipseCoord = coord;
            ellipseCoord.y *= 2.0; // 拉长
            float ellipseDistance = length(ellipseCoord);
            if (ellipseDistance > 0.5) {
                discard_fragment();
            }
            color.a *= (1.0 - ellipseDistance * 2.0);
            break;
        }
        
        case 1: { // 雪花
            // 六角形雪花图案
            float angle = atan2(coord.y, coord.x);
            float radius = length(coord);
            
            // 创建六角形图案
            float hexPattern = cos(angle * 6.0) * 0.5 + 0.5;
            float snowflake = smoothstep(0.3, 0.5, hexPattern) * (1.0 - smoothstep(0.3, 0.5, radius));
            
            if (snowflake < 0.1) {
                discard_fragment();
            }
            
            color.a *= snowflake;
            break;
        }
        
        case 2: { // 云朵
            // 柔和的圆形
            if (distance > 0.5) {
                discard_fragment();
            }
            float softness = 1.0 - smoothstep(0.2, 0.5, distance);
            color.a *= softness;
            break;
        }
        
        case 3: { // 雾气
            // 非常柔和的渐变
            float fogAlpha = 1.0 - smoothstep(0.0, 0.5, distance);
            fogAlpha *= fogAlpha; // 平方衰减，更柔和
            color.a *= fogAlpha * 0.6; // 降低整体透明度
            break;
        }
        
        default: {
            // 默认圆形
            if (distance > 0.5) {
                discard_fragment();
            }
            color.a *= (1.0 - distance * 2.0);
            break;
        }
    }
    
    return color;
}

// MARK: - 后处理着色器（用于雾霾效果）

/// 雾霾色调调整片段着色器
fragment float4 haze_tone_adjustment(VertexOut in [[stage_in]],
                                    texture2d<float> colorTexture [[texture(0)]],
                                    constant float& hazeIntensity [[buffer(0)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float4 originalColor = colorTexture.sample(textureSampler, in.texCoord);
    
    // 雾霾色调调整
    float3 hazeColor = float3(0.7, 0.6, 0.5); // 暖黄色调
    float hazeFactor = hazeIntensity * 0.3;
    
    // 降低亮度和对比度
    originalColor.rgb *= (1.0 - hazeFactor * 0.4);
    
    // 混合雾霾色调
    originalColor.rgb = mix(originalColor.rgb, hazeColor, hazeFactor);
    
    // 降低饱和度
    float luminance = dot(originalColor.rgb, float3(0.299, 0.587, 0.114));
    originalColor.rgb = mix(originalColor.rgb, float3(luminance), hazeFactor * 0.5);
    
    return originalColor;
}