using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  DeviceDisplayPrefs — the change-notifying source the Device-Discovery peer cards bind their
//  display gates to. The DiscoveredPeerItemTemplate lives in the window's Resources (its own XAML
//  namescope), so a per-item DataTemplate cannot reach the page-level SessionViewModel via
//  ElementName/RelativeSource. ONE instance is declared as an application resource
//  (App.xaml x:Key="DeviceDisplayPrefs"); the SessionViewModel resolves that SAME instance from
//  Application.Current.Resources and the SettingsCoordinator effect sinks push
//  显示设备详情 / 紧凑模式 / 显示设备图标 into it. It raises PropertyChanged, so every peer card
//  re-reads live — observable, real. The cards bind:
//    • detail block Visibility ← ShowDetails (via BoolToVisibilityConverter)
//    • icon chip   Visibility ← ShowIcons   (via BoolToVisibilityConverter)
//    • card Padding ← CardPadding, icon Width/Height ← IconSize (compact density)
//  Plus each detail row keeps its own presence converter so a blank field still drops out.
//
//  Real state, not a fake: it carries the persisted defaults (details on, compact off, icons on)
//  until the sinks update it. Nothing here invents peer data.
// =====================================================================================

public sealed class DeviceDisplayPrefs : INotifyPropertyChanged
{
    private bool _showDetails = true;
    private bool _compact;
    private bool _showIcons = true;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>通用 > 界面 > 显示设备详情 — gates the peer card's DeviceId / Capabilities /
    /// Fingerprint / TrustSummary rows.</summary>
    public bool ShowDetails
    {
        get => _showDetails;
        set => Set(ref _showDetails, value);
    }

    /// <summary>通用 > 界面 > 紧凑模式 — tightens the peer card padding/icon size.</summary>
    public bool Compact
    {
        get => _compact;
        set
        {
            if (Set(ref _compact, value))
            {
                OnChanged(nameof(CardPadding));
                OnChanged(nameof(IconSize));
            }
        }
    }

    /// <summary>设备 > 过滤排序 > 显示设备图标 — gates the peer card's device-type icon chip.</summary>
    public bool ShowIcons
    {
        get => _showIcons;
        set => Set(ref _showIcons, value);
    }

    /// <summary>Card inner padding — tighter in compact mode (Mac density parity).</summary>
    public Thickness CardPadding => _compact ? new Thickness(10) : new Thickness(14);

    /// <summary>Device icon-chip side length — smaller in compact mode.</summary>
    public double IconSize => _compact ? 34 : 44;

    private bool Set(ref bool field, bool value, [CallerMemberName] string? name = null)
    {
        if (field == value)
        {
            return false;
        }

        field = value;
        OnChanged(name);
        return true;
    }

    private void OnChanged(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
