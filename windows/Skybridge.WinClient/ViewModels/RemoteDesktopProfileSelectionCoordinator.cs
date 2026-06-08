using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class RemoteDesktopProfileSelectionCoordinator
{
    private readonly IRemoteDesktopProfileCatalogClient _profileCatalogClient;
    private readonly Action<string> _setStatusMessage;

    public RemoteDesktopProfileSelectionCoordinator(
        IRemoteDesktopProfileCatalogClient profileCatalogClient,
        Action<string> setStatusMessage)
    {
        _profileCatalogClient = profileCatalogClient;
        _setStatusMessage = setStatusMessage;
    }

    public void ApplyBitrateSelection(string value) =>
        _setStatusMessage(_profileCatalogClient.BuildBitrateSelectionStatus(value));

    public void ApplyFramerateSelection(string value) =>
        _setStatusMessage(_profileCatalogClient.BuildFramerateSelectionStatus(value));
}
