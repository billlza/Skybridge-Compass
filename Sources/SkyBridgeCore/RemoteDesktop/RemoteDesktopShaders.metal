#include <metal_stdlib>
using namespace metal;

/// 帧缩放计算着色器
kernel void scaleFrame(texture2d<float, access::read> inputTexture [[texture(0)]],
                      texture2d<float, access::write> outputTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    
    // 检查边界
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 计算输入纹理的采样坐标
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    
    float2 scale = inputSize / outputSize;
    float2 coord = (float2(gid) + 0.5) * scale;
    
    // 使用read方法读取纹理像素，然后进行双线性插值
    uint2 inputCoord = uint2(coord);
    float4 color = inputTexture.read(inputCoord);
    
    // 写入输出纹理
    outputTexture.write(color, gid);
}

/// 颜色空间转换着色器
kernel void convertColorSpace(texture2d<float, access::read> inputTexture [[texture(0)]],
                             texture2d<float, access::write> outputTexture [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float4 color = inputTexture.read(gid);
    
    // RGB to YUV 转换矩阵
    float3x3 rgbToYuv = float3x3(
        float3(0.299, 0.587, 0.114),
        float3(-0.169, -0.331, 0.5),
        float3(0.5, -0.419, -0.081)
    );
    
    float3 yuv = rgbToYuv * color.rgb;
    yuv.yz += 0.5; // 偏移UV分量
    
    outputTexture.write(float4(yuv, color.a), gid);
}

/// 图像锐化着色器
kernel void sharpenImage(texture2d<float, access::read> inputTexture [[texture(0)]],
                        texture2d<float, access::write> outputTexture [[texture(1)]],
                        constant float &sharpness [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // 锐化卷积核
    float4 center = inputTexture.read(gid);
    float4 top = inputTexture.read(uint2(gid.x, max(0u, gid.y - 1)));
    float4 bottom = inputTexture.read(uint2(gid.x, min(inputTexture.get_height() - 1, gid.y + 1)));
    float4 left = inputTexture.read(uint2(max(0u, gid.x - 1), gid.y));
    float4 right = inputTexture.read(uint2(min(inputTexture.get_width() - 1, gid.x + 1), gid.y));
    
    float4 sharpened = center * (1.0 + 4.0 * sharpness) - (top + bottom + left + right) * sharpness;
    
    outputTexture.write(clamp(sharpened, 0.0, 1.0), gid);
}