using System.ComponentModel;
using System.Runtime.CompilerServices;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.ViewModels;

/// <summary>A stable UI row whose commands retain the exact admitted session identity.</summary>
public sealed class RemoteControlHostSessionViewModel : INotifyPropertyChanged
{
    private RemoteControlHostSessionStatus _status;
    private readonly Func<string, string> _text;
    private readonly Func<bool> _isBusy;

    internal RemoteControlHostSessionViewModel(
        RemoteControlHostSessionStatus status, Func<string, string> text, Func<bool> isBusy,
        Func<Guid, bool, Task> approve, Func<Guid, Task> transfer, Func<Guid, Task> disconnect)
    {
        _status = status;
        _text = text;
        _isBusy = isBusy;
        ApproveViewingCommand = new AsyncRelayCommand(() => approve(Id, false), () => CanApprove && _status.SupportsSharedAccess);
        ApproveControlCommand = new AsyncRelayCommand(() => approve(Id, true), () => CanApprove);
        TransferInputCommand = new AsyncRelayCommand(() => transfer(Id), () => !_isBusy() && _status.Phase == RemoteControlHostSessionPhase.Viewing && _status.SupportsSharedAccess);
        DisconnectCommand = new AsyncRelayCommand(() => disconnect(Id), () => !_isBusy() && _status.Phase is not (RemoteControlHostSessionPhase.Disconnecting or RemoteControlHostSessionPhase.Failed));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public Guid Id => _status.Id;
    public string DeviceName => _status.DeviceName.Length > 0 ? _status.DeviceName : _text("RemoteControlHostStatusAuthenticating");
    public string DeviceId => _status.DeviceId;
    public string ErrorMessage => _status.Error;
    public bool HasError => _status.Error.Length > 0;
    private bool CanApprove => !_isBusy() && _status.Phase == RemoteControlHostSessionPhase.AwaitingApproval;
    public string StatusText => _text(_status.Phase switch
    {
        RemoteControlHostSessionPhase.AwaitingApproval => "RemoteControlHostSessionAwaitingApproval",
        RemoteControlHostSessionPhase.Preparing => "RemoteControlHostSessionPreparing",
        RemoteControlHostSessionPhase.Viewing => "RemoteControlHostSessionViewing",
        RemoteControlHostSessionPhase.Controlling => "RemoteControlHostSessionControlling",
        RemoteControlHostSessionPhase.Disconnecting => "RemoteControlHostSessionDisconnecting",
        RemoteControlHostSessionPhase.Failed => "RemoteControlHostStatusFailed",
        _ => "RemoteControlHostStatusAuthenticating"
    });
    public AsyncRelayCommand ApproveViewingCommand { get; }
    public AsyncRelayCommand ApproveControlCommand { get; }
    public AsyncRelayCommand TransferInputCommand { get; }
    public AsyncRelayCommand DisconnectCommand { get; }

    internal void Apply(RemoteControlHostSessionStatus status)
    {
        if (status.Id != Id) throw new InvalidOperationException("A controller row cannot change its session identity.");
        var previous = _status;
        _status = status;
        if (previous.DeviceName != status.DeviceName) Notify(nameof(DeviceName));
        if (previous.DeviceId != status.DeviceId) Notify(nameof(DeviceId));
        if (previous.Phase != status.Phase) Notify(nameof(StatusText));
        if (previous.Error != status.Error)
        {
            Notify(nameof(ErrorMessage));
            if ((previous.Error.Length == 0) != (status.Error.Length == 0)) Notify(nameof(HasError));
        }
        if (previous.Phase != status.Phase || previous.SupportsSharedAccess != status.SupportsSharedAccess)
            RefreshCommands();
    }

    internal void RefreshCommands()
    {
        ApproveViewingCommand.RaiseCanExecuteChanged();
        ApproveControlCommand.RaiseCanExecuteChanged();
        TransferInputCommand.RaiseCanExecuteChanged();
        DisconnectCommand.RaiseCanExecuteChanged();
    }

    private void Notify([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
}
