//
//  HazeParticleShaders.metal
//  SkyBridgeCore
//
//  动态雾霾粒子系统 - 真正的粒子渲染而非静态雾效果
//  特性：粒子生成、运动、生命周期、鼠标交互驱散
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 粒子结构

struct HazeParticle {
    float2 position;        // 当前位置
    float2 velocity;        // 速度向量
    float2 initialPos;      // 初始位置（用于重置）
    float size;             // 粒子大小
    float life;             // 生命值 (0-1)
    float maxLife;          // 最大生命值
    float opacity;          // 透明度
    float rotationSpeed;    // 旋转速度
    float rotation;         // 当前旋转角度
};

struct ParticleUniforms {
    float2 resolution;      // 屏幕分辨率
    float time;             // 时间
    float deltaTime;        // 帧间隔
    float intensity;        // 雾霾强度 (0-1)
    float4 tint;            // 雾霾颜色
    float windStrength;     // 风力强度
    float2 windDirection;   // 风向
    int particleCount;      // 粒子数量
    float globalOpacity;    // 全局透明度
    int clearZoneCount;     // 清除区域数量
};

struct ClearZone {
    float2 center;          // 清除区域中心
    float radius;           // 清除区域半径
    float strength;         // 清除强度 (0-1)
};

// MARK: - 噪声函数

static inline float hash(float2 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * (p.x + p.y));
}

static inline float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// MARK: - 粒子更新计算着色器

// MARK: - 粒子聚集函数

static inline float2 getClusterCenter(float2 position, float clusterSize) {
    // 将世界坐标映射到聚集网格
    float2 gridPos = floor(position / clusterSize);
    
    // 为每个网格生成一个稳定的随机偏移
    float2 seed = gridPos * 0.1234;
    float offsetX = (hash(seed) - 0.5) * clusterSize * 0.3;
    float offsetY = (hash(seed + float2(100.0, 0.0)) - 0.5) * clusterSize * 0.3;
    
    return (gridPos + 0.5) * clusterSize + float2(offsetX, offsetY);
}

static inline float getClusterDensity(float2 position, float time) {
    // 使用多层噪声创建密度变化
    float density = 0.0;
    
    // 大尺度密度变化
    density += noise(position * 0.003 + time * 0.05) * 0.6;
    
    // 中尺度聚集
    density += noise(position * 0.01 + time * 0.1) * 0.3;
    
    // 小尺度细节
    density += noise(position * 0.05 + time * 0.2) * 0.1;
    
    return saturate(density);
}

kernel void updateHazeParticles(device HazeParticle* particles [[buffer(0)]],
                               constant ParticleUniforms& uniforms [[buffer(1)]],
                               constant ClearZone* clearZones [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
    
    if (id >= uint(uniforms.particleCount)) return;
    
    HazeParticle particle = particles[id];
    
    // 基础物理更新
    float2 acceleration = float2(0.0);
    
    // 🌫️ 粒子聚集力 - 让粒子形成小团
    float clusterSize = 120.0; // 聚集团的大小
    float2 clusterCenter = getClusterCenter(particle.position, clusterSize);
    float2 toCluster = clusterCenter - particle.position;
    float clusterDistance = length(toCluster);
    
    // 聚集力：距离聚集中心越远，吸引力越强
    if (clusterDistance > 10.0) {
        float2 clusterForce = normalize(toCluster) * min(clusterDistance * 0.02, 2.0);
        acceleration += clusterForce;
    }
    
    // 🌊 相邻粒子相互作用（模拟流体动力学）
    // 注意：这里简化处理，实际应用中可能需要空间分割优化
    float neighborRadius = 25.0;
    float2 separationForce = float2(0.0);
    float2 cohesionForce = float2(0.0);
    int neighborCount = 0;
    
    // 简化的邻居检测（仅检查附近的粒子）
    for (int i = max(0, int(id) - 5); i < min(uniforms.particleCount, int(id) + 5); ++i) {
        if (i == int(id)) continue;
        
        HazeParticle neighbor = particles[i];
        float2 diff = particle.position - neighbor.position;
        float dist = length(diff);
        
        if (dist < neighborRadius && dist > 0.1) {
            neighborCount++;
            
            // 分离力：避免粒子重叠
            if (dist < neighborRadius * 0.5) {
                separationForce += normalize(diff) * (neighborRadius * 0.5 - dist) * 0.1;
            }
            
            // 聚合力：保持适当距离
            cohesionForce += (neighbor.position - particle.position) * 0.005;
        }
    }
    
    if (neighborCount > 0) {
        cohesionForce /= float(neighborCount);
        acceleration += separationForce + cohesionForce;
    }
    
    // 风力影响
    acceleration += uniforms.windDirection * uniforms.windStrength;
    
    // 添加噪声扰动（模拟湍流）- 减少强度以保持聚集效果
    float2 noisePos = particle.position * 0.01 + uniforms.time * 0.1;
    float noiseX = noise(noisePos) - 0.5;
    float noiseY = noise(noisePos + float2(100.0, 0.0)) - 0.5;
    acceleration += float2(noiseX, noiseY) * 0.15; // 从0.3减少到0.15
    
    // 重力效果（轻微下沉）
    acceleration.y -= 0.05; // 从0.1减少到0.05，让雾气更轻盈
    
    // 检查清除区域影响 - 增强驱散效果
    float clearEffect = 0.0;
    float2 totalDispersionForce = float2(0.0);
    
    for (int i = 0; i < uniforms.clearZoneCount; ++i) {
        ClearZone zone = clearZones[i];
        float dist = distance(particle.position, zone.center);
        
        if (dist < zone.radius) {
            // 计算驱散力 - 增强效果
            float2 direction = normalize(particle.position - zone.center);
            float normalizedDist = dist / zone.radius;
            
            // 使用更强的力场函数：平方反比 + 指数衰减
            float forceStrength = zone.strength * (1.0 - normalizedDist * normalizedDist) * exp(-normalizedDist * 2.0);
            
            // 增强驱散加速度（从50.0增加到150.0）
            float horizBoost = 1.0 + 0.25 * saturate(fabs(direction.x));
            float2 dispersionForce = direction * forceStrength * 150.0 * horizBoost;
            totalDispersionForce += dispersionForce;
            
            clearEffect = max(clearEffect, forceStrength);
            
            // 添加旋转效果，让粒子围绕清除中心旋转后被驱散
            float2 tangent = float2(-direction.y, direction.x);
            totalDispersionForce += tangent * forceStrength * 30.0;
        }
    }
    
    // 应用驱散力
    acceleration += totalDispersionForce;
    if (clearEffect > 0.0) {
        acceleration -= uniforms.windDirection * uniforms.windStrength * clearEffect;
        acceleration.y += 0.05 * clearEffect;
    }
    
    // 更新速度和位置
    particle.velocity += acceleration * uniforms.deltaTime;
    
    // 在清除区域内增加额外的阻力，让粒子更快消散
    if (clearEffect > 0.1) {
        particle.velocity *= (0.85 - clearEffect * 0.3); // 更强的阻力
    } else {
        particle.velocity *= 0.98; // 正常阻力
    }
    
    particle.position += particle.velocity * uniforms.deltaTime;
    
    // 更新旋转 - 在清除区域内旋转更快
    float rotationMultiplier = 1.0 + clearEffect * 5.0;
    particle.rotation += particle.rotationSpeed * uniforms.deltaTime * rotationMultiplier;
    
    // 🌫️ 根据聚集密度调整粒子大小和透明度
    float localDensity = getClusterDensity(particle.position, uniforms.time);
    particle.size = mix(8.0, 25.0, localDensity); // 密集区域粒子更大
    
    // 更新生命值 - 在清除区域内生命值消耗更快
    float lifeDrain = uniforms.deltaTime / particle.maxLife;
    if (clearEffect > 0.1) {
        lifeDrain *= (1.0 + clearEffect * 3.0); // 清除区域内生命值消耗加速
    }
    particle.life -= lifeDrain;
    
    // 根据清除效果和密度调整透明度 - 更强的透明度变化
    float baseOpacity = particle.life / particle.maxLife;
    float densityOpacity = mix(0.3, 1.0, localDensity);
    float attenuation = clamp(1.0 - clearEffect * 1.4, 0.0, 1.0);
    particle.opacity = baseOpacity * densityOpacity * attenuation;
    
    // 边界检查和重置
    if (particle.life <= 0.0 || 
        particle.position.x < -100 || particle.position.x > uniforms.resolution.x + 100 ||
        particle.position.y < -100 || particle.position.y > uniforms.resolution.y + 100) {
        
        // 重置粒子
        particle.position = particle.initialPos;
        particle.velocity = float2(0.0);
        particle.life = 1.0;
        particle.opacity = 1.0;
        particle.rotation = 0.0;
        particle.size = 15.0; // 重置大小
        
        // 添加随机偏移
        float2 randomOffset = float2(
            hash(particle.initialPos + uniforms.time) - 0.5,
            hash(particle.initialPos + uniforms.time + 100.0) - 0.5
        ) * 50.0;
        particle.position += randomOffset;
    }
    
    particles[id] = particle;
}

// MARK: - 顶点着色器

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
    float size;
    float rotation;
};

vertex VertexOut hazeParticleVertex(uint vertexID [[vertex_id]],
                                   uint instanceID [[instance_id]],
                                   constant HazeParticle* particles [[buffer(0)]],
                                   constant ParticleUniforms& uniforms [[buffer(1)]]) {
    
    HazeParticle particle = particles[instanceID];
    
    // 四边形顶点 (0,0), (1,0), (0,1), (1,1)
    float2 quadVertices[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    
    float2 localPos = quadVertices[vertexID] - 0.5; // 中心化
    
    // 应用旋转
    float c = cos(particle.rotation);
    float s = sin(particle.rotation);
    float2 rotatedPos = float2(
        localPos.x * c - localPos.y * s,
        localPos.x * s + localPos.y * c
    );
    
    // 缩放
    rotatedPos *= particle.size;
    
    // 世界位置
    float2 worldPos = particle.position + rotatedPos;
    
    // 转换到NDC
    float2 ndc = (worldPos / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y; // 翻转Y轴
    
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = quadVertices[vertexID];
    out.opacity = particle.opacity * uniforms.intensity * uniforms.globalOpacity;
    out.size = particle.size;
    out.rotation = particle.rotation;
    
    return out;
}

// MARK: - 片段着色器

fragment float4 hazeParticleFragment(VertexOut in [[stage_in]],
                                    constant ParticleUniforms& uniforms [[buffer(0)]]) {
    
    // 计算粒子到中心的距离
    float2 center = float2(0.5, 0.5);
    float2 uv = in.texCoord;
    float distanceToCenter = distance(uv, center);
    
    // 🌫️ 创建软边圆形粒子 - 改进的形状
    float radius = 0.45;
    float softness = 0.15;
    float alpha = 1.0 - smoothstep(radius - softness, radius + softness, distanceToCenter);
    
    // 💧 凝露效果 - 根据粒子大小和密度创建水滴效果
    float dewFactor = saturate((in.size - 15.0) / 10.0); // 大粒子更容易形成露水
    
    if (dewFactor > 0.3) {
        // 创建水滴形状
        float2 dewUV = uv - center;
        
        // 水滴的椭圆形状（上圆下尖）
        float dewY = dewUV.y * 1.2; // 拉伸Y轴
        float dewX = dewUV.x;
        
        // 水滴顶部（圆形）
        float topDist = length(float2(dewX, max(0.0, dewY + 0.1)));
        float topAlpha = 1.0 - smoothstep(0.2, 0.35, topDist);
        
        // 水滴底部（尖锐）
        float bottomFactor = saturate(-dewY * 3.0);
        float bottomWidth = 0.15 * (1.0 - bottomFactor);
        float bottomAlpha = 1.0 - smoothstep(0.0, bottomWidth, abs(dewX));
        bottomAlpha *= smoothstep(-0.4, -0.1, dewY);
        
        // 合并水滴形状
        float dewAlpha = max(topAlpha, bottomAlpha);
        
        // 水滴高光效果
        float2 highlightPos = float2(-0.15, 0.15);
        float highlightDist = distance(dewUV, highlightPos);
        float highlight = 1.0 - smoothstep(0.05, 0.15, highlightDist);
        
        // 混合雾气和水滴效果
        alpha = mix(alpha, dewAlpha, dewFactor * 0.7);
        
        // 添加高光
        alpha = saturate(alpha + highlight * dewFactor * 0.3);
    }
    
    // 🌊 添加噪声纹理，创建更自然的雾气效果
    float2 noiseUV = uv * 3.0 + uniforms.time * 0.1;
    float noiseValue = noise(noiseUV);
    
    // 多层噪声，创建复杂的雾气纹理
    float detailNoise = noise(uv * 8.0 + uniforms.time * 0.05) * 0.3;
    float turbulence = noise(uv * 15.0 - uniforms.time * 0.2) * 0.2;
    
    // 组合噪声效果
    float combinedNoise = noiseValue * 0.5 + detailNoise + turbulence;
    alpha *= (0.7 + combinedNoise * 0.3);
    
    // 应用粒子透明度
    alpha *= in.opacity;
    
    // 🎨 雾气颜色 - 根据密度和环境调整
    float3 baseColor = float3(0.9, 0.95, 1.0); // 淡蓝白色
    
    // 根据粒子大小调整颜色（大粒子更白，小粒子更透明）
    float sizeFactor = saturate((in.size - 8.0) / 17.0);
    baseColor = mix(float3(0.7, 0.8, 0.9), float3(1.0, 1.0, 1.0), sizeFactor);
    
    // 💧 凝露颜色效果
    if (dewFactor > 0.3) {
        // 水滴有轻微的蓝色调和更高的反射
        float3 dewColor = float3(0.85, 0.92, 1.0);
        baseColor = mix(baseColor, dewColor, dewFactor * 0.6);
        
        // 增加水滴的亮度
        baseColor *= (1.0 + dewFactor * 0.3);
    }
    
    // 🌈 环境光影响
    float ambientFactor = 0.8 + 0.2 * sin(uniforms.time * 0.5);
    baseColor *= ambientFactor;
    
    // 边缘发光效果
    float edgeGlow = 1.0 - distanceToCenter;
    edgeGlow = pow(edgeGlow, 2.0) * 0.2;
    baseColor += edgeGlow;
    
    // 最终颜色输出
    return float4(baseColor, alpha);
}
