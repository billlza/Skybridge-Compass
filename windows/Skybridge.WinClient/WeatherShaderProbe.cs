using ComputeSharp;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherShaderProbe — a minimal animated GPU compute shader used purely to confirm that
//  the ComputeSharp.WinUI 3.2.0 DX12 pipeline compiles, dispatches and animates on this
//  machine. It paints a slow night-sky vertical gradient with a faint time-based shimmer.
//
//  v3.2.0 API NOTE (build-correctness): a shader driven by AnimatedComputeShaderPanel via
//  ShaderRunner<T> MUST implement IComputeShader<float4> — i.e. the *pixel-shader-style*
//  interface whose Execute() RETURNS the pixel value. The panel/runner owns the target
//  texture and writes the returned float4 into texture[ThreadIds.XY] for us (the runner
//  calls GraphicsDevice.ForEach(texture, shader) internally). The shader itself therefore
//  has NO IReadWriteNormalizedTexture2D<float4> constructor parameter and CANNOT write
//  `texture[ThreadIds.XY] = ...` directly — the only ctor param is the `float time` uniform.
//  (The texture-write form belongs to the non-generic `IComputeShader` + `For<T>` API,
//  which AnimatedComputeShaderPanel/ShaderRunner<T> do not use.) Confirmed against:
//    - src/ComputeSharp.UI/ShaderRunner{T}.cs  (constraint: T : IComputeShader<Float4>, IComputeShaderDescriptor<T>)
//    - src/ComputeSharp/Interfaces/IComputeShader{TPixel}.cs  (TPixel Execute();)
//    - samples/.../HelloWorld.cs + MainViewModel.cs  (new ShaderRunner<T>(static time => new((float)time.TotalSeconds)))
// =====================================================================================

/// <summary>
/// Minimal animated night-sky probe shader.
/// </summary>
/// <param name="time">Elapsed time, in seconds, since the panel started rendering.</param>
[ThreadGroupSize(DefaultThreadGroupSizes.XY)]
[GeneratedComputeShaderDescriptor]
internal readonly partial struct WeatherShaderProbe(float time) : IComputeShader<float4>
{
    /// <inheritdoc/>
    public float4 Execute()
    {
        // Normalized 0..1 screen-space UV for the current pixel. .Y == 0 at the top.
        float2 uv = ThreadIds.Normalized.XY;

        // Vertical night-sky gradient: dark blue at the top, slightly brighter/warmer at the bottom.
        float3 top = new(0.02f, 0.05f, 0.12f);
        float3 bottom = new(0.06f, 0.10f, 0.20f);
        float3 col = Hlsl.Lerp(top, bottom, uv.Y);

        // Faint, slow time-based shimmer so we can visually confirm the shader animates.
        // Two desynced sine bands drifting at different rates keep the motion organic.
        float shimmer =
            (Hlsl.Sin((uv.Y * 6.0f) + (time * 0.40f)) * 0.5f) +
            (Hlsl.Sin((uv.X * 4.0f) - (time * 0.25f)) * 0.5f);

        col += 0.015f * shimmer;

        // Clamp to keep the result in a valid color range before presenting.
        col = Hlsl.Saturate(col);

        return new float4(col, 1f);
    }
}
