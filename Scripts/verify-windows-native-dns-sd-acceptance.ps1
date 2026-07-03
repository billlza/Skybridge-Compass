param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateRange(1, 30)]
    [int]$ExtendedSearchSeconds = 2,
    [switch]$RequirePeer,
    [string]$ExpectedDeviceId = "",
    [string]$ExpectedFingerprint = "",
    [string]$SearchText = ""
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

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
}

function Invoke-NativeTool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$FailureMessage
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Output $stdout.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Output $stderr.TrimEnd()
    }

    Assert-True -Condition ($process.ExitCode -eq 0) -Message $FailureMessage
}

$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/SkybridgeNativeLibraryResolver.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryClient.cs",
    "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs",
    "windows/Skybridge.WinClient/Services/NativeWindowsDnsSdBrowseClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing native DNS-SD acceptance source file: $sourceFile"
}

$nativeProviderSource = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/NativeWindowsDnsSdBrowseClient.cs")
foreach ($nativeLifecycleSignal in @(
    "DnsServiceBrowseCancel",
    "DnsServiceResolveCancel",
    "DnsRecordListFree",
    "DnsServiceFreeInstance"
)) {
    Assert-True -Condition ($nativeProviderSource.Contains($nativeLifecycleSignal)) -Message "Native DNS-SD provider missing lifecycle signal: $nativeLifecycleSignal"
}

$coreManifest = Join-Path $RepoRoot "core/Skybridge-core/Cargo.toml"
if (-not (Test-Path -LiteralPath $coreManifest)) {
    $coreManifest = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
}

Assert-True -Condition (Test-Path -LiteralPath $coreManifest) -Message "Missing Rust Core manifest for native DNS-SD acceptance: $coreManifest"
Invoke-NativeTool `
    -FilePath "cargo" `
    -Arguments @("build", "--manifest-path", $coreManifest, "--lib") `
    -FailureMessage "Rust Core native library build failed for native DNS-SD acceptance."

$coreRoot = Split-Path -Parent $coreManifest
$nativeDll = Join-Path $coreRoot "target/debug/skybridge_core.dll"
Assert-True -Condition (Test-Path -LiteralPath $nativeDll) -Message "Missing skybridge_core.dll for Core TXT parsing: $nativeDll"

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-native-dns-sd-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinNativeDnsSdAcceptance.csproj"
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

var options = AcceptanceOptions.Parse(args);
AssertEqual(true, typeof(IWindowsDnsSdBrowseClient).IsAssignableFrom(typeof(NativeWindowsDnsSdBrowseClient)), "native provider interface");

var browser = new WindowsDiscoveryBrowserClient(
    new CoreDiscoveryClient(new CoreBridge()),
    new NativeWindowsDnsSdBrowseClient());
var snapshot = await browser.BuildReadOnlySnapshotAsync(
    new DiscoveryBrowserRequest(
        DiscoveryBrowserAction.Start,
        "",
        "",
        options.SearchText,
        CompatibilityMode: false,
        options.ExtendedSearchSeconds));

var factText = string.Join(
    Environment.NewLine,
    snapshot.Facts.Select(fact => $"{fact.Label}|{fact.Value}|{fact.Detail}"));
AssertContains(factText, "DnsServiceBrowse", "native browse API fact");
AssertContains(factText, "DnsServiceResolve", "native resolve API fact");

foreach (var fact in snapshot.Facts)
{
    if (fact.Value.Equals("unavailable", StringComparison.OrdinalIgnoreCase) ||
        fact.Value.Equals("marshal error", StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException($"Native DNS-SD provider is not acceptable: {fact.Label} {fact.Value} {fact.Detail}");
    }
}

if (options.RequirePeer && snapshot.Peers.Count == 0)
{
    throw new InvalidOperationException("Expected at least one Core-validated _skybridge peer from native DNS-SD, but none were discovered.");
}

if (!string.IsNullOrWhiteSpace(options.ExpectedDeviceId))
{
    AssertEqual(
        true,
        snapshot.Peers.Any(peer => peer.Peer.DeviceId.Equals(options.ExpectedDeviceId, StringComparison.OrdinalIgnoreCase)),
        $"expected deviceId {options.ExpectedDeviceId}");
}

if (!string.IsNullOrWhiteSpace(options.ExpectedFingerprint))
{
    AssertEqual(
        true,
        snapshot.Peers.Any(peer => peer.Peer.PublicKeyFingerprint.Equals(options.ExpectedFingerprint, StringComparison.OrdinalIgnoreCase)),
        $"expected fingerprint {options.ExpectedFingerprint}");
}

foreach (var peer in snapshot.Peers)
{
    AssertContains(peer.TrustSummary, "fingerprint only", "fingerprint-only trust summary");
    Console.WriteLine($"peer: {peer.Peer.DeviceId}|{peer.Peer.DisplayName}|{peer.Peer.PlatformLabel}|{peer.CapabilitiesSummary}");
}

foreach (var fact in snapshot.Facts)
{
    Console.WriteLine($"fact: {fact.Label}|{fact.Value}|{fact.Detail}");
}

Console.WriteLine($"windows-native-dns-sd-acceptance: ok peers={snapshot.Peers.Count} facts={snapshot.Facts.Count}");

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
        throw new InvalidOperationException($"{label}: expected text to contain '{expected}'. Text was:{Environment.NewLine}{text}");
    }
}

sealed record AcceptanceOptions(
    int ExtendedSearchSeconds,
    bool RequirePeer,
    string ExpectedDeviceId,
    string ExpectedFingerprint,
    string SearchText)
{
    public static AcceptanceOptions Parse(string[] args)
    {
        var seconds = 2;
        var requirePeer = false;
        var expectedDeviceId = "";
        var expectedFingerprint = "";
        var searchText = "";

        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--seconds":
                    seconds = int.Parse(RequireValue(args, ++index, "--seconds"));
                    break;
                case "--require-peer":
                    requirePeer = true;
                    break;
                case "--expected-device-id":
                    expectedDeviceId = RequireValue(args, ++index, "--expected-device-id");
                    break;
                case "--expected-fingerprint":
                    expectedFingerprint = RequireValue(args, ++index, "--expected-fingerprint");
                    break;
                case "--search":
                    searchText = RequireValue(args, ++index, "--search");
                    break;
                default:
                    throw new InvalidOperationException($"Unknown argument: {args[index]}");
            }
        }

        if (seconds < 1 || seconds > 30)
        {
            throw new InvalidOperationException("--seconds must be between 1 and 30.");
        }

        return new AcceptanceOptions(seconds, requirePeer, expectedDeviceId, expectedFingerprint, searchText);
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

    Invoke-NativeTool `
        -FilePath "dotnet" `
        -Arguments @("restore", $testProject) `
        -FailureMessage "Windows native DNS-SD acceptance restore failed."

    $oldPath = $env:PATH
    $env:PATH = "$(Split-Path -Parent $nativeDll);$oldPath"
    try {
        $runArgs = @(
            "run",
            "--project",
            $testProject,
            "--no-restore",
            "--",
            "--seconds",
            $ExtendedSearchSeconds.ToString()
        )

        if ($RequirePeer) {
            $runArgs += "--require-peer"
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) {
            $runArgs += @("--expected-device-id", $ExpectedDeviceId)
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
            $runArgs += @("--expected-fingerprint", $ExpectedFingerprint)
        }

        if (-not [string]::IsNullOrWhiteSpace($SearchText)) {
            $runArgs += @("--search", $SearchText)
        }

        Invoke-NativeTool `
            -FilePath "dotnet" `
            -Arguments $runArgs `
            -FailureMessage "Windows native DNS-SD acceptance run failed."
    }
    finally {
        $env:PATH = $oldPath
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTempRoot
        $isOwnedSmokeDir = $resolvedTempRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-win-native-dns-sd-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
