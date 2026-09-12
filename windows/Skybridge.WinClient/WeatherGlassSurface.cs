using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient;

/// <summary>Connects a real panel's geometry to its window's weather renderer.</summary>
public static class WeatherGlassSurface
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(WeatherGlassSurface), new PropertyMetadata(false, OnEnabledChanged));
    private static readonly DependencyProperty RendererProperty = DependencyProperty.RegisterAttached(
        "Renderer", typeof(WeatherBackdropDX), typeof(WeatherGlassSurface), new PropertyMetadata(null));
    private static readonly DependencyProperty RegistrationProperty = DependencyProperty.RegisterAttached(
        "Registration", typeof(WeatherBackdropDX), typeof(WeatherGlassSurface), new PropertyMetadata(null));

    public static bool GetIsEnabled(DependencyObject target) => (bool)target.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject target, bool value) => target.SetValue(IsEnabledProperty, value);
    internal static void SetRenderer(DependencyObject root, WeatherBackdropDX renderer) => root.SetValue(RendererProperty, renderer);

    private static void OnEnabledChanged(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        if (target is not Border border) throw new System.InvalidOperationException("Weather glass surfaces must be Borders.");
        if ((bool)args.NewValue)
        {
            border.Loaded += OnLoaded;
            border.Unloaded += OnUnloaded;
            if (border.IsLoaded) Attach(border);
        }
        else
        {
            border.Loaded -= OnLoaded;
            border.Unloaded -= OnUnloaded;
            Detach(border);
        }
    }

    private static void OnLoaded(object sender, RoutedEventArgs args) => Attach((Border)sender);
    private static void OnUnloaded(object sender, RoutedEventArgs args) => Detach((Border)sender);

    private static void Attach(Border border)
    {
        Detach(border);
        for (DependencyObject? node = border; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node.GetValue(RendererProperty) is WeatherBackdropDX renderer)
            {
                border.SetValue(RegistrationProperty, renderer);
                renderer.RegisterGlassSurface(border);
                return;
            }
        }
    }

    private static void Detach(Border border)
    {
        if (border.GetValue(RegistrationProperty) is WeatherBackdropDX renderer)
        {
            renderer.UnregisterGlassSurface(border);
            border.ClearValue(RegistrationProperty);
        }
    }
}
