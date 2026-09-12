using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Windows projection of the versioned SkyBridge wire and discovery constants owned by the
/// cross-platform protocol ADRs. Product code must consume these constants instead of defining
/// transport- or feature-local spellings.
/// </summary>
internal static class SkyBridgeProtocolConstants
{
    public const string QuicControlDnsSdService = "_skybridge._udp";
    public const string TcpControlDnsSdService = "_skybridge._tcp";
    public const string FileTransferDnsSdService = "_skybridge-xfer._tcp";
    public const string RemoteDesktopDnsSdService = "_skybridge-rd._tcp";
    public const string LegacyFileTransferDnsSdService = "_skybridge-transfer._tcp";
    public const string LegacyRemoteDesktopDnsSdService = "_skybridge-remote._tcp";
    public const string MsQuicAlpn = "skybridge-sbq/1";

    public static IReadOnlyList<string> WindowsDnsSdQueryOrder { get; } = Array.AsReadOnly(
        new[]
        {
            QuicControlDnsSdService,
            TcpControlDnsSdService,
            FileTransferDnsSdService,
            RemoteDesktopDnsSdService,
            LegacyFileTransferDnsSdService,
            LegacyRemoteDesktopDnsSdService
        });

    public static bool TryCanonicalizeDnsSdServiceType(
        string? serviceType,
        out string canonicalServiceType)
    {
        canonicalServiceType = "";
        if (string.IsNullOrWhiteSpace(serviceType))
        {
            return false;
        }

        canonicalServiceType = serviceType.Trim().ToLowerInvariant() switch
        {
            QuicControlDnsSdService => QuicControlDnsSdService,
            TcpControlDnsSdService => TcpControlDnsSdService,
            FileTransferDnsSdService => FileTransferDnsSdService,
            RemoteDesktopDnsSdService => RemoteDesktopDnsSdService,
            LegacyFileTransferDnsSdService => FileTransferDnsSdService,
            LegacyRemoteDesktopDnsSdService => RemoteDesktopDnsSdService,
            _ => ""
        };
        return canonicalServiceType.Length != 0;
    }

    public static string CanonicalizeDnsSdInstanceName(
        string instanceName,
        string sourceServiceType,
        string canonicalServiceType)
    {
        ArgumentNullException.ThrowIfNull(instanceName);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceServiceType);
        ArgumentException.ThrowIfNullOrWhiteSpace(canonicalServiceType);

        var normalized = instanceName.Trim();
        normalized = CanonicalizeLegacyInstanceSuffix(
            normalized,
            LegacyFileTransferDnsSdService,
            FileTransferDnsSdService);
        normalized = CanonicalizeLegacyInstanceSuffix(
            normalized,
            LegacyRemoteDesktopDnsSdService,
            RemoteDesktopDnsSdService);

        var source = sourceServiceType.Trim();
        if (string.Equals(source, canonicalServiceType, StringComparison.OrdinalIgnoreCase))
        {
            return normalized;
        }

        return ReplaceTerminalServiceName(normalized, source, canonicalServiceType, ".local")
            ?? ReplaceTerminalServiceName(normalized, source, canonicalServiceType, "")
            ?? normalized;
    }

    private static string CanonicalizeLegacyInstanceSuffix(
        string instanceName,
        string legacyServiceType,
        string canonicalServiceType)
    {
        return ReplaceTerminalServiceName(instanceName, legacyServiceType, canonicalServiceType, ".local")
            ?? ReplaceTerminalServiceName(instanceName, legacyServiceType, canonicalServiceType, "")
            ?? instanceName;
    }

    private static string? ReplaceTerminalServiceName(
        string instanceName,
        string sourceServiceType,
        string canonicalServiceType,
        string terminalSuffix)
    {
        var sourceSuffix = sourceServiceType + terminalSuffix;
        if (!instanceName.EndsWith(sourceSuffix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return instanceName[..^sourceSuffix.Length] + canonicalServiceType + terminalSuffix;
    }
}
