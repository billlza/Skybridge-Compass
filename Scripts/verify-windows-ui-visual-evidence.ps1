param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceDir
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

function Get-MarkdownCodeValues {
    param([string]$Text)

    @([regex]::Matches($Text, '`([^`]+)`') |
        ForEach-Object { $_.Groups[1].Value })
}

function Split-MarkdownTableRow {
    param([string]$Line)

    $trimmed = $Line.Trim()
    Assert-True -Condition ($trimmed.StartsWith("|") -and $trimmed.EndsWith("|")) -Message "Invalid markdown table row: $Line"
    @($trimmed.Trim("|").Split("|") | ForEach-Object { $_.Trim() })
}

function Get-ActionOrderMatrix {
    param([string]$MatrixPath)

    Assert-True -Condition (Test-Path -LiteralPath $MatrixPath) -Message "Missing UI parity matrix: $MatrixPath"
    $matrix = Get-Content -Raw -LiteralPath $MatrixPath
    $rows = [System.Collections.Generic.Dictionary[string, string[]]]::new()
    $inSection = $false

    foreach ($line in ($matrix -split "\r?\n")) {
        if ($line.Trim() -eq "## Action Order Matrix") {
            $inSection = $true
            continue
        }

        if ($inSection -and $line.StartsWith("## ")) {
            break
        }

        if (-not $inSection -or -not $line.Trim().StartsWith("|")) {
            continue
        }

        if ($line -match '---') {
            continue
        }

        $columns = Split-MarkdownTableRow -Line $line
        if ($columns.Count -ne 2 -or $columns[0] -eq "Surface") {
            continue
        }

        $surfaceValues = @(Get-MarkdownCodeValues -Text $columns[0])
        $keyValues = @(Get-MarkdownCodeValues -Text $columns[1])
        Assert-True -Condition ($surfaceValues.Count -eq 1) -Message "Action Order Matrix row must have one surface: $line"
        Assert-True -Condition ($keyValues.Count -gt 0) -Message "Action Order Matrix row must have at least one key: $line"
        Assert-True -Condition (-not $rows.ContainsKey($surfaceValues[0])) -Message "Duplicate Action Order Matrix surface: $($surfaceValues[0])"
        $rows[$surfaceValues[0]] = [string[]]@($keyValues)
    }

    Assert-True -Condition ($rows.Count -gt 0) -Message "Action Order Matrix did not contain any runtime action rows."
    return $rows
}

function ConvertTo-SafeFileName {
    param([string]$Value)

    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Assert-PositiveBounds {
    param(
        $Bounds,
        [string]$Context,
        [double]$MinimumWidth = 1,
        [double]$MinimumHeight = 1
    )

    Assert-True -Condition ($null -ne $Bounds) -Message "Missing bounds: $Context"
    Assert-True -Condition ([double]$Bounds.width -ge $MinimumWidth) -Message "Bounds width too small: $Context width=$($Bounds.width)"
    Assert-True -Condition ([double]$Bounds.height -ge $MinimumHeight) -Message "Bounds height too small: $Context height=$($Bounds.height)"
}

function Assert-PngFile {
    param([string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Missing screenshot file: $Path"
    $file = Get-Item -LiteralPath $Path
    Assert-True -Condition ($file.Length -gt 1024) -Message "Screenshot file is too small to be useful evidence: $Path length=$($file.Length)"

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $header = [byte[]]::new(8)
        $read = $stream.Read($header, 0, $header.Length)
        Assert-True -Condition ($read -eq 8) -Message "Screenshot file is missing PNG header: $Path"
        $expected = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        for ($index = 0; $index -lt $expected.Length; $index++) {
            Assert-True -Condition ($header[$index] -eq $expected[$index]) -Message "Screenshot file is not a PNG: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }
}

$resolvedEvidenceDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidenceDir)
$manifestPath = Join-Path $resolvedEvidenceDir "windows-ui-visual-evidence.json"
Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message "Missing visual evidence manifest: $manifestPath"

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$matrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$actionOrderBySurface = Get-ActionOrderMatrix -MatrixPath $matrixPath

$expectedFeatures = [ordered]@{
    "Dashboard" = @{
        Heading = "Dashboard"
        Anchor = "WorkspaceAction.DashboardQuickActions.ScanDevices"
        Surfaces = @("DashboardQuickActions")
    }
    "Device Discovery" = @{
        Heading = "Device Discovery"
        Anchor = "WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt"
        Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal", "CrossNetworkQr", "CrossNetworkCodePrimary", "CrossNetworkCodeConnect")
    }
    "USB Management" = @{
        Heading = "USB Management"
        Anchor = "WorkspaceAction.UsbManagementHeader.RefreshDevices"
        Surfaces = @("UsbManagementHeader")
    }
    "File Transfer" = @{
        Heading = "File Transfer"
        Anchor = "WorkspaceAction.FileTransfer.GenerateQr"
        Surfaces = @("FileTransferHeader", "FileTransfer")
    }
    "Remote Desktop" = @{
        Heading = "Remote Desktop"
        Anchor = "WorkspaceAction.RemoteDesktop.RecommendedConnect"
        Surfaces = @("RemoteDesktopHeader", "RemoteDesktop")
    }
    "Quantum" = @{
        Heading = "Quantum"
        Anchor = "WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics"
        Surfaces = @("QuantumDiagnosticsHeader")
    }
    "System Monitor" = @{
        Heading = "System Monitor"
        Anchor = "WorkspaceAction.SystemMonitorControls.Monitoring"
        Surfaces = @("SystemMonitorHeader", "SystemMonitorControls")
    }
    "Settings" = @{
        Heading = "Settings"
        Anchor = "WorkspaceAction.SettingsToolbar.ExportSettings"
        Surfaces = @("SettingsHeader", "SettingsToolbar", "SettingsMaintenance")
    }
}

    $globalSurfaces = @("TopBarActions", "SessionControls")
$expectedSizes = @(
    @{ Width = 1280; Height = 900 },
    @{ Width = 1366; Height = 768 }
)

Assert-True -Condition ($manifest.app -eq "Skybridge.WinClient") -Message "Unexpected evidence app: $($manifest.app)"
Assert-True -Condition ($manifest.actionOrderMatrix -eq "docs/windows-ui-parity-matrix.md#action-order-matrix") -Message "Visual evidence must reference the UI action-order matrix."

$captures = @($manifest.captures)
Assert-True -Condition ([int]$manifest.captureCount -eq ($expectedFeatures.Count * $expectedSizes.Count)) -Message "Unexpected manifest captureCount: $($manifest.captureCount)"
Assert-True -Condition ($captures.Count -eq [int]$manifest.captureCount) -Message "Manifest captureCount does not match captures array length."

foreach ($featureName in $expectedFeatures.Keys) {
    $feature = $expectedFeatures[$featureName]
    foreach ($size in $expectedSizes) {
        $capture = @($captures | Where-Object {
            $_.feature -eq $featureName -and
            [int]$_.requestedWidth -eq [int]$size.Width -and
            [int]$_.requestedHeight -eq [int]$size.Height
        })
        Assert-True -Condition ($capture.Count -eq 1) -Message "Expected one visual capture for $featureName $($size.Width)x$($size.Height), found $($capture.Count)."
        $capture = $capture[0]

        Assert-True -Condition ($capture.heading -eq $feature.Heading) -Message "Heading mismatch for $featureName evidence."
        Assert-True -Condition ($capture.anchor -eq $feature.Anchor) -Message "Anchor mismatch for $featureName evidence."
        Assert-True -Condition ($capture.screenshot -eq ("{0}x{1}-{2}.png" -f $size.Width, $size.Height, (ConvertTo-SafeFileName -Value $featureName))) -Message "Unexpected screenshot name for $featureName evidence: $($capture.screenshot)"
        Assert-True -Condition ([int]$capture.screenshotWidth -gt 0 -and [int]$capture.screenshotHeight -gt 0) -Message "Screenshot dimensions must be positive for $featureName."
        Assert-PngFile -Path (Join-Path $resolvedEvidenceDir $capture.screenshot)

        $anchorIds = @($capture.anchors | ForEach-Object { $_.automationId })
        foreach ($requiredAnchor in @(
            "Skybridge.Navigation.List",
            "Skybridge.SelectedFeature.Title",
            "WorkspaceAction.TopBarActions.Notifications",
            "WorkspaceAction.TopBarActions.Theme",
            "WorkspaceAction.SessionControls.Connect",
            $feature.Anchor
        )) {
            Assert-True -Condition ($anchorIds -contains $requiredAnchor) -Message "Evidence capture missing anchor $requiredAnchor for $featureName."
        }

        foreach ($anchor in @($capture.anchors)) {
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$anchor.automationId)) -Message "Evidence anchor has an empty automation id for $featureName."
            Assert-True -Condition (-not [bool]$anchor.isOffscreen) -Message "Evidence anchor is offscreen: $($anchor.automationId) for $featureName."
            Assert-PositiveBounds -Bounds $anchor.bounds -Context "anchor $($anchor.automationId) $featureName"
        }

        $expectedSurfaces = @($globalSurfaces + $feature.Surfaces)
        $runtimeSurfaces = @($capture.runtimeActionBounds)
        $surfaceNames = @($runtimeSurfaces | ForEach-Object { $_.surface })
        foreach ($surface in $expectedSurfaces) {
            Assert-True -Condition ($surfaceNames -contains $surface) -Message "Runtime action evidence missing surface $surface for $featureName."
        }

        foreach ($surfaceEvidence in $runtimeSurfaces) {
            $surface = [string]$surfaceEvidence.surface
            Assert-True -Condition ($expectedSurfaces -contains $surface) -Message "Runtime action evidence has unexpected surface $surface for $featureName."
            Assert-True -Condition ($actionOrderBySurface.ContainsKey($surface)) -Message "Runtime action evidence surface is not in matrix: $surface"
            $expectedKeys = @($actionOrderBySurface[$surface])
            $actions = @($surfaceEvidence.actions)
            Assert-True -Condition ([int]$surfaceEvidence.actionCount -eq $expectedKeys.Count) -Message "Runtime action evidence count mismatch for $surface in $featureName."
            Assert-True -Condition ($actions.Count -eq $expectedKeys.Count) -Message "Runtime action array count mismatch for $surface in $featureName."

            for ($index = 0; $index -lt $expectedKeys.Count; $index++) {
                $expectedKey = $expectedKeys[$index]
                $action = $actions[$index]
                Assert-True -Condition ([int]$action.order -eq ($index + 1)) -Message "Runtime action order mismatch for $surface.$expectedKey in $featureName."
                Assert-True -Condition ($action.key -eq $expectedKey) -Message "Runtime action key mismatch for $surface index=$index in $featureName."
                Assert-True -Condition ($action.automationId -eq "WorkspaceAction.$surface.$expectedKey") -Message "Runtime action automation id mismatch for $surface.$expectedKey in $featureName."
                Assert-True -Condition (-not [bool]$action.isOffscreen) -Message "Runtime action is offscreen: $($action.automationId) for $featureName."
                Assert-PositiveBounds -Bounds $action.bounds -Context "action $($action.automationId) $featureName" -MinimumWidth 32 -MinimumHeight 24
            }
        }
    }
}

Write-Output "windows-ui-visual-evidence-verify: ok dir=$resolvedEvidenceDir captures=$($captures.Count)"
