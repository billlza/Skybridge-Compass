using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IRemoteDesktopProfileCatalogClient
{
    RemoteDesktopProfileCatalogSnapshot BuildReadOnlySnapshot();

    string BuildBitrateSelectionStatus(string value);

    string BuildFramerateSelectionStatus(string value);
}

public sealed class RemoteDesktopProfileCatalogClient : IRemoteDesktopProfileCatalogClient
{
    private static readonly string[] BitrateProfiles = { "Low", "Medium", "High" };
    private static readonly string[] FramerateProfiles = { "Fps30", "Fps60" };

    public RemoteDesktopProfileCatalogSnapshot BuildReadOnlySnapshot() =>
        new(
            BitrateProfiles,
            FramerateProfiles,
            "Medium",
            "Fps60");

    public string BuildBitrateSelectionStatus(string value) =>
        $"Bitrate set to {value}";

    public string BuildFramerateSelectionStatus(string value) =>
        $"Framerate set to {value}";
}

public sealed record RemoteDesktopProfileCatalogSnapshot(
    IReadOnlyList<string> BitrateProfiles,
    IReadOnlyList<string> FramerateProfiles,
    string DefaultBitrateProfile,
    string DefaultFramerateProfile);
