using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient.RemoteControl;

public sealed partial class RemoteControlHostView : UserControl
{
    public RemoteControlHostView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (DataContext is RemoteControlHostViewModel viewModel)
        {
            await viewModel.InitializeAsync();
        }
    }

    private async void OnHostToggled(object sender, RoutedEventArgs args)
    {
        if (DataContext is RemoteControlHostViewModel viewModel && HostToggle.IsOn != viewModel.IsEnabled)
        {
            await viewModel.SetEnabledAsync(HostToggle.IsOn);
        }
    }
}
