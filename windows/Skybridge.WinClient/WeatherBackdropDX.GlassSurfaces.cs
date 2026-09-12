using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Skybridge.WinClient;

public sealed partial class WeatherBackdropDX
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct GlassSurfaceConstants
    {
        public Vector4 Bounds;
        public Vector4 Clip;
        public Vector4 Optics;
    }

    private readonly HashSet<Border> _registeredGlassSurfaces = new();
    private readonly HashSet<Border> _paintedGlassSurfaces = new();
    private readonly HashSet<Border> _nextPaintedGlassSurfaces = new();
    private readonly HashSet<ScrollViewer> _glassScrollViewers = new();
    private readonly HashSet<ScrollViewer> _nextGlassScrollViewers = new();
    private readonly List<(Border Border, GlassSurfaceConstants Data)> _visibleGlassSurfaces = new();
    private readonly SolidColorBrush _transparentGlassSurface = new(Microsoft.UI.Colors.Transparent);
    private GlassSurfaceConstants[] _glassSurfaces = new GlassSurfaceConstants[WeatherGlassGeometry.MaximumSurfaceCount];
    private GlassSurfaceConstants[] _nextGlassSurfaces = new GlassSurfaceConstants[WeatherGlassGeometry.MaximumSurfaceCount];
    private int _glassSurfaceCount;

    internal void RegisterGlassSurface(Border border)
    {
        _registeredGlassSurfaces.Add(border);
        RefreshGlassSurfaces();
    }

    internal void UnregisterGlassSurface(Border border)
    {
        _registeredGlassSurfaces.Remove(border);
        RestoreSurfaceBacking(border);
        RefreshGlassSurfaces();
    }

    // Called after layout, never by the per-frame animation loop. The shader sees only
    // visible outer panels; nested panels share their ancestor's glass material.
    internal void RefreshGlassSurfaces()
    {
        if (!_shaderReady || Panel.ActualWidth <= 0 || Panel.ActualHeight <= 0)
        {
            RestoreGlassSurfaceBackings();
            return;
        }
        _visibleGlassSurfaces.Clear();
        _nextGlassScrollViewers.Clear();
        foreach (Border border in _registeredGlassSurfaces)
        {
            if (TryGetGlassSurface(border, out GlassSurfaceConstants data))
            {
                _visibleGlassSurfaces.Add((border, data));
            }
        }
        _visibleGlassSurfaces.Sort(static (a, b) =>
        {
            int area = (b.Data.Bounds.Z * b.Data.Bounds.W).CompareTo(a.Data.Bounds.Z * a.Data.Bounds.W);
            return area != 0 ? area : GlassVisualDepth(a.Border).CompareTo(GlassVisualDepth(b.Border));
        });
        foreach (ScrollViewer viewer in _glassScrollViewers)
            if (!_nextGlassScrollViewers.Contains(viewer)) viewer.ViewChanged -= OnGlassScrollChanged;
        foreach (ScrollViewer viewer in _nextGlassScrollViewers)
            if (!_glassScrollViewers.Contains(viewer)) viewer.ViewChanged += OnGlassScrollChanged;
        _glassScrollViewers.Clear();
        _glassScrollViewers.UnionWith(_nextGlassScrollViewers);

        Array.Clear(_nextGlassSurfaces);
        GlassSurfaceConstants[] next = _nextGlassSurfaces;
        _nextPaintedGlassSurfaces.Clear();
        int count = 0;
        foreach (var surface in _visibleGlassSurfaces)
        {
            bool sharesAncestor = false;
            for (DependencyObject? node = VisualTreeHelper.GetParent(surface.Border); node is not null; node = VisualTreeHelper.GetParent(node))
            {
                if (node is Border ancestor && _nextPaintedGlassSurfaces.Contains(ancestor)) { sharesAncestor = true; break; }
            }
            if (!sharesAncestor)
            {
                if (count == WeatherGlassGeometry.MaximumSurfaceCount) continue;
                next[count++] = surface.Data;
            }
            _nextPaintedGlassSurfaces.Add(surface.Border);
        }

        foreach (Border previous in _paintedGlassSurfaces)
        {
            if (!_nextPaintedGlassSurfaces.Contains(previous) && ReferenceEquals(previous.ReadLocalValue(Border.BackgroundProperty), _transparentGlassSurface))
                previous.ClearValue(Border.BackgroundProperty);
        }
        _paintedGlassSurfaces.IntersectWith(_nextPaintedGlassSurfaces);
        bool changed = count != _glassSurfaceCount;
        for (int i = 0; !changed && i < count; i++)
        {
            changed = next[i].Bounds != _glassSurfaces[i].Bounds || next[i].Clip != _glassSurfaces[i].Clip || next[i].Optics != _glassSurfaces[i].Optics;
        }
        _nextGlassSurfaces = _glassSurfaces;
        _glassSurfaces = next;
        _glassSurfaceCount = count;
        if (changed) RequestFrame();
    }

    private bool TryGetGlassSurface(Border border, out GlassSurfaceConstants data)
    {
        data = default;
        if (border.XamlRoot != XamlRoot || border.ActualWidth <= 0 || border.ActualHeight <= 0) return false;
        object localBackground = border.ReadLocalValue(Border.BackgroundProperty);
        // Preserve a caller's explicit brush or binding. Only style-owned panel backgrounds
        // are replaced, and ClearValue restores the current style on unload/device loss.
        if (localBackground != DependencyProperty.UnsetValue && !ReferenceEquals(localBackground, _transparentGlassSurface)) return false;
        CornerRadius radius = border.CornerRadius;
        if (radius.TopLeft != radius.TopRight || radius.TopLeft != radius.BottomLeft || radius.TopLeft != radius.BottomRight) return false;

        Rect bounds = border.TransformToVisual(this).TransformBounds(new Rect(0, 0, border.ActualWidth, border.ActualHeight));
        Rect clip = new(0, 0, Panel.ActualWidth, Panel.ActualHeight);
        for (DependencyObject? node = border; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is UIElement element && (element.Visibility != Visibility.Visible || element.Opacity <= 0)) return false;
            if (node is ScrollViewer scroll)
            {
                _nextGlassScrollViewers.Add(scroll);
                Rect viewport = scroll.TransformToVisual(this).TransformBounds(new Rect(0, 0, scroll.ActualWidth, scroll.ActualHeight));
                clip = IntersectGlassRects(clip, viewport);
            }
        }
        Rect visible = IntersectGlassRects(bounds, clip);
        if (visible.Width <= 0 || visible.Height <= 0) return false;
        float width = (float)Panel.ActualWidth, height = (float)Panel.ActualHeight;
        data.Bounds = new((float)bounds.X / width, (float)bounds.Y / height, (float)bounds.Width / width, (float)bounds.Height / height);
        // Keep the ancestor viewport separate from the panel silhouette: water can hang
        // below a panel's lip, but must never escape the scrolling viewport.
        data.Clip = new((float)clip.X / width, (float)clip.Y / height, (float)clip.Width / width, (float)clip.Height / height);
        data.Optics = new((float)radius.TopLeft / height, (RuntimeHelpers.GetHashCode(border) & 0xFFFF) / 2048f, 0, 0);
        return true;
    }

    private static Rect IntersectGlassRects(Rect a, Rect b)
    {
        double x = Math.Max(a.X, b.X), y = Math.Max(a.Y, b.Y);
        return new Rect(x, y, Math.Max(0, Math.Min(a.Right, b.Right) - x), Math.Max(0, Math.Min(a.Bottom, b.Bottom) - y));
    }

    private static int GlassVisualDepth(DependencyObject node)
    {
        int depth = 0;
        for (DependencyObject? parent = VisualTreeHelper.GetParent(node); parent is not null; parent = VisualTreeHelper.GetParent(parent)) depth++;
        return depth;
    }

    private void RestoreSurfaceBacking(Border border)
    {
        if (_paintedGlassSurfaces.Remove(border) && ReferenceEquals(border.ReadLocalValue(Border.BackgroundProperty), _transparentGlassSurface))
            border.ClearValue(Border.BackgroundProperty);
    }

    private void OnGlassScrollChanged(object? sender, ScrollViewerViewChangedEventArgs args) => RefreshGlassSurfaces();

    private void CommitGlassSurfaceBackings()
    {
        // Keep the readable XAML backing until a frame containing these surfaces was submitted.
        foreach (Border border in _nextPaintedGlassSurfaces)
        {
            object local = border.ReadLocalValue(Border.BackgroundProperty);
            if (local != DependencyProperty.UnsetValue && !ReferenceEquals(local, _transparentGlassSurface)) continue;
            _paintedGlassSurfaces.Add(border);
            if (!ReferenceEquals(border.Background, _transparentGlassSurface)) border.Background = _transparentGlassSurface;
        }
    }

    private void RestoreGlassSurfaceBackings()
    {
        foreach (Border border in _paintedGlassSurfaces)
        {
            if (ReferenceEquals(border.ReadLocalValue(Border.BackgroundProperty), _transparentGlassSurface)) border.ClearValue(Border.BackgroundProperty);
        }
        _paintedGlassSurfaces.Clear();
        _nextPaintedGlassSurfaces.Clear();
        foreach (ScrollViewer viewer in _glassScrollViewers) viewer.ViewChanged -= OnGlassScrollChanged;
        _glassScrollViewers.Clear();
        _glassSurfaceCount = 0;
        Array.Clear(_glassSurfaces);
        Array.Clear(_nextGlassSurfaces);
    }
}
