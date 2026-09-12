param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceFile = (Resolve-Path -LiteralPath $SourcePath).Path
$text = [IO.File]::ReadAllText($sourceFile)
$shaderMatches = [regex]::Matches($text, 'private const string WeatherHlsl = @"(?<source>(?:[^"]|"")*)";')
if ($shaderMatches.Count -ne 1) { throw 'Expected one complete embedded weather shader source.' }
$shader = $shaderMatches[0].Groups['source'].Value.Replace('""', '"')
$encoding = [Text.Encoding]::GetEncoding('us-ascii', [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
$bytes = $encoding.GetBytes($shader)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SkybridgeWeatherBuild {
    public sealed class ShaderResult {
        public string EntryPoint;
        public string Profile;
        public ulong BytecodeBytes;
    }
    public static class Compiler {
        [ComImport, Guid("8BA5FB08-5195-40E2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface Blob {
            [PreserveSig] IntPtr GetBufferPointer();
            [PreserveSig] UIntPtr GetBufferSize();
        }
        [DllImport("d3dcompiler_47.dll", ExactSpelling = true, CharSet = CharSet.Ansi)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int D3DCompile([In] byte[] source, UIntPtr size, string sourceName,
            IntPtr defines, IntPtr include, string entryPoint, string target,
            uint flags, uint effectFlags, out Blob bytecode, out Blob diagnostics);

        public static ShaderResult Compile(byte[] source, string sourceName, string entry, string profile, string outputPath) {
            Blob code = null, diagnostic = null;
            try {
                // Same O3 and warnings-as-errors policy as the product renderer.
                const uint flags = (1u << 15) | (1u << 18);
                int result = D3DCompile(source, new UIntPtr((uint)source.Length), sourceName,
                    IntPtr.Zero, IntPtr.Zero, entry, profile, flags, 0, out code, out diagnostic);
                string detail = diagnostic == null ? "" : Marshal.PtrToStringAnsi(diagnostic.GetBufferPointer());
                if (result < 0 || code == null || !String.IsNullOrWhiteSpace(detail)) {
                    throw new InvalidOperationException(entry + " " + profile + " compilation failed: " + detail + " (HRESULT " + result + ")");
                }
                int length = checked((int)code.GetBufferSize().ToUInt64());
                byte[] compiled = new byte[length];
                Marshal.Copy(code.GetBufferPointer(), compiled, 0, length);
                System.IO.File.WriteAllBytes(outputPath, compiled);
                return new ShaderResult {EntryPoint = entry, Profile = profile, BytecodeBytes = (ulong)length};
            }
            finally {
                if (diagnostic != null) Marshal.ReleaseComObject(diagnostic);
                if (code != null) Marshal.ReleaseComObject(code);
            }
        }
    }
}
'@

$destination = [IO.Path]::GetFullPath($EvidencePath)
$compiledDirectory = [IO.Path]::GetDirectoryName($destination)
[IO.Directory]::CreateDirectory($compiledDirectory) | Out-Null
$receipt = [ordered]@{
    sourceSha256 = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
    optimization = 'O3'
    warningsAsErrors = $true
    stages = @()
    status = 'running'
}
try {
    foreach ($stage in @(@('VSMain', 'vs_5_0'), @('PSMain', 'ps_5_0'))) {
        $compiledPath = Join-Path $compiledDirectory ($stage[0] + '.cso')
        $receipt.stages += [SkybridgeWeatherBuild.Compiler]::Compile($bytes, $sourceFile, $stage[0], $stage[1], $compiledPath)
    }
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try { $shaderHash = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hashAlgorithm.Dispose() }
    [IO.File]::WriteAllText((Join-Path $compiledDirectory 'weather-shader-source.sha256'), $shaderHash, [Text.Encoding]::ASCII)
    $receipt.shaderSha256 = $shaderHash
    $receipt.status = 'passed'
    Write-Output 'Weather shaders: VSMain and PSMain passed native FXC with warnings as errors.'
}
catch {
    $receipt.status = 'failed'
    $receipt.error = $_.Exception.ToString()
    throw
}
finally {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8
}
