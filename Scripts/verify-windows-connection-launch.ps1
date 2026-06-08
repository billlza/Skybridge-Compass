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
    "windows/Skybridge.WinClient/Services/NativeWindowsDnsSdBrowseClient.cs",
    "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs",
    "windows/Skybridge.WinClient/Services/CrossNetworkConnectionClient.cs",
    "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs",
    "windows/Skybridge.WinClient/Services/ConnectionLaunchRequest.cs",
    "windows/Skybridge.WinClient/Services/WindowsTransportAdapterClient.cs",
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
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(
        stateClient.BuildPreflightValidatedState(
            pairedState,
            BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: Fingerprint, liveReady: false, localEndpoint: "")))),
    "Connection launch requires a local transport endpoint.");

ExpectThrows<InvalidOperationException>(
    () => stateClient.BuildConnectionLaunchRequest(
        stateClient.BuildPreflightValidatedState(
            pairedState,
            BuildSnapshot(BuildPlan(peerDeviceId: "mac-1", fingerprint: Fingerprint, liveReady: false, timestampWindowMs: 0)))),
    "Connection launch requires a non-zero transport timestamp window.");

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

var recordingDiscovery = new RecordingDiscoveryClient(peer);
var recordingDnsSd = new RecordingDnsSdBrowseClient(new WindowsDnsSdBrowseSnapshot(
    new[]
    {
        new WindowsDnsSdResolvedTxtRecord(
            "_skybridge._udp",
            "deviceId=mac-1;pubKeyFP=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
            "Desk Mac",
            "desk-mac.local",
            11550)
    },
    new[]
    {
        new DiscoveryBrowserFact(
            "Native browse",
            "resolved",
            "Injected DNS-SD smoke record; production provider must use DnsServiceBrowse/DnsServiceResolve.")
    }));
var discoveryBrowser = new WindowsDiscoveryBrowserClient(recordingDiscovery, recordingDnsSd);
AssertEqual(true, typeof(IWindowsDnsSdBrowseClient).IsAssignableFrom(typeof(NativeWindowsDnsSdBrowseClient)), "native DNS-SD provider interface");
var browserSnapshot = await discoveryBrowser.BuildReadOnlySnapshotAsync(
    new DiscoveryBrowserRequest(
        DiscoveryBrowserAction.Start,
        "",
        "",
        "desk",
        CompatibilityMode: false,
        ExtendedSearchSeconds: 15));
AssertEqual(1, recordingDnsSd.Requests.Count, "DNS-SD browse request count");
AssertEqual("_skybridge._udp,_skybridge._tcp", string.Join(",", recordingDnsSd.Requests[0].QueryOrder), "DNS-SD query order");
AssertEqual(1, recordingDiscovery.ParseCalls.Count, "discovery parser call count");
AssertEqual("_skybridge._udp", recordingDiscovery.ParseCalls[0].Service, "discovery parser service");
AssertEqual(1, browserSnapshot.Peers.Count, "DNS-SD Core-validated peer count");
AssertContains(browserSnapshot.Peers[0].TrustSummary, "fingerprint only", "browser trust summary");
AssertContains(
    browserSnapshot.Facts.Last().Detail,
    "desk-mac.local:11550",
    "Core TXT parse fact source");

var pendingAdapter = await new PendingWindowsTransportAdapterClient().PrepareAsync(
    new WindowsTransportAdapterRequest(
        peer,
        pairingMaterial,
        CoreTransportKind.WebRtcDataChannel,
        CoreTransportAuditCode.WebRtcInterop,
        RelayRequired: false,
        RelayAllowed: true,
        PeerCapabilities.Windows(),
        peer.Capabilities,
        NetworkPath.CrossNatPath()));
AssertEqual(false, pendingAdapter.IsLiveAdapterReady, "pending adapter live readiness");
AssertEqual("adapter pending", pendingAdapter.AdapterBinding, "pending adapter binding");
AssertEqual("windows-preflight.local:443", pendingAdapter.LocalEndpoint, "pending adapter local endpoint");
AssertEqual("WebRtcDataChannel/preflight-candidate", pendingAdapter.SelectedCandidatePair, "pending adapter candidate");
AssertEqual(32, pendingAdapter.TransportSecretFingerprint.Length, "pending adapter secret fingerprint length");
AssertEqual(32, pendingAdapter.CapabilityDigest.Length, "pending adapter capability digest length");
var pendingBindingMaterial = pendingAdapter.BuildTransportBindingMaterial(CoreTransportKind.WebRtcDataChannel);
AssertEqual("windows-preflight.local:443", pendingBindingMaterial.LocalEndpoint, "pending binding local endpoint");

var crossNetworkClient = new CrossNetworkConnectionClient();
var verifiedDynamicSnapshot = await crossNetworkClient.BuildReadOnlySnapshotAsync(
    new CrossNetworkConnectionRequest(
        CrossNetworkConnectionAction.ScanQrCode,
        BuildDynamicQrInput(includeSignedOsVersion: true, tamperDeviceName: false),
        "",
        ""));
AssertEqual("QR signature verified", verifiedDynamicSnapshot.Status, "dynamic QR verified status");
AssertEqual("DynamicQRCodeData", Fact(verifiedDynamicSnapshot, "QR schema").Value, "dynamic QR schema");
AssertEqual("verified", Fact(verifiedDynamicSnapshot, "Signature").Value, "dynamic QR signature fact");
AssertContains(Fact(verifiedDynamicSnapshot, "Signature").Detail, "P256 dynamic canonical signature verified", "dynamic QR signature detail");

var unverifiableDynamicSnapshot = await crossNetworkClient.BuildReadOnlySnapshotAsync(
    new CrossNetworkConnectionRequest(
        CrossNetworkConnectionAction.ScanQrCode,
        BuildDynamicQrInput(includeSignedOsVersion: false, tamperDeviceName: false),
        "",
        ""));
AssertEqual("QR payload validated", unverifiableDynamicSnapshot.Status, "dynamic QR unverifiable status");
AssertEqual("unverifiable", Fact(unverifiableDynamicSnapshot, "Signature").Value, "dynamic QR unverifiable signature fact");
AssertContains(Fact(unverifiableDynamicSnapshot, "Signature").Detail, "generator osVersion", "dynamic QR unverifiable detail");

await ExpectThrowsAsync<InvalidOperationException>(
    () => crossNetworkClient.BuildReadOnlySnapshotAsync(
        new CrossNetworkConnectionRequest(
            CrossNetworkConnectionAction.ScanQrCode,
            BuildDynamicQrInput(includeSignedOsVersion: true, tamperDeviceName: true),
            "",
            "")),
    "QR dynamic canonical signature verification failed.");

Console.WriteLine("windows-connection-launch-smoke: ok");

static ConnectionPreflightSnapshot BuildSnapshot(ConnectionPreflightPlan plan) =>
    new(DateTimeOffset.UnixEpoch, plan, Array.Empty<ConnectionPreflightFact>());

static ConnectionPreflightPlan BuildPlan(
    string peerDeviceId,
    string fingerprint,
    bool liveReady,
    int digestLength = 32,
    string adapterBinding = "adapter pending",
    string localEndpoint = "windows-preflight.local:443",
    string remoteEndpoint = "mac-1.skybridge-preflight.local:443",
    string selectedCandidatePair = "WebRtcDataChannel/preflight-candidate",
    string? relayId = null,
    ulong timestampWindowMs = 10_000) =>
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
        adapterBinding,
        localEndpoint,
        remoteEndpoint,
        selectedCandidatePair,
        relayId,
        timestampWindowMs);

static string BuildDynamicQrInput(bool includeSignedOsVersion, bool tamperDeviceName)
{
    const string sessionId = "smoke-session";
    const string deviceName = "Desk Mac";
    const string deviceFingerprint = "0011223344556677";
    const string osVersion = "Version 15.5 (Build 24F74)";
    var timestampText = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0)
        .ToString("F3", CultureInfo.InvariantCulture);
    var expiresText = ((DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeMilliseconds() / 1000.0) - 978_307_200.0)
        .ToString("F3", CultureInfo.InvariantCulture);
    var agreementPublicKey = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();

    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var signingPublicKey = ExportP256PublicKey(signingKey);
    var signingFingerprint = Convert.ToHexString(SHA256.HashData(signingPublicKey)).ToLowerInvariant();
    var canonical = BuildMacDynamicQrCanonical(
        deviceFingerprint,
        deviceName,
        osVersion,
        timestampText,
        signingFingerprint);
    var signature = signingKey.SignData(
        Encoding.UTF8.GetBytes(canonical),
        HashAlgorithmName.SHA256,
        DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    using var jsonStream = new MemoryStream();
    using (var writer = new Utf8JsonWriter(jsonStream))
    {
        writer.WriteStartObject();
        writer.WriteNumber("version", 2);
        writer.WriteString("sessionID", sessionId);
        writer.WriteString("deviceName", tamperDeviceName ? "Desk Mac Tampered" : deviceName);
        writer.WriteString("deviceFingerprint", deviceFingerprint);
        writer.WriteString("publicKey", Convert.ToBase64String(agreementPublicKey));
        writer.WriteString("signingPublicKey", Convert.ToBase64String(signingPublicKey));
        writer.WriteString("signature", Convert.ToBase64String(signature));
        writer.WritePropertyName("signatureTimestamp");
        writer.WriteRawValue(timestampText);
        writer.WriteStartArray("iceServers");
        writer.WriteStringValue("stun:stun.l.google.com:19302");
        writer.WriteEndArray();
        writer.WritePropertyName("expiresAt");
        writer.WriteRawValue(expiresText);
        if (includeSignedOsVersion)
        {
            writer.WriteString("osVersion", osVersion);
        }

        writer.WriteEndObject();
    }

    return "skybridge://connect/" + Base64UrlEncode(jsonStream.ToArray());
}

static string BuildMacDynamicQrCanonical(
    string deviceFingerprint,
    string deviceName,
    string osVersion,
    string timestampText,
    string signingFingerprint) =>
    $"id={deviceFingerprint}|name={deviceName}|type=macOS|address=0.0.0.0|port=0|os={osVersion}|cap=p2p,cross-network|ts={timestampText}|fp={signingFingerprint}";

static byte[] ExportP256PublicKey(ECDsa signingKey)
{
    var parameters = signingKey.ExportParameters(false);
    if (parameters.Q.X is null || parameters.Q.Y is null)
    {
        throw new InvalidOperationException("P256 smoke key is missing public coordinates.");
    }

    var publicKey = new byte[65];
    publicKey[0] = 0x04;
    parameters.Q.X.CopyTo(publicKey.AsSpan(1, 32));
    parameters.Q.Y.CopyTo(publicKey.AsSpan(33, 32));
    return publicKey;
}

static string Base64UrlEncode(byte[] value) =>
    Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');

static CrossNetworkConnectionFact Fact(CrossNetworkConnectionSnapshot snapshot, string label) =>
    snapshot.Facts.Single(fact => string.Equals(fact.Label, label, StringComparison.Ordinal));

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

static void AssertContains(string text, string expected, string label)
{
    if (!text.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"{label}: expected '{text}' to contain '{expected}'.");
    }
}

sealed class RecordingDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    private readonly WindowsDnsSdBrowseSnapshot _snapshot;

    public RecordingDnsSdBrowseClient(WindowsDnsSdBrowseSnapshot snapshot)
    {
        _snapshot = snapshot;
    }

    public List<WindowsDnsSdBrowseRequest> Requests { get; } = new();

    public Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(WindowsDnsSdBrowseRequest request)
    {
        Requests.Add(request);
        return Task.FromResult(_snapshot);
    }
}

sealed class RecordingDiscoveryClient : IDiscoveryClient
{
    private readonly DiscoveredPeer _peer;

    public RecordingDiscoveryClient(DiscoveredPeer peer)
    {
        _peer = peer;
    }

    public List<(string Service, string TxtRecord)> ParseCalls { get; } = new();

    public string BuildPendingStatus() => "Parsing...";

    public bool CanParseAdvertisement(string service, string txtRecord) =>
        !string.IsNullOrWhiteSpace(service) && !string.IsNullOrWhiteSpace(txtRecord);

    public Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord)
    {
        ParseCalls.Add((service, txtRecord));
        return Task.FromResult(_peer);
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
