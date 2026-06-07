using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IManualConnectionClient
{
    string BuildPendingStatus();

    bool CanPrepareTarget(string host, string port);

    Task<ManualConnectionSnapshot> BuildReadOnlySnapshotAsync(ManualConnectionRequest request);
}

public sealed class ManualConnectionClient : IManualConnectionClient
{
    public string BuildPendingStatus() => DefaultPendingStatus;

    public static string DefaultPendingStatus { get; } = "Preparing...";

    public bool CanPrepareTarget(string host, string port) =>
        HasManualTargetInputs(host, port);

    public static bool HasManualTargetInputs(string host, string port) =>
        !string.IsNullOrWhiteSpace(host)
        && !string.IsNullOrWhiteSpace(port);

    public Task<ManualConnectionSnapshot> BuildReadOnlySnapshotAsync(ManualConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var host = NormalizeHost(request.Host);
        var port = ParsePort(request.Port);
        var code = request.Code?.Trim() ?? string.Empty;

        var facts = new List<ManualConnectionFact>
        {
            new("Host / IP", host, "Manual target only; live adapter must resolve and bind the actual endpoint before handshake."),
            new("Port", port.ToString(CultureInfo.InvariantCulture), "Matches the mac manual-connect default when left at 11550."),
            new("Service", "_skybridge._tcp", "Manual targets use the TCP fallback service shape until DNS-SD TXT data is resolved."),
            new("Code", string.IsNullOrWhiteSpace(code) ? "not provided" : "provided", "Code is routing or pairing input only; it is never treated as a peer public key."),
            new("Safety", "no connection started", "Pairing, trust approval, Core connection plan, and transport binding remain required before FfiEngineClient can connect.")
        };

        if (code.StartsWith("skybridge-pair:v1", StringComparison.Ordinal))
        {
            facts.Add(new ManualConnectionFact(
                "Pairing code",
                "detected",
                "Validate Pairing must parse and verify this material before a peer key provider is available."));
        }

        var target = new ManualConnectionTarget(host, port, code, "_skybridge._tcp");
        return Task.FromResult(new ManualConnectionSnapshot(DateTimeOffset.UtcNow, target, facts));
    }

    private static string NormalizeHost(string host)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(host);
        var normalized = host.Trim();
        if (normalized.Length > 253)
        {
            throw new InvalidOperationException("Manual connection host is too long.");
        }

        return normalized;
    }

    private static int ParsePort(string port)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(port);
        if (!int.TryParse(port.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var parsed))
        {
            throw new InvalidOperationException("Manual connection port must be a number.");
        }

        if (parsed is < 1 or > 65535)
        {
            throw new InvalidOperationException("Manual connection port must be between 1 and 65535.");
        }

        return parsed;
    }
}

public sealed record ManualConnectionRequest(
    string Host,
    string Port,
    string Code);

public sealed record ManualConnectionSnapshot(
    DateTimeOffset CapturedAt,
    ManualConnectionTarget Target,
    IReadOnlyList<ManualConnectionFact> Facts);

public sealed record ManualConnectionTarget(
    string Host,
    int Port,
    string Code,
    string Service);

public sealed record ManualConnectionFact(
    string Label,
    string Value,
    string Detail);
