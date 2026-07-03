using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.ViewModels;
using Windows.Graphics;
using Windows.UI;

namespace Skybridge.WinClient;

public sealed partial class MainWindow : Window
{
    // Match the macOS app's window proportions (VisualParity windowSize = 1200x800, 3:2),
    // instead of the stretched WinUI default that read as "a long strip". The Mac is the
    // parity target, so the Windows shell opens at the same aspect, centered.
    private const int DefaultWidth = 1200;
    private const int DefaultHeight = 800;

    public SessionViewModel ViewModel { get; }

    public MainWindow()
    {
        InitializeComponent();
        ViewModel = new SessionViewModel(SessionViewModelDependencyFactory.CreateConfigured());
        RootShell.DataContext = ViewModel;

        // Subscribe to the two Settings theme effects the VM cannot host itself (it has no
        // FrameworkElement). The VM raises these from the SettingsCoordinator's live-effect hooks
        // (on a settings change and once at startup via ApplyInitialEffects). MainWindow owns the
        // RootShell FrameworkElement + the Application resources, so it applies them here.
        ViewModel.DarkModeEffectRequested += OnDarkModeEffectRequested;
        ViewModel.AccentColorEffectRequested += OnAccentColorEffectRequested;

        // Provide the Settings Export/Import file pickers (they need this window's HWND, which the
        // VM cannot reach). The EXISTING Export/Import toolbar actions call these to get a path,
        // then the real SettingsCoordinator.ExportTo/ImportFrom runs — no new command, no new button.
        ViewModel.ExportSettingsPathRequested = PickExportSettingsPathAsync;
        ViewModel.ImportSettingsPathRequested = PickImportSettingsPathAsync;

        // Apply the persisted theme + accent ONCE here, after subscribing. The VM's
        // ApplyInitialEffects (in its ctor) ran before these handlers were attached, so its
        // theme/accent events had no listener yet — every other effect (pills, DD prefs, logger,
        // discovery, signal) is applied via VM props/resources and already took. We close that gap
        // by reading the live persisted values straight off the coordinator and applying them now.
        OnDarkModeEffectRequested(ViewModel.Settings.UseDarkMode);
        OnAccentColorEffectRequested(ViewModel.Settings.ThemeColorHex);

        SizeAndCenter();

        // Restore a remembered Supabase session (DPAPI) on launch so the account block shows
        // the real signed-in user without a tap. Queued on the UI dispatcher: HydrateFromStore
        // touches the network + the VM's UI-thread-affine SetField props, and it must run after
        // the window is up. It never throws (the coordinator swallows all failures internally).
        DispatcherQueue.TryEnqueue(async () =>
        {
            await ViewModel.HydrateFromStoreAsync();
        });

        // Stop the real runtime lifecycle when the window closes: native Core engine, WebRTC
        // adapters, settings timers, and top-bar telemetry must not outlive the UI.
        Closed += OnWindowClosed;
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        ViewModel.DarkModeEffectRequested -= OnDarkModeEffectRequested;
        ViewModel.AccentColorEffectRequested -= OnAccentColorEffectRequested;
        ViewModel.Dispose();
    }

    // 启用深色模式 live effect: set the root FrameworkElement.RequestedTheme. The app ships
    // dark-locked at App.xaml (RequestedTheme="Dark"); overriding it on the root content element
    // re-themes the whole visual tree live. Non-throwing — a theme set never faults, but guard the
    // root just in case it is not yet realized.
    private void OnDarkModeEffectRequested(bool useDark)
    {
        if (RootShell is { } root)
        {
            root.RequestedTheme = useDark ? ElementTheme.Dark : ElementTheme.Light;
        }
    }

    // 主题颜色 live effect: override the SkyBridgeAccentColor + SkyBridgeAccentBrush application
    // resources with the chosen hex and re-tint. Every surface that uses
    // {StaticResource SkyBridgeAccentBrush} re-reads on the next layout pass; we nudge the root's
    // RequestedTheme to force an immediate resource re-evaluation. Defensive parse — an invalid hex
    // leaves the accent untouched (never crashes, never blanks the accent).
    private void OnAccentColorEffectRequested(string hex)
    {
        if (!TryParseHexColor(hex, out var color))
        {
            return;
        }

        var resources = Application.Current?.Resources;
        if (resources is null)
        {
            return;
        }

        resources["SkyBridgeAccentColor"] = color;
        resources["SkyBridgeAccentBrush"] = new SolidColorBrush(color);

        // Force a re-tint: toggle the root theme to itself so StaticResource consumers re-resolve.
        if (RootShell is { } root)
        {
            var current = root.RequestedTheme;
            root.RequestedTheme = current == ElementTheme.Dark ? ElementTheme.Default : ElementTheme.Dark;
            root.RequestedTheme = current;
        }
    }

    // Parse "#RRGGBB" / "#AARRGGBB" (and the 6/8-digit forms without '#') into a Color. Returns
    // false on any malformed input — the caller then leaves the accent unchanged.
    private static bool TryParseHexColor(string? hex, out Color color)
    {
        color = default;
        var s = (hex ?? string.Empty).Trim().TrimStart('#');
        if (s.Length == 6)
        {
            s = "FF" + s; // assume opaque
        }

        if (s.Length != 8 ||
            !byte.TryParse(s.Substring(0, 2), System.Globalization.NumberStyles.HexNumber, null, out var a) ||
            !byte.TryParse(s.Substring(2, 2), System.Globalization.NumberStyles.HexNumber, null, out var r) ||
            !byte.TryParse(s.Substring(4, 2), System.Globalization.NumberStyles.HexNumber, null, out var g) ||
            !byte.TryParse(s.Substring(6, 2), System.Globalization.NumberStyles.HexNumber, null, out var b))
        {
            return false;
        }

        color = Color.FromArgb(a, r, g, b);
        return true;
    }

    // The sidebar account block was Tapped. This used to open a ContentDialog (SignInDialog /
    // sign-out confirm) via an async-void ShowAsync — which CRASHED the process: ShowAsync
    // throws ArgumentException/COMException for the single-open-dialog rule and for an
    // invalid/stale XamlRoot, and on the async-void path that exception tears down the app.
    //
    // It is now a trivial, synchronous, non-throwing flip of a VM flag: the VM routes to the
    // in-window AuthOverlay (signed out) or UserProfileOverlay (signed in), each a UserControl
    // layer already in the visual tree. No XamlRoot, no single-dialog rule, no ShowAsync — the
    // entire crash class is gone. Sign-in runs through ViewModel.SignInWithEmailAsync (which
    // calls the same coordinator/auth seam as before); sign-out still binds to SignOutCommand
    // (surfaced inside the profile/auth UI flows), unchanged.
    private void OnAccountBlockTapped(object sender, TappedRoutedEventArgs e)
    {
        ViewModel.ToggleAccountOverlay();
    }

    // BATCH 1 — view-state selection via Border.Tapped (NOT a raw Button, so the gated
    // inline-<Button> budget is unchanged). Each tappable Border carries its mode/tab in
    // FrameworkElement.Tag; the handler parses it and routes to the VM's pure view-state
    // setter. Mirrors the Mac segmented controls / modernTabBar selection.

    // Device Discovery connection-mode tab tapped (Tag = LocalScan / Qr / Cloud / Code).
    private void OnDiscoveryModeTabTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement element &&
            element.Tag is string tag &&
            Enum.TryParse<DiscoveryMode>(tag, ignoreCase: true, out var mode))
        {
            ViewModel.SelectDiscoveryMode(mode);
        }
    }

    // Remote Desktop connection-mode segment tapped (Tag = Auto / Near / Far).
    private void OnRemoteDesktopModeTabTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement element &&
            element.Tag is string tag &&
            Enum.TryParse<RemoteDesktopConnectionMode>(tag, ignoreCase: true, out var mode))
        {
            ViewModel.SelectRemoteDesktopMode(mode);
        }
    }

    // File Transfer segmented tab tapped (Tag = "0" Transfer / "1" History).
    private void OnFileTransferTabTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement element &&
            element.Tag is string tag &&
            int.TryParse(tag, out var tab))
        {
            ViewModel.SelectFileTransferTab(tab);
        }
    }

    // BATCH 2 — A13: System Monitor advanced-monitoring banner tapped. Routes through the
    // EXISTING, real EnableAdvancedSystemMonitoringCommand (in-memory honest advanced client)
    // when it is currently executable; the whole Border is the affordance (no raw Button).
    private void OnEnableAdvancedMonitoringBannerTapped(object sender, TappedRoutedEventArgs e)
    {
        var command = ViewModel.EnableAdvancedSystemMonitoringCommand;
        if (command is not null && command.CanExecute(null))
        {
            command.Execute(null);
        }
    }

    // BATCH 2 — B1: smart-connection-code lease-mode segment tapped (Tag = ShortLived / DayStable).
    // Sets the real lease mode that drives the generated-code TTL (no raw Button).
    private void OnConnectionCodeLeaseModeTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement element &&
            element.Tag is string tag &&
            Enum.TryParse<Skybridge.WinClient.Services.CrossNetworkCodeLeaseMode>(tag, ignoreCase: true, out var mode))
        {
            ViewModel.SelectConnectionCodeLeaseMode(mode);
        }
    }

    // Export settings: a FileSavePicker initialized with this window's HWND (required unpackaged).
    // Returns the chosen path, or null on cancel. Defensive — any picker failure yields null and
    // the action reports the honest cancel/fail message.
    private async System.Threading.Tasks.Task<string?> PickExportSettingsPathAsync()
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileSavePicker
            {
                SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
                SuggestedFileName = "skybridge-settings",
            };
            picker.FileTypeChoices.Add("SkyBridge settings", new System.Collections.Generic.List<string> { ".json" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSaveFileAsync();
            return file?.Path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Import settings: a FileOpenPicker initialized with this window's HWND. Returns the chosen
    // path, or null on cancel/failure.
    private async System.Threading.Tasks.Task<string?> PickImportSettingsPathAsync()
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker
            {
                SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
            };
            picker.FileTypeFilter.Add(".json");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            return file?.Path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private void SizeAndCenter()
    {
        var appWindow = AppWindow;
        if (appWindow is null)
        {
            return;
        }

        var work = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary)?.WorkArea;
        // Clamp to the work area so the 3:2 window still fits smaller displays without clipping.
        var width = work is { } w ? System.Math.Min(DefaultWidth, w.Width) : DefaultWidth;
        var height = work is { } h ? System.Math.Min(DefaultHeight, h.Height) : DefaultHeight;
        appWindow.Resize(new SizeInt32(width, height));

        if (work is { } area)
        {
            appWindow.Move(new PointInt32(
                area.X + System.Math.Max(0, (area.Width - width) / 2),
                area.Y + System.Math.Max(0, (area.Height - height) / 2)));
        }
    }

    // Ctrl+Shift+Down / Ctrl+Shift+Up — move the selected sidebar feature, matching the
    // macOS app's Cmd+Shift+Up/Down sidebar navigation. The NavigationView's SelectedItem is
    // TwoWay-bound to ViewModel.SelectedFeature, so setting it here drives both the highlight
    // and the content pane.
    private void OnSidebarNavigateNext(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = MoveSidebarSelection(1);
    }

    private void OnSidebarNavigatePrevious(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = MoveSidebarSelection(-1);
    }

    private bool MoveSidebarSelection(int delta)
    {
        var items = ViewModel.NavigationItems;
        if (items.Count == 0)
        {
            return false;
        }

        var currentIndex = ViewModel.SelectedFeature is { } current ? items.IndexOf(current) : -1;
        var nextIndex = System.Math.Clamp(currentIndex + delta, 0, items.Count - 1);
        if (nextIndex == currentIndex)
        {
            return false;
        }

        ViewModel.SelectedFeature = items[nextIndex];
        return true;
    }
}
