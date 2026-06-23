using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a settings detail row's <see cref="SettingsControlKind"/> to a
/// <see cref="Visibility"/> so the three control-row layouts (toggle / dropdown / value)
/// can co-exist in one DataTemplate and the right one shows itself based on the row's
/// honest, backend-derived kind. The desired kind is passed as the ConverterParameter
/// ("Toggle" / "Dropdown" / "Value"); the matching layer is Visible, the others Collapsed.
///
/// This is a pure view-state switch — it renders the control type that matches the kind the
/// backend value already implies (On/Off → toggle, "(default · A/B/C)" → dropdown, else →
/// value text). It invents nothing; an unrecognized parameter collapses the layer.
/// </summary>
public sealed class SettingsControlKindToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var kind = value is SettingsControlKind k ? k : SettingsControlKind.Value;
        var wanted = (parameter as string ?? string.Empty).Trim();

        var match = wanted switch
        {
            "Toggle" => kind == SettingsControlKind.Toggle,
            "Dropdown" => kind == SettingsControlKind.Dropdown,
            "Value" => kind == SettingsControlKind.Value,
            _ => false
        };

        return match ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps the currently <c>SelectedSettingsTab</c> (a <see cref="SettingsTabItemView"/>) to a
/// <see cref="Visibility"/> for the SettingsView master-detail HOST: the right pane stacks the
/// eight per-tab UserControls and shows exactly the one whose stable English tab title matches
/// the <c>ConverterParameter</c> (e.g. "General" / "Network" / … / "Advanced"). All others
/// collapse, so only the selected tab's content is realized/visible.
///
/// The match is on <see cref="SettingsTabItemView.Title"/> — the same stable key the right-pane
/// card projection already groups against (Section == Title). A null selection or an
/// unrecognized parameter collapses the layer. Pure view-state; invents nothing.
/// </summary>
public sealed class SettingsTabKeyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value switch
        {
            SettingsTabItemView tab => tab.Title,
            string s => s,
            _ => string.Empty
        };

        var wanted = (parameter as string ?? string.Empty).Trim();

        return !string.IsNullOrEmpty(wanted)
            && string.Equals(title, wanted, StringComparison.Ordinal)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a settings detail row's status <c>Value</c> string to a tint brush for the
/// right-aligned value-row status text, so honest "non-settable" markers read at a glance
/// the way the Mac SettingsView tints its read-only / platform-gated labels:
///   • "Core-owned" / "Read-only" / "Always on" / "policy-forced" → accent-secondary (cyan):
///     enforced-by-platform, not a user control.
///   • "macOS-only" / "OS-managed" / "OS-negotiated"              → muted gray:
///     not applicable / governed elsewhere.
///   • "Gated" / "Disabled" / "Not wired" / "Not persisted" /
///     "Not reported" / "Not scanned" / "Not requested"          → warning (amber):
///     present-but-inert, honestly flagged.
///   • everything else (live runtime reads, intent ids, plain values) → primary text.
/// Keyed off the backend's own honesty vocabulary — no fabricated state, no new strings.
/// </summary>
public sealed class SettingsValueStateToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var v = (value as string ?? string.Empty);
        var lower = v.ToLowerInvariant();

        string key;
        if (lower.Contains("core-owned") ||
            lower.Contains("read-only") ||
            lower.Contains("always on") ||
            lower.Contains("policy-forced") ||
            lower.Contains("strict-pqc"))
        {
            key = "SkyBridgeAccentSecondaryBrush";
        }
        else if (lower.Contains("macos-only") ||
                 lower.Contains("os-managed") ||
                 lower.Contains("os-negotiated"))
        {
            key = "SkyBridgeTextMutedBrush";
        }
        else if (lower.Contains("gated") ||
                 lower.Contains("disabled") ||
                 lower.Contains("not wired") ||
                 lower.Contains("not persisted") ||
                 lower.Contains("not reported") ||
                 lower.Contains("not scanned") ||
                 lower.Contains("not requested") ||
                 lower.Contains("unknown"))
        {
            key = "SkyBridgeWarningBrush";
        }
        else
        {
            key = "SkyBridgeTextPrimaryBrush";
        }

        return MetricKeyToBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
