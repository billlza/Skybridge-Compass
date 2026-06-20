using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
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
}
