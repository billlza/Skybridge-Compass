using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
using Windows.Graphics;

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
        SizeAndCenter();

        // Restore a remembered Supabase session (DPAPI) on launch so the account block shows
        // the real signed-in user without a tap. Queued on the UI dispatcher: HydrateFromStore
        // touches the network + the VM's UI-thread-affine SetField props, and it must run after
        // the window is up. It never throws (the coordinator swallows all failures internally).
        DispatcherQueue.TryEnqueue(async () =>
        {
            await ViewModel.HydrateFromStoreAsync();
        });

        // Stop the live top-bar network telemetry loop (and release its PeriodicTimer) when the
        // window closes so the background sampling task doesn't outlive the UI. Non-throwing.
        Closed += OnWindowClosed;
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        ViewModel.DisposeNetworkCoordinator();
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
