using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class CrossNetworkCodeInputCoordinator
{
    private readonly ICrossNetworkConnectionClient _crossNetworkConnectionClient;

    public CrossNetworkCodeInputCoordinator(ICrossNetworkConnectionClient crossNetworkConnectionClient)
    {
        _crossNetworkConnectionClient = crossNetworkConnectionClient;
    }

    public CrossNetworkCodeInputUpdate BuildInputUpdate(
        string currentValue,
        string? proposedValue)
    {
        var normalized = _crossNetworkConnectionClient.NormalizeCodeInput(proposedValue);
        return new CrossNetworkCodeInputUpdate(
            normalized,
            !string.Equals(currentValue, normalized, StringComparison.Ordinal),
            !string.Equals(proposedValue, normalized, StringComparison.Ordinal));
    }
}

internal sealed record CrossNetworkCodeInputUpdate(
    string NormalizedValue,
    bool ShouldUpdateValue,
    bool ShouldNotifyNormalizedValue);
