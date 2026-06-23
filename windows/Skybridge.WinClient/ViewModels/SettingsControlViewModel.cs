using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  SettingsControlViewModel — a SETTABLE, change-notifying view-model for ONE interactive
//  Settings control row (a tab view renders an ItemsControl of these inside each section card).
//
//  This is DELIBERATELY a class (not a record) and INotifyPropertyChanged with a TWO-WAY Value:
//  it is the parallel settable counterpart to WorkspaceItemViews' display-only
//  SettingsDetailItemView record (whose `IsSettable => false` is a contract-locked literal that
//  must NOT change). The collapsed flat-mirror keeps using that record for the gates; the live
//  cards bind to THIS type so toggles/dropdowns/sliders actually move and persist.
//
//  Wiring honesty (no fake/dead controls): the `Kind` declares what the row IS, and the cards
//  render accordingly. A row is ALWAYS one of:
//    • Toggle / Dropdown / Slider / TextField — a real REAL-FULL / REAL-PERSIST control whose
//      two-way Value round-trips through SettingsCoordinator → SettingsService → disk.
//    • Status        — a HARDWARE-REAL read (Wi-Fi SSID, Bluetooth state). Display-only, IsEnabled=false.
//    • Locked        — a LOCKED-STATUS row: force-on, read-only (cert validation, app-layer PQC).
//    • AppleOnly     — an OMIT-APPLE-ONLY row: disabled + captioned "macOS only", never faked.
//  The honest `Caption` carries the macOS-only / managed-by-Windows / not-yet-wired note so the
//  UI never pretends an inert control works.
// =====================================================================================

public enum SettableControlKind
{
    Toggle,
    Dropdown,
    Slider,
    TextField,
    Status,
    Locked,
    AppleOnly
}

public sealed class SettingsControlViewModel : INotifyPropertyChanged
{
    private string _label = string.Empty;
    private string _caption = string.Empty;
    private object? _value;
    private bool _isEnabled = true;

    public event PropertyChangedEventHandler? PropertyChanged;

    public SettingsControlViewModel(
        SettableControlKind kind,
        string label,
        object? value = null,
        IEnumerable<string>? options = null,
        double minimum = 0,
        double maximum = 0,
        double step = 0,
        bool isEnabled = true,
        string caption = "")
    {
        Kind = kind;
        _label = label ?? string.Empty;
        _value = value;
        _isEnabled = isEnabled;
        _caption = caption ?? string.Empty;
        Minimum = minimum;
        Maximum = maximum;
        Step = step;
        Options = options is null
            ? new ObservableCollection<string>()
            : new ObservableCollection<string>(options);
    }

    /// <summary>What this row IS — drives the DataTemplate selection in the card.</summary>
    public SettableControlKind Kind { get; }

    /// <summary>The control's display label (e.g. "启动时自动扫描设备").</summary>
    public string Label
    {
        get => _label;
        set => SetField(ref _label, value ?? string.Empty);
    }

    /// <summary>
    /// Honest caption shown under/beside the control: the macOS-only note, the
    /// "managed by Windows" / "not yet wired" disclosure, or a unit hint. Never implies a dead
    /// control works.
    /// </summary>
    public string Caption
    {
        get => _caption;
        set => SetField(ref _caption, value ?? string.Empty);
    }

    /// <summary>
    /// The TWO-WAY value. For Toggle this is a bool, Dropdown a string, Slider a double, TextField
    /// a string. The owning SettingsCoordinator subscribes to PropertyChanged on this row (or binds
    /// its own per-key property to it) so a user edit writes through to SettingsService.
    /// </summary>
    public object? Value
    {
        get => _value;
        set => SetField(ref _value, value);
    }

    /// <summary>Options for a Dropdown (empty otherwise).</summary>
    public ObservableCollection<string> Options { get; }

    /// <summary>Slider bounds + step (ignored for non-slider kinds).</summary>
    public double Minimum { get; }
    public double Maximum { get; }
    public double Step { get; }

    /// <summary>
    /// Whether the control is interactive. False for Status/Locked/AppleOnly rows and for a
    /// Dropdown/Slider gated behind a parent toggle (e.g. scan level disabled until virus-scan on).
    /// </summary>
    public bool IsEnabled
    {
        get => _isEnabled;
        set => SetField(ref _isEnabled, value);
    }

    // ---- Kind shortcuts for XAML visibility binding (no converter needed) ------------
    public bool IsToggle => Kind == SettableControlKind.Toggle;
    public bool IsDropdown => Kind == SettableControlKind.Dropdown;
    public bool IsSlider => Kind == SettableControlKind.Slider;
    public bool IsTextField => Kind == SettableControlKind.TextField;
    public bool IsStatus => Kind == SettableControlKind.Status;
    public bool IsLocked => Kind == SettableControlKind.Locked;
    public bool IsAppleOnly => Kind == SettableControlKind.AppleOnly;

    /// <summary>True for the read-only kinds (Status/Locked/AppleOnly) — never settable.</summary>
    public bool IsReadOnlyRow =>
        Kind is SettableControlKind.Status or SettableControlKind.Locked or SettableControlKind.AppleOnly;

    /// <summary>Whether a caption should render (non-empty).</summary>
    public bool HasCaption => !string.IsNullOrWhiteSpace(_caption);

    // ---- Typed convenience accessors -------------------------------------------------
    public bool BoolValue
    {
        get => _value is bool b && b;
        set => Value = value;
    }

    public string TextValue
    {
        get => _value as string ?? string.Empty;
        set => Value = value;
    }

    public double DoubleValue
    {
        get => _value switch
        {
            double d => d,
            int i => i,
            _ => 0
        };
        set => Value = value;
    }

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }

        field = value;
        OnPropertyChanged(propertyName);

        // When Value changes, the typed convenience accessors change too.
        if (propertyName == nameof(Value))
        {
            OnPropertyChanged(nameof(BoolValue));
            OnPropertyChanged(nameof(TextValue));
            OnPropertyChanged(nameof(DoubleValue));
        }

        if (propertyName == nameof(Caption))
        {
            OnPropertyChanged(nameof(HasCaption));
        }
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
