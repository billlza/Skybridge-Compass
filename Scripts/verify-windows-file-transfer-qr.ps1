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

$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows file-transfer QR source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-file-transfer-qr-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinFileTransferQrSmoke.csproj"
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
  <ItemGroup>
    <PackageReference Include="QRCoder" Version="1.8.0" />
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using System.Text;
using System.Text.Json;
using Skybridge.WinClient.Services;

var client = new FileTransferWorkspaceClient(new CoreBridge());
AssertEqual(true, client.CanGenerateShareQr(), "share QR readiness");
AssertEqual("Preparing QR...", client.BuildShareQrPendingStatus(), "share QR pending status");

var result = await client.BuildShareQrActionAsync();
AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyStatus, result.Status, "share QR status");
AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyMessage, result.Message, "share QR message");
AssertContains(result.Detail, "intent=FT-0001", "share QR intent id");
AssertContains(result.Detail, "no local files were read", "share QR file safety");
AssertContains(result.Detail, "no transport or signaling session was started", "share QR transport safety");
AssertEqual(true, !string.IsNullOrWhiteSpace(result.ShareQrPayload), "share QR payload");
AssertEqual(true, result.ShareQrPayload!.StartsWith("skybridge://file-transfer?data=", StringComparison.Ordinal), "share QR URI");
AssertEqual(true, !string.IsNullOrWhiteSpace(result.ShareQrPngBase64), "share QR PNG base64");

var png = Convert.FromBase64String(result.ShareQrPngBase64!);
AssertEqual(true, png.Length > 32, "share QR PNG length");
AssertEqual((byte)0x89, png[0], "share QR PNG signature byte 0");
AssertEqual((byte)0x50, png[1], "share QR PNG signature byte 1");
AssertEqual((byte)0x4E, png[2], "share QR PNG signature byte 2");
AssertEqual((byte)0x47, png[3], "share QR PNG signature byte 3");

using var document = JsonDocument.Parse(Encoding.UTF8.GetString(DecodeShareQrPayload(result.ShareQrPayload!)));
var root = document.RootElement;
var payload = root.GetProperty("payload");
AssertEqual(1, payload.GetProperty("version").GetInt32(), "share QR payload version");
AssertEqual("FT-0001", payload.GetProperty("intentId").GetString(), "share QR payload intent id");
AssertEqual("Windows", payload.GetProperty("deviceType").GetString(), "share QR payload device type");
AssertEqual("intent-only", payload.GetProperty("shareMode").GetString(), "share QR payload mode");
AssertEqual(0, payload.GetProperty("manifestFileCount").GetInt32(), "share QR manifest file count");
AssertEqual(0L, payload.GetProperty("manifestBytes").GetInt64(), "share QR manifest bytes");
AssertEqual(true, payload.GetProperty("capabilities").EnumerateArray().Any(value => value.GetString() == "file-transfer"), "share QR file-transfer capability");
AssertEqual(true, Convert.FromBase64String(root.GetProperty("signatureBase64").GetString()!).Length == 64, "share QR raw P256 signature");
AssertEqual(true, Convert.FromBase64String(root.GetProperty("publicKeyBase64").GetString()!).Length == 64, "share QR raw P256 public key");
AssertEqual(true, !string.IsNullOrWhiteSpace(root.GetProperty("timestamp").GetString()), "share QR timestamp");
AssertEqual(64, root.GetProperty("publicKeyFingerprint").GetString()!.Length, "share QR public key fingerprint");

Console.WriteLine("windows-file-transfer-qr: ok");

static byte[] DecodeShareQrPayload(string uri)
{
    const string prefix = "skybridge://file-transfer?data=";
    if (!uri.StartsWith(prefix, StringComparison.Ordinal))
    {
        throw new InvalidOperationException("Unexpected file-transfer QR URI prefix.");
    }

    var value = uri[prefix.Length..].Replace('-', '+').Replace('_', '/');
    var padding = value.Length % 4;
    if (padding != 0)
    {
        value = value.PadRight(value.Length + 4 - padding, '=');
    }

    return Convert.FromBase64String(value);
}

static void AssertContains(string value, string expected, string label)
{
    if (!value.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"{label}: expected to contain {expected}, got {value}");
    }
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected {expected}, got {actual}");
    }
}
'@

    dotnet run --project $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows-file-transfer-qr smoke failed with exit code $LASTEXITCODE"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
