using System;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Windows.UI;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdrop — cinematic GPU weather layer (WinUI Composition) that maps the live
//  weather condition to a full-screen effect, the Windows counterpart of the macOS
//  WeatherEffectView family (CinematicClearSky / Cloudy / Rain / Snow / Fog).
//
//  This is a from-scratch rewrite to reach Mac-parity cinematic quality using ONLY the
//  Composition primitives that build reliably on WindowsAppSDK: Compositor, ContainerVisual,
//  SpriteVisual, ShapeVisual + CompositionRoundedRectangleGeometry / CompositionEllipseGeometry,
//  CompositionColorBrush, CompositionLinearGradientBrush, CompositionRadialGradientBrush,
//  ScalarKeyFrameAnimation, Vector3KeyFrameAnimation, AnimationIterationBehavior, InsetClip.
//  Every effect is GPU/independent-animation driven (no per-frame CPU loop), so it composites
//  cheaply off the UI thread at 60 fps.
//
//  Design principles ported from the Mac effects:
//   - Real depth: 3 parallax bands per field (far/mid/near) with distinct size / opacity /
//     speed / blur-read; nearer = larger, brighter, faster, crisper.
//   - Cinematic colour: rain streaks carry a white->cyan->blue vertical gradient + bright head;
//     snow flakes carry a soft white->pale-blue glow halo; clouds are shaded (gradient body +
//     under-shadow + warm top highlight) not flat ellipses; fog is stacked soft radial blobs.
//   - Organic motion: per-element phase-desynced wind sway / twinkle / breathing so nothing is
//     in lockstep; off-screen wrapping so the infinite loops are never visible.
//   - Atmosphere: star field under every condition; sky gradient + glow where it sells the scene;
//     a final fog/vignette veil that ties highlights together.
//   - Counts scale to the live ActualWidth/ActualHeight so the field stays dense but bounded.
//
//  Condition keys (WeatherConditionKey): Clear / Cloudy / Rainy / Snowy / Foggy / Haze /
//  Stormy / Unknown. Rainy & Stormy => rain (Stormy heavier + lightning). Foggy & Haze => fog.
//  Clear & Unknown => the cinematic star field only.
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

    // Live weather condition key. Drives which effect layer renders over the star field.
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

        switch (Condition)
        {
            case "Rainy":
                BuildStormSky(w, h);
                BuildStars(w, h, dim: true);
                BuildCloudBand(w, h, dark: true);
                BuildRain(w, h, density: 1.0f, storm: false);
                BuildPuddleBand(w, h);
                BuildFogVeil(w, h, 0.08f);
                break;
            case "Stormy":
                BuildStormSky(w, h);
                BuildCloudBand(w, h, dark: true);
                BuildRain(w, h, density: 1.5f, storm: true);
                BuildPuddleBand(w, h);
                BuildLightning(w, h);
                BuildFogVeil(w, h, 0.10f);
                break;
            case "Snowy":
                BuildWinterSky(w, h);
                BuildSnow(w, h);
                BuildGroundSnow(w, h);
                BuildFogVeil(w, h, 0.06f);
                break;
            case "Cloudy":
                BuildStars(w, h, dim: true);
                BuildClouds(w, h);
                BuildFogVeil(w, h, 0.05f);
                break;
            case "Foggy":
            case "Haze":
                BuildFog(w, h);
                break;
            default:
                // Clear / Unknown — cinematic star field + sky glow + clear-sky light layer.
                BuildClearSky(w, h);
                break;
        }
    }

    // ---------------------------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------------------------

    private float Rand() => (float)_rng.NextDouble();
    private float Rand(float min, float max) => min + (float)_rng.NextDouble() * (max - min);

    private static Color Argb(float a, byte r, byte g, byte b) =>
        Color.FromArgb((byte)Math.Clamp(a * 255f, 0f, 255f), r, g, b);

    // A vertical 3-stop linear gradient sprite (top -> bottom).
    private SpriteVisual GradientRect(float width, float height, (float pos, Color color)[] stops, bool vertical = true)
    {
        var brush = _compositor!.CreateLinearGradientBrush();
        brush.StartPoint = new Vector2(0f, 0f);
        brush.EndPoint = vertical ? new Vector2(0f, 1f) : new Vector2(1f, 0f);
        foreach (var (pos, color) in stops)
        {
            brush.ColorStops.Add(_compositor.CreateColorGradientStop(pos, color));
        }
        var sprite = _compositor.CreateSpriteVisual();
        sprite.Brush = brush;
        sprite.Size = new Vector2(width, height);
        return sprite;
    }

    // A soft radial-gradient sprite (center bright -> edge clear). Reused for stars glow,
    // fog blobs, snow halos, cloud highlights, glow motes, lens flares.
    private SpriteVisual RadialBlob(float diameter, (float pos, Color color)[] stops)
    {
        var brush = _compositor!.CreateRadialGradientBrush();
        brush.EllipseCenter = new Vector2(0.5f, 0.5f);
        brush.EllipseRadius = new Vector2(0.5f, 0.5f);
        foreach (var (pos, color) in stops)
        {
            brush.ColorStops.Add(_compositor.CreateColorGradientStop(pos, color));
        }
        var sprite = _compositor.CreateSpriteVisual();
        sprite.Brush = brush;
        sprite.Size = new Vector2(diameter, diameter);
        return sprite;
    }

    private SpriteVisual SolidEllipse(float diameter, Color color)
    {
        var brush = _compositor!.CreateRadialGradientBrush();
        brush.EllipseCenter = new Vector2(0.5f, 0.5f);
        brush.EllipseRadius = new Vector2(0.5f, 0.5f);
        brush.ColorStops.Add(_compositor.CreateColorGradientStop(0f, color));
        brush.ColorStops.Add(_compositor.CreateColorGradientStop(0.85f, color));
        brush.ColorStops.Add(_compositor.CreateColorGradientStop(1f, Color.FromArgb(0, color.R, color.G, color.B)));
        var sprite = _compositor.CreateSpriteVisual();
        sprite.Brush = brush;
        sprite.Size = new Vector2(diameter, diameter);
        return sprite;
    }

    private void LoopOffset(Visual v, Vector3 from, Vector3 to, double seconds, double delay = 0.0)
    {
        var anim = _compositor!.CreateVector3KeyFrameAnimation();
        anim.InsertKeyFrame(0f, from);
        anim.InsertKeyFrame(1f, to);
        anim.Duration = TimeSpan.FromSeconds(seconds);
        anim.IterationBehavior = AnimationIterationBehavior.Forever;
        if (delay > 0.0)
        {
            anim.DelayTime = TimeSpan.FromSeconds(delay);
        }
        v.StartAnimation("Offset", anim);
    }

    private void LoopOpacity(Visual v, float a, float b, double seconds, double delay = 0.0)
    {
        var anim = _compositor!.CreateScalarKeyFrameAnimation();
        anim.InsertKeyFrame(0f, a);
        anim.InsertKeyFrame(0.5f, b);
        anim.InsertKeyFrame(1f, a);
        anim.Duration = TimeSpan.FromSeconds(seconds);
        anim.IterationBehavior = AnimationIterationBehavior.Forever;
        if (delay > 0.0)
        {
            anim.DelayTime = TimeSpan.FromSeconds(delay);
        }
        v.StartAnimation("Opacity", anim);
    }

    private void LoopRotation(Visual v, float fromDeg, float toDeg, double seconds, double delay = 0.0)
    {
        v.RotationAxis = new Vector3(0f, 0f, 1f);
        var anim = _compositor!.CreateScalarKeyFrameAnimation();
        anim.InsertKeyFrame(0f, fromDeg);
        anim.InsertKeyFrame(0.5f, toDeg);
        anim.InsertKeyFrame(1f, fromDeg);
        anim.Duration = TimeSpan.FromSeconds(seconds);
        anim.IterationBehavior = AnimationIterationBehavior.Forever;
        if (delay > 0.0)
        {
            anim.DelayTime = TimeSpan.FromSeconds(delay);
        }
        v.StartAnimation("RotationAngleInDegrees", anim);
    }

    // ---------------------------------------------------------------------------------
    //  STAR FIELD (shared base for clear / cloudy / light rain)
    // ---------------------------------------------------------------------------------

    // Three parallax star tiers with per-star phased twinkle. `dim` darkens it for use
    // beneath weather where it should only peek through.
    private void BuildStars(float w, float h, bool dim)
    {
        var area = w * h;
        // Tier: (count factor, size, opacityBase, twinkleSecMin, twinkleSecMax, blue-tint chance)
        BuildStarTier(w, h, Math.Clamp((int)(area / 4200f), 60, 350), 0.9f, dim ? 0.30f : 0.55f, 6.0, 9.0, 0.30f);
        BuildStarTier(w, h, Math.Clamp((int)(area / 11000f), 30, 130), 1.6f, dim ? 0.45f : 0.80f, 3.5, 6.0, 0.40f);
        BuildStarTier(w, h, Math.Clamp((int)(area / 30000f), 10, 45), 2.8f, dim ? 0.55f : 1.0f, 2.0, 4.0, 0.20f);
    }

    private void BuildStarTier(float w, float h, int count, float size, float opacityBase, double tMin, double tMax, float tintChance)
    {
        for (var i = 0; i < count; i++)
        {
            var s = size * Rand(0.7f, 1.3f);
            Color color;
            var roll = Rand();
            if (roll < tintChance * 0.5f)
            {
                color = Color.FromArgb(255, 190, 205, 255); // blue-white
            }
            else if (roll < tintChance)
            {
                color = Color.FromArgb(255, 215, 195, 255); // purple-white
            }
            else
            {
                color = Color.FromArgb(255, 255, 255, 255);
            }

            // Star body with a faint glow halo (radial) so brighter stars bloom.
            var star = RadialBlob(s * 3f, new[]
            {
                (0f, color),
                (0.30f, Color.FromArgb((byte)(color.A * 0.8f), color.R, color.G, color.B)),
                (1f, Color.FromArgb(0, color.R, color.G, color.B)),
            });
            star.Offset = new Vector3(Rand() * w, Rand() * h, 0f);
            var baseOp = opacityBase * Rand(0.6f, 1.0f);
            star.Opacity = baseOp;
            _root!.Children.InsertAtTop(star);

            LoopOpacity(star, baseOp * 0.25f, baseOp, Rand((float)tMin, (float)tMax), Rand() * tMax);
        }
    }

    // ---------------------------------------------------------------------------------
    //  CLEAR SKY (stars + nebula glow + warm sunlit light spots + lens flare)
    // ---------------------------------------------------------------------------------

    private void BuildClearSky(float w, float h)
    {
        // Deep night sky base gradient.
        var sky = GradientRect(w, h, new[]
        {
            (0f, Argb(1f, 3, 3, 20)),
            (0.33f, Argb(1f, 8, 8, 38)),
            (0.66f, Argb(1f, 20, 15, 64)),
            (1f, Argb(1f, 31, 26, 77)),
        });
        _root!.Children.InsertAtTop(sky);

        // Nebula colour clouds (soft, breathing, slowly drifting).
        BuildNebula(w, h);

        // Star field over the nebula.
        BuildStars(w, h, dim: false);

        // Shooting star.
        BuildMeteor(w, h);

        // Daytime sunlit "glass" light layer over the night base — warm sky tint + prismatic
        // light spots + glow motes + lens flare. Held at moderate opacity so stars peek through.
        var clearLayer = _compositor!.CreateContainerVisual();
        clearLayer.Size = new Vector2(w, h);
        clearLayer.Opacity = 0.55f;
        _root.Children.InsertAtTop(clearLayer);

        var skyTint = GradientRect(w, h, new[]
        {
            (0f, Argb(0.35f, 102, 153, 230)),
            (0.33f, Argb(0.30f, 153, 204, 255)),
            (0.66f, Argb(0.22f, 230, 242, 250)),
            (1f, Argb(0.25f, 255, 250, 230)),
        });
        clearLayer.Children.InsertAtTop(skyTint);

        BuildLightSpots(clearLayer, w, h);
        BuildGlowMotes(clearLayer, w, h);
        BuildLensFlare(clearLayer, w, h);

        // Ambient breathing of the whole sunlit layer.
        LoopOpacity(clearLayer, 0.45f, 0.62f, 31.0);
    }

    private void BuildNebula(float w, float h)
    {
        (float x, float y, float r, Color c, double drift)[] blobs =
        {
            (0.2f, 0.3f, 0.40f, Argb(0.5f, 77, 26, 128), 22.0),
            (0.8f, 0.7f, 0.50f, Argb(0.5f, 26, 26, 102), 26.0),
            (0.5f, 0.5f, 0.30f, Argb(0.45f, 26, 102, 128), 18.0),
            (0.1f, 0.8f, 0.40f, Argb(0.4f, 51, 26, 102), 30.0),
        };
        var i = 0;
        foreach (var (x, y, r, c, drift) in blobs)
        {
            var d = r * w * 2f;
            var blob = RadialBlob(d, new[]
            {
                (0f, c),
                (0.5f, Color.FromArgb((byte)(c.A * 0.5f), c.R, c.G, c.B)),
                (1f, Color.FromArgb(0, c.R, c.G, c.B)),
            });
            var cx = x * w - d / 2f;
            var cy = y * h - d / 2f;
            blob.Offset = new Vector3(cx, cy, 0f);
            _root!.Children.InsertAtTop(blob);

            var amp = w * 0.10f;
            LoopOffset(blob, new Vector3(cx - amp, cy - amp * 0.6f, 0f), new Vector3(cx + amp, cy + amp * 0.6f, 0f), drift, i * 2.0);
            LoopOpacity(blob, 0.25f, 0.5f, 12.0 + i * 1.5, i * 1.2);
            i++;
        }
    }

    private void BuildLightSpots(ContainerVisual parent, float w, float h)
    {
        var count = Math.Clamp((int)(w * h / 80000f), 8, 15);
        for (var i = 0; i < count; i++)
        {
            var size = Rand(80f, 200f);
            var intensity = Rand(0.15f, 0.35f);
            // Pale prismatic hue.
            var color = HsvToColor(Rand(0f, 360f), 0.30f, 1.0f, intensity);
            // Three concentric refraction rings.
            for (var k = 0; k < 3; k++)
            {
                var ringSize = size * (1f + k * 0.4f);
                var ringAlpha = intensity / (k + 1);
                var ring = RadialBlob(ringSize, new[]
                {
                    (0f, Color.FromArgb((byte)(color.A * 0.0f), color.R, color.G, color.B)),
                    (0.55f, Color.FromArgb((byte)Math.Clamp(ringAlpha * 0.8f * 255f, 0, 255), color.R, color.G, color.B)),
                    (0.80f, Color.FromArgb((byte)Math.Clamp(ringAlpha * 0.4f * 255f, 0, 255), 255, 255, 255)),
                    (1f, Color.FromArgb(0, color.R, color.G, color.B)),
                });
                var px = Rand() * w - ringSize / 2f;
                var py = Rand() * h - ringSize / 2f;
                ring.Offset = new Vector3(px, py, 0f);
                parent.Children.InsertAtTop(ring);

                LoopOpacity(ring, ringAlpha * 0.5f, ringAlpha, Rand(6f, 10f), i * 0.5);
                var dx = Rand(-40f, 40f);
                var dy = Rand(-40f, 40f);
                LoopOffset(ring, new Vector3(px - dx, py - dy, 0f), new Vector3(px + dx, py + dy, 0f), Rand(28f, 48f), i * 0.6);
            }
        }
    }

    private void BuildGlowMotes(ContainerVisual parent, float w, float h)
    {
        int[] counts = { 30, 40, 30 };
        for (var layer = 0; layer < 3; layer++)
        {
            var n = Math.Clamp((int)(counts[layer] * (w * h / 960000f)), 10, counts[layer]);
            for (var i = 0; i < n; i++)
            {
                var size = Rand(2f, 8f);
                var mote = RadialBlob(size * 2.2f, new[]
                {
                    (0f, Argb(0.8f, 255, 255, 255)),
                    (0.5f, Argb(0.4f, 180, 240, 255)),
                    (1f, Color.FromArgb(0, 180, 240, 255)),
                });
                var px = Rand() * w;
                var py = Rand() * h;
                mote.Offset = new Vector3(px, py, 0f);
                mote.Opacity = Rand(0.18f, 0.42f) * (1f - layer * 0.25f);
                parent.Children.InsertAtTop(mote);

                var dx = Rand(-30f, 30f);
                var dy = Rand(-30f, 30f);
                LoopOffset(mote, new Vector3(px - dx, py - dy, 0f), new Vector3(px + dx, py + dy, 0f), Rand(20f, 40f), i * 0.2);
            }
        }
    }

    private void BuildLensFlare(ContainerVisual parent, float w, float h)
    {
        // Main warm flare upper-right (sun direction).
        var mainD = 600f;
        var main = RadialBlob(mainD, new[]
        {
            (0f, Argb(0.4f, 255, 255, 255)),
            (0.35f, Argb(0.3f, 255, 245, 180)),
            (0.65f, Argb(0.2f, 255, 200, 120)),
            (1f, Color.FromArgb(0, 255, 200, 120)),
        });
        main.Offset = new Vector3(0.75f * w - mainD / 2f, 0.20f * h - mainD / 2f, 0f);
        parent.Children.InsertAtTop(main);
        LoopOpacity(main, 0.18f, 0.45f, 21.0);

        // Secondary cool reflection lower-left.
        var secD = 300f;
        var sec = RadialBlob(secD, new[]
        {
            (0f, Argb(0.3f, 150, 230, 255)),
            (0.5f, Argb(0.2f, 100, 160, 255)),
            (1f, Color.FromArgb(0, 100, 160, 255)),
        });
        sec.Offset = new Vector3(0.30f * w - secD / 2f, 0.60f * h - secD / 2f, 0f);
        parent.Children.InsertAtTop(sec);
        LoopOpacity(sec, 0.10f, 0.25f, 21.0, 3.0);
    }

    private void BuildMeteor(float w, float h)
    {
        // A reusable horizontal gradient streak rotated to a down-left angle, flashing on a cycle.
        var len = Rand(220f, 380f);
        var streak = GradientRect(len, 2.4f, new[]
        {
            (0f, Color.FromArgb(0, 255, 255, 255)),
            (0.6f, Argb(0.5f, 150, 200, 255)),
            (1f, Argb(0.95f, 255, 255, 255)),
        }, vertical: false);
        var head = RadialBlob(9f, new[]
        {
            (0f, Argb(1f, 255, 255, 255)),
            (0.4f, Argb(0.5f, 255, 255, 255)),
            (1f, Color.FromArgb(0, 255, 255, 255)),
        });

        var sx = Rand(0.4f, 0.9f) * w;
        var sy = Rand(0.0f, 0.5f) * h;
        var angle = Rand(110f, 160f);
        var rad = angle * (float)Math.PI / 180f;
        var dx = (float)Math.Cos(rad) * len;
        var dy = (float)Math.Sin(rad) * len;

        var container = _compositor!.CreateContainerVisual();
        container.Size = new Vector2(len, 9f);
        container.RotationAxis = new Vector3(0f, 0f, 1f);
        container.RotationAngleInDegrees = angle;
        container.Children.InsertAtTop(streak);
        head.Offset = new Vector3(len - 4.5f, -3.3f, 0f);
        container.Children.InsertAtTop(head);
        container.Opacity = 0f;
        _root!.Children.InsertAtTop(container);

        const double cycle = 7.0;
        var travel = _compositor.CreateVector3KeyFrameAnimation();
        travel.InsertKeyFrame(0f, new Vector3(sx, sy, 0f));
        travel.InsertKeyFrame(0.114f, new Vector3(sx + dx, sy + dy, 0f)); // 0.8s of 7s
        travel.InsertKeyFrame(1f, new Vector3(sx + dx, sy + dy, 0f));
        travel.Duration = TimeSpan.FromSeconds(cycle);
        travel.IterationBehavior = AnimationIterationBehavior.Forever;
        container.StartAnimation("Offset", travel);

        var fade = _compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0f, 0.9f);
        fade.InsertKeyFrame(0.114f, 0f);
        fade.InsertKeyFrame(1f, 0f);
        fade.Duration = TimeSpan.FromSeconds(cycle);
        fade.IterationBehavior = AnimationIterationBehavior.Forever;
        container.StartAnimation("Opacity", fade);
    }

    // ---------------------------------------------------------------------------------
    //  RAIN (3 parallax depth layers, gradient streaks + head highlight, wind sway/tilt)
    // ---------------------------------------------------------------------------------

    private void BuildStormSky(float w, float h)
    {
        var sky = GradientRect(w, h, new[]
        {
            (0f, Argb(1f, 18, 22, 34)),
            (0.5f, Argb(1f, 28, 34, 50)),
            (1f, Argb(1f, 20, 26, 40)),
        });
        _root!.Children.InsertAtTop(sky);
    }

    private void BuildRain(float w, float h, float density, bool storm)
    {
        // (count factor per layer, lengthMin, lengthMax, thickness, opacity, fallSeconds, swayAmp)
        BuildRainLayer(w, h, ScaleCount(w, 100, density), 12f, 18f, 2.5f, 0.80f, 2.2 / (storm ? 1.8 : 1.0), 6f, false);
        BuildRainLayer(w, h, ScaleCount(w, 80, density), 20f, 28f, 2.0f, 0.65f, 1.5 / (storm ? 1.8 : 1.0), 14f, true);
        BuildRainLayer(w, h, ScaleCount(w, 50, density), 34f, 48f, 1.8f, 0.55f, 1.0 / (storm ? 1.8 : 1.0), 26f, true);
    }

    private int ScaleCount(float w, int baseCount, float density)
    {
        // baseCount is authored for a ~1200px window; scale to width and density, then bound.
        var scaled = (int)(baseCount * (w / 1200f) * density);
        return Math.Clamp(scaled, baseCount / 4, (int)(baseCount * 1.6f * density));
    }

    private void BuildRainLayer(float w, float h, int count, float lenMin, float lenMax, float thickness,
                                float opacity, double fallSec, float swayAmp, bool gradient)
    {
        for (var i = 0; i < count; i++)
        {
            var length = Rand(lenMin, lenMax);
            var op = opacity * Rand(0.7f, 1.0f);
            var x = Rand() * w;

            SpriteVisual streak;
            if (gradient)
            {
                streak = GradientRect(thickness, length, new[]
                {
                    (0f, Argb(op, 255, 255, 255)),
                    (0.33f, Argb(op * 0.8f, 0, 255, 255)),
                    (0.66f, Argb(op * 0.6f, 40, 80, 255)),
                    (1f, Argb(op * 0.3f, 255, 255, 255)),
                });
            }
            else
            {
                streak = _compositor!.CreateSpriteVisual();
                streak.Brush = _compositor.CreateColorBrush(Argb(op, 210, 225, 250));
                streak.Size = new Vector2(thickness, length);
            }

            // Slight wind tilt.
            streak.RotationAxis = new Vector3(0f, 0f, 1f);
            streak.RotationAngleInDegrees = Rand(-6f, 6f) * (swayAmp / 26f);

            var startY = -length - Rand(0f, h * 0.5f);
            streak.Offset = new Vector3(x, startY, 0f);
            _root!.Children.InsertAtTop(streak);

            // Head highlight overlay for the gradient (near/mid) streaks.
            if (gradient)
            {
                var head = _compositor!.CreateSpriteVisual();
                head.Brush = _compositor.CreateColorBrush(Argb(0.92f, 255, 255, 255));
                head.Size = new Vector2(thickness * 0.5f, length * 0.3f);
                head.Offset = new Vector3(thickness * 0.25f, length * 0.7f, 0f);
                streak.Children.InsertAtTop(head);
            }

            var jitter = (float)(1.0 + Rand(-0.15f, 0.2f));
            var dur = fallSec * jitter;
            var sway = Rand(-swayAmp, swayAmp);

            var fall = _compositor!.CreateVector3KeyFrameAnimation();
            fall.InsertKeyFrame(0f, new Vector3(x, startY, 0f));
            fall.InsertKeyFrame(0.5f, new Vector3(x + sway, (startY + h) * 0.5f, 0f));
            fall.InsertKeyFrame(1f, new Vector3(x + sway * 0.4f, h + length, 0f));
            fall.Duration = TimeSpan.FromSeconds(dur);
            fall.IterationBehavior = AnimationIterationBehavior.Forever;
            fall.DelayTime = TimeSpan.FromSeconds(Rand() * dur);
            streak.StartAnimation("Offset", fall);
        }
    }

    private void BuildPuddleBand(float w, float h)
    {
        var bandH = Math.Min(h * 0.08f, 64f);
        var band = GradientRect(w, bandH, new[]
        {
            (0f, Argb(0.6f, 38, 51, 77)),
            (0.5f, Argb(0.7f, 51, 64, 89)),
            (1f, Argb(0.8f, 64, 77, 102)),
        });
        band.Offset = new Vector3(0f, h - bandH, 0f);
        _root!.Children.InsertAtTop(band);

        // Expanding impact ripples on a pooled loop.
        var rippleCount = Math.Clamp((int)(w / 90f), 6, 20);
        for (var i = 0; i < rippleCount; i++)
        {
            var x = Rand() * w;
            var maxR = Rand(20f, 56f);
            var ripple = RingEllipse(maxR * 2f, Argb(0.5f, 255, 255, 255));
            ripple.CenterPoint = new Vector3(maxR, maxR * 0.5f, 0f);
            ripple.Offset = new Vector3(x - maxR, h - bandH * 0.6f - maxR * 0.5f, 0f);
            ripple.Scale = new Vector3(0f, 0f, 0f);
            ripple.Opacity = 0f;
            _root!.Children.InsertAtTop(ripple);

            var period = Rand(0.9f, 2.0f);
            var grow = _compositor!.CreateVector3KeyFrameAnimation();
            grow.InsertKeyFrame(0f, new Vector3(0f, 0f, 0f));
            grow.InsertKeyFrame(1f, new Vector3(1f, 0.5f, 0f)); // flatten vertically (perspective)
            grow.Duration = TimeSpan.FromSeconds(period);
            grow.IterationBehavior = AnimationIterationBehavior.Forever;
            grow.DelayTime = TimeSpan.FromSeconds(Rand() * 3.0f);
            ripple.StartAnimation("Scale", grow);

            var fade = _compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(0f, 0.55f);
            fade.InsertKeyFrame(1f, 0f);
            fade.Duration = TimeSpan.FromSeconds(period);
            fade.IterationBehavior = AnimationIterationBehavior.Forever;
            fade.DelayTime = TimeSpan.FromSeconds(Rand() * 3.0f);
            ripple.StartAnimation("Opacity", fade);
        }
    }

    // Stroked ellipse ring (no fill) via two concentric ellipse geometries.
    private ShapeVisual RingEllipse(float diameter, Color color)
    {
        var geo = _compositor!.CreateEllipseGeometry();
        geo.Radius = new Vector2(diameter / 2f, diameter / 4f); // flattened ripple
        var shape = _compositor.CreateSpriteShape(geo);
        shape.StrokeBrush = _compositor.CreateColorBrush(color);
        shape.StrokeThickness = 1.5f;
        shape.Offset = new Vector2(diameter / 2f, diameter / 4f);
        var visual = _compositor.CreateShapeVisual();
        visual.Size = new Vector2(diameter, diameter / 2f);
        visual.Shapes.Add(shape);
        return visual;
    }

    private void BuildLightning(float w, float h)
    {
        var flash = _compositor!.CreateSpriteVisual();
        flash.Brush = _compositor.CreateColorBrush(Color.FromArgb(255, 255, 255, 255));
        flash.Size = new Vector2(w, h);
        flash.Opacity = 0f;
        _root!.Children.InsertAtTop(flash);

        // Strike roughly every 5-12s: a quick bright flash then fade. Modeled as a long loop
        // with a short bright window.
        const double cycle = 9.0;
        var anim = _compositor.CreateScalarKeyFrameAnimation();
        anim.InsertKeyFrame(0f, 0f);
        anim.InsertKeyFrame(0.02f, 0.0f);
        anim.InsertKeyFrame(0.03f, 0.7f);
        anim.InsertKeyFrame(0.05f, 0.2f);
        anim.InsertKeyFrame(0.07f, 0.6f);
        anim.InsertKeyFrame(0.13f, 0f);
        anim.InsertKeyFrame(1f, 0f);
        anim.Duration = TimeSpan.FromSeconds(cycle);
        anim.IterationBehavior = AnimationIterationBehavior.Forever;
        flash.StartAnimation("Opacity", anim);
    }

    // ---------------------------------------------------------------------------------
    //  SNOW (3 parallax depth layers, bokeh far + crystal/halo near, gusting sway)
    // ---------------------------------------------------------------------------------

    private void BuildWinterSky(float w, float h)
    {
        var sky = GradientRect(w, h, new[]
        {
            (0f, Argb(1f, 191, 204, 224)),
            (0.33f, Argb(1f, 209, 217, 230)),
            (0.66f, Argb(1f, 224, 230, 237)),
            (1f, Argb(1f, 235, 237, 242)),
        });
        _root!.Children.InsertAtTop(sky);

        // Diffuse sun glow through cloud.
        var glow = RadialBlob(360f, new[]
        {
            (0f, Argb(0.25f, 255, 255, 255)),
            (0.5f, Argb(0.15f, 255, 250, 242)),
            (1f, Color.FromArgb(0, 255, 250, 242)),
        });
        glow.Offset = new Vector3(0.30f * w - 180f, 0.15f * h - 180f, 0f);
        _root.Children.InsertAtTop(glow);
        LoopOffset(glow, new Vector3(0.27f * w - 180f, 0.15f * h - 180f, 0f),
                          new Vector3(0.33f * w - 180f, 0.15f * h - 180f, 0f), 120.0);
    }

    private void BuildSnow(float w, float h)
    {
        // Far / bokeh layer (soft discs).
        BuildSnowLayer(w, h, ScaleCount(w, 80, 1f), 6f, 15f, 0.2f, 0.4f, 10.0, 16.0, 14f, true, false);
        // Mid layer (semi-sharp + halo).
        BuildSnowLayer(w, h, ScaleCount(w, 60, 1f), 5f, 10f, 0.5f, 0.7f, 7.0, 11.0, 22f, false, true);
        // Near layer (sharp crystal + strong halo).
        BuildSnowLayer(w, h, ScaleCount(w, 35, 1f), 10f, 18f, 0.75f, 0.95f, 4.5, 8.0, 34f, false, true);
    }

    private void BuildSnowLayer(float w, float h, int count, float sizeMin, float sizeMax,
                                float opMin, float opMax, double fallMin, double fallMax,
                                float swayAmp, bool bokeh, bool halo)
    {
        for (var i = 0; i < count; i++)
        {
            var size = Rand(sizeMin, sizeMax);
            var op = Rand(opMin, opMax);
            var x = Rand() * w;

            SpriteVisual flake;
            if (bokeh)
            {
                flake = RadialBlob(size, new[]
                {
                    (0f, Argb(op * 0.5f, 255, 255, 255)),
                    (0.4f, Argb(op * 0.3f, 255, 255, 255)),
                    (0.7f, Argb(op * 0.15f, 255, 255, 255)),
                    (1f, Color.FromArgb(0, 255, 255, 255)),
                });
            }
            else if (halo)
            {
                flake = RadialBlob(size * 1.4f, new[]
                {
                    (0f, Argb(op, 255, 255, 255)),
                    (0.45f, Argb(op * 0.7f, 255, 255, 255)),
                    (0.75f, Argb(op * 0.3f, 230, 242, 255)),
                    (1f, Color.FromArgb(0, 230, 242, 255)),
                });
            }
            else
            {
                flake = SolidEllipse(size, Argb(op, 255, 255, 255));
            }

            var startY = Rand(-0.2f, 1.0f) * h - size;
            flake.Offset = new Vector3(x, startY, 0f);
            _root!.Children.InsertAtTop(flake);

            // Tumble rotation on near/mid crystals.
            if (!bokeh)
            {
                LoopRotation(flake, Rand(-30f, 0f), Rand(30f, 70f), Rand(6f, 14f), i * 0.1);
            }

            var dur = Rand((float)fallMin, (float)fallMax);
            var sway = Rand(swayAmp * 0.4f, swayAmp);
            var fall = _compositor!.CreateVector3KeyFrameAnimation();
            fall.InsertKeyFrame(0f, new Vector3(x, -size, 0f));
            fall.InsertKeyFrame(0.33f, new Vector3(x + sway, h * 0.33f, 0f));
            fall.InsertKeyFrame(0.66f, new Vector3(x - sway, h * 0.66f, 0f));
            fall.InsertKeyFrame(1f, new Vector3(x + sway * 0.5f, h + size, 0f));
            fall.Duration = TimeSpan.FromSeconds(dur);
            fall.IterationBehavior = AnimationIterationBehavior.Forever;
            fall.DelayTime = TimeSpan.FromSeconds(Rand() * dur);
            flake.StartAnimation("Offset", fall);
        }
    }

    private void BuildGroundSnow(float w, float h)
    {
        var groundY = h * 0.88f;
        var ground = GradientRect(w, h - groundY, new[]
        {
            (0f, Argb(0.7f, 242, 247, 255)),
            (0.5f, Argb(0.85f, 255, 255, 255)),
            (1f, Argb(0.9f, 230, 235, 242)),
        });
        ground.Offset = new Vector3(0f, groundY, 0f);
        _root!.Children.InsertAtTop(ground);

        // Soft mounds (static domes).
        var mounds = Math.Clamp((int)(w / 60f), 8, 20);
        for (var i = 0; i < mounds; i++)
        {
            var mw = Rand(50f, 120f);
            var mh = Rand(10f, 25f);
            var op = Rand(0.6f, 0.9f);
            var mound = RadialBlob(mw, new[]
            {
                (0f, Argb(op, 255, 255, 255)),
                (0.6f, Argb(op * 0.8f, 242, 247, 255)),
                (1f, Color.FromArgb(0, 242, 247, 255)),
            });
            mound.Size = new Vector2(mw, mh * 2f);
            mound.Offset = new Vector3(Rand() * w - mw / 2f, groundY - mh, 0f);
            _root.Children.InsertAtTop(mound);
        }
    }

    // ---------------------------------------------------------------------------------
    //  CLOUDY (3 shaded parallax cloud banks: gradient body + under-shadow + warm rim)
    // ---------------------------------------------------------------------------------

    private void BuildClouds(float w, float h)
    {
        var minDim = Math.Min(w, h);
        // Cirrus (far/high/thin), Main-far, Main-near.
        // Tuned on-device: clouds are an ATMOSPHERE behind the glass cards, not a wall — far
        // fewer + much lower opacity than the workflow's first pass (which buried the StatCards).
        BuildCloudLayer(w, h, Math.Clamp((int)(w / 120f), 4, 12), 0.02f, 0.15f, minDim * 0.025f, 0.22f, 34f, 0.55f, true, false);
        BuildCloudLayer(w, h, Math.Clamp((int)(w / 175f), 3, 9), 0.05f, 0.20f, minDim * 0.075f, 0.22f, 14f, 0.65f, false, false);
        BuildCloudLayer(w, h, Math.Clamp((int)(w / 145f), 3, 10), 0.09f, 0.28f, minDim * 0.060f, 0.26f, 24f, 0.85f, false, true);
    }

    private void BuildCloudLayer(float w, float h, int count, float yMin, float yMax, float baseR,
                                 float opacity, float speedPxSec, float depthFade, bool cirrus, bool silverLining)
    {
        for (var i = 0; i < count; i++)
        {
            var cw = cirrus ? baseR * Rand(6f, 11f) : baseR * Rand(2.6f, 4.2f);
            var ch = cirrus ? baseR * Rand(0.5f, 1.0f) : baseR * Rand(1.4f, 2.4f);
            var y = Rand(yMin, yMax) * h;
            var op = Math.Clamp(opacity * depthFade * 0.6f, 0f, 1f);

            var cloud = _compositor!.CreateContainerVisual();
            cloud.Size = new Vector2(cw, ch);

            // Shaded body: vertical gradient (bright top -> dark bottom), soft via radial edges.
            var body = RadialBlob(Math.Max(cw, ch), cirrus
                ? new[]
                {
                    (0f, Argb(op * 0.48f, 235, 240, 250)),
                    (0.5f, Argb(op * 0.40f, 219, 224, 240)),
                    (0.85f, Argb(op * 0.20f, 179, 188, 204)),
                    (1f, Color.FromArgb(0, 179, 188, 204)),
                }
                : new[]
                {
                    (0f, Argb(op * 0.75f, 219, 224, 235)),
                    (0.5f, Argb(op * 0.62f, 199, 204, 214)),
                    (0.82f, Argb(op * 0.55f, 140, 149, 163)),
                    (1f, Color.FromArgb(0, 140, 149, 163)),
                });
            body.Size = new Vector2(cw, ch);
            cloud.Children.InsertAtTop(body);

            // Under-shadow (darker lower half) for volume — main layers only.
            if (!cirrus)
            {
                var shadow = RadialBlob(cw, new[]
                {
                    (0f, Color.FromArgb(0, 30, 36, 46)),
                    (0.6f, Argb(op * 0.15f, 30, 36, 46)),
                    (1f, Argb(op * 0.28f, 20, 24, 32)),
                });
                shadow.Size = new Vector2(cw * 0.9f, ch * 0.6f);
                shadow.Offset = new Vector3(cw * 0.05f, ch * 0.45f, 0f);
                cloud.Children.InsertAtTop(shadow);
            }

            // Warm top-left rim "silver lining" — near layer only.
            if (silverLining)
            {
                var rim = RadialBlob(cw * 0.6f, new[]
                {
                    (0f, Argb(op * 0.5f, 255, 247, 230)),
                    (0.5f, Argb(op * 0.25f, 255, 247, 230)),
                    (1f, Color.FromArgb(0, 255, 247, 230)),
                });
                rim.Size = new Vector2(cw * 0.5f, ch * 0.5f);
                rim.Offset = new Vector3(cw * 0.08f, ch * 0.05f, 0f);
                cloud.Children.InsertAtTop(rim);
            }

            var span = w + cw * 2f;
            var startX = -cw + Rand() * span;
            cloud.Offset = new Vector3(startX, y, 0f);
            _root!.Children.InsertAtTop(cloud);

            // Horizontal drift (seamless wrap off-screen). startX already pre-populates the band
            // so the field looks continuous from the first frame rather than "drifting in".
            var dur = span / speedPxSec;
            LoopOffset(cloud, new Vector3(-cw, y, 0f), new Vector3(w + cw, y, 0f), dur, Rand() * dur);

            // Subtle breathing bob so the bank feels alive rather than a pasted bitmap.
            LoopOpacity(cloud, 0.85f, 1.0f, Rand(18f, 30f), i * 0.4);
        }
    }

    // ---------------------------------------------------------------------------------
    //  FOG / HAZE (atmosphere gradient + parallax soft blob field + god rays + vignette)
    // ---------------------------------------------------------------------------------

    private void BuildFog(float w, float h)
    {
        // Atmosphere base gradient (cool grey, denser at bottom).
        var sky = GradientRect(w, h, new[]
        {
            (0f, Argb(1f, 184, 192, 204)),
            (0.5f, Argb(1f, 196, 203, 212)),
            (1f, Argb(1f, 174, 182, 192)),
        });
        _root!.Children.InsertAtTop(sky);

        // Soft sun glow through fog.
        var glow = RadialBlob(420f, new[]
        {
            (0f, Argb(0.3f, 255, 242, 217)),
            (0.6f, Argb(0.12f, 255, 242, 217)),
            (1f, Color.FromArgb(0, 255, 242, 217)),
        });
        glow.Offset = new Vector3(0.75f * w - 210f, 0.20f * h - 210f, 0f);
        _root.Children.InsertAtTop(glow);
        LoopOffset(glow, new Vector3(0.72f * w - 210f, 0.20f * h - 210f, 0f),
                          new Vector3(0.78f * w - 210f, 0.20f * h - 210f, 0f), 120.0);

        // Three parallax blob fields (far slow/large/dim -> near fast/small/dense).
        BuildFogLayer(w, h, Math.Clamp((int)(w * h / 70000f), 12, 24), 220f, 420f, 0.10f, 0.14f, 6f);
        BuildFogLayer(w, h, Math.Clamp((int)(w * h / 55000f), 16, 30), 140f, 260f, 0.14f, 0.20f, 10f);
        BuildFogLayer(w, h, Math.Clamp((int)(w * h / 70000f), 12, 24), 100f, 180f, 0.18f, 0.26f, 14f);

        // God rays — the single biggest cinematic tell.
        BuildGodRays(w, h);

        // Vignette + faint fog veil.
        BuildVignette(w, h, 0.35f);
        BuildFogVeil(w, h, 0.06f);
    }

    private void BuildFogLayer(float w, float h, int count, float dMin, float dMax,
                              float opMin, float opMax, float speedPxSec)
    {
        for (var i = 0; i < count; i++)
        {
            var d = Rand(dMin, dMax) * Rand(0.8f, 1.25f);
            // Bias toward the lower 60% (ground fog denser) and scale alpha by vertical position.
            var yNorm = Rand() < 0.65f ? Rand(0.4f, 1.0f) : Rand(0f, 1.0f);
            var vert = 0.7f + 0.3f * yNorm;
            var op = Rand(opMin, opMax) * vert;

            var blob = RadialBlob(d, new[]
            {
                (0f, Argb(op, 199, 204, 214)),
                (0.5f, Argb(op * 0.5f, 199, 204, 214)),
                (1f, Color.FromArgb(0, 199, 204, 214)),
            });
            var px = Rand() * (w + d) - d;
            var py = yNorm * h - d / 2f;
            blob.Offset = new Vector3(px, py, 0f);
            blob.Opacity = 1f;
            _root!.Children.InsertAtTop(blob);

            // Horizontal scroll with off-screen wrap.
            var span = w + d * 2f;
            var dur = span / speedPxSec;
            LoopOffset(blob, new Vector3(-d, py, 0f), new Vector3(w + d, py, 0f), dur, (Rand() * dur));

            // Breathing + sway + scale pulse, phase-desynced.
            LoopOpacity(blob, op * 0.7f, op, Rand(4f, 9f), i * 0.3);
            var pulse = _compositor!.CreateVector3KeyFrameAnimation();
            pulse.InsertKeyFrame(0f, new Vector3(1f, 1f, 0f));
            pulse.InsertKeyFrame(0.5f, new Vector3(1.08f, 1.08f, 0f));
            pulse.InsertKeyFrame(1f, new Vector3(1f, 1f, 0f));
            pulse.Duration = TimeSpan.FromSeconds(Rand(8f, 14f));
            pulse.IterationBehavior = AnimationIterationBehavior.Forever;
            blob.CenterPoint = new Vector3(d / 2f, d / 2f, 0f);
            blob.StartAnimation("Scale", pulse);
        }
    }

    private void BuildGodRays(float w, float h)
    {
        // 5 widening warm shafts radiating from an off-screen sun upper-right.
        (float angle, float width, float opacity)[] rays =
        {
            (-25f, 180f, 0.25f),
            (-10f, 120f, 0.35f),
            (5f, 150f, 0.30f),
            (20f, 100f, 0.20f),
            (35f, 80f, 0.15f),
        };
        var sunX = 0.75f * w;
        var sunY = -50f;
        var length = 1.5f * Math.Max(w, h);

        var i = 0;
        foreach (var (angle, width, opacity) in rays)
        {
            var ray = GradientRect(width * 2.5f, length, new[]
            {
                (0f, Argb(opacity, 255, 249, 229)),
                (0.5f, Argb(opacity * 0.5f, 242, 235, 217)),
                (0.8f, Argb(opacity * 0.2f, 230, 224, 204)),
                (1f, Color.FromArgb(0, 230, 224, 204)),
            });
            ray.CenterPoint = new Vector3(width * 1.25f, 0f, 0f);
            ray.RotationAxis = new Vector3(0f, 0f, 1f);
            ray.RotationAngleInDegrees = angle;
            ray.Offset = new Vector3(sunX - width * 1.25f, sunY, 0f);
            ray.Opacity = opacity;
            _root!.Children.InsertAtTop(ray);

            LoopRotation(ray, angle - 2f, angle + 2f, Rand(6f, 12f), i * 0.8);
            LoopOpacity(ray, opacity * 0.8f, opacity, Rand(5f, 10f), i * 0.5);
            i++;
        }
    }

    private void BuildVignette(float w, float h, float strength)
    {
        var d = Math.Max(w, h) * 1.6f;
        var vig = RadialBlob(d, new[]
        {
            (0f, Color.FromArgb(0, 51, 64, 89)),
            (0.45f, Color.FromArgb(0, 51, 64, 89)),
            (0.75f, Argb(strength * 0.45f, 77, 89, 115)),
            (1f, Argb(strength, 51, 64, 89)),
        });
        vig.Offset = new Vector3((w - d) / 2f, (h - d) / 2f, 0f);
        _root!.Children.InsertAtTop(vig);
    }

    // ---------------------------------------------------------------------------------
    //  SHARED ATMOSPHERIC PIECES
    // ---------------------------------------------------------------------------------

    // Dark cloud band across the top (storm/rain depth).
    private void BuildCloudBand(float w, float h, bool dark)
    {
        var bandH = h * 0.4f;
        var clusters = Math.Clamp((int)(w / 200f), 4, 8);
        for (var i = 0; i < clusters; i++)
        {
            var cw = Rand(180f, 280f);
            var ch = cw * 0.6f;
            var x = (w / clusters) * i + Rand(-40f, 40f);
            var y = Rand(0f, bandH * 0.5f);
            var puff = RadialBlob(cw, new[]
            {
                (0f, Argb(0.9f, 30, 30, 46)),
                (0.5f, Argb(0.5f, 46, 46, 61)),
                (1f, Color.FromArgb(0, 64, 64, 82)),
            });
            puff.Size = new Vector2(cw, ch);
            puff.Offset = new Vector3(x, y, 0f);
            _root!.Children.InsertAtTop(puff);

            LoopOffset(puff, new Vector3(x - 30f, y, 0f), new Vector3(x + 30f, y, 0f), Rand(50f, 80f), i * 1.0);
        }
    }

    // Final fog/haze veil over everything (keeps highlights from looking pasted on).
    private void BuildFogVeil(float w, float h, float intensity)
    {
        var veil = GradientRect(w, h, new[]
        {
            (0f, Color.FromArgb(0, 128, 128, 140)),
            (0.6f, Argb(intensity, 128, 128, 140)),
            (1f, Argb(intensity * 0.8f, 102, 102, 115)),
        });
        _root!.Children.InsertAtTop(veil);
    }

    // ---------------------------------------------------------------------------------
    //  COLOUR UTILITY
    // ---------------------------------------------------------------------------------

    private static Color HsvToColor(float h, float s, float v, float alpha)
    {
        h = ((h % 360f) + 360f) % 360f;
        var c = v * s;
        var x = c * (1f - Math.Abs((h / 60f) % 2f - 1f));
        var m = v - c;
        float r, g, b;
        if (h < 60f) { r = c; g = x; b = 0f; }
        else if (h < 120f) { r = x; g = c; b = 0f; }
        else if (h < 180f) { r = 0f; g = c; b = x; }
        else if (h < 240f) { r = 0f; g = x; b = c; }
        else if (h < 300f) { r = x; g = 0f; b = c; }
        else { r = c; g = 0f; b = x; }
        return Color.FromArgb(
            (byte)Math.Clamp(alpha * 255f, 0f, 255f),
            (byte)Math.Clamp((r + m) * 255f, 0f, 255f),
            (byte)Math.Clamp((g + m) * 255f, 0f, 255f),
            (byte)Math.Clamp((b + m) * 255f, 0f, 255f));
    }
}
