using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

// The addresses discovery resolved for one peer, kept apart from the DNS-SD browse machinery that
// produces them. Preflight and the transport adapters need to carry these routes without taking a
// dependency on the browser, its native DNS-SD codec, or the protocol constants table; the
// FromResolvedTxtRecord factories live with that machinery in DiscoveryBrowserClient.cs.

public sealed partial record DiscoveryPeerEndpoint(
    string Service,
    string HostName,
    ushort Port,
    string InstanceName,
    string Provenance);

public sealed partial record DiscoveryPeerRoutes(
    DiscoveryPeerEndpoint? Control,
    DiscoveryPeerEndpoint? FileTransfer,
    DiscoveryPeerEndpoint? RemoteDesktop)
{
    public static DiscoveryPeerRoutes Empty { get; } = new(null, null, null);

    public bool HasAny => Control is not null || FileTransfer is not null || RemoteDesktop is not null;

    public string Summary
    {
        get
        {
            var values = new List<string>();
            if (Control is not null)
            {
                values.Add($"control={Control.HostName}:{Control.Port}");
            }

            if (FileTransfer is not null)
            {
                values.Add($"file-transfer={FileTransfer.HostName}:{FileTransfer.Port}");
            }

            if (RemoteDesktop is not null)
            {
                values.Add($"remote-desktop={RemoteDesktop.HostName}:{RemoteDesktop.Port}");
            }

            return values.Count == 0
                ? "No resolved DNS-SD endpoints; TXT port fields are diagnostic only."
                : string.Join(", ", values);
        }
    }
}
