param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$ShaderHostPath = "windows/Skybridge.WinClient/WeatherBackdropDX.xaml.cs",
    [string]$ConstantName = "WeatherHlsl",
    [string]$EvidencePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

# Pull the C# verbatim string that holds the HLSL. A verbatim string ends at the first quote
# that is not doubled, so scan for that rather than trusting the first quote on a line.
function Get-VerbatimStringLiteral {
    param(
        [string[]]$Lines,
        [string]$ConstantName
    )

    $marker = "private const string $ConstantName = @`""
    $startIndex = -1
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        if ($Lines[$i].IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0) {
            $startIndex = $i
            break
        }
    }
    Assert-True -Condition ($startIndex -ge 0) -Message "Could not find a verbatim string constant named $ConstantName."

    $collected = [System.Collections.Generic.List[string]]::new()
    $first = $Lines[$startIndex].Substring($Lines[$startIndex].IndexOf($marker, [System.StringComparison]::Ordinal) + $marker.Length)
    $pending = @($first) + $Lines[($startIndex + 1)..($Lines.Length - 1)]

    foreach ($line in $pending) {
        $j = 0
        $closed = $false
        while ($j -lt $line.Length) {
            if ($line[$j] -eq '"') {
                if (($j + 1) -lt $line.Length -and $line[$j + 1] -eq '"') {
                    $j += 2
                    continue
                }
                $collected.Add($line.Substring(0, $j))
                $closed = $true
                break
            }
            $j++
        }
        if ($closed) {
            return ($collected -join "`n")
        }
        $collected.Add($line)
    }

    throw "Verbatim string constant $ConstantName is never closed."
}

$hostFullPath = Join-Path $RepoRoot $ShaderHostPath
Assert-True -Condition (Test-Path -LiteralPath $hostFullPath) -Message "Shader host file does not exist: $hostFullPath"
$hlsl = Get-VerbatimStringLiteral -Lines ([System.IO.File]::ReadAllLines($hostFullPath)) -ConstantName $ConstantName

# ---------------------------------------------------------------------------------------------
# The property that actually matters.
#
# Compiler.Compile(string, ...) hands D3DCompile a UTF-8 buffer whose length is the *character*
# count of the string. Every character above U+007F therefore encodes to more bytes than the
# declared length accounts for, and D3DCompile silently stops short of the end of the source. Two
# em-dashes in comments were enough to cut ";\n}\n" off the tail and produce
#   error X3000: syntax error: unexpected end of file
# at the closing brace of PSMain - after which the panel caught the failure and rendered a flat
# clear colour, so the whole backdrop was dead with no visible cause.
#
# Keeping the shader source pure ASCII makes that truncation arithmetically impossible.
# ---------------------------------------------------------------------------------------------
$charCount = $hlsl.Length
$byteCount = [System.Text.Encoding]::UTF8.GetByteCount($hlsl)

$nonAscii = [System.Collections.Generic.List[string]]::new()
$lines = $hlsl -split "`n"
for ($i = 0; $i -lt $lines.Length; $i++) {
    foreach ($ch in $lines[$i].ToCharArray()) {
        if ([int]$ch -gt 126) {
            $nonAscii.Add(("line {0}: U+{1:X4} '{2}'" -f ($i + 1), [int]$ch, $ch))
            break
        }
    }
}

Assert-True -Condition ($nonAscii.Count -eq 0) -Message "$ConstantName must be pure ASCII; D3DCompile truncates the source by one byte per extra UTF-8 byte. Offending lines: $($nonAscii -join '; ')"
Assert-True -Condition ($charCount -eq $byteCount) -Message "$ConstantName UTF-8 byte count ($byteCount) differs from its character count ($charCount); D3DCompile would drop the last $($byteCount - $charCount) bytes of the shader."

# Cheap structural sanity so an unbalanced edit is caught on macOS instead of at device init.
$depthBrace = 0
$depthParen = 0
$depthBracket = 0
$inBlockComment = $false
foreach ($line in $lines) {
    $k = 0
    while ($k -lt $line.Length) {
        $two = if (($k + 1) -lt $line.Length) { $line.Substring($k, 2) } else { "" }
        if ($inBlockComment) {
            if ($two -eq "*/") { $inBlockComment = $false; $k += 2 } else { $k++ }
            continue
        }
        if ($two -eq "/*") { $inBlockComment = $true; $k += 2; continue }
        if ($two -eq "//") { break }
        switch ($line[$k]) {
            "{" { $depthBrace++ }
            "}" { $depthBrace-- }
            "(" { $depthParen++ }
            ")" { $depthParen-- }
            "[" { $depthBracket++ }
            "]" { $depthBracket-- }
        }
        $k++
    }
}

Assert-True -Condition (-not $inBlockComment) -Message "$ConstantName ends inside an unterminated /* block comment."
Assert-True -Condition ($depthBrace -eq 0) -Message "$ConstantName has unbalanced braces (depth $depthBrace at end of source)."
Assert-True -Condition ($depthParen -eq 0) -Message "$ConstantName has unbalanced parentheses (depth $depthParen at end of source)."
Assert-True -Condition ($depthBracket -eq 0) -Message "$ConstantName has unbalanced brackets (depth $depthBracket at end of source)."

# Shell glass contract. The frosted material under the sidebar and the top bar is rendered by the
# shader (pass 0 into the glass source at t0, pass 1 samples it inside the frost rects), because
# WinUI paints every in-app AcrylicBrush as its FallbackColor while the weather swap chain is
# attached to the XAML tree. A later change that reintroduces an AcrylicBrush, paints the pane or
# the bar opaque, or stops handing the rects to the renderer would degrade silently on screen.
Assert-True -Condition ($hlsl.Contains("Texture2D<float4> glassSource : register(t0)")) -Message "$ConstantName no longer declares the glass source at t0."
Assert-True -Condition ($hlsl.Contains("int    renderPass;")) -Message "$ConstantName no longer carries renderPass in its constant buffer."
Assert-True -Condition ($hlsl.Contains("float4 glassRect0;") -and $hlsl.Contains("float4 glassRect1;")) -Message "$ConstantName no longer carries the two frost rects."
$clientRoot = Join-Path $RepoRoot "windows/Skybridge.WinClient"
$xamlFiles = Get-ChildItem -Path $clientRoot -Recurse -Filter *.xaml | Where-Object { $_.FullName -notmatch "[\\/](bin|obj)[\\/]" }
foreach ($xamlFile in $xamlFiles) {
    $xamlText = [System.IO.File]::ReadAllText($xamlFile.FullName)
    Assert-True -Condition ($xamlText.IndexOf("<AcrylicBrush", [System.StringComparison]::Ordinal) -lt 0) -Message "$($xamlFile.Name) declares an AcrylicBrush; XAML acrylic renders as its fallback colour under the weather swap chain."
}
$themeText = [System.IO.File]::ReadAllText((Join-Path $clientRoot "Themes/SkyBridgeTheme.xaml"))
Assert-True -Condition ($themeText.Contains('<SolidColorBrush x:Key="SkyBridgeSidebarFillBrush" Color="Transparent" />')) -Message "SkyBridgeSidebarFillBrush must be Transparent so the shader's frost shows through the pane."
Assert-True -Condition ($themeText.Contains('<SolidColorBrush x:Key="SkyBridgeTopBarFillBrush" Color="Transparent" />')) -Message "SkyBridgeTopBarFillBrush must be Transparent so the shader's frost shows through the top bar."
$windowText = [System.IO.File]::ReadAllText((Join-Path $clientRoot "MainWindow.xaml.cs"))
Assert-True -Condition ($windowText.Contains("WeatherBackdrop.SetGlassRegions(")) -Message "MainWindow no longer hands the frost rects to the weather renderer."
Assert-True -Condition ($windowText.Contains("ConfigureShellGlass();")) -Message "MainWindow no longer wires the shell glass independently of title-bar customization."
Assert-True -Condition ($windowText.Contains("RootShell.LayoutUpdated += _glassLayoutUpdated;")) -Message "MainWindow no longer re-derives the frost rects after layout passes."
$appText = [System.IO.File]::ReadAllText((Join-Path $clientRoot "App.xaml"))
Assert-True -Condition ($appText.Contains('<StaticResource x:Key="NavigationViewDefaultPaneBackground" ResourceKey="SkyBridgeSidebarFillBrush" />') -and $appText.Contains('<StaticResource x:Key="NavigationViewExpandedPaneBackground" ResourceKey="SkyBridgeSidebarFillBrush" />')) -Message "The NavigationView pane backgrounds must alias SkyBridgeSidebarFillBrush (transparent) so the shader's frost shows through."
Assert-True -Condition ($appText.Contains('<SolidColorBrush x:Key="NavigationViewContentBackground" Color="Transparent" />')) -Message "The NavigationView content background must stay transparent over the weather backdrop."
$mainXaml = [System.IO.File]::ReadAllText((Join-Path $clientRoot "MainWindow.xaml"))
Assert-True -Condition ($mainXaml.Contains('x:Name="TopBarChrome"') -and $mainXaml.Contains('Background="{StaticResource SkyBridgeTopBarFillBrush}"')) -Message "The top bar must keep SkyBridgeTopBarFillBrush (transparent) as its background so the shader's frost shows through."
$csFiles = Get-ChildItem -Path $clientRoot -Recurse -Filter *.cs | Where-Object { $_.FullName -notmatch "[\\/](bin|obj)[\\/]" }
foreach ($csFile in $csFiles) {
    $csText = [System.IO.File]::ReadAllText($csFile.FullName)
    Assert-True -Condition ($csText.IndexOf("new AcrylicBrush(", [System.StringComparison]::Ordinal) -lt 0) -Message "$($csFile.Name) creates an AcrylicBrush in code; XAML acrylic renders as its fallback colour under the weather swap chain."
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidence = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        script = "verify-windows-shader-source.ps1"
        shaderHostPath = $ShaderHostPath
        constantName = $ConstantName
        characterCount = $charCount
        utf8ByteCount = $byteCount
        nonAsciiLineCount = $nonAscii.Count
        braceDepth = $depthBrace
        parenDepth = $depthParen
        bracketDepth = $depthBracket
        accepted = $true
    }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidencePath)
    $directory = Split-Path -Parent $resolved
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [System.IO.File]::WriteAllText($resolved, ($evidence | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Write-Output "windows-shader-source: evidence=$resolved"
}

Write-Output ("windows-shader-source: ok constant={0} chars={1} utf8Bytes={2} nonAscii=0 braces/parens/brackets balanced; shell glass contract ok" -f $ConstantName, $charCount, $byteCount)
exit 0
