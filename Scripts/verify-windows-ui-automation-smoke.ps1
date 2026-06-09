param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [int]$TimeoutSeconds = 20,
    [string]$EvidenceDir = ""
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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition $Text.Contains($Needle) -Message $Message
}

function Find-ByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ListItemByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    $typeCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $condition = New-Object System.Windows.Automation.AndCondition($nameCondition, $typeCondition)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-ForElementByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $element = Find-ByAutomationId -Root $Root -AutomationId $AutomationId
        if ($null -ne $element) {
            return $element
        }

        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for automation id: $AutomationId"
}

function Wait-ForMainWindow {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "Skybridge.WinClient exited before exposing a WinUI window. exitCode=$($Process.ExitCode)"
        }

        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id)
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $condition)
        if ($null -ne $window) {
            return $window
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for Skybridge.WinClient main window."
}

function Assert-VisibleByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId,
        [int]$TimeoutSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $element = Find-ByAutomationId -Root $Root -AutomationId $AutomationId
        if ($null -ne $element -and -not $element.Current.IsOffscreen) {
            return $element
        }

        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    $lastElement = Find-ByAutomationId -Root $Root -AutomationId $AutomationId
    Assert-True -Condition ($null -ne $lastElement) -Message "Automation id is missing: $AutomationId"
    Assert-True -Condition (-not $lastElement.Current.IsOffscreen) -Message "Automation id is present but offscreen: $AutomationId"
    return $lastElement
}

function Assert-PresentByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId,
        [int]$TimeoutSeconds = 5
    )

    $element = Wait-ForElementByAutomationId -Root $Root -AutomationId $AutomationId -TimeoutSeconds $TimeoutSeconds
    Assert-True -Condition ($null -ne $element) -Message "Automation id is missing: $AutomationId"
    return $element
}

function Assert-SelectedFeatureTitle {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$ExpectedHeading
    )

    $heading = Assert-PresentByAutomationId -Root $Window -AutomationId "Skybridge.SelectedFeature.Title"
    Assert-True -Condition ($heading.Current.Name -eq $ExpectedHeading) -Message "Selected heading mismatch. expected=$ExpectedHeading actual=$($heading.Current.Name)"
    return $heading
}

function Assert-StatusMessageContains {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$ExpectedText
    )

    $status = Assert-PresentByAutomationId -Root $Window -AutomationId "Skybridge.Status.Message"
    Assert-True -Condition $status.Current.Name.Contains($ExpectedText) -Message "Status message mismatch. expectedContains=$ExpectedText actual=$($status.Current.Name)"
    return $status
}

function Try-ScrollIntoView {
    param([System.Windows.Automation.AutomationElement]$Element)

    try {
        $scrollItemPattern = $Element.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)
        $scrollItemPattern.ScrollIntoView()
        Start-Sleep -Milliseconds 250
    }
    catch {
        Write-Verbose "ScrollItemPattern unavailable for $($Element.Current.AutomationId): $($_.Exception.Message)"
    }
}

function Assert-PresentAndVisibleByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId,
        [int]$TimeoutSeconds = 5
    )

    $element = Assert-PresentByAutomationId -Root $Root -AutomationId $AutomationId -TimeoutSeconds $TimeoutSeconds
    if ($element.Current.IsOffscreen) {
        Try-ScrollIntoView -Element $element
        $element = Assert-PresentByAutomationId -Root $Root -AutomationId $AutomationId -TimeoutSeconds $TimeoutSeconds
    }

    Assert-True -Condition (-not $element.Current.IsOffscreen) -Message "Automation id is present but offscreen after scroll attempt: $AutomationId"
    return $element
}

function Select-Feature {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Title,
        [string]$ExpectedHeading,
        [string]$AnchorAutomationId
    )

    $item = Find-ListItemByName -Root $Window -Name $Title
    Assert-True -Condition ($null -ne $item) -Message "Navigation item missing: $Title"
    $selectionPattern = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selectionPattern.Select()
    Start-Sleep -Milliseconds 250

    [void](Assert-SelectedFeatureTitle -Window $Window -ExpectedHeading $ExpectedHeading)
    [void](Assert-PresentAndVisibleByAutomationId -Root $Window -AutomationId $AnchorAutomationId)
}

function Assert-BasicLayout {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$Width,
        [int]$Height
    )

    Restore-TestWindow -Window $Window
    [void][NativeMethods]::MoveWindow([IntPtr]$Window.Current.NativeWindowHandle, 40, 40, $Width, $Height, $true)
    Activate-TestWindow -Window $Window
    Start-Sleep -Milliseconds 300
    [void](Assert-SelectedFeatureTitle -Window $Window -ExpectedHeading "Dashboard")
    $navigation = Assert-VisibleByAutomationId -Root $Window -AutomationId "Skybridge.Navigation.List"
    $topBar = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.TopBarActions.Notifications"
    $themeAction = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.TopBarActions.Theme"
    $dashboardAction = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.DashboardQuickActions.ScanDevices"
    $windowRect = $Window.Current.BoundingRectangle

    Assert-True -Condition ($navigation.Current.BoundingRectangle.Left -lt $topBar.Current.BoundingRectangle.Left) -Message "Navigation must remain left of top-bar actions at ${Width}x${Height}."
    Assert-True -Condition ($navigation.Current.BoundingRectangle.Left -lt $dashboardAction.Current.BoundingRectangle.Left) -Message "Navigation must remain left of dashboard quick actions at ${Width}x${Height}."
    Assert-True -Condition ($topBar.Current.BoundingRectangle.Top -lt $dashboardAction.Current.BoundingRectangle.Top) -Message "Top-bar actions must remain above dashboard quick actions at ${Width}x${Height}."
    Assert-True -Condition ($topBar.Current.BoundingRectangle.Left -lt $themeAction.Current.BoundingRectangle.Left) -Message "Top-bar notification action must remain left of theme action at ${Width}x${Height}."
    Assert-True -Condition ($themeAction.Current.BoundingRectangle.Right -le ($windowRect.Right - 8)) -Message "Top-bar theme action must remain inside the window at ${Width}x${Height}."
}

function Restore-TestWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [void][NativeMethods]::ShowWindow($handle, 9)
    [void][NativeMethods]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 200
}

function Activate-TestWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [void][NativeMethods]::ShowWindow($handle, 5)
    [void][NativeMethods]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 200
}

function ConvertTo-SafeFileName {
    param([string]$Value)

    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
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

function Test-ActionBoundsFollow {
    param(
        $PreviousBounds,
        $CurrentBounds
    )

    $verticalGap = [double]$CurrentBounds.top - [double]$PreviousBounds.top
    if ($verticalGap -gt 2) {
        return $true
    }

    if ([Math]::Abs($verticalGap) -le 2 -and ([double]$CurrentBounds.left -gt ([double]$PreviousBounds.left + 2))) {
        return $true
    }

    return $false
}

function Get-RuntimeActionSurfaceSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [System.Collections.IDictionary]$ActionOrderBySurface,
        [string[]]$Surfaces,
        [string]$Context
    )

    $minimumUsableActionWidth = 32
    $minimumUsableActionHeight = 24

    @($Surfaces | ForEach-Object {
        $surface = $_
        Assert-True -Condition $ActionOrderBySurface.ContainsKey($surface) -Message "Runtime action surface is missing from Action Order Matrix: $surface"
        $keys = @($ActionOrderBySurface[$surface])
        $actions = [System.Collections.Generic.List[object]]::new()

        for ($index = 0; $index -lt $keys.Count; $index++) {
            $key = $keys[$index]
            $automationId = "WorkspaceAction.$surface.$key"
            $element = Assert-PresentByAutomationId -Root $Root -AutomationId $automationId -TimeoutSeconds 5
            $rect = $element.Current.BoundingRectangle
            if ($element.Current.IsOffscreen -or
                $rect.Width -lt $minimumUsableActionWidth -or
                $rect.Height -lt $minimumUsableActionHeight) {
                Try-ScrollIntoView -Element $element
                $element = Assert-PresentByAutomationId -Root $Root -AutomationId $automationId -TimeoutSeconds 5
                $rect = $element.Current.BoundingRectangle
            }

            Assert-True -Condition ($rect.Width -gt 0 -and $rect.Height -gt 0) -Message "Runtime action has invalid bounds: $automationId context=$Context"
            Assert-True `
                -Condition ($rect.Width -ge $minimumUsableActionWidth -and $rect.Height -ge $minimumUsableActionHeight) `
                -Message "Runtime action is clipped below minimum usable bounds: $automationId context=$Context width=$($rect.Width) height=$($rect.Height)"

            $actions.Add([pscustomobject]@{
                order = $index + 1
                key = $key
                automationId = $automationId
                name = $element.Current.Name
                isEnabled = [bool]$element.Current.IsEnabled
                isOffscreen = [bool]$element.Current.IsOffscreen
                bounds = [pscustomobject]@{
                    left = [double]$rect.Left
                    top = [double]$rect.Top
                    width = [double]$rect.Width
                    height = [double]$rect.Height
                }
            })
        }

        for ($index = 1; $index -lt $actions.Count; $index++) {
            $previous = $actions[$index - 1]
            $current = $actions[$index]
            Assert-True `
                -Condition (Test-ActionBoundsFollow -PreviousBounds $previous.bounds -CurrentBounds $current.bounds) `
                -Message "Runtime action bounds order drifted for $surface in $Context`: $($previous.automationId) must precede $($current.automationId)."
        }

        [pscustomobject]@{
            surface = $surface
            context = $Context
            actionCount = $actions.Count
            actions = @($actions)
        }
    })
}

function Get-AutomationAnchorSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string[]]$AutomationIds
    )

    return @($AutomationIds | ForEach-Object {
        $automationId = $_
        $element = Find-ByAutomationId -Root $Root -AutomationId $automationId
        Assert-True -Condition ($null -ne $element) -Message "Evidence anchor is missing: $automationId"
        $rect = $element.Current.BoundingRectangle

        [pscustomobject]@{
            automationId = $automationId
            name = $element.Current.Name
            isOffscreen = [bool]$element.Current.IsOffscreen
            bounds = [pscustomobject]@{
                left = [double]$rect.Left
                top = [double]$rect.Top
                width = [double]$rect.Width
                height = [double]$rect.Height
            }
        }
    })
}

function Save-WindowScreenshot {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Path
    )

    $rect = $Window.Current.BoundingRectangle
    $left = [int][Math]::Round($rect.Left)
    $top = [int][Math]::Round($rect.Top)
    $width = [int][Math]::Round($rect.Width)
    $height = [int][Math]::Round($rect.Height)

    Assert-True -Condition ($width -gt 0 -and $height -gt 0) -Message "Cannot capture a zero-sized window screenshot."

    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($left, $top, 0, 0, [System.Drawing.Size]::new($width, $height))
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
        }
    }
    finally {
        $bitmap.Dispose()
    }

    return [pscustomobject]@{
        width = $width
        height = $height
    }
}

$projectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
$projectText = Get-Content -Raw -LiteralPath $projectPath
Assert-Contains -Text $projectText -Needle "<WindowsPackageType>None</WindowsPackageType>" -Message "WinUI automation smoke requires unpackaged Windows App SDK auto-initialization."
$matrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$actionOrderBySurface = Get-ActionOrderMatrix -MatrixPath $matrixPath

& dotnet build $projectPath --configuration $Configuration --no-restore | Write-Output
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WinUI automation smoke build failed."

$targetFramework = "net10.0-windows10.0.19041.0"
$exePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/bin/$Configuration/$targetFramework/Skybridge.WinClient.exe"
Assert-True -Condition (Test-Path -LiteralPath $exePath) -Message "Missing WinUI executable: $exePath"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not [string]::IsNullOrWhiteSpace($EvidenceDir)) {
    Add-Type -AssemblyName System.Drawing
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$process = $null
try {
    $features = @(
        @{ Title = "Dashboard"; Heading = "Dashboard"; Anchor = "WorkspaceAction.DashboardQuickActions.ScanDevices"; Surfaces = @("DashboardQuickActions") },
        @{ Title = "Device Discovery"; Heading = "Device Discovery"; Anchor = "WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt"; Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal", "CrossNetworkQr", "CrossNetworkCodePrimary", "CrossNetworkCodeConnect") },
        @{ Title = "USB Management"; Heading = "USB Management"; Anchor = "WorkspaceAction.UsbManagementHeader.RefreshDevices"; Surfaces = @("UsbManagementHeader") },
        @{ Title = "File Transfer"; Heading = "File Transfer"; Anchor = "WorkspaceAction.FileTransfer.GenerateQr"; Surfaces = @("FileTransferHeader", "FileTransfer") },
        @{ Title = "Remote Desktop"; Heading = "Remote Desktop"; Anchor = "WorkspaceAction.RemoteDesktop.RecommendedConnect"; Surfaces = @("RemoteDesktopHeader", "RemoteDesktop") },
        @{ Title = "Quantum"; Heading = "Quantum"; Anchor = "WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics"; Surfaces = @("QuantumDiagnosticsHeader") },
        @{ Title = "System Monitor"; Heading = "System Monitor"; Anchor = "WorkspaceAction.SystemMonitorControls.Monitoring"; Surfaces = @("SystemMonitorHeader", "SystemMonitorControls") },
        @{ Title = "Settings"; Heading = "Settings"; Anchor = "WorkspaceAction.SettingsToolbar.ExportSettings"; EvidenceAnchors = @("WorkspaceAction.SettingsMaintenance.ApplySettings"); Surfaces = @("SettingsHeader", "SettingsToolbar", "SettingsMaintenance") }
    )
    $globalActionSurfaces = @("SidebarSession", "TopBarActions", "SessionControls")

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exePath
    $startInfo.WorkingDirectory = Split-Path $exePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($variable in @(
        "SKYBRIDGE_WINDOWS_RUNTIME",
        "SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER",
        "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES",
        "SKYBRIDGE_WINDOWS_ADAPTER_KIND",
        "SKYBRIDGE_WINDOWS_ADAPTER_BINDING",
        "SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT",
        "SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT",
        "SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR",
        "SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX",
        "SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX",
        "SKYBRIDGE_WINDOWS_RELAY_ID",
        "SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS"
    )) {
        [void]$startInfo.Environment.Remove($variable)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $window = Wait-ForMainWindow -Process $process -TimeoutSeconds $TimeoutSeconds
    Restore-TestWindow -Window $window
    try {
        $windowPattern = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
    }
    catch {
        Write-Verbose "Window visual-state normalization was unavailable: $($_.Exception.Message)"
    }
    Restore-TestWindow -Window $window
    [void][NativeMethods]::MoveWindow([IntPtr]$window.Current.NativeWindowHandle, 40, 40, 1280, 900, $true)
    Activate-TestWindow -Window $window
    Start-Sleep -Milliseconds 500

    foreach ($requiredAnchor in @(
        "Skybridge.Navigation.List",
        "Skybridge.Session.SelectedFeature.Title",
        "WorkspaceAction.SidebarSession.Connect",
        "WorkspaceAction.TopBarActions.Notifications",
        "WorkspaceAction.TopBarActions.Theme"
    )) {
        [void](Assert-VisibleByAutomationId -Root $window -AutomationId $requiredAnchor)
    }
    [void](Assert-SelectedFeatureTitle -Window $window -ExpectedHeading "Dashboard")
    [void](Assert-StatusMessageContains -Window $window -ExpectedText "Idle")

    Assert-BasicLayout -Window $window -Width 1280 -Height 900
    [void](Get-RuntimeActionSurfaceSnapshot -Root $window -ActionOrderBySurface $actionOrderBySurface -Surfaces $globalActionSurfaces -Context "global 1280x900")
    Assert-BasicLayout -Window $window -Width 1366 -Height 768
    [void](Get-RuntimeActionSurfaceSnapshot -Root $window -ActionOrderBySurface $actionOrderBySurface -Surfaces $globalActionSurfaces -Context "global 1366x768")

    foreach ($feature in $features) {
        Select-Feature -Window $window -Title $feature.Title -ExpectedHeading $feature.Heading -AnchorAutomationId $feature.Anchor
        [void](Get-RuntimeActionSurfaceSnapshot -Root $window -ActionOrderBySurface $actionOrderBySurface -Surfaces $feature.Surfaces -Context "$($feature.Title) runtime")
    }

    if (-not [string]::IsNullOrWhiteSpace($EvidenceDir)) {
        New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
        $resolvedEvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
        $captures = [System.Collections.Generic.List[object]]::new()

        foreach ($size in @(
            @{ Width = 1280; Height = 900 },
            @{ Width = 1366; Height = 768 }
        )) {
            Restore-TestWindow -Window $window
            [void][NativeMethods]::MoveWindow([IntPtr]$window.Current.NativeWindowHandle, 40, 40, $size.Width, $size.Height, $true)
            Activate-TestWindow -Window $window
            Start-Sleep -Milliseconds 500
            $globalActionBounds = Get-RuntimeActionSurfaceSnapshot -Root $window -ActionOrderBySurface $actionOrderBySurface -Surfaces $globalActionSurfaces -Context "global $($size.Width)x$($size.Height)"

            foreach ($feature in $features) {
                Select-Feature -Window $window -Title $feature.Title -ExpectedHeading $feature.Heading -AnchorAutomationId $feature.Anchor
                $featureActionBounds = Get-RuntimeActionSurfaceSnapshot -Root $window -ActionOrderBySurface $actionOrderBySurface -Surfaces $feature.Surfaces -Context "$($feature.Title) $($size.Width)x$($size.Height)"
                $fileName = "{0}x{1}-{2}.png" -f $size.Width, $size.Height, (ConvertTo-SafeFileName -Value $feature.Title)
                $screenshotPath = Join-Path $resolvedEvidenceDir $fileName
                $screenshot = Save-WindowScreenshot -Window $window -Path $screenshotPath
                Assert-True -Condition (Test-Path -LiteralPath $screenshotPath) -Message "Missing evidence screenshot: $screenshotPath"

                $anchorIds = @(
                    "Skybridge.Navigation.List",
                    "Skybridge.SelectedFeature.Title",
                    "WorkspaceAction.TopBarActions.Notifications",
                    "WorkspaceAction.TopBarActions.Theme",
                    "WorkspaceAction.SidebarSession.Connect",
                    $feature.Anchor
                ) + @($feature.EvidenceAnchors)

                $captures.Add([pscustomobject]@{
                    feature = $feature.Title
                    heading = $feature.Heading
                    anchor = $feature.Anchor
                    requestedWidth = $size.Width
                    requestedHeight = $size.Height
                    screenshotWidth = $screenshot.width
                    screenshotHeight = $screenshot.height
                    screenshot = $fileName
                    runtimeActionBounds = @($globalActionBounds + $featureActionBounds)
                    anchors = Get-AutomationAnchorSnapshot -Root $window -AutomationIds $anchorIds
                })
            }
        }

        Assert-True -Condition ($captures.Count -eq ($features.Count * 2)) -Message "Unexpected visual evidence capture count: $($captures.Count)"
        $manifestPath = Join-Path $resolvedEvidenceDir "windows-ui-visual-evidence.json"
        [pscustomobject]@{
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            app = "Skybridge.WinClient"
            configuration = $Configuration
            targetFramework = $targetFramework
            captureCount = $captures.Count
            actionOrderMatrix = "docs/windows-ui-parity-matrix.md#action-order-matrix"
            captures = @($captures)
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message "Missing visual evidence manifest: $manifestPath"
        Write-Output "windows-ui-visual-evidence: ok dir=$resolvedEvidenceDir manifest=$manifestPath captures=$($captures.Count)"
    }

    Select-Feature -Window $window -Title "File Transfer" -ExpectedHeading "File Transfer" -AnchorAutomationId "WorkspaceAction.FileTransfer.GenerateQr"
    $generateQr = Assert-VisibleByAutomationId -Root $window -AutomationId "WorkspaceAction.FileTransfer.GenerateQr"
    $invokePattern = $generateQr.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
    [void](Assert-VisibleByAutomationId -Root $window -AutomationId "FileTransferShareQrImage" -TimeoutSeconds 10)
    [void](Assert-StatusMessageContains -Window $window -ExpectedText "no local files were read")

    Write-Output "windows-ui-automation-smoke: ok"
}
catch {
    if ($process -and -not $process.HasExited) {
        try { $process.Kill() } catch { }
    }

    if ($process) {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Output "windows-ui-automation-smoke stdout:"
            Write-Output $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Output "windows-ui-automation-smoke stderr:"
            Write-Output $stderr
        }
    }

    throw
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
