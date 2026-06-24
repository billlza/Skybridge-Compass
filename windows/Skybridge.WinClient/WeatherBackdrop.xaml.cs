using System;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Windows.UI;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdrop — lightweight GPU particle layer (twinkling stars + falling rain
//  streaks) on the Composition API, the WinUI equivalent of the Mac dashboard's Metal
//  weather background (RealisticRainView / CinematicRainSystem). Runs off the UI thread
//  (Composition animations are GPU/independent), so density does not stall layout.
//
//  Particle counts scale with the live size; everything is re-laid out on SizeChanged.
//  Stars always render (night-sky atmosphere reads fine under any condition); rain can be
//  toggled via RainEnabled (default on) so a future binding to the live WeatherConditionKey
//  can suppress it under clear skies — wired after a live visual pass (tunnel-gated).
//
//  NOTE: authored while the box SSH tunnel was down, so this has NOT yet been compiled or
//  visually tuned on the device. Verify build + tune particle counts / speed / opacity /
//  colours against the Mac once the tunnel is back.
// =====================================================================================
public sealed partial class WeatherBackdrop : UserControl
{
    private readonly Random _rng = new();
    private Compositor? _compositor;
    private ContainerVisual? _root;

    public WeatherBackdrop()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        SizeChanged += OnSizeChanged;
    }

    public static readonly DependencyProperty RainEnabledProperty =
        DependencyProperty.Register(
            nameof(RainEnabled),
            typeof(bool),
            typeof(WeatherBackdrop),
            new PropertyMetadata(true, OnRainEnabledChanged));

    // When false, only the star field is drawn (clear-sky look). Default true.
    public bool RainEnabled
    {
        get => (bool)GetValue(RainEnabledProperty);
        set => SetValue(RainEnabledProperty, value);
    }

    private static void OnRainEnabledChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is WeatherBackdrop backdrop)
        {
            backdrop.Rebuild();
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _compositor = ElementCompositionPreview.GetElementVisual(HostGrid).Compositor;
        _root = _compositor.CreateContainerVisual();
        ElementCompositionPreview.SetElementChildVisual(HostGrid, _root);
        Rebuild();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_root is not null)
        {
            _root.Children.RemoveAll();
            ElementCompositionPreview.SetElementChildVisual(HostGrid, null);
            _root.Dispose();
            _root = null;
        }
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e) => Rebuild();

    private void Rebuild()
    {
        if (_compositor is null || _root is null)
        {
            return;
        }

        var w = (float)HostGrid.ActualWidth;
        var h = (float)HostGrid.ActualHeight;
        if (w < 1f || h < 1f)
        {
            return;
        }

        _root.Children.RemoveAll();
        _root.Size = new Vector2(w, h);
        _root.Clip = _compositor.CreateInsetClip();

        BuildStars(w, h);
        if (RainEnabled)
        {
            BuildRain(w, h);
        }
    }

    // Faint white star field, each star slowly twinkling on its own phase.
    private void BuildStars(float w, float h)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 255, 255, 255));
        var count = Math.Clamp((int)(w * h / 14000f), 18, 60);

        for (var i = 0; i < count; i++)
        {
            var size = 1f + (float)_rng.NextDouble() * 1.6f;
            var star = _compositor.CreateSpriteVisual();
            star.Brush = brush;
            star.Size = new Vector2(size, size);
            star.Offset = new Vector3((float)_rng.NextDouble() * w, (float)_rng.NextDouble() * h, 0f);
            star.Opacity = 0.15f + (float)_rng.NextDouble() * 0.25f;
            _root!.Children.InsertAtTop(star);

            var twinkle = _compositor.CreateScalarKeyFrameAnimation();
            twinkle.InsertKeyFrame(0f, 0.12f);
            twinkle.InsertKeyFrame(0.5f, 0.55f);
            twinkle.InsertKeyFrame(1f, 0.12f);
            twinkle.Duration = TimeSpan.FromSeconds(2.5 + _rng.NextDouble() * 3.5);
            twinkle.IterationBehavior = AnimationIterationBehavior.Forever;
            twinkle.DelayTime = TimeSpan.FromSeconds(_rng.NextDouble() * 4.0);
            star.StartAnimation("Opacity", twinkle);
        }
    }

    // Cool blue-white rain streaks falling top→bottom, desynced via per-drop delay.
    private void BuildRain(float w, float h)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 190, 210, 245));
        var count = Math.Clamp((int)(w / 14f), 24, 90);

        for (var i = 0; i < count; i++)
        {
            var length = 10f + (float)_rng.NextDouble() * 12f;
            var x = (float)_rng.NextDouble() * w;
            var drop = _compositor.CreateSpriteVisual();
            drop.Brush = brush;
            drop.Size = new Vector2(1.3f, length);
            drop.Offset = new Vector3(x, (float)_rng.NextDouble() * h, 0f);
            drop.Opacity = 0.18f + (float)_rng.NextDouble() * 0.22f;
            _root!.Children.InsertAtTop(drop);

            var fall = _compositor.CreateVector3KeyFrameAnimation();
            fall.InsertKeyFrame(0f, new Vector3(x, -length - 20f, 0f));
            fall.InsertKeyFrame(1f, new Vector3(x, h + 20f, 0f));
            fall.Duration = TimeSpan.FromSeconds(0.8 + _rng.NextDouble() * 0.9);
            fall.IterationBehavior = AnimationIterationBehavior.Forever;
            fall.DelayTime = TimeSpan.FromSeconds(_rng.NextDouble() * 2.2);
            drop.StartAnimation("Offset", fall);
        }
    }
}
