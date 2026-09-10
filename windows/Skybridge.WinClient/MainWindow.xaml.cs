using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.ViewModels;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.UI;

namespace Skybridge.WinClient;

public sealed partial class MainWindow : Window
{
    // Match the macOS app's logical window proportions (VisualParity windowSize =
    // 1200x800, 3:2), instead of treating those device-independent dimensions as raw
    // Win32 screen pixels. AppWindow.Resize consumes screen coordinates, so the requested
    // size must be scaled for the window's current monitor DPI first.
    private const int DefaultWidth = 1200;
    private const int DefaultHeight = 800;
    private const uint DefaultDpi = 96;

    public SessionViewModel ViewModel { get; }
    public RemoteControlHostViewModel RemoteControlHost { get; }
    private readonly WindowsDeviceWorkspace _remoteControlWorkspace = new();
    private readonly FileTransferWorkspaceClient _fileTransferWorkspace;
    private RemoteControl.RemoteControlViewerWindow? _remoteControlViewer;
    private Window? _remoteControlNotice;
    private bool _closingRemoteControlNotice;
    private bool _hostShutdownInProgress;
    private bool _hostShutdownComplete;
    private readonly Microsoft.Windows.ApplicationModel.Resources.ResourceLoader _remoteControlResources = new();

    public MainWindow()
    {
        InitializeComponent();

        // The taskbar button, Alt-Tab entry and window chrome all read Window.Title. WinUI
        // leaves it at the project-template default ("WinUI Desktop") unless it is set, and
        // that default was what shipped. The Mac creates its window as
        // WindowGroup(localizedString("app.name")), so the same localized product name is
        // used here — read from the PRI resources rather than hardcoded, so it follows the
        // trilingual selection App.OnLaunched already applies.
        Title = ResolveWindowTitle();
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "SkyBridgeCompass.ico"));
        ConfigureShellGlass();
        ConfigureTitleBar();

        _fileTransferWorkspace = new(_remoteControlWorkspace, new NativeFileTransferSelection(this),
            ReadCurrentDeviceAccount, RemoteControlText);
        ViewModel = new SessionViewModel(SessionViewModelDependencyFactory.CreateConfigured(_fileTransferWorkspace));
        _fileTransferWorkspace.Changed += OnFileTransferChanged;
        ViewModel.PropertyChanged += OnFileTransferAccountChanged;
        RootShell.DataContext = ViewModel;
        RemoteControlHost = new RemoteControlHostViewModel(
            _remoteControlWorkspace,
            RemoteControlText,
            CopyRemoteControlPairingTextAsync,
            ReadRemoteControlPairingTextAsync,
            action =>
            {
                if (!DispatcherQueue.TryEnqueue(() => action()) && !_hostShutdownComplete)
                {
                    throw new InvalidOperationException("The remote-control status could not be presented in the application window.");
                }
            });
        RemoteControlHostPanel.DataContext = RemoteControlHost;
        RemoteControlHostBanner.DataContext = RemoteControlHost;
        RemoteControlHost.ConnectedNoticeChanged += OnRemoteControlNoticeChanged;
        ViewModel.NearFieldRemoteDesktopRequested += OnNearFieldRemoteDesktopRequested;
        AppWindow.Closing += OnWindowClosing;

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
        // the window is up. Expected auth/storage failures remain typed and visible.
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
        AppWindow.Closing -= OnWindowClosing;
        AppWindow.Changed -= OnAppWindowChangedForChrome;
        if (_chromeScaleChanged is not null && RootShell.XamlRoot is not null)
        {
            RootShell.XamlRoot.Changed -= _chromeScaleChanged;
        }

        if (_chromeLayoutUpdated is not null)
        {
            RootShell.LayoutUpdated -= _chromeLayoutUpdated;
        }

        if (_glassLayoutUpdated is not null)
        {
            RootShell.LayoutUpdated -= _glassLayoutUpdated;
        }

        RemoteControlHost.ConnectedNoticeChanged -= OnRemoteControlNoticeChanged;
        ViewModel.NearFieldRemoteDesktopRequested -= OnNearFieldRemoteDesktopRequested;
        ViewModel.DarkModeEffectRequested -= OnDarkModeEffectRequested;
        ViewModel.AccentColorEffectRequested -= OnAccentColorEffectRequested;
        _fileTransferWorkspace.Changed -= OnFileTransferChanged;
        ViewModel.PropertyChanged -= OnFileTransferAccountChanged;
        ViewModel.Dispose();
    }

    private async void OnWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_hostShutdownComplete) return;
        args.Cancel = true;
        if (_hostShutdownInProgress) return;
        _hostShutdownInProgress = true;
        try
        {
            if (_remoteControlViewer is { } viewer) await viewer.CloseForShutdownAsync();
            await _fileTransferWorkspace.DisposeAsync();
            await RemoteControlHost.DisposeAsync();
            _hostShutdownComplete = true;
            OnRemoteControlNoticeChanged(false);
            Close();
        }
        catch (Exception error)
        {
            _hostShutdownInProgress = false;
            RemoteControlHost.ReportError(error);
        }
    }

    private void OnNearFieldRemoteDesktopRequested()
    {
        try
        {
            if (_remoteControlViewer is { } existing) { existing.Activate(); return; }
            var position = AppWindow.Position;
            var size = AppWindow.Size;
            var viewer = new RemoteControl.RemoteControlViewerWindow(_remoteControlWorkspace, ViewModel.DiscoveredPeers,
                ViewModel.RefreshRemoteDesktopPeersAsync, RemoteControlText,
                ReadCurrentDeviceAccount,
                new RectInt32(position.X, position.Y, size.Width, size.Height));
            _remoteControlViewer = viewer;
            viewer.Closed += (_, _) => { if (ReferenceEquals(_remoteControlViewer, viewer)) _remoteControlViewer = null; };
            viewer.Activate();
        }
        catch (Exception failure) { ViewModel.ReportRemoteDesktopError(failure); }
    }

    private void OnRemoteControlNoticeChanged(bool connected)
    {
        if (!connected)
        {
            if (!_hostShutdownComplete && RemoteControlHost.IsEnabled && RemoteControlHost.HasError) return;
            if (_remoteControlNotice is not { } notice) return;
            _closingRemoteControlNotice = true;
            _remoteControlNotice = null;
            notice.Close();
            _closingRemoteControlNotice = false;
            return;
        }

        if (_remoteControlNotice is not null) return;
        var window = new Window
        {
            Title = RemoteControlText("RemoteControlHostNoticeWindowTitle"),
            Content = new RemoteControl.RemoteControlHostBanner { DataContext = RemoteControlHost }
        };
        _remoteControlNotice = window;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = true;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.Closing += async (_, args) =>
        {
            if (_closingRemoteControlNotice || _hostShutdownComplete) return;
            args.Cancel = true;
            await RemoteControlHost.SetEnabledAsync(false);
        };
        window.Activate();
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var scale = GetDpiForWindow(handle) / (double)DefaultDpi;
        var display = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest);
        var width = (int)Math.Round(540 * scale);
        var height = (int)Math.Round(440 * scale);
        if (display is not null)
        {
            width = Math.Min(width, Math.Max(1, display.WorkArea.Width - 32));
            height = Math.Min(height, Math.Max(1, display.WorkArea.Height - 32));
        }
        window.AppWindow.Resize(new SizeInt32(width, height));
        if (display is not null)
        {
            var bounds = window.AppWindow.Size;
            window.AppWindow.Move(new PointInt32(
                display.WorkArea.X + Math.Max(0, display.WorkArea.Width - bounds.Width - 16),
                display.WorkArea.Y + 16));
        }
    }

    private string RemoteControlText(string key)
    {
        var value = _remoteControlResources.GetString(key);
        return string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"The remote-control text resource '{key}' is missing.")
            : value;
    }

    // Feature operations invoke this after startup, so both features read the same
    // current account without publishing a second cached account identity.
    private RemoteControlViewerAccount? ReadCurrentDeviceAccount() => ViewModel.IsSignedIn
        ? new RemoteControlViewerAccount(ViewModel.DisplayName, ViewModel.NebulaId) : null;

    private static Task CopyRemoteControlPairingTextAsync(string value)
    {
        var package = new DataPackage();
        package.SetText(value);
        Clipboard.SetContent(package);
        Clipboard.Flush();
        return Task.CompletedTask;
    }

    private static async Task<string> ReadRemoteControlPairingTextAsync()
    {
        var content = Clipboard.GetContent();
        return content.Contains(StandardDataFormats.Text) ? await content.GetTextAsync() : string.Empty;
    }

    // Resolve the localized product name for Window.Title from the app PRI. The literal
    // fallback is the en-US value of the same resource, so a resource-loader failure still
    // shows the product name rather than reintroducing "WinUI Desktop".
    private static string ResolveWindowTitle()
    {
        const string Fallback = "SkyBridge Compass";

        try
        {
            var value = new Microsoft.Windows.ApplicationModel.Resources.ResourceLoader()
                .GetString("AppWindowTitle");
            return string.IsNullOrWhiteSpace(value) ? Fallback : value;
        }
        catch (Exception)
        {
            return Fallback;
        }
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

        var windowHandle = Microsoft.UI.Win32Interop.GetWindowFromWindowId(appWindow.Id);
        var dpi = GetDpiForWindow(windowHandle);
        if (dpi == 0)
        {
            throw new InvalidOperationException("Unable to resolve the WinUI window DPI before sizing.");
        }

        var desiredWidth = ScaleLogicalPixels(DefaultWidth, dpi);
        var desiredHeight = ScaleLogicalPixels(DefaultHeight, dpi);
        var work = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary)?.WorkArea;

        // AppWindow and DisplayArea both use screen coordinates. Fit the DPI-scaled 3:2
        // rectangle inside a smaller work area as one unit so clamping cannot distort it.
        var fitScale = work is { } available
            ? System.Math.Min(1d, System.Math.Min(
                available.Width / (double)desiredWidth,
                available.Height / (double)desiredHeight))
            : 1d;
        var width = System.Math.Max(1, (int)System.Math.Round(desiredWidth * fitScale));
        var height = System.Math.Max(1, (int)System.Math.Round(desiredHeight * fitScale));
        appWindow.Resize(new SizeInt32(width, height));

        if (work is { } area)
        {
            appWindow.Move(new PointInt32(
                area.X + System.Math.Max(0, (area.Width - width) / 2),
                area.Y + System.Math.Max(0, (area.Height - height) / 2)));
        }
    }

    private static int ScaleLogicalPixels(int logicalPixels, uint dpi) =>
        checked((int)System.Math.Round(
            logicalPixels * (dpi / (double)DefaultDpi),
            MidpointRounding.AwayFromZero));

    // Window chrome, Mac parity: the macOS window is `.windowStyle(.hiddenTitleBar)`, so the app's
    // own top strip is the title bar. The AppWindow title bar API is used rather than
    // Window.SetTitleBar because only it lets the caption (drag) area and the interactive
    // pass-through areas be stated as explicit rectangles: the top bar and the sidebar header drag
    // the window, while the telemetry strip and the action buttons inside the top bar keep their
    // tooltips, scrolling and clicks (under Window.SetTitleBar the whole element is caption,
    // whatever sits above it in z-order). The system caption buttons draw transparent over the
    // glass, and the top bar reserves their width on its right so the actions never sit under them.
    private void ConfigureTitleBar()
    {
        if (!AppWindowTitleBar.IsCustomizationSupported())
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Warning,
                "window",
                "AppWindow title bar customization is not supported here; the system title bar stays visible.");
            return;
        }

        AppWindowTitleBar titleBar = AppWindow.TitleBar;
        titleBar.ExtendsContentIntoTitleBar = true;
        // 48px caption buttons sit inside the 56px top bar instead of the 32px default strip.
        titleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        ApplyCaptionButtonColors();

        RootShell.Loaded += OnRootShellLoadedForChrome;
        // The caption buttons, and with them RightInset, exist once the window is shown; the window
        // reports that through AppWindow.Changed before any XAML layout that follows it.
        AppWindow.Changed += OnAppWindowChangedForChrome;
    }

    // Handlers kept so OnWindowClosed can detach them like the other window subscriptions.
    private Windows.Foundation.TypedEventHandler<XamlRoot, XamlRootChangedEventArgs>? _chromeScaleChanged;
    private EventHandler<object>? _chromeLayoutUpdated;
    private EventHandler<object>? _glassLayoutUpdated;

    private void OnRootShellLoadedForChrome(object sender, RoutedEventArgs e)
    {
        RootShell.Loaded -= OnRootShellLoadedForChrome;
        if (RootShell.XamlRoot is null)
        {
            throw new InvalidOperationException("The shell content has no XamlRoot at Loaded; the window chrome cannot be laid out.");
        }

        LayOutWindowChrome();
        _chromeScaleChanged = (_, _) => LayOutWindowChrome();      // scale changes
        RootShell.XamlRoot.Changed += _chromeScaleChanged;
        // Elements inside the top bar move when the caption-button column is reserved or the
        // window resizes; a move without a size change only shows up as a layout pass, so the
        // regions are re-derived after every pass and re-applied only when they differ.
        _chromeLayoutUpdated = (_, _) => ApplyNonClientRegions();
        RootShell.LayoutUpdated += _chromeLayoutUpdated;
    }

    private void OnAppWindowChangedForChrome(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidVisibilityChange || args.DidSizeChange || args.DidPresenterChange)
        {
            LayOutWindowChrome();
        }
    }

    private void LayOutWindowChrome()
    {
        // Before the content has a XamlRoot there is nothing to measure; the Loaded pass follows.
        if (RootShell.XamlRoot is null || TopBarChrome.ActualWidth <= 0)
        {
            return;
        }

        ReserveCaptionButtonsWidth(RootShell.XamlRoot.RasterizationScale);
        ApplyNonClientRegions();
    }

    // Shell glass: the weather renderer frosts the sidebar and the top bar itself (with its swap
    // chain attached, XAML acrylic is not available; see WeatherBackdropDX). It needs the two
    // rects in its own dip space after every layout pass, whether or not the title bar could be
    // customized, so this subscription is independent of ConfigureTitleBar.
    private void ConfigureShellGlass()
    {
        RootShell.Loaded += OnRootShellLoadedForGlass;
    }

    private void OnRootShellLoadedForGlass(object sender, RoutedEventArgs e)
    {
        RootShell.Loaded -= OnRootShellLoadedForGlass;
        ApplyGlassRegions();
        _glassLayoutUpdated = (_, _) => ApplyGlassRegions();
        RootShell.LayoutUpdated += _glassLayoutUpdated;
    }

    private (double, double, double, double, double) _glassSignature;

    // The sidebar is the NavigationView pane: RootShell has no rows, so the pane spans the whole
    // shell height at the open (or compact) pane width. The top bar is its own element.
    private void ApplyGlassRegions()
    {
        if (WeatherBackdrop.ActualWidth <= 0 || RootShell.ActualHeight <= 0 || TopBarChrome.ActualWidth <= 0)
        {
            return;
        }

        double paneWidth = SidebarNavigation.IsPaneOpen ? SidebarNavigation.OpenPaneLength : SidebarNavigation.CompactPaneLength;
        var signature = (WeatherBackdrop.ActualWidth, WeatherBackdrop.ActualHeight, RootShell.ActualHeight, TopBarChrome.ActualHeight, paneWidth);
        if (signature == _glassSignature)
        {
            return;
        }

        _glassSignature = signature;
        Windows.Foundation.Rect sidebar = RootShell.TransformToVisual(WeatherBackdrop)
            .TransformBounds(new Windows.Foundation.Rect(0, 0, paneWidth, RootShell.ActualHeight));
        // The top-bar band spans the full width so the 1 dip content-grid rule between the pane
        // and the bar is frosted too (the two rects may overlap; the shader unions them).
        Windows.Foundation.Rect topBarBounds = TopBarChrome.TransformToVisual(WeatherBackdrop)
            .TransformBounds(new Windows.Foundation.Rect(0, 0, TopBarChrome.ActualWidth, TopBarChrome.ActualHeight));
        var topBar = new Windows.Foundation.Rect(0, topBarBounds.Y, WeatherBackdrop.ActualWidth, topBarBounds.Height);
        WeatherBackdrop.SetGlassRegions(sidebar, topBar);
    }

    private RectInt32[] _appliedCaptionRegions = Array.Empty<RectInt32>();
    private RectInt32[] _appliedPassthroughRegions = Array.Empty<RectInt32>();
    // The sizes that determine every region rect; unchanged sizes mean unchanged rects, so a
    // layout pass that moved nothing costs a tuple comparison and no transforms.
    private (double, double, double, double, double, double, double, double, double, double) _chromeSignature;

    private void ApplyNonClientRegions()
    {
        if (RootShell.XamlRoot is null || TopBarChrome.ActualWidth <= 0)
        {
            return;
        }

        double scale = RootShell.XamlRoot.RasterizationScale;
        var signature = (RootShell.ActualWidth, RootShell.ActualHeight, TopBarChrome.ActualWidth, TopBarChrome.ActualHeight,
            TelemetryStrip.ActualWidth, TopBarActionsHost.ActualWidth, SidebarHeader.ActualWidth, SidebarHeader.ActualHeight,
            CaptionButtonsColumn.Width.Value, scale);
        if (signature == _chromeSignature)
        {
            return;
        }

        _chromeSignature = signature;
        RectInt32[] caption = { PhysicalRect(TopBarChrome, scale), PhysicalRect(SidebarHeader, scale) };
        RectInt32[] passthrough = { PhysicalRect(TelemetryStrip, scale), PhysicalRect(TopBarActionsHost, scale) };
        if (SameRects(caption, _appliedCaptionRegions) && SameRects(passthrough, _appliedPassthroughRegions))
        {
            return;
        }

        var source = Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id);
        source.SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Caption, caption);
        source.SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, passthrough);
        _appliedCaptionRegions = caption;
        _appliedPassthroughRegions = passthrough;
        string Fmt(RectInt32[] rects) => string.Join(" | ", System.Linq.Enumerable.Select(rects, r => $"{r.X},{r.Y},{r.Width},{r.Height}"));
        WindowsRuntimeLog.Write(WindowsLogLevel.Debug, "window",
            $"Non-client regions at scale {scale:0.##}: caption=[{Fmt(caption)}] passthrough=[{Fmt(passthrough)}].");
    }

    private static bool SameRects(RectInt32[] a, RectInt32[] b)
    {
        if (a.Length != b.Length)
        {
            return false;
        }

        for (int i = 0; i < a.Length; i++)
        {
            if (a[i].X != b[i].X || a[i].Y != b[i].Y || a[i].Width != b[i].Width || a[i].Height != b[i].Height)
            {
                return false;
            }
        }

        return true;
    }

    // Window-relative physical pixels, which is what the non-client region API expects.
    private RectInt32 PhysicalRect(FrameworkElement element, double scale)
    {
        Windows.Foundation.Point origin = element.TransformToVisual(RootShell).TransformPoint(new Windows.Foundation.Point(0, 0));
        return checked(new RectInt32(
            (int)System.Math.Round(origin.X * scale),
            (int)System.Math.Round(origin.Y * scale),
            (int)System.Math.Round(element.ActualWidth * scale),
            (int)System.Math.Round(element.ActualHeight * scale)));
    }

    private void ReserveCaptionButtonsWidth(double scale)
    {
        int inset = AppWindow.TitleBar.RightInset;
        double logical = inset / scale;
        if (CaptionButtonsColumn.Width.Value != logical)
        {
            CaptionButtonsColumn.Width = new GridLength(logical);
            // A zero inset once the window is up means the caption buttons would overlay the
            // top-bar actions; it is reported rather than left to be discovered on screen.
            WindowsRuntimeLog.Write(
                inset > 0 ? WindowsLogLevel.Info : WindowsLogLevel.Warning,
                "window",
                $"Caption buttons reserve {logical:0.#} logical px on the top bar (inset {inset} px at scale {scale:0.##}).");
        }
    }

    // Caption buttons follow the shell surface, which is dark glass regardless of the Fluent
    // theme toggle (the shell has no light variant): white glyphs, a faint white wash on
    // hover/press (the same washes the sidebar rows use), inactive at half strength.
    private void ApplyCaptionButtonColors()
    {
        AppWindowTitleBar titleBar = AppWindow.TitleBar;
        Color foreground = Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xF7, 0xFA, 0xFF);
        Color hover = Microsoft.UI.ColorHelper.FromArgb(0x1A, 0xFF, 0xFF, 0xFF);
        Color pressed = Microsoft.UI.ColorHelper.FromArgb(0x29, 0xFF, 0xFF, 0xFF);

        titleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = Microsoft.UI.ColorHelper.FromArgb(0x80, foreground.R, foreground.G, foreground.B);
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedBackgroundColor = pressed;
        titleBar.ButtonPressedForegroundColor = foreground;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr windowHandle);

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
