using Microsoft.UI.Xaml;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient;

public sealed partial class MainWindow : Window
{
    public SessionViewModel ViewModel { get; }

    public MainWindow()
    {
        InitializeComponent();
        ViewModel = new SessionViewModel(SessionViewModelDependencyFactory.CreateConfigured());
        RootShell.DataContext = ViewModel;
    }
}
