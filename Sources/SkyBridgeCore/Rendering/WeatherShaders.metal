#include <metal_stdlib>
using namespace metal;

// MARK: - 数据结构定义

/// 粒子数据结构
struct ParticleData {
    float3 position;
    float3 velocity;
    float4 color;
    float size;
    float life;
    float maxLife;
    int type; // 粒子类型：0=雨滴，1=雪花，2=云朵，3=雾气，4=雾霾
};

/// Uniform数据结构
struct UniformData {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float time;
    float deltaTime;
};

/// 天气参数结构
struct WeatherUniformData {
    int weatherType;
    float intensity;
    float temperature;
    float humidity;
    float windSpeed;
    float windDirection;
    float cloudCoverage;
    float precipitationAmount;
    float visibility;
    float pressure;
    float uvIndex;
    int timeOfDay;
};

/// 顶点输出结构
struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
    float2 texCoord;
};

// MARK: - 工具函数

/// 生成随机数
float random(float2 st) {
    return fract(sin(dot(st.xy, float2(12.9898, 78.233))) * 43758.5453123);
}

/// 3D噪声函数
float noise3D(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    
    float2 uv = (i.xy + float2(37.0, 17.0) * i.z) + f.xy;
    float2 rg = float2(random(uv), random(uv + float2(1.0, 0.0)));
    
    return mix(rg.x, rg.y, f.z);
}

/// 风力影响计算
float3 calculateWindForce(float3 position, float windSpeed, float windDirection, float time) {
    float windX = cos(windDirection) * windSpeed;
    float windZ = sin(windDirection) * windSpeed;
    
    // 添加湍流效果
    float turbulence = noise3D(position * 0.1 + float3(time * 0.5, 0.0, 0.0)) * 0.3;
    
    return float3(windX + turbulence, 0.0, windZ + turbulence);
}

// MARK: - 粒子更新计算着色器

kernel void particle_update_compute(
    device ParticleData* particles [[buffer(0)]],
    constant UniformData& uniforms [[buffer(1)]],
    constant WeatherUniformData& weather [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= 100000) return; // 最大粒子数限制
    
    ParticleData particle = particles[id];
    
    // 更新粒子生命周期
    particle.life -= uniforms.deltaTime;
    
    // 如果粒子死亡，重新初始化
    if (particle.life <= 0.0) {
        // 根据天气类型重新初始化粒子
        float3 spawnPos = float3(
            random(float2(id, uniforms.time)) * 40.0 - 20.0,
            20.0 + random(float2(id + 1000, uniforms.time)) * 10.0,
            random(float2(id + 2000, uniforms.time)) * 40.0 - 20.0
        );
        
        particle.position = spawnPos;
        particle.life = particle.maxLife;
        
        // 根据天气类型设置粒子属性
        switch (weather.weatherType) {
            case 0: // 晴天 - 少量灰尘粒子
                particle.velocity = float3(0.0, -0.1, 0.0);
                particle.color = float4(0.8, 0.8, 0.6, 0.1);
                particle.type = 3;
                break;
                
            case 1: // 雨天
                particle.velocity = float3(0.0, -8.0, 0.0);
                particle.color = float4(0.7, 0.8, 1.0, 0.8);
                particle.size = 0.8;
                particle.type = 0;
                break;
                
            case 2: // 雪天
                particle.velocity = float3(0.0, -2.0, 0.0);
                particle.color = float4(1.0, 1.0, 1.0, 0.9);
                particle.size = 1.2;
                particle.type = 1;
                break;
                
            case 3: // 雷暴
                particle.velocity = float3(0.0, -12.0, 0.0);
                particle.color = float4(0.5, 0.6, 0.9, 0.9);
                particle.size = 1.0;
                particle.type = 0;
                break;
                
            case 4: // 雾霾天气 - 新增雾霾粒子初始化
                particle.velocity = float3(
                    random(float2(id + 3000, uniforms.time)) * 0.6 - 0.3,
                    random(float2(id + 4000, uniforms.time)) * 0.2 - 0.1,
                    random(float2(id + 5000, uniforms.time)) * 0.6 - 0.3
                );
                particle.color = float4(0.8, 0.7, 0.5, 0.25); // 黄灰色调
                particle.size = 1.5 + random(float2(id + 6000, uniforms.time)) * 2.0;
                particle.type = 4; // 雾霾类型
                break;
                
            default: // 其他天气
                particle.velocity = float3(0.0, -1.0, 0.0);
                particle.color = float4(0.8, 0.8, 0.8, 0.5);
                particle.size = 0.6;
                particle.type = 2;
                break;
        }
        
        particle.maxLife = 3.0 + random(float2(id, uniforms.time + 100)) * 4.0;
        
        // 雾霾粒子生命周期更长
        if (particle.type == 4) {
            particle.maxLife = 10.0 + random(float2(id, uniforms.time + 200)) * 10.0;
        }
    }
    
    // 计算物理力
    float3 gravity = float3(0.0, -9.8, 0.0);
    float3 windForce = calculateWindForce(particle.position, weather.windSpeed, weather.windDirection, uniforms.time);
    
    // 根据粒子类型调整物理参数
    float mass = 1.0;
    float drag = 0.1;
    
    switch (particle.type) {
        case 0: // 雨滴
            mass = 2.0;
            drag = 0.05;
            break;
        case 1: // 雪花
            mass = 0.5;
            drag = 0.3;
            break;
        case 2: // 云朵
            mass = 0.1;
            drag = 0.8;
            gravity *= 0.1; // 云朵受重力影响小
            break;
        case 3: // 雾气
            mass = 0.05;
            drag = 0.9;
            gravity *= 0.05;
            break;
        case 4: // 雾霾 - 新增雾霾粒子物理参数
            mass = 0.08; // 比雾气稍重
            drag = 0.85; // 阻力稍小，移动更缓慢
            gravity *= 0.03; // 受重力影响很小，悬浮效果
            break;
    }
    
    // 应用力
    float3 totalForce = gravity * mass + windForce - particle.velocity * drag;
    particle.velocity += totalForce * uniforms.deltaTime / mass;
    
    // 更新位置
    particle.position += particle.velocity * uniforms.deltaTime;
    
    // 边界检查和回收
    if (particle.position.y < -5.0 || 
        abs(particle.position.x) > 25.0 || 
        abs(particle.position.z) > 25.0) {
        particle.life = 0.0; // 标记为死亡，下一帧重新生成
    }
    
    // 根据生命周期调整透明度
    float lifeRatio = particle.life / particle.maxLife;
    particle.color.a *= lifeRatio;
    
    // 应用天气强度影响
    particle.color.a *= weather.intensity;
    
    // 雾霾粒子特殊处理 - 根据能见度调整透明度
    if (particle.type == 4) {
        float visibilityFactor = 1.0 - clamp(weather.visibility / 10.0, 0.0, 1.0);
        particle.color.a *= (1.0 + visibilityFactor * 0.5); // 能见度越低，雾霾越浓
    }
    
    particles[id] = particle;
}

// MARK: - 粒子渲染顶点着色器

vertex VertexOut particle_vertex(
    const device ParticleData* particles [[buffer(0)]],
    constant UniformData& uniforms [[buffer(1)]],
    constant WeatherUniformData& weather [[buffer(2)]],
    uint vertexID [[vertex_id]]
) {
    VertexOut out;
    
    if (vertexID >= 100000) {
        out.position = float4(0.0);
        out.color = float4(0.0);
        out.pointSize = 0.0;
        out.texCoord = float2(0.0);
        return out;
    }
    
    ParticleData particle = particles[vertexID];
    
    // 变换到屏幕空间
    float4 worldPos = float4(particle.position, 1.0);
    float4 viewPos = uniforms.viewMatrix * worldPos;
    out.position = uniforms.projectionMatrix * viewPos;
    
    // 设置颜色
    out.color = particle.color;
    
    // 设置纹理坐标
    out.texCoord = float2(0.5, 0.5);
    
    // 根据距离调整点大小
    float distance = length(viewPos.xyz);
    float sizeScale = 100.0 / (distance + 1.0);
    out.pointSize = particle.size * sizeScale * weather.intensity;
    
    // 限制点大小范围
    out.pointSize = clamp(out.pointSize, 1.0, 20.0);
    
    return out;
}

// MARK: - 粒子渲染片段着色器

fragment float4 particle_fragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // 创建圆形粒子
    float2 center = float2(0.5, 0.5);
    float distance = length(pointCoord - center);
    
    // 软边缘效果
    float alpha = 1.0 - smoothstep(0.3, 0.5, distance);
    
    float4 color = in.color;
    color.a *= alpha;
    
    // 如果透明度太低，丢弃片段
    if (color.a < 0.01) {
        discard_fragment();
    }
    
    return color;
}

/// 计算雾霾色调调整
float3 calculateHazeToneAdjustment(float3 baseColor, float visibility, float intensity, float humidity) {
    // 雾霾强度基于能见度和湿度
    float hazeIntensity = (1.0 - visibility) * intensity;
    hazeIntensity = mix(hazeIntensity, hazeIntensity * 1.5, humidity * 0.5);
    
    // 雾霾色调 - 偏黄灰色
    float3 hazeTint = float3(1.2, 1.1, 0.8);
    
    // 整体变暗效果
    float darkeningFactor = 1.0 - hazeIntensity * 0.6;
    
    float3 adjustedColor = baseColor * darkeningFactor;
    adjustedColor = mix(adjustedColor, adjustedColor * hazeTint, hazeIntensity * 0.4);
    
    return adjustedColor;
}

/// 计算动态色调调整（基于天气类型和时间）
float3 calculateDynamicToneAdjustment(float3 baseColor, int weatherType, float intensity, float visibility, float humidity, int timeOfDay) {
    float3 adjustedColor = baseColor;
    
    // 根据天气类型应用特定的色调调整
    switch (weatherType) {
        case 0: // 晴天 - 增强暖色调
            adjustedColor *= float3(1.1, 1.05, 0.95);
            break;
            
        case 1: // 雨天 - 冷色调和降低饱和度
            adjustedColor *= float3(0.8, 0.9, 1.1);
            adjustedColor = mix(adjustedColor, float3(dot(adjustedColor, float3(0.299, 0.587, 0.114))), 0.3);
            break;
            
        case 2: // 雪天 - 增强蓝白色调
            adjustedColor *= float3(0.9, 0.95, 1.2);
            break;
            
        case 3: // 雷暴 - 强烈变暗和紫色调
            adjustedColor *= float3(0.4, 0.3, 0.6);
            break;
            
        case 4: // 雾天/雾霾 - 应用雾霾色调调整
            adjustedColor = calculateHazeToneAdjustment(adjustedColor, visibility, intensity, humidity);
            break;
            
        default:
            break;
    }
    
    // 根据时间段进一步调整色调
    switch (timeOfDay) {
        case 0: // 上午 - 清新明亮
            adjustedColor *= float3(1.0, 1.0, 1.0);
            break;
        case 1: // 下午 - 温暖色调
            adjustedColor *= float3(1.05, 1.0, 0.95);
            break;
        case 2: // 傍晚 - 橙红色调
            adjustedColor *= float3(1.2, 0.9, 0.7);
            break;
        case 3: // 夜晚 - 蓝紫色调和整体变暗
            adjustedColor *= float3(0.3, 0.4, 0.6);
            break;
    }
    
    return adjustedColor;
}


// MARK: - 光线追踪计算着色器（简化版本）

kernel void ray_tracing_compute(
    texture2d<float, access::write> outputTexture [[texture(0)]],
    constant UniformData& uniforms [[buffer(0)]],
    constant WeatherUniformData& weather [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 简化的光线追踪实现
    float2 uv = float2(gid) / float2(outputTexture.get_width(), outputTexture.get_height());
    uv = uv * 2.0 - 1.0; // 转换到[-1, 1]范围
    
    // 基础天空颜色
    float3 skyColor = float3(0.5, 0.7, 1.0);
    
    // 根据天气类型调整天空颜色
    switch (weather.weatherType) {
        case 0: // 晴天
            skyColor = float3(0.3, 0.6, 1.0);
            break;
        case 1: // 雨天
            skyColor = float3(0.4, 0.4, 0.6);
            break;
        case 2: // 雪天
            skyColor = float3(0.8, 0.8, 0.9);
            break;
        case 3: // 雷暴
            skyColor = float3(0.2, 0.2, 0.4);
            break;
        case 4: // 雾天/雾霾 - 特殊处理
            skyColor = float3(0.6, 0.5, 0.4); // 黄灰色基调
            break;
        default:
            skyColor = float3(0.5, 0.5, 0.5);
            break;
    }
    
    // 添加云层效果
    float cloudNoise = noise3D(float3(uv * 5.0, uniforms.time * 0.1));
    float cloudDensity = weather.cloudCoverage * weather.intensity;
    
    float3 cloudColor = float3(0.9, 0.9, 0.9);
    if (weather.weatherType == 3) { // 雷暴云
        cloudColor = float3(0.3, 0.3, 0.4);
    } else if (weather.weatherType == 4) { // 雾霾云
        cloudColor = float3(0.7, 0.6, 0.5); // 污染的云层颜色
    }
    
    // 混合天空和云层
    float3 finalColor = mix(skyColor, cloudColor, cloudNoise * cloudDensity);
    
    // 应用动态色调调整
    finalColor = calculateDynamicToneAdjustment(
        finalColor, 
        weather.weatherType, 
        weather.intensity, 
        weather.visibility, 
        weather.humidity, 
        weather.timeOfDay
    );
    
    // 添加时间变化效果（在动态色调调整之后进行微调）
    float timeOfDayFactor = 1.0;
    switch (weather.timeOfDay) {
        case 0: // 上午
            timeOfDayFactor = 1.0;
            break;
        case 1: // 下午
            timeOfDayFactor = 0.9;
            break;
        case 2: // 傍晚
            timeOfDayFactor = 0.7;
            break;
        case 3: // 夜晚
            timeOfDayFactor = 0.3;
            break;
    }
    
    finalColor *= timeOfDayFactor;
    
    // 应用能见度影响（特别是雾霾天气）
    float visibilityFactor = clamp(weather.visibility / 10.0, 0.3, 1.0);
    if (weather.weatherType == 4) { // 雾霾天气特殊处理
        // 雾霾时能见度影响更强烈
        visibilityFactor = clamp(weather.visibility / 15.0, 0.2, 0.8);
        // 添加雾霾粒子散射效果
        float hazeScattering = (1.0 - visibilityFactor) * weather.intensity;
        finalColor = mix(finalColor, float3(0.8, 0.7, 0.6), hazeScattering * 0.3);
    }
    
    finalColor *= visibilityFactor;
    
    outputTexture.write(float4(finalColor, 1.0), gid);
}

// MARK: - 体积云渲染着色器

kernel void volumetric_clouds_compute(
    texture3d<float, access::read> cloudTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant UniformData& uniforms [[buffer(0)]],
    constant WeatherUniformData& weather [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float2 uv = float2(gid) / float2(outputTexture.get_width(), outputTexture.get_height());
    
    // 简化的体积云渲染
    float3 rayDir = normalize(float3(uv * 2.0 - 1.0, 1.0));
    float3 rayPos = float3(0.0, 0.0, -10.0);
    
    float cloudDensity = 0.0;
    float stepSize = 0.1;
    int maxSteps = 50;
    
    // 光线步进
    for (int i = 0; i < maxSteps; i++) {
        float3 samplePos = rayPos + rayDir * float(i) * stepSize;
        
        // 采样3D云纹理 - 使用read()方法而不是sample()
        float3 texCoord = (samplePos + 10.0) / 20.0; // 归一化到[0,1]
        if (all(texCoord >= 0.0) && all(texCoord <= 1.0)) {
            // 将纹理坐标转换为整数坐标
            uint3 coord = uint3(texCoord * float3(cloudTexture.get_width(), 
                                                 cloudTexture.get_height(), 
                                                 cloudTexture.get_depth()));
            float density = cloudTexture.read(coord).r;
            cloudDensity += density * stepSize * weather.cloudCoverage;
        }
    }
    
    // 计算最终云层颜色
    float3 cloudColor = float3(1.0, 1.0, 1.0);
    float alpha = 1.0 - exp(-cloudDensity * weather.intensity);
    
    outputTexture.write(float4(cloudColor, alpha), gid);
}