param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$ProofPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint,
    [ValidateRange(1, 600000)]
    [UInt64]$MaxProofAgeMs = 60000
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

Assert-True -Condition (Test-Path -LiteralPath $ProofPath) -Message "Missing Windows WebRTC proof file: $ProofPath"
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) -Message "Windows WebRTC proof gate requires -ExpectedDeviceId."
Assert-True -Condition ($ExpectedFingerprint -match '^[0-9a-f]{64}$') -Message "Windows WebRTC proof gate requires -ExpectedFingerprint as 64 lowercase hex characters."

$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/SkybridgeNativeLibraryResolver.cs",
    "windows/Skybridge.WinClient/Services/IEngineClient.cs",
    "windows/Skybridge.WinClient/Services/FfiEngineClient.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryClient.cs",
    "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs",
    "windows/Skybridge.WinClient/Services/ConnectionLaunchRequest.cs",
    "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs",
    "windows/Skybridge.WinClient/Services/WindowsTransportAdapterClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows WebRTC proof source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-webrtc-proof-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinWebRtcProof.csproj"
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

var options = ProofOptions.Parse(args);
var peer = new DiscoveredPeer(
    CoreDiscoveryServiceKind.QuicPrimary,
    options.ExpectedDeviceId,
    "Verified Mac",
    CorePeerPlatform.Apple,
    "macOS",
    options.ExpectedFingerprint,
    "apple,webrtc,tcp,relay",
    "1",
    PeerCapabilities.Apple());
var pairingMaterial = new PairingMaterial(
    options.ExpectedDeviceId,
    "Verified Mac",
    "macOS",
    options.ExpectedFingerprint,
    new byte[] { 1, 2, 3, 4 },
    VerifiedAgainstDiscoveryFingerprint: true,
    "windows-webrtc-proof-gate");
var request = new WindowsTransportAdapterRequest(
    peer,
    pairingMaterial,
    CoreTransportKind.WebRtcDataChannel,
    CoreTransportAuditCode.WebRtcInterop,
    RelayRequired: false,
    RelayAllowed: true,
    PeerCapabilities.Windows(),
    peer.Capabilities,
    NetworkPath.CrossNatPath());

var adapter = new VerifiedWebRtcDataChannelTransportAdapterClient(
    new WindowsVerifiedWebRtcDataChannelOptions(options.ProofPath, options.MaxProofAgeMs));
var snapshot = await adapter.PrepareAsync(request);
AssertEqual(true, snapshot.IsLiveAdapterReady, "verified WebRTC live readiness");
AssertEqual(ConnectionLaunchAdapterKind.WebRtcDataChannel, snapshot.AdapterKind, "verified WebRTC adapter kind");
AssertEqual(32, snapshot.TransportSecretFingerprint.Length, "verified WebRTC secret fingerprint length");
AssertEqual(32, snapshot.CapabilityDigest.Length, "verified WebRTC capability digest length");
AssertContains(snapshot.AdapterBinding, "webrtc", "verified WebRTC adapter binding");
AssertContains(snapshot.SelectedCandidatePair, "webrtc", "verified WebRTC selected candidate pair");
AssertContains(string.Join(Environment.NewLine, snapshot.Facts.Select(fact => fact.Detail)), "SBF1", "verified WebRTC SBF1 fact");

var material = snapshot.BuildTransportBindingMaterial(CoreTransportKind.WebRtcDataChannel);
AssertEqual(CoreTransportKind.WebRtcDataChannel, material.Transport, "verified WebRTC binding transport");
AssertEqual(snapshot.LocalEndpoint, material.LocalEndpoint, "verified WebRTC local endpoint");

await ExpectThrowsAsync<InvalidOperationException>(
    () => adapter.PrepareAsync(
        request with
        {
            TransportKind = CoreTransportKind.AppleNative,
            TransportAudit = CoreTransportAuditCode.AppleNativeDefault
        }),
    "Windows verified WebRTC adapter must not select AppleNative");

Console.WriteLine($"windows-webrtc-proof: ok proof={options.ProofPath}");
Console.WriteLine($"windows-webrtc-proof: binding={snapshot.AdapterBinding}");
Console.WriteLine($"windows-webrtc-proof: endpoints={snapshot.LocalEndpoint}->{snapshot.RemoteEndpoint}");
Console.WriteLine($"windows-webrtc-proof: candidate={snapshot.SelectedCandidatePair}");

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}

static void AssertContains(string text, string expected, string label)
{
    if (!text.Contains(expected, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException($"{label}: expected '{text}' to contain '{expected}'.");
    }
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
        throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}', got {ex.GetType().Name}: {ex.Message}");
    }

    throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}'.");
}

sealed record ProofOptions(
    string ProofPath,
    string ExpectedDeviceId,
    string ExpectedFingerprint,
    ulong MaxProofAgeMs)
{
    public static ProofOptions Parse(string[] args)
    {
        var proofPath = "";
        var expectedDeviceId = "";
        var expectedFingerprint = "";
        ulong maxProofAgeMs = 60000;

        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--proof":
                    proofPath = RequireValue(args, ++index, "--proof");
                    break;
                case "--expected-device-id":
                    expectedDeviceId = RequireValue(args, ++index, "--expected-device-id");
                    break;
                case "--expected-fingerprint":
                    expectedFingerprint = RequireValue(args, ++index, "--expected-fingerprint");
                    break;
                case "--max-age-ms":
                    maxProofAgeMs = ulong.Parse(RequireValue(args, ++index, "--max-age-ms"));
                    break;
                default:
                    throw new InvalidOperationException($"Unknown argument: {args[index]}");
            }
        }

        if (string.IsNullOrWhiteSpace(proofPath))
        {
            throw new InvalidOperationException("--proof is required.");
        }

        if (string.IsNullOrWhiteSpace(expectedDeviceId))
        {
            throw new InvalidOperationException("--expected-device-id is required.");
        }

        if (!System.Text.RegularExpressions.Regex.IsMatch(expectedFingerprint, "^[0-9a-f]{64}$"))
        {
            throw new InvalidOperationException("--expected-fingerprint must be 64 lowercase hex characters.");
        }

        if (maxProofAgeMs == 0)
        {
            throw new InvalidOperationException("--max-age-ms must be greater than zero.");
        }

        return new ProofOptions(proofPath, expectedDeviceId, expectedFingerprint, maxProofAgeMs);
    }

    private static string RequireValue(string[] args, int index, string option)
    {
        if (index >= args.Length)
        {
            throw new InvalidOperationException($"{option} requires a value.");
        }

        return args[index];
    }
}
'@

    & dotnet restore $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC proof restore failed."

    & dotnet build $testProject --no-restore
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC proof build failed."

    & dotnet run --project $testProject --no-build -- --proof $ProofPath --expected-device-id $ExpectedDeviceId --expected-fingerprint $ExpectedFingerprint --max-age-ms $MaxProofAgeMs.ToString()
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC proof run failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTempRoot
        $isOwnedSmokeDir = $resolvedTempRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-win-webrtc-proof-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
