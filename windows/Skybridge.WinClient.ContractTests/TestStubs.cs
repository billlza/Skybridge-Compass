namespace Skybridge.WinClient.Services;

public interface ISkyBridgeDataPlane
{
}

public sealed record PairingMaterial(string DeviceId);

public sealed record ConnectionPreflightSnapshot(
    DateTimeOffset CapturedAt,
    ConnectionPreflightPlan Plan);

public sealed record ConnectionPreflightPlan(bool IsLiveAdapterReady = false)
{
    public void ValidateForLaunch(PairingMaterial pairingMaterial)
    {
    }
}

public sealed record ConnectionLaunchRequest(
    PairingMaterial PairingMaterial,
    ConnectionPreflightSnapshot PreflightSnapshot);

public sealed record ManualConnectionSnapshot(
    ManualConnectionTarget Target);

public sealed record ManualConnectionTarget(
    string Host,
    int Port,
    string Service);

public sealed record CrossNetworkConnectionSnapshot(
    string Status);
