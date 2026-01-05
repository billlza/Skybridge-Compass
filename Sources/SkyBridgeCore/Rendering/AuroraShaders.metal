#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float  time;
    float  renderScale;
    int    qualityLevel;
    int    shadowLevel;
    int    postFX;
    float  gpuHint;
    float  wind;
    float  humidity;
    int    condition;
};

vertex float4 auroraVertex(uint vid [[vertex_id]]) {
    float2 pos;
    if (vid == 0) pos = float2(-1.0, -1.0);
    else if (vid == 1) pos = float2( 3.0, -1.0);
    else pos = float2(-1.0,  3.0);
    return float4(pos, 0.0, 1.0);
}

static inline float hash21(float2 p){ p=fract(p*float2(443.8975,397.2973)); p+=dot(p.xy,p.yx+19.19); return fract(p.x*p.y*(p.x+p.y)); }
static inline float smoothNoise(float2 p){ float2 i=floor(p), f=fract(p); float a=hash21(i), b=hash21(i+float2(1,0)), c=hash21(i+float2(0,1)), d=hash21(i+float2(1,1)); float2 u=f*f*f*(f*(f*(f*(-20.0*f+70.0)-84.0)+35.0)); return mix(mix(a,b,u.x),mix(c,d,u.x),u.y); }
static inline float fbm(float2 p,int oct){ float v=0.0,a=0.5,f=1.0; for(int i=0;i<oct;i++){ v+=a*smoothNoise(p*f); f*=2.02; a*=0.48; } return v; }

fragment float4 auroraFragment(float4 pos [[position]], constant Uniforms& u [[buffer(0)]]){
    float2 uv = pos.xy / u.resolution;
    float2 center = float2(0.5,0.5);
    float t = u.time * (0.6 + 0.6 * u.gpuHint);

    // 丝带密度（三层）
    float d1 = fbm(uv*4.0 + float2(t*0.08, t*0.06), 4 + u.qualityLevel);
    float d2 = fbm(uv*6.0 + float2(-t*0.07, t*0.05), 5 + u.qualityLevel);
    float d3 = fbm(uv*8.0 + float2(t*0.04, -t*0.06), 6 + u.qualityLevel);
    float density = 0.45*d1 + 0.35*d2 + 0.25*d3;

    // 天气联动：湿度增大→更柔和；风更强→更快流动
    float soft = clamp(u.humidity/100.0, 0.2, 0.8);
    density = pow(density, 1.0 - 0.35*soft);

    // 色彩（三色插值：冰蓝/青/薄紫）
    float3 c1 = float3(0.42, 0.82, 1.00);
    float3 c2 = float3(0.31, 0.82, 0.77);
    float3 c3 = float3(0.66, 0.55, 0.98);
    float3 col = mix(mix(c1,c2,density), c3, 0.35 + 0.35*density);

    // 体积光（shadowLevel控制强度与层数）
    float rays = 0.0;
    if (u.shadowLevel > 0){
        float2 p = uv - float2(0.8,0.2);
        float r = 1.0 - clamp(length(p), 0.0, 1.0);
        rays = r * (u.shadowLevel==2 ? 0.35 : 0.22);
    }

    // 后处理（轻颗粒/晕影）
    float vignette = smoothstep(0.0, 0.9, (1.0 - length(uv - center))*1.05);
    float grain = (u.postFX > 0) ? (smoothNoise(uv*12.0 + t*0.4) - 0.5) * 0.02 : 0.0;

    // 最终合成
    float a = clamp(density + rays, 0.0, 1.0);
    col = col * (0.85 + 0.15 * a);
    col += grain;
    col *= vignette;
    return float4(col, a);
}
