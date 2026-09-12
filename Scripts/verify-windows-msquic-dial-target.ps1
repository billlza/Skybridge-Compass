param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

# The Windows-native MsQuic adapter used to learn its dial target from one place only:
# SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT, a hand-typed host:port. That made the native
# Windows<->Windows path a lab harness rather than a product path. It now prefers the
# control route DNS-SD resolved for the selected peer, keeps the pinned option as a
# harness override, and fails closed when it has neither.
#
# This gate compiles the real adapter (no stubs, no second implementation) into a plain
# net10.0 console and exercises ResolveDialTarget directly, so the precedence is checked
# as behaviour rather than as source text. Nothing here opens a socket: every case is
# decided before any dial, which is why it runs on a non-Windows host too.
$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/ConnectionLaunchRequest.cs",
    "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs",
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryClient.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryPeerRoutes.cs",
    "windows/Skybridge.WinClient/Services/FfiEngineClient.cs",
    "windows/Skybridge.WinClient/Services/IEngineClient.cs",
    "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs",
    "windows/Skybridge.WinClient/Services/SkyBridgeProtocolConstants.cs",
    "windows/Skybridge.WinClient/Services/SkybridgeNativeLibraryResolver.cs",
    "windows/Skybridge.WinClient/Services/WindowsNativeMsQuicEphemeralCertificate.cs",
    "windows/Skybridge.WinClient/Services/WindowsNativeMsQuicTransportAdapterClient.cs",
    "windows/Skybridge.WinClient/Services/WindowsNativeMsQuicTransportSecret.cs",
    "windows/Skybridge.WinClient/Services/WindowsTransportAdapterClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing MsQuic dial-target source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-msquic-dial-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinMsQuicDialSmoke.csproj"
$testProgram = Join-Path $tempRoot "Program.cs"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $programXml = [System.Security.SecurityElement]::Escape($testProgram)
    $compileItems = @("    <Compile Include=""$programXml"" />")
    foreach ($sourceFile in $sourceFiles) {
        $sourceFileXml = [System.Security.SecurityElement]::Escape($sourceFile)
        $compileItems += "    <Compile Include=""$sourceFileXml"" />"
    }
    $compileItemText = $compileItems -join "`r`n"

    Set-Content -LiteralPath $testProject -Encoding UTF8 -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
$compileItemText
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using System;
using Skybridge.WinClient.Services;

static class DialTargetSmoke
{
    static int failures;

    static void Check(bool condition, string message)
    {
        if (condition)
        {
            Console.WriteLine("  ok   " + message);
            return;
        }

        failures++;
        Console.WriteLine("  FAIL " + message);
    }

    static DiscoveryPeerEndpoint Endpoint(string service, string host, ushort port) =>
        new(service, host, port, "instance", "resolved-dns-sd-endpoint");

    static WindowsTransportAdapterRequest Request(DiscoveryPeerRoutes? routes)
    {
        var capabilities = PeerCapabilities.Windows();
        var peer = new DiscoveredPeer(
            CoreDiscoveryServiceKind.QuicPrimary,
            "device-under-test",
            "Device Under Test",
            CorePeerPlatform.Windows,
            "Windows",
            "fp",
            "tokens",
            "1",
            capabilities);
        var pairing = new PairingMaterial(
            "device-under-test",
            "Device Under Test",
            "Windows",
            "fp",
            new byte[] { 1, 2, 3, 4 },
            true,
            "gate");
        return new WindowsTransportAdapterRequest(
            peer,
            pairing,
            CoreTransportKind.WindowsNativeMsQuic,
            CoreTransportAuditCode.WindowsNativeMsQuicSameLan,
            false,
            false,
            capabilities,
            capabilities,
            NetworkPath.SameLanPath(),
            routes);
    }

    static WindowsNativeMsQuicTransportAdapterClient Adapter(string? pinnedEndpoint) =>
        new(new WindowsNativeMsQuicTransportAdapterOptions(pinnedEndpoint, 30000));

    static string? Rejected(string? pinnedEndpoint, DiscoveryPeerRoutes? routes)
    {
        try
        {
            Adapter(pinnedEndpoint).ResolveDialTarget(Request(routes));
            return null;
        }
        catch (InvalidOperationException ex)
        {
            return ex.Message;
        }
    }

    static int Main()
    {
        Console.WriteLine("windows-msquic-dial-target: resolve-precedence");

        var control = DiscoveryPeerRoutes.Empty with
        {
            Control = Endpoint(SkyBridgeProtocolConstants.QuicControlDnsSdService, "peer.local", 41641)
        };

        // 1. A pinned endpoint is the harness override and outranks discovery.
        var pinned = Adapter("10.0.0.9:7777").ResolveDialTarget(Request(control));
        Check(pinned.Host == "10.0.0.9" && pinned.Port == 7777,
            "pinned endpoint wins over a resolved control route (got " + pinned.Host + ":" + pinned.Port + ")");

        // 2. With no pin the adapter dials what discovery actually resolved. This is the
        //    product path: no environment variable is involved.
        var discovered = Adapter(null).ResolveDialTarget(Request(control));
        Check(discovered.Host == "peer.local" && discovered.Port == 41641,
            "resolved control route is dialled when nothing is pinned (got " + discovered.Host + ":" + discovered.Port + ")");

        // 3. The TCP control service is an equally valid control route.
        var tcp = DiscoveryPeerRoutes.Empty with
        {
            Control = Endpoint(SkyBridgeProtocolConstants.TcpControlDnsSdService, "tcp-peer.local", 5001)
        };
        var tcpTarget = Adapter(null).ResolveDialTarget(Request(tcp));
        Check(tcpTarget.Host == "tcp-peer.local" && tcpTarget.Port == 5001,
            "tcp control route is dialled as well as the quic one");

        // 4. Fail closed with nothing to dial, rather than inventing an address.
        var noRoutes = Rejected(null, null);
        Check(noRoutes is not null, "no pin and no routes is rejected");
        Check(noRoutes is not null
                && noRoutes.Contains(SkyBridgeProtocolConstants.QuicControlDnsSdService, StringComparison.Ordinal)
                && noRoutes.Contains(SkyBridgeProtocolConstants.TcpControlDnsSdService, StringComparison.Ordinal),
            "the rejection names the control services that must be resolved");

        // 5. File-transfer and remote-desktop routes are not control routes. The adapter
        //    dials the control channel; substituting a data-plane port would be silent.
        var dataPlaneOnly = DiscoveryPeerRoutes.Empty with
        {
            FileTransfer = Endpoint(SkyBridgeProtocolConstants.FileTransferDnsSdService, "peer.local", 41642),
            RemoteDesktop = Endpoint(SkyBridgeProtocolConstants.RemoteDesktopDnsSdService, "peer.local", 41643)
        };
        Check(Rejected(null, dataPlaneOnly) is not null,
            "file-transfer and remote-desktop routes do not stand in for a control route");

        // 6. A resolved route missing a usable host or port is rejected, not dialled as ":0".
        Check(Rejected(null, DiscoveryPeerRoutes.Empty with
        {
            Control = Endpoint(SkyBridgeProtocolConstants.QuicControlDnsSdService, "   ", 41641)
        }) is not null, "a control route with a blank host is rejected");
        Check(Rejected(null, DiscoveryPeerRoutes.Empty with
        {
            Control = Endpoint(SkyBridgeProtocolConstants.QuicControlDnsSdService, "peer.local", 0)
        }) is not null, "a control route with port 0 is rejected");

        // 7. A blank pinned value is absent, not a pin of the empty string; it must fall
        //    through to discovery instead of failing the connection.
        var blankPin = Adapter("   ").ResolveDialTarget(Request(control));
        Check(blankPin.Host == "peer.local" && blankPin.Port == 41641,
            "a blank pinned endpoint falls through to the resolved control route");

        Console.WriteLine(failures == 0
            ? "windows-msquic-dial-target: all checks passed"
            : "windows-msquic-dial-target: " + failures + " check(s) failed");
        return failures == 0 ? 0 : 1;
    }
}
'@

    Write-Host "windows-msquic-dial-target: build-and-run"
    & dotnet run --project $testProject -c Debug --nologo
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "MsQuic dial-target precedence smoke failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "verify-windows-msquic-dial-target: OK"
