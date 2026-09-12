using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.Services;
using Windows.UI;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Gives every sidebar row its Mac GlassSidebar colouring when NavigationView prepares the
/// row's container. On the Mac each tab owns a colour: the glyph wears it at rest, and the
/// selected row becomes a rounded pill filled with that colour's gradient under a white glyph
/// (SwiftUI <c>tab.color.gradient</c>). WinUI's stock NavigationViewItemPresenter paints those
/// states from theme keys, so this selector stamps per-row overrides of exactly those keys into
/// the container's resources (lightweight styling) and sets the rest-state foreground. It adds
/// no style of its own: the built-in NavigationViewItem style remains the base (the pill radius
/// is set on the container from the SkyBridgeSidebarPillCornerRadius token), and the presenter
/// keeps hover, focus, keyboarding
/// and the UI Automation peers the smoke gate walks. Runs again when a container is recycled,
/// so a row never carries another feature's colour.
/// </summary>
public sealed class SidebarItemStyleSelector : StyleSelector
{
    protected override Style SelectStyleCore(object item, DependencyObject container)
    {
        if (container is not NavigationViewItem row)
        {
            throw new InvalidOperationException(
                $"{nameof(SidebarItemStyleSelector)} expects NavigationViewItem containers; got {container?.GetType().Name ?? "null"}.");
        }

        if (item is not FeatureEntry feature)
        {
            throw new InvalidOperationException(
                $"Sidebar items must be {nameof(FeatureEntry)}; got {item?.GetType().Name ?? "null"}.");
        }

        SolidColorBrush accent = FeatureAccentBrushes.Resolve(feature.Id);
        LinearGradientBrush pill = SelectionPill(accent.Color);

        // Mac pill radius. NavigationViewItem.CornerRadius is template-bound into the stock
        // presenter; the built-in style sets it from ControlCornerRadius (4), and a local value
        // on the container overrides that setter without touching the template.
        row.CornerRadius = PillCornerRadius();

        // Rest state: the glyph inherits this through the presenter; the label paints itself.
        row.Foreground = accent;

        ResourceDictionary overrides = row.Resources;
        overrides["NavigationViewItemBackgroundSelected"] = pill;
        // The Mac's selected pill has no hover or pressed variant.
        overrides["NavigationViewItemBackgroundSelectedPointerOver"] = pill;
        overrides["NavigationViewItemBackgroundSelectedPressed"] = pill;
        // Hovering an unselected row keeps the glyph's colour (the Mac only adds a frosted patch).
        overrides["NavigationViewItemForegroundPointerOver"] = accent;
        overrides["NavigationViewItemForegroundPressed"] = accent;

        return base.SelectStyleCore(item, container);
    }

    private static CornerRadius PillCornerRadius()
    {
        const string key = "SkyBridgeSidebarPillCornerRadius";
        if (Application.Current.Resources.TryGetValue(key, out object? value) && value is CornerRadius radius)
        {
            return radius;
        }

        throw new InvalidOperationException($"App.xaml must define {key} as a CornerRadius.");
    }

    // SwiftUI Color.gradient: the colour itself, lighter at the top and darker at the bottom.
    private static LinearGradientBrush SelectionPill(Color accent)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0, 1),
        };
        brush.GradientStops.Add(new GradientStop { Color = Shade(accent, 0.12), Offset = 0.0 });
        brush.GradientStops.Add(new GradientStop { Color = Shade(accent, -0.12), Offset = 1.0 });
        return brush;
    }

    // amount > 0 mixes toward white, amount < 0 toward black; alpha is preserved.
    private static Color Shade(Color color, double amount)
    {
        double target = amount >= 0 ? 255.0 : 0.0;
        double t = Math.Abs(amount);
        byte Mix(byte channel) => (byte)Math.Clamp(Math.Round(channel + (target - channel) * t), 0, 255);
        return Color.FromArgb(color.A, Mix(color.R), Mix(color.G), Mix(color.B));
    }
}
