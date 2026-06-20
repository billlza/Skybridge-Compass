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

# Only the OS-free core is compiled into the plain net10.0 smoke console. The Win32
# monitor (WindowsClipboardSyncService.cs) is exercised on the box by the live
# clipboard test; see the README note in this script's output for how it is driven.
$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/WindowsClipboardSyncCore.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows clipboard-sync source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-clipboard-sync-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinClipboardSyncSmoke.csproj"
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

    # The smoke drives the internal codec via InternalsVisibleTo-free reflection-light
    # access: WindowsClipboardSyncCore types are `internal`, and because the temp
    # project compiles the SAME source files into the SAME assembly, the test code can
    # reference them directly. (Same technique the file-transfer-qr smoke uses.)
    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using System;
using System.Text;
using Skybridge.WinClient.Services;

// 1) Envelope seal/open round-trip (AES-256-GCM, nonce||ct||tag).
var keyProvider = new DerivedDevelopmentKeyProvider("smoke-key");
var key = keyProvider.CurrentKey();
AssertEqual(32, key.Length, "session key is AES-256 (32 bytes)");

var cleartext = Encoding.UTF8.GetBytes("hello clipboard 你好");
var envelope = ClipboardEnvelope.Seal(cleartext, key);
AssertEqual(ClipboardEnvelope.NonceSize + cleartext.Length + ClipboardEnvelope.TagSize, envelope.Length, "envelope length = nonce + ct + tag");
var opened = ClipboardEnvelope.Open(envelope, key);
AssertSequenceEqual(cleartext, opened, "seal/open round-trips cleartext");

// 1a) Two seals of the same cleartext use different nonces (random nonce per seal).
var envelope2 = ClipboardEnvelope.Seal(cleartext, key);
AssertEqual(false, AsHex(envelope[..ClipboardEnvelope.NonceSize]) == AsHex(envelope2[..ClipboardEnvelope.NonceSize]), "nonce is randomized per seal");

// 1b) Tamper -> open throws (GCM tag verify).
var tampered = (byte[])envelope.Clone();
tampered[^1] ^= 0xFF;
AssertThrows(() => ClipboardEnvelope.Open(tampered, key), "tampered envelope fails to open");

// 1c) Wrong key -> open throws.
var wrongKey = new DerivedDevelopmentKeyProvider("other-key").CurrentKey();
AssertThrows(() => ClipboardEnvelope.Open(envelope, wrongKey), "wrong key fails to open");

// 2) Text/image payload framing round-trip ([kind:1][content:N]).
var textPayload = ClipboardPayload.Text("framed text");
var framedText = textPayload.Frame();
AssertEqual((byte)ClipboardItemKind.Text, framedText[0], "text frame kind byte = 0");
var unframedText = ClipboardPayload.Unframe(framedText);
AssertEqual("framed text", unframedText.AsText(), "text frame round-trips");

var pngBytes = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3 };
var imagePayload = ClipboardPayload.ImagePng(pngBytes);
var framedImage = imagePayload.Frame();
AssertEqual((byte)ClipboardItemKind.ImagePng, framedImage[0], "image frame kind byte = 1");
var unframedImage = ClipboardPayload.Unframe(framedImage);
AssertEqual(ClipboardItemKind.ImagePng, unframedImage.Kind, "image frame kind round-trips");
AssertSequenceEqual(pngBytes, unframedImage.Content.ToArray(), "image frame content round-trips");

// 2a) Empty / unknown-kind frames are rejected.
AssertThrows(() => ClipboardPayload.Unframe(Array.Empty<byte>()), "empty frame rejected");
AssertThrows(() => ClipboardPayload.Unframe(new byte[] { 0x09, 1, 2 }), "unknown kind rejected");

// 3) Dedup: identical local copies are only broadcast once.
var codec = new ClipboardSyncCodec(keyProvider);
var first = codec.TryBuildOutboundEnvelope(ClipboardPayload.Text("dup"));
AssertEqual(true, first is not null, "first copy is broadcast");
var second = codec.TryBuildOutboundEnvelope(ClipboardPayload.Text("dup"));
AssertEqual(true, second is null, "identical re-copy is deduped");
var changed = codec.TryBuildOutboundEnvelope(ClipboardPayload.Text("different"));
AssertEqual(true, changed is not null, "a changed copy is broadcast");

// 4) Loop suppression end-to-end: sender seals -> receiver decodes+applies ->
//    the receiver's own re-observed local change must NOT be re-broadcast.
var sender = new ClipboardSyncCodec(new DerivedDevelopmentKeyProvider("shared"));
var receiver = new ClipboardSyncCodec(new DerivedDevelopmentKeyProvider("shared"));

var outbound = sender.TryBuildOutboundEnvelope(ClipboardPayload.Text("loop-me"));
AssertEqual(true, outbound is not null, "sender produces envelope");

var inbound = receiver.TryDecodeInbound(outbound!);
AssertEqual(true, inbound is not null, "receiver decodes envelope");
AssertEqual("loop-me", inbound!.Value.AsText(), "receiver recovers text");

// Receiver marks applied (as the service does immediately before writing the OS clipboard)...
receiver.MarkInboundApplied(inbound.Value);
// ...so the echo (the local change its own apply caused) is suppressed:
var echo = receiver.TryBuildOutboundEnvelope(ClipboardPayload.Text("loop-me"));
AssertEqual(true, echo is null, "receiver does not re-broadcast the applied item (loop suppressed)");

// 4a) Re-receiving the SAME item is a no-op (dedup on the apply side).
var again = receiver.TryDecodeInbound(outbound!);
AssertEqual(true, again is null, "re-received identical item is deduped on apply side");

Console.WriteLine("windows-clipboard-sync: ok");

static string AsHex(ReadOnlySpan<byte> b)
{
    var sb = new StringBuilder(b.Length * 2);
    foreach (var x in b) sb.Append(x.ToString("x2"));
    return sb.ToString();
}

static void AssertThrows(Action action, string label)
{
    try
    {
        action();
    }
    catch
    {
        return;
    }

    throw new InvalidOperationException($"{label}: expected an exception, none thrown");
}

static void AssertSequenceEqual(byte[] expected, byte[] actual, string label)
{
    if (!expected.AsSpan().SequenceEqual(actual))
    {
        throw new InvalidOperationException($"{label}: byte sequences differ");
    }
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!System.Collections.Generic.EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected {expected}, got {actual}");
    }
}
'@

    dotnet run --project $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows-clipboard-sync smoke failed with exit code $LASTEXITCODE"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
