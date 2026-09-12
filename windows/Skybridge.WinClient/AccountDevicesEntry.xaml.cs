using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Skybridge.WinClient.ViewModels;
namespace Skybridge.WinClient;
public sealed partial class AccountDevicesEntry : UserControl
{
    private AccountDevicesCoordinator? _coordinator;
    public event EventHandler? OpenRequested;
    public AccountDevicesEntry(){InitializeComponent();Unloaded+=OnUnloaded;Loaded+=OnLoaded;}
    internal void Configure(AccountDevicesCoordinator coordinator,string automationId,bool glassSurface = false)
    {
        if (glassSurface)
        {
            GlassSurface.Visibility = Visibility.Visible;
            OpenButton.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
            OpenButton.BorderThickness = new Thickness(0);
            OpenButton.CornerRadius = new CornerRadius(20);
            OpenButton.Padding = new Thickness(20);
        }
        if(_coordinator is not null)_coordinator.PropertyChanged-=Changed;
        _coordinator=coordinator;
        AutomationProperties.SetAutomationId(OpenButton,automationId);
        if(IsLoaded)_coordinator.PropertyChanged+=Changed;
        Update();
    }
    private void OnLoaded(object sender,RoutedEventArgs e){if(_coordinator is not null)_coordinator.PropertyChanged+=Changed;Update();}
    private void OnUnloaded(object sender,RoutedEventArgs e){if(_coordinator is not null)_coordinator.PropertyChanged-=Changed;}
    private void Changed(object? sender,PropertyChangedEventArgs e)=>Update();
    private void Update(){if(_coordinator is not null)SummaryText.Text=_coordinator.Summary;}
    private void OnOpen(object sender,RoutedEventArgs e)=>OpenRequested?.Invoke(this,EventArgs.Empty);
    internal void RestoreFocus()=>OpenButton.Focus(FocusState.Programmatic);
}
