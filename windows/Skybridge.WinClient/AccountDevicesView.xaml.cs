using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
namespace Skybridge.WinClient;
public sealed partial class AccountDevicesView : UserControl
{
    private AccountDevicesCoordinator? _coordinator;
    private bool _embedded;
    public event EventHandler? CloseRequested;
    public AccountDevicesView(){InitializeComponent();Loaded+=OnLoaded;Unloaded+=OnUnloaded;}
    internal void Configure(AccountDevicesCoordinator coordinator, bool embedded = false)
    {
        _embedded = embedded;
        if (embedded)
        {
            Backdrop.Background = null;
            Backdrop.Padding = new Thickness(0);
            Backdrop.TabFocusNavigation = KeyboardNavigationMode.Local;
            Card.ClearValue(Border.BackgroundProperty);
            Card.ClearValue(Border.BorderBrushProperty);
            Card.ClearValue(Border.BorderThicknessProperty);
            Card.Style = (Style)Application.Current.Resources["GlassPanel"];
            Card.Padding = new Thickness(20);
            Card.MaxWidth = double.PositiveInfinity;
            Card.MaxHeight = double.PositiveInfinity;
            DeviceList.MaxHeight = 520;
            CloseButton.Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(this, "Skybridge.DeviceDiscovery.AccountDevices");
            AutomationProperties.SetAutomationId(DeviceList, "Skybridge.DeviceDiscovery.AccountDevices.List");
            AutomationProperties.SetAutomationId(StatusText, "Skybridge.DeviceDiscovery.AccountDevices.Status");
            AutomationProperties.SetAutomationId(RefreshButton, "Skybridge.DeviceDiscovery.AccountDevices.Refresh");
        }
        if(_coordinator is not null)_coordinator.PropertyChanged-=Changed;
        _coordinator=coordinator;DeviceList.ItemsSource=coordinator.Devices;
        if(IsLoaded)coordinator.PropertyChanged+=Changed;Update();
    }
    private void OnLoaded(object sender,RoutedEventArgs args){if(_coordinator is not null)_coordinator.PropertyChanged+=Changed;Update();}
    private void OnUnloaded(object sender,RoutedEventArgs args){if(_coordinator is not null)_coordinator.PropertyChanged-=Changed;}
    private void Changed(object? sender,PropertyChangedEventArgs args)=>Update();
    private void Update(){if(_coordinator is null)return;StatusText.Text=_coordinator.Status;AutomationProperties.SetItemStatus(StatusText,_coordinator.Phase);RefreshButton.IsEnabled=_coordinator.CanRefresh;LoadingProgress.Visibility=_coordinator.IsBusy?Visibility.Visible:Visibility.Collapsed;}
    internal void FocusClose()=>CloseButton.Focus(FocusState.Programmatic);
    private void OnRefresh(object sender,RoutedEventArgs args)=>_coordinator?.Refresh();
    private void OnClose(object sender,RoutedEventArgs args)=>CloseRequested?.Invoke(this,EventArgs.Empty);
    private void OnBackdropTapped(object sender,TappedRoutedEventArgs args)=>CloseRequested?.Invoke(this,EventArgs.Empty);
    private void OnCardTapped(object sender,TappedRoutedEventArgs args)=>args.Handled=true;
    private void OnKeyDown(object sender,KeyRoutedEventArgs args){if(!_embedded && args.Key==Windows.System.VirtualKey.Escape){args.Handled=true;CloseRequested?.Invoke(this,EventArgs.Empty);}}
}
