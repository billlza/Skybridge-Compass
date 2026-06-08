using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class CrossNetworkConnectionActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ICrossNetworkConnectionClient _crossNetworkConnectionClient;
    private readonly WorkspaceViewStateBuilder _viewStateBuilder;
    private readonly ConnectionWorkspaceResultProjector _connectionResultProjector;
    private readonly Func<string> _getCrossNetworkQrInput;
    private readonly Func<string> _getCrossNetworkCodeInput;
    private readonly Func<string> _getCrossNetworkGeneratedCode;
    private readonly Action<string> _setCrossNetworkStatus;
    private readonly Action<string> _setCrossNetworkGeneratedCode;

    public CrossNetworkConnectionActions(
        WorkspaceBusyCoordinator busyCoordinator,
        ICrossNetworkConnectionClient crossNetworkConnectionClient,
        WorkspaceViewStateBuilder viewStateBuilder,
        ConnectionWorkspaceResultProjector connectionResultProjector,
        Func<string> getCrossNetworkQrInput,
        Func<string> getCrossNetworkCodeInput,
        Func<string> getCrossNetworkGeneratedCode,
        Action<string> setCrossNetworkStatus,
        Action<string> setCrossNetworkGeneratedCode)
    {
        _busyCoordinator = busyCoordinator;
        _crossNetworkConnectionClient = crossNetworkConnectionClient;
        _viewStateBuilder = viewStateBuilder;
        _connectionResultProjector = connectionResultProjector;
        _getCrossNetworkQrInput = getCrossNetworkQrInput;
        _getCrossNetworkCodeInput = getCrossNetworkCodeInput;
        _getCrossNetworkGeneratedCode = getCrossNetworkGeneratedCode;
        _setCrossNetworkStatus = setCrossNetworkStatus;
        _setCrossNetworkGeneratedCode = setCrossNetworkGeneratedCode;
    }

    public Task GenerateQrCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.GenerateQrCode);

    public Task ScanQrCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.ScanQrCode);

    public Task GenerateCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.GenerateCode);

    public Task RegenerateCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.RegenerateCode);

    public Task CopyCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.CopyCode);

    public Task ConnectWithCodeAsync() =>
        RunAsync(CrossNetworkConnectionAction.ConnectWithCode);

    private Task RunAsync(CrossNetworkConnectionAction action) =>
        _busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery, async () =>
        {
            _setCrossNetworkStatus(_crossNetworkConnectionClient.BuildPendingStatus(action));

            var snapshot = await _crossNetworkConnectionClient.BuildReadOnlySnapshotAsync(
                _viewStateBuilder.BuildCrossNetworkConnectionRequest(
                    action,
                    _getCrossNetworkQrInput(),
                    _getCrossNetworkCodeInput(),
                    _getCrossNetworkGeneratedCode()));

            _connectionResultProjector.ApplyCrossNetworkPrepared(
                snapshot,
                _setCrossNetworkGeneratedCode);
        });
}
