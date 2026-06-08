param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [int]$TimeoutSeconds = 20
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

    $heading = Assert-VisibleByAutomationId -Root $Window -AutomationId "Skybridge.SelectedFeature.Title"
    Assert-True -Condition ($heading.Current.Name -eq $ExpectedHeading) -Message "Selected heading mismatch for $Title. expected=$ExpectedHeading actual=$($heading.Current.Name)"
    [void](Assert-VisibleByAutomationId -Root $Window -AutomationId $AnchorAutomationId)
}

function Assert-BasicLayout {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$Width,
        [int]$Height
    )

    [void][NativeMethods]::MoveWindow([IntPtr]$Window.Current.NativeWindowHandle, 40, 40, $Width, $Height, $true)
    Start-Sleep -Milliseconds 300
    $navigation = Assert-VisibleByAutomationId -Root $Window -AutomationId "Skybridge.Navigation.List"
    $heading = Assert-VisibleByAutomationId -Root $Window -AutomationId "Skybridge.SelectedFeature.Title"
    $topBar = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.TopBarActions.Notifications"
    $dashboardAction = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.DashboardQuickActions.ScanDevices"

    Assert-True -Condition ($navigation.Current.BoundingRectangle.Left -lt $heading.Current.BoundingRectangle.Left) -Message "Navigation must remain left of the selected heading at ${Width}x${Height}."
    Assert-True -Condition ($heading.Current.BoundingRectangle.Top -lt $dashboardAction.Current.BoundingRectangle.Top) -Message "Selected heading must remain above dashboard quick actions at ${Width}x${Height}."
    Assert-True -Condition ($heading.Current.BoundingRectangle.Left -lt $topBar.Current.BoundingRectangle.Left) -Message "Selected heading must remain left of the top-bar actions at ${Width}x${Height}."
}

$projectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
$projectText = Get-Content -Raw -LiteralPath $projectPath
Assert-Contains -Text $projectText -Needle "<WindowsPackageType>None</WindowsPackageType>" -Message "WinUI automation smoke requires unpackaged Windows App SDK auto-initialization."

& dotnet build $projectPath --configuration $Configuration --no-restore | Write-Output
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WinUI automation smoke build failed."

$targetFramework = "net10.0-windows10.0.19041.0"
$exePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/bin/$Configuration/$targetFramework/Skybridge.WinClient.exe"
Assert-True -Condition (Test-Path -LiteralPath $exePath) -Message "Missing WinUI executable: $exePath"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int nWidth, int nHeight, bool bRepaint);
}
"@

$process = $null
try {
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
    try {
        $windowPattern = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
    }
    catch {
    }
    [void][NativeMethods]::MoveWindow([IntPtr]$window.Current.NativeWindowHandle, 40, 40, 1280, 900, $true)
    Start-Sleep -Milliseconds 500

    foreach ($requiredAnchor in @(
        "Skybridge.Navigation.List",
        "Skybridge.SelectedFeature.Title",
        "Skybridge.Status.Message",
        "Skybridge.Session.SelectedFeature.Title",
        "WorkspaceAction.SidebarSession.Connect",
        "WorkspaceAction.TopBarActions.Notifications"
    )) {
        [void](Assert-VisibleByAutomationId -Root $window -AutomationId $requiredAnchor)
    }

    Assert-BasicLayout -Window $window -Width 1280 -Height 900
    Assert-BasicLayout -Window $window -Width 1366 -Height 768

    foreach ($feature in @(
        @{ Title = "Dashboard"; Heading = "Dashboard"; Anchor = "WorkspaceAction.DashboardQuickActions.ScanDevices" },
        @{ Title = "Device Discovery"; Heading = "Device Discovery"; Anchor = "WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt" },
        @{ Title = "USB Management"; Heading = "USB Management"; Anchor = "WorkspaceAction.UsbManagementHeader.RefreshDevices" },
        @{ Title = "File Transfer"; Heading = "File Transfer"; Anchor = "WorkspaceAction.FileTransfer.GenerateQr" },
        @{ Title = "Remote Desktop"; Heading = "Remote Desktop"; Anchor = "WorkspaceAction.RemoteDesktop.RecommendedConnect" },
        @{ Title = "Quantum"; Heading = "Quantum"; Anchor = "WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics" },
        @{ Title = "System Monitor"; Heading = "System Monitor"; Anchor = "WorkspaceAction.SystemMonitorControls.Monitoring" },
        @{ Title = "Settings"; Heading = "Settings"; Anchor = "WorkspaceAction.SettingsToolbar.ExportSettings" }
    )) {
        Select-Feature -Window $window -Title $feature.Title -ExpectedHeading $feature.Heading -AnchorAutomationId $feature.Anchor
    }

    Select-Feature -Window $window -Title "File Transfer" -ExpectedHeading "File Transfer" -AnchorAutomationId "WorkspaceAction.FileTransfer.GenerateQr"
    $generateQr = Assert-VisibleByAutomationId -Root $window -AutomationId "WorkspaceAction.FileTransfer.GenerateQr"
    $invokePattern = $generateQr.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
    [void](Assert-VisibleByAutomationId -Root $window -AutomationId "FileTransferShareQrImage" -TimeoutSeconds 10)
    $status = Assert-VisibleByAutomationId -Root $window -AutomationId "Skybridge.Status.Message"
    Assert-True -Condition $status.Current.Name.Contains("no local files were read") -Message "File Transfer QR action must keep the no-local-file-read safety message visible."

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
