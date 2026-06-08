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

$winClientProject = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
Assert-True -Condition (Test-Path -LiteralPath $winClientProject) -Message "Missing Windows client project: $winClientProject"
$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/IEngineClient.cs",
    "windows/Skybridge.WinClient/Services/FfiEngineClient.cs",
    "windows/Skybridge.WinClient/Services/DummyEngineClient.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryClient.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs",
    "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs",
    "windows/Skybridge.WinClient/Services/CrossNetworkConnectionClient.cs",
    "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs",
    "windows/Skybridge.WinClient/Services/ConnectionLaunchRequest.cs",
    "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs",
    "windows/Skybridge.WinClient/Services/ConnectionWorkspaceStateClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows connection launch source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-launch-smoke-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinLaunchSmoke.csproj"
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
using Skybridge.WinClient.Services;

const string Fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

var stateClient = new ConnectionWorkspaceStateClient();
var peer = new DiscoveredPeer(
    CoreDiscoveryServiceKind.QuicPrimary,
    "mac-1",
    "Desk Mac",
    CorePeerPlatform.Apple,
    "macOS",
    Fingerprint,
    "apple,webrtc,tcp,relay",
    "1",
    PeerCapabilities.Apple());
var pairingMaterial = new PairingMaterial(
    "mac-1",
    "Desk Mac",
    "macOS",
    Fingerprint,
    new byte[] { 1, 2, 3, 4, 5 },
    true,
    "smoke");

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(stateClient.BuildInputInvalidatedState()),
    "Parse a Core-validated discovery TXT record before connection launch.");

var discoveredState = stateClient.BuildDiscoveryPeerValidatedState(peer);
ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(discoveredState),
    "Validate pairing material before connection launch.");

var pairedState = stateClient.BuildPairingValidatedState(discoveredState, pairingMaterial);
ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(pairedState),
    "Prepare Core connection preflight before connection launch.");

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(
        stateClient.BuildPreflightValidatedState(
            pairedState,
            BuildSnapshot(BuildPlan(peerDeviceId: "other-mac", fingerprint: Fingerprint, liveReady: false)))),
    "Connection launch request peer does not match pairing material.");

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(
        stateClient.BuildPreflightValidatedState(
            pairedState,
            BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: "bad-fingerprint", liveReady: false)))),
    "Connection launch request fingerprint does not match pairing material.");

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(
        stateClient.BuildPreflightValidatedState(
            pairedState,
            BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: Fingerprint, liveReady: false, digestLength: 31)))),
    "Connection launch requires a 32-byte transport binding digest from Core preflight.");

var preflightOnlyRequest = stateClient.BuildConnectionLaunchRequest(
    stateClient.BuildPreflightValidatedState(
        pairedState,
        BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: Fingerprint, liveReady: false))));
AssertEqual(ConnectionLaunchAdapterKind.WebRtcDataChannel, preflightOnlyRequest.Plan.AdapterKind, "adapter kind");
AssertEqual("adapter pending", preflightOnlyRequest.Plan.AdapterBinding, "preflight adapter binding");

await ExpectThrowsAsync<NotSupportedException>(
    () => new DummyEngineClient().ConnectAsync(preflightOnlyRequest),
    "Connection launch requires a live Windows transport adapter; the current request is preflight-only.");

var liveRequest = stateClient.BuildConnectionLaunchRequest(
    stateClient.BuildPreflightValidatedState(
        pairedState,
        BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: Fingerprint, liveReady: true, adapterBinding: "smoke live adapter"))));
var engine = new DummyEngineClient();
await engine.ConnectAsync(liveRequest);
AssertEqual(EngineConnectionState.Connected, engine.State, "dummy live adapter state");
await engine.SendHeartbeatAsync();
await engine.DisconnectAsync();
AssertEqual(EngineConnectionState.Disconnected, engine.State, "dummy disconnect state");

Console.WriteLine("windows-connection-launch-smoke: ok");

static ConnectionPreflightSnapshot BuildSnapshot(ConnectionPreflightPlan plan) =>
    new(DateTimeOffset.UnixEpoch, plan, Array.Empty<ConnectionPreflightFact>());

static ConnectionPreflightPlan BuildPlan(
    string peerDeviceId,
    string fingerprint,
    bool liveReady,
    int digestLength = 32,
    string adapterBinding = "adapter pending") =>
    new(
        peerDeviceId,
        fingerprint,
        CoreTransportKind.WebRtcDataChannel,
        CoreTransportAuditCode.WebRtcInterop,
        RelayRequired: false,
        RelayAllowed: true,
        CoreCryptoSuiteKind.XWingHybrid,
        0x1001,
        CoreCryptoSuiteAuditCode.HybridPqcPreferred,
        Sbp2Enabled: true,
        (nuint)1024,
        (nuint)16,
        Enumerable.Range(0, digestLength).Select(value => (byte)value).ToArray(),
        ConnectionLaunchAdapterKind.WebRtcDataChannel,
        liveReady,
        adapterBinding);

static void ExpectThrows<T>(Action action, string messageFragment)
    where T : Exception
{
    try
    {
        action();
    }
    catch (T ex) when (ex.Message.Contains(messageFragment, StringComparison.Ordinal))
    {
        return;
    }
    catch (Exception ex)
    {
        throw new InvalidOperationException(
            $"Expected {typeof(T).Name} containing '{messageFragment}', got {ex.GetType().Name}: {ex.Message}");
    }

    throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}'.");
}

static async Task ExpectThrowsAsync<T>(Func<Task> action, string messageFragment)
    where T : Exception
{
    try
    {
        await action();
    }
    catch (T ex) when (ex.Message.Contains(messageFragment, StringComparison.Ordinal))
    {
        return;
    }
    catch (Exception ex)
    {
        throw new InvalidOperationException(
            $"Expected {typeof(T).Name} containing '{messageFragment}', got {ex.GetType().Name}: {ex.Message}");
    }

    throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}'.");
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}
'@

    & dotnet restore $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows connection launch smoke restore failed."

    & dotnet run --project $testProject --no-restore
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows connection launch smoke run failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTempRoot
        $isOwnedSmokeDir = $resolvedTempRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-win-launch-smoke-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
