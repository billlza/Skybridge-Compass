using System;
using ComputeSharp.WinUI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdropCS — a ComputeSharp.WinUI (DX12 compute-shader) variant of the weather
//  backdrop, used as a build-correctness + visual probe for ComputeSharp.WinUI 3.2.0.
//
//  It hosts a single AnimatedComputeShaderPanel and drives it with WeatherShaderProbe (a
//  slowly animated night-sky gradient) so we can confirm the GPU shader pipeline compiles,
//  dispatches and animates on the target machine.
//
//  It deliberately exposes a `Condition` DependencyProperty that is IDENTICAL in name, type
//  and default to WeatherBackdrop.Condition, so MainWindow's existing
//  `Condition="{Binding WeatherConditionKey}"` binding works unchanged if this control is
//  swapped in. The probe ignores the condition for now (the shimmer animates regardless).
// =====================================================================================
public sealed partial class WeatherBackdropCS : UserControl
{
    public WeatherBackdropCS()
    {
        InitializeComponent();

        // v3.2.0 ShaderRunner<T> factory: the public ctor takes Func<TimeSpan, T> and the
        // runner calls GraphicsDevice.ForEach(texture, factory(time)) each frame, writing the
        // float4 returned by WeatherShaderProbe.Execute() into the panel-owned texture.
        // Canonical form (samples/.../MainViewModel.cs):
        //   new ShaderRunner<HelloWorld>(static time => new((float)time.TotalSeconds))
        Panel.ShaderRunner = new ShaderRunner<WeatherShaderProbe>(
            static time => new WeatherShaderProbe((float)time.TotalSeconds));
    }

    // Live weather condition key. Mirrors WeatherBackdrop.Condition exactly (name/type/default)
    // so the existing MainWindow binding `Condition="{Binding WeatherConditionKey}"` is unchanged.
    public static readonly DependencyProperty ConditionProperty =
        DependencyProperty.Register(
            nameof(Condition),
            typeof(string),
            typeof(WeatherBackdropCS),
            new PropertyMetadata("Clear"));

    public string Condition
    {
        get => (string)GetValue(ConditionProperty);
        set => SetValue(ConditionProperty, value);
    }
}
