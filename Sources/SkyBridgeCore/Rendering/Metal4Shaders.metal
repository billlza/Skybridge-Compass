#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// MARK: - 常量和结构体定义

struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float time;
};

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float3 normal [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float3 worldNormal;
    float3 worldPosition;
};

struct FragmentOut {
    float4 color [[color(0)]];
    float4 normal [[color(1)]];
    float4 motion [[color(2)]];
};

// MARK: - AI推理相关常量

// constant float AI_INFERENCE_SCALE = 2.0;  // ✅ 已注释：未使用的变量
constant int MLP_HIDDEN_SIZE = 256;
constant int MLP_LAYERS = 4;

// MARK: - 顶点着色器

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                            constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;
    
    // 变换顶点位置
    float4 worldPosition = uniforms.modelMatrix * in.position;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    
    // 传递纹理坐标
    out.texCoord = in.texCoord;
    
    // 变换法线
    float3x3 normalMatrix = float3x3(uniforms.modelMatrix[0].xyz,
                                    uniforms.modelMatrix[1].xyz,
                                    uniforms.modelMatrix[2].xyz);
    out.worldNormal = normalize(normalMatrix * in.normal);
    
    return out;
}

// MARK: - 片段着色器

fragment FragmentOut fragment_main(VertexOut in [[stage_in]],
                                  constant Uniforms& uniforms [[buffer(0)]],
                                  texture2d<float> colorTexture [[texture(0)]],
                                  sampler colorSampler [[sampler(0)]]) {
    FragmentOut out;
    
    // 基础颜色采样
    float4 baseColor = colorTexture.sample(colorSampler, in.texCoord);
    
    // 简单的光照计算
    float3 lightDir = normalize(float3(1.0, 1.0, 1.0));
    float NdotL = max(dot(in.worldNormal, lightDir), 0.0);
    
    // 应用光照
    float3 finalColor = baseColor.rgb * (0.3 + 0.7 * NdotL);
    
    // 输出多个渲染目标
    out.color = float4(finalColor, baseColor.a);
    out.normal = float4(in.worldNormal * 0.5 + 0.5, 1.0);
    out.motion = float4(0.0, 0.0, 0.0, 1.0); // 运动向量，用于时间上采样
    
    return out;
}

// MARK: - 计算着色器

kernel void compute_main(texture2d<float, access::read> inputTexture [[texture(0)]],
                        texture2d<float, access::write> outputTexture [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 简单的后处理效果
    float4 color = inputTexture.read(gid);
    
    // 应用色调映射
    color.rgb = color.rgb / (color.rgb + 1.0);
    
    // 伽马校正
    color.rgb = pow(color.rgb, 1.0/2.2);
    
    outputTexture.write(color, gid);
}

// MARK: - AI推理着色器 - Metal 4.0新特性

// 多层感知机（MLP）激活函数
float relu(float x) {
    return max(0.0, x);
}

float swish(float x) {
    return x / (1.0 + exp(-x));
}

float gelu(float x) {
    return 0.5 * x * (1.0 + tanh(sqrt(2.0 / M_PI_F) * (x + 0.044715 * pow(x, 3.0))));
}

// 神经网络层计算
float4 mlp_layer(float4 input, 
                constant float* weights [[buffer(0)]],
                int layer_index,
                int input_size,
                int output_size) {
    float4 output = float4(0.0);
    
    // 矩阵乘法 - 简化版本
    for (int i = 0; i < min(4, output_size); i++) {
        float sum = 0.0;
        for (int j = 0; j < min(4, input_size); j++) {
            int weight_idx = layer_index * input_size * output_size + i * input_size + j;
            sum += input[j] * weights[weight_idx];
        }
        output[i] = sum;
    }
    
    // 应用激活函数
    output.x = gelu(output.x);
    output.y = gelu(output.y);
    output.z = gelu(output.z);
    output.w = gelu(output.w);
    
    return output;
}

// AI推理主计算着色器
kernel void ai_inference_shader(texture2d<float, access::read> inputTexture [[texture(0)]],
                               texture2d<float, access::write> outputTexture [[texture(1)]],
                               constant float* mlpWeights [[buffer(0)]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 读取输入像素
    float4 inputColor = inputTexture.read(gid);
    
    // 准备神经网络输入
    float2 uv = float2(gid) / float2(inputTexture.get_width(), inputTexture.get_height());
    float4 networkInput = float4(inputColor.rgb, length(uv - 0.5));
    
    // 通过多层感知机
    float4 hidden = networkInput;
    
    // 第一层
    hidden = mlp_layer(hidden, mlpWeights, 0, 4, MLP_HIDDEN_SIZE);
    
    // 中间层
    for (int layer = 1; layer < MLP_LAYERS - 1; layer++) {
        hidden = mlp_layer(hidden, mlpWeights, layer, MLP_HIDDEN_SIZE, MLP_HIDDEN_SIZE);
    }
    
    // 输出层
    float4 output = mlp_layer(hidden, mlpWeights, MLP_LAYERS - 1, MLP_HIDDEN_SIZE, 4);
    
    // 应用残差连接
    output.rgb = inputColor.rgb + output.rgb * 0.1;
    output.a = inputColor.a;
    
    // 确保输出在有效范围内
    output = clamp(output, 0.0, 1.0);
    
    outputTexture.write(output, gid);
}

// MARK: - 神经网络上采样着色器

kernel void neural_upscale_compute(texture2d<float, access::read> inputTexture [[texture(0)]],
                                  texture2d<float, access::write> outputTexture [[texture(1)]],
                                  constant float* upscaleWeights [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 计算输入纹理坐标
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 scale = inputSize / outputSize;
    
    float2 inputCoord = (float2(gid) + 0.5) * scale - 0.5;
    
    // 双线性插值采样
    int2 coord0 = int2(floor(inputCoord));
    int2 coord1 = coord0 + int2(1, 1);
    
    float2 frac = inputCoord - float2(coord0);
    
    // 边界检查
    coord0 = clamp(coord0, int2(0), int2(inputSize) - 1);
    coord1 = clamp(coord1, int2(0), int2(inputSize) - 1);
    
    // 采样四个邻近像素
    float4 c00 = inputTexture.read(uint2(coord0.x, coord0.y));
    float4 c10 = inputTexture.read(uint2(coord1.x, coord0.y));
    float4 c01 = inputTexture.read(uint2(coord0.x, coord1.y));
    float4 c11 = inputTexture.read(uint2(coord1.x, coord1.y));
    
    // 双线性插值
    float4 c0 = mix(c00, c10, frac.x);
    float4 c1 = mix(c01, c11, frac.x);
    float4 baseColor = mix(c0, c1, frac.y);
    
    // 神经网络增强
    float4 features = float4(baseColor.rgb, length(frac));
    
    // 简化的神经网络处理
    float4 enhanced = baseColor;
    enhanced.rgb += sin(features.rgb * 3.14159) * 0.05; // 简单的频率增强
    enhanced.rgb = clamp(enhanced.rgb, 0.0, 1.0);
    
    outputTexture.write(enhanced, gid);
}

// MARK: - 帧插值计算着色器 - Metal 4.0新特性

kernel void frame_interpolation_compute(texture2d<float, access::read> frame0 [[texture(0)]],
                                       texture2d<float, access::read> frame1 [[texture(1)]],
                                       texture2d<float, access::read> motionVectors [[texture(2)]],
                                       texture2d<float, access::write> interpolatedFrame [[texture(3)]],
                                       constant float& interpolationFactor [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= interpolatedFrame.get_width() || gid.y >= interpolatedFrame.get_height()) {
        return;
    }
    
    // 读取运动向量
    float2 motion = motionVectors.read(gid).xy;
    
    // 计算反向运动向量
    float2 backwardMotion = motion * interpolationFactor;
    float2 forwardMotion = motion * (interpolationFactor - 1.0);
    
    // 计算采样坐标
    int2 coord0 = int2(float2(gid) + backwardMotion);
    int2 coord1 = int2(float2(gid) + forwardMotion);
    
    // 边界检查
    coord0 = clamp(coord0, int2(0), int2(frame0.get_width() - 1, frame0.get_height() - 1));
    coord1 = clamp(coord1, int2(0), int2(frame1.get_width() - 1, frame1.get_height() - 1));
    
    // 采样两帧
    float4 color0 = frame0.read(uint2(coord0));
    float4 color1 = frame1.read(uint2(coord1));
    
    // 线性插值
    float4 interpolated = mix(color0, color1, interpolationFactor);
    
    // 运动补偿质量评估
    float motionMagnitude = length(motion);
    float confidence = 1.0 - clamp(motionMagnitude * 0.1, 0.0, 1.0);
    
    // 如果运动过大，回退到简单混合
    if (confidence < 0.5) {
        interpolated = mix(color0, color1, interpolationFactor);
    }
    
    interpolatedFrame.write(interpolated, gid);
}

// MARK: - 光线追踪着色器 - Metal 4.0增强

struct Ray {
    float3 origin;
    float3 direction;
};

struct Sphere {
    float3 center;
    float radius;
    float3 color;
};

// 球体相交测试
float intersectSphere(Ray ray, Sphere sphere) {
    float3 oc = ray.origin - sphere.center;
    float a = dot(ray.direction, ray.direction);
    float b = 2.0 * dot(oc, ray.direction);
    float c = dot(oc, oc) - sphere.radius * sphere.radius;
    float discriminant = b * b - 4 * a * c;
    
    if (discriminant < 0) {
        return -1.0;
    }
    
    return (-b - sqrt(discriminant)) / (2.0 * a);
}

// 简单的光线追踪计算着色器
kernel void raytracing_compute(texture2d<float, access::write> outputTexture [[texture(0)]],
                              constant Uniforms& uniforms [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 计算射线方向
    float2 uv = (float2(gid) / float2(outputTexture.get_width(), outputTexture.get_height())) * 2.0 - 1.0;
    uv.y = -uv.y; // 翻转Y轴
    
    Ray ray;
    ray.origin = float3(0.0, 0.0, 0.0);
    ray.direction = normalize(float3(uv, -1.0));
    
    // 定义场景中的球体
    Sphere sphere;
    sphere.center = float3(0.0, 0.0, -3.0);
    sphere.radius = 1.0;
    sphere.color = float3(1.0, 0.5, 0.2);
    
    // 相交测试
    float t = intersectSphere(ray, sphere);
    
    float3 color = float3(0.1, 0.1, 0.2); // 背景色
    
    if (t > 0.0) {
        // 计算交点和法线
        float3 hitPoint = ray.origin + t * ray.direction;
        float3 normal = normalize(hitPoint - sphere.center);
        
        // 简单的光照
        float3 lightDir = normalize(float3(1.0, 1.0, 1.0));
        float NdotL = max(dot(normal, lightDir), 0.0);
        
        color = sphere.color * (0.3 + 0.7 * NdotL);
    }
    
    outputTexture.write(float4(color, 1.0), gid);
}

// MARK: - 去噪着色器 - Metal 4.0新特性

// 双边滤波去噪
kernel void denoise_bilateral(texture2d<float, access::read> noisyTexture [[texture(0)]],
                             texture2d<float, access::read> normalTexture [[texture(1)]],
                             texture2d<float, access::write> denoisedTexture [[texture(2)]],
                             constant float& spatialSigma [[buffer(0)]],
                             constant float& colorSigma [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= denoisedTexture.get_width() || gid.y >= denoisedTexture.get_height()) {
        return;
    }
    
    float4 centerColor = noisyTexture.read(gid);
    float3 centerNormal = normalTexture.read(gid).xyz;
    
    float4 sum = float4(0.0);
    float weightSum = 0.0;
    
    int radius = 3;
    
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 sampleCoord = int2(gid) + int2(dx, dy);
            
            // 边界检查
            if (sampleCoord.x < 0 || sampleCoord.x >= int(noisyTexture.get_width()) ||
                sampleCoord.y < 0 || sampleCoord.y >= int(noisyTexture.get_height())) {
                continue;
            }
            
            float4 sampleColor = noisyTexture.read(uint2(sampleCoord));
            float3 sampleNormal = normalTexture.read(uint2(sampleCoord)).xyz;
            
            // 空间权重
            float spatialDist = length(float2(dx, dy));
            float spatialWeight = exp(-spatialDist * spatialDist / (2.0 * spatialSigma * spatialSigma));
            
            // 颜色权重
            float colorDist = length(sampleColor.rgb - centerColor.rgb);
            float colorWeight = exp(-colorDist * colorDist / (2.0 * colorSigma * colorSigma));
            
            // 法线权重
            float normalWeight = max(0.0, dot(centerNormal, sampleNormal));
            normalWeight = pow(normalWeight, 4.0);
            
            float totalWeight = spatialWeight * colorWeight * normalWeight;
            
            sum += sampleColor * totalWeight;
            weightSum += totalWeight;
        }
    }
    
    float4 result = weightSum > 0.0 ? sum / weightSum : centerColor;
    denoisedTexture.write(result, gid);
}

// MARK: - 时间抗锯齿着色器

kernel void temporal_antialiasing(texture2d<float, access::read> currentFrame [[texture(0)]],
                                 texture2d<float, access::read> previousFrame [[texture(1)]],
                                 texture2d<float, access::read> motionVectors [[texture(2)]],
                                 texture2d<float, access::write> outputFrame [[texture(3)]],
                                 constant float& blendFactor [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }
    
    float4 currentColor = currentFrame.read(gid);
    float2 motion = motionVectors.read(gid).xy;
    
    // 计算前一帧的采样坐标
    float2 prevCoord = float2(gid) + motion;
    
    // 边界检查
    if (prevCoord.x < 0 || prevCoord.x >= previousFrame.get_width() ||
        prevCoord.y < 0 || prevCoord.y >= previousFrame.get_height()) {
        outputFrame.write(currentColor, gid);
        return;
    }
    
    // 双线性插值采样前一帧
    int2 coord0 = int2(floor(prevCoord));
    int2 coord1 = coord0 + int2(1, 1);
    float2 frac = prevCoord - float2(coord0);
    
    coord0 = clamp(coord0, int2(0), int2(previousFrame.get_width() - 1, previousFrame.get_height() - 1));
    coord1 = clamp(coord1, int2(0), int2(previousFrame.get_width() - 1, previousFrame.get_height() - 1));
    
    float4 c00 = previousFrame.read(uint2(coord0.x, coord0.y));
    float4 c10 = previousFrame.read(uint2(coord1.x, coord0.y));
    float4 c01 = previousFrame.read(uint2(coord0.x, coord1.y));
    float4 c11 = previousFrame.read(uint2(coord1.x, coord1.y));
    
    float4 c0 = mix(c00, c10, frac.x);
    float4 c1 = mix(c01, c11, frac.x);
    float4 previousColor = mix(c0, c1, frac.y);
    
    // 时间混合
    float4 result = mix(previousColor, currentColor, blendFactor);
    
    outputFrame.write(result, gid);
}

// MARK: - 屏幕空间反射着色器

kernel void screen_space_reflections(texture2d<float, access::read> colorTexture [[texture(0)]],
                                    texture2d<float, access::read> normalTexture [[texture(1)]],
                                    texture2d<float, access::read> depthTexture [[texture(2)]],
                                    texture2d<float, access::write> reflectionTexture [[texture(3)]],
                                    constant Uniforms& uniforms [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= reflectionTexture.get_width() || gid.y >= reflectionTexture.get_height()) {
        return;
    }
    
    float2 uv = float2(gid) / float2(reflectionTexture.get_width(), reflectionTexture.get_height());
    
    // 读取G-Buffer数据
    float4 baseColor = colorTexture.read(gid);
    float3 normal = normalize(normalTexture.read(gid).xyz * 2.0 - 1.0);
    float depth = depthTexture.read(gid).r;
    
    // 重建世界空间位置
    float4 clipPos = float4(uv * 2.0 - 1.0, depth, 1.0);
    float4 worldPos = uniforms.viewMatrix * clipPos;
    worldPos /= worldPos.w;
    
    // 计算反射方向
    float3 viewDir = normalize(worldPos.xyz);
    float3 reflectDir = reflect(viewDir, normal);
    
    // 屏幕空间光线步进
    float3 rayStart = worldPos.xyz;
    float3 rayDir = reflectDir;
    
    float4 reflectionColor = float4(0.0);
    float reflectionStrength = 0.0;
    
    // 简化的光线步进
    for (int i = 0; i < 16; i++) {
        float3 rayPos = rayStart + rayDir * (float(i) * 0.1);
        
        // 投影到屏幕空间
        float4 screenPos = uniforms.projectionMatrix * uniforms.viewMatrix * float4(rayPos, 1.0);
        screenPos /= screenPos.w;
        
        float2 screenUV = screenPos.xy * 0.5 + 0.5;
        
        // 边界检查
        if (screenUV.x < 0.0 || screenUV.x > 1.0 || screenUV.y < 0.0 || screenUV.y > 1.0) {
            break;
        }
        
        // 采样深度
        uint2 sampleCoord = uint2(screenUV * float2(depthTexture.get_width(), depthTexture.get_height()));
        float sampleDepth = depthTexture.read(sampleCoord).r;
        
        // 深度测试
        if (screenPos.z > sampleDepth) {
            reflectionColor = colorTexture.read(sampleCoord);
            reflectionStrength = 1.0 - float(i) / 16.0;
            break;
        }
    }
    
    // 混合反射
    float4 result = baseColor;
    if (reflectionStrength > 0.0) {
        float fresnel = pow(1.0 - max(0.0, dot(-viewDir, normal)), 2.0);
        result.rgb = mix(result.rgb, reflectionColor.rgb, fresnel * reflectionStrength * 0.3);
    }
    
    reflectionTexture.write(result, gid);
}