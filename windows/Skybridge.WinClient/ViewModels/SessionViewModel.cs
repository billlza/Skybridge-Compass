using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public enum BitrateProfile
{
    Low,
    Medium,
    High
}

public enum FramerateProfile
{
    Fps30,
    Fps60
}

public sealed class SessionViewModel : INotifyPropertyChanged
{
    private readonly IEngineClient _engineClient;
    private string _statusMessage = "Idle";
    private BitrateProfile _selectedBitrate = BitrateProfile.Medium;
    private FramerateProfile _selectedFramerate = FramerateProfile.Fps60;
    private EngineConnectionState _connectionState;
    private bool _isBusy;

    public SessionViewModel(IEngineClient engineClient)
    {
        _engineClient = engineClient;
        _connectionState = _engineClient.State;
        _engineClient.ConnectionStateChanged += OnEngineStateChanged;
        ConnectCommand = new AsyncRelayCommand(ConnectAsync, CanConnect);
        DisconnectCommand = new AsyncRelayCommand(DisconnectAsync, CanDisconnect);
        HeartbeatCommand = new AsyncRelayCommand(SendHeartbeatAsync, CanSendHeartbeat);
        BitrateProfiles = new ObservableCollection<BitrateProfile>((BitrateProfile[])Enum.GetValues(typeof(BitrateProfile)));
        FramerateProfiles = new ObservableCollection<FramerateProfile>((FramerateProfile[])Enum.GetValues(typeof(FramerateProfile)));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<BitrateProfile> BitrateProfiles { get; }

    public ObservableCollection<FramerateProfile> FramerateProfiles { get; }

    public EngineConnectionState ConnectionState
    {
        get => _connectionState;
        private set
        {
            if (SetField(ref _connectionState, value))
            {
                OnPropertyChanged(nameof(ConnectionStatus));
                RefreshCommandStates();
            }
        }
    }

    public string ConnectionStatus => ConnectionState.ToString();

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetField(ref _isBusy, value))
            {
                RefreshCommandStates();
            }
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        private set => SetField(ref _statusMessage, value);
    }

    public BitrateProfile SelectedBitrate
    {
        get => _selectedBitrate;
        set
        {
            if (SetField(ref _selectedBitrate, value))
            {
                StatusMessage = $"Bitrate set to {value}";
            }
        }
    }

    public FramerateProfile SelectedFramerate
    {
        get => _selectedFramerate;
        set
        {
            if (SetField(ref _selectedFramerate, value))
            {
                StatusMessage = $"Framerate set to {value}";
            }
        }
    }

    public ICommand ConnectCommand { get; }

    public ICommand DisconnectCommand { get; }

    public ICommand HeartbeatCommand { get; }

    private async Task ConnectAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            StatusMessage = "Connecting...";
            await _engineClient.ConnectAsync();
            StatusMessage = "Connected";
        });
    }

    private async Task DisconnectAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            StatusMessage = "Disconnecting...";
            await _engineClient.DisconnectAsync();
            StatusMessage = "Disconnected";
        });
    }

    private async Task SendHeartbeatAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            await _engineClient.SendHeartbeatAsync();
            StatusMessage = "Heartbeat acknowledged";
        });
    }

    private bool CanConnect() => !IsBusy && ConnectionState == EngineConnectionState.Disconnected;

    private bool CanDisconnect() => !IsBusy && (ConnectionState == EngineConnectionState.Connected || ConnectionState == EngineConnectionState.Reconnecting);

    private bool CanSendHeartbeat() => !IsBusy && ConnectionState == EngineConnectionState.Connected;

    private async Task RunWithBusyState(Func<Task> action)
    {
        try
        {
            IsBusy = true;
            await action();
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void RefreshCommandStates()
    {
        (ConnectCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (DisconnectCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (HeartbeatCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
    }

    private void OnEngineStateChanged(object? sender, EngineConnectionState newState)
    {
        ConnectionState = newState;
        StatusMessage = newState switch
        {
            EngineConnectionState.Connecting => "Connecting...",
            EngineConnectionState.Connected => "Connected",
            EngineConnectionState.Reconnecting => "Reconnecting...",
            EngineConnectionState.ShuttingDown => "Disconnecting...",
            _ => "Disconnected"
        };
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<Task> _execute;
    private readonly Func<bool>? _canExecute;

    public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public async void Execute(object? parameter)
    {
        await _execute();
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
