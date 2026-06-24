using System;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Windows.UI;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdrop — GPU particle layer (Composition API) that maps the live weather
//  condition to a full-screen effect, the WinUI counterpart of the Mac WeatherEffectView
//  (clear/cloudy/rainy/snowy/foggy → CinematicClearSky/Cloudy/Rain/Snow/Fog). A faint star
//  field always renders underneath; the per-condition layer (rain / snow / drifting clouds /
//  fog band) is swapped on top when Condition changes.
//
//  Honesty: the Mac effects are Metal GPU shaders (volumetric clouds, cinematic shading —
//  AAA). This is the Composition "神似" equivalent — same condition→effect structure, GPU
//  animated, but not a pixel-for-pixel shader port. Star/rain/snow are sprite fields; clouds
//  are soft capsules; fog is a pulsing band. Tune densities/speeds/opacity on device.
//
//  NOTE: authored with the box SSH tunnel down — NOT yet compiled or visually tuned. Verify
//  the Composition API builds and tune every effect against the Mac once the tunnel is back.
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

    // Live weather condition key (WeatherConditionKey: Clear/Cloudy/Rainy/Snowy/Foggy/Haze/
    // Stormy/Unknown). Drives which effect layer renders over the star field.
    public static readonly DependencyProperty ConditionProperty =
        DependencyProperty.Register(
            nameof(Condition),
            typeof(string),
            typeof(WeatherBackdrop),
            new PropertyMetadata("Clear", OnConditionChanged));

    public string Condition
    {
        get => (string)GetValue(ConditionProperty);
        set => SetValue(ConditionProperty, value);
    }

    private static void OnConditionChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
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

        // Star field is the shared night-sky base under every condition.
        BuildStars(w, h);

        switch (Condition)
        {
            case "Rainy":
                BuildRain(w, h, density: 1.0f);
                break;
            case "Stormy":
                BuildRain(w, h, density: 1.5f);
                break;
            case "Snowy":
                BuildSnow(w, h);
                break;
            case "Cloudy":
                BuildClouds(w, h);
                break;
            case "Foggy":
            case "Haze":
                BuildFog(w, h);
                break;
            default:
                // Clear / Unknown — stars only (matches the Mac clear-sky, no precipitation).
                break;
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

    // Cool blue-white rain streaks falling top→bottom, desynced via per-drop delay. Density
    // scales the count (1.0 = rain, 1.5 = storm).
    private void BuildRain(float w, float h, float density)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 190, 210, 245));
        var count = Math.Clamp((int)(w / 14f * density), 24, 130);

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
            fall.Duration = TimeSpan.FromSeconds((0.8 + _rng.NextDouble() * 0.9) / density);
            fall.IterationBehavior = AnimationIterationBehavior.Forever;
            fall.DelayTime = TimeSpan.FromSeconds(_rng.NextDouble() * 2.2);
            drop.StartAnimation("Offset", fall);
        }
    }

    // Soft snowflakes drifting down slowly, with a gentle horizontal sway via a second
    // looping X animation offset from the fall.
    private void BuildSnow(float w, float h)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 245, 248, 255));
        var count = Math.Clamp((int)(w / 18f), 20, 80);

        for (var i = 0; i < count; i++)
        {
            var size = 2f + (float)_rng.NextDouble() * 2.5f;
            var x = (float)_rng.NextDouble() * w;
            var flake = _compositor.CreateSpriteVisual();
            flake.Brush = brush;
            flake.Size = new Vector2(size, size);
            flake.Offset = new Vector3(x, (float)_rng.NextDouble() * h, 0f);
            flake.Opacity = 0.35f + (float)_rng.NextDouble() * 0.4f;
            _root!.Children.InsertAtTop(flake);

            var fall = _compositor.CreateVector3KeyFrameAnimation();
            var swayLeft = x - (6f + (float)_rng.NextDouble() * 10f);
            var swayRight = x + (6f + (float)_rng.NextDouble() * 10f);
            fall.InsertKeyFrame(0f, new Vector3(x, -size - 10f, 0f));
            fall.InsertKeyFrame(0.5f, new Vector3(swayRight, h * 0.5f, 0f));
            fall.InsertKeyFrame(1f, new Vector3(swayLeft, h + 10f, 0f));
            fall.Duration = TimeSpan.FromSeconds(6.0 + _rng.NextDouble() * 5.0);
            fall.IterationBehavior = AnimationIterationBehavior.Forever;
            fall.DelayTime = TimeSpan.FromSeconds(_rng.NextDouble() * 6.0);
            flake.StartAnimation("Offset", fall);
        }
    }

    // Slow drifting cloud puffs — soft low-opacity capsules crossing horizontally. Rendered as
    // rounded-rectangle shapes so they read as soft blobs, not hard boxes.
    private void BuildClouds(float w, float h)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 150, 160, 195));
        var count = Math.Clamp((int)(w / 220f), 3, 6);

        for (var i = 0; i < count; i++)
        {
            var cw = 140f + (float)_rng.NextDouble() * 160f;
            var ch = 40f + (float)_rng.NextDouble() * 30f;
            var y = (float)_rng.NextDouble() * (h * 0.55f);

            var geometry = _compositor.CreateRoundedRectangleGeometry();
            geometry.Size = new Vector2(cw, ch);
            geometry.CornerRadius = new Vector2(ch / 2f, ch / 2f);
            var shape = _compositor.CreateSpriteShape(geometry);
            shape.FillBrush = brush;
            var cloud = _compositor.CreateShapeVisual();
            cloud.Size = new Vector2(cw, ch);
            cloud.Shapes.Add(shape);
            cloud.Opacity = 0.10f + (float)_rng.NextDouble() * 0.10f;
            var startX = -cw - (float)_rng.NextDouble() * w;
            cloud.Offset = new Vector3(startX, y, 0f);
            _root!.Children.InsertAtTop(cloud);

            var drift = _compositor.CreateVector3KeyFrameAnimation();
            drift.InsertKeyFrame(0f, new Vector3(-cw, y, 0f));
            drift.InsertKeyFrame(1f, new Vector3(w + cw, y, 0f));
            drift.Duration = TimeSpan.FromSeconds(40.0 + _rng.NextDouble() * 30.0);
            drift.IterationBehavior = AnimationIterationBehavior.Forever;
            drift.DelayTime = TimeSpan.FromSeconds(_rng.NextDouble() * 20.0);
            cloud.StartAnimation("Offset", drift);
        }
    }

    // Volumetric-ish fog: a few wide translucent bands slowly drifting + pulsing opacity.
    private void BuildFog(float w, float h)
    {
        var brush = _compositor!.CreateColorBrush(Color.FromArgb(255, 200, 205, 215));
        const int bands = 4;

        for (var i = 0; i < bands; i++)
        {
            var bh = h * 0.22f;
            var y = (h / bands) * i;
            var band = _compositor.CreateSpriteVisual();
            band.Brush = brush;
            band.Size = new Vector2(w * 1.4f, bh);
            band.Offset = new Vector3(-(w * 0.2f), y, 0f);
            band.Opacity = 0.05f + (float)_rng.NextDouble() * 0.05f;
            _root!.Children.InsertAtTop(band);

            var drift = _compositor.CreateVector3KeyFrameAnimation();
            drift.InsertKeyFrame(0f, new Vector3(-(w * 0.4f), y, 0f));
            drift.InsertKeyFrame(1f, new Vector3(0f, y, 0f));
            drift.Duration = TimeSpan.FromSeconds(30.0 + _rng.NextDouble() * 20.0);
            drift.IterationBehavior = AnimationIterationBehavior.Forever;
            band.StartAnimation("Offset", drift);

            var pulse = _compositor.CreateScalarKeyFrameAnimation();
            pulse.InsertKeyFrame(0f, 0.04f);
            pulse.InsertKeyFrame(0.5f, 0.12f);
            pulse.InsertKeyFrame(1f, 0.04f);
            pulse.Duration = TimeSpan.FromSeconds(8.0 + _rng.NextDouble() * 6.0);
            pulse.IterationBehavior = AnimationIterationBehavior.Forever;
            band.StartAnimation("Opacity", pulse);
        }
    }
}
