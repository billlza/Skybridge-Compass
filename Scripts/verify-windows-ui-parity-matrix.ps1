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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

function Assert-Count {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$ExpectedCount,
        [string]$Message
    )

    $count = [regex]::Matches($Text, $Pattern).Count
    Assert-True -Condition ($count -eq $ExpectedCount) -Message "$Message Expected $ExpectedCount, got $count."
}

function Assert-Ordered {
    param(
        [string]$Text,
        [string[]]$Needles,
        [string]$Context
    )

    $lastIndex = -1
    foreach ($needle in $Needles) {
        $index = $Text.IndexOf($needle, $lastIndex + 1, [StringComparison]::Ordinal)
        Assert-True -Condition ($index -ge 0) -Message "$Context missing ordered signal after index ${lastIndex}: $needle"
        Assert-True -Condition ($index -gt $lastIndex) -Message "$Context order regression: $needle"
        $lastIndex = $index
    }
}

function Assert-SequenceEqual {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Context
    )

    Assert-True -Condition ($Actual.Count -eq $Expected.Count) -Message "$Context count mismatch. Expected $($Expected.Count), got $($Actual.Count). Actual=[$($Actual -join ', ')]"
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        Assert-True -Condition ($Actual[$i] -eq $Expected[$i]) -Message "$Context mismatch at index $i. Expected '$($Expected[$i])', got '$($Actual[$i])'."
    }
}

function Assert-NoDuplicates {
    param(
        [string[]]$Values,
        [string]$Context
    )

    $duplicates = @($Values |
        Group-Object |
        Where-Object { $_.Count -gt 1 } |
        ForEach-Object { $_.Name })
    Assert-True -Condition ($duplicates.Count -eq 0) -Message "$Context contains duplicate values: $($duplicates -join ', ')"
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

function Test-GitObjectExists {
    param([string]$ObjectName)

    $result = Invoke-Git -Arguments @("cat-file", "-e", $ObjectName)
    return $result.ExitCode -eq 0
}

function Invoke-Git {
    param([string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.Arguments = Join-ProcessArguments -Arguments (@("-C", $RepoRoot) + $Arguments)
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $textParts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $textParts += $stdout.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $textParts += $stderr.TrimEnd()
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text = ($textParts -join [Environment]::NewLine)
    }
}

function Get-GitObjectText {
    param([string]$ObjectName)

    $result = Invoke-Git -Arguments @("show", $ObjectName)
    Assert-True -Condition ($result.ExitCode -eq 0) -Message "Unable to read pinned git object: $ObjectName $($result.Text)"
    return $result.Text
}

function Split-MarkdownTableLine {
    param([string]$Line)

    return @($Line.Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
}

function Get-MarkdownTableRows {
    param(
        [string]$Text,
        [string]$Heading,
        [string[]]$Columns
    )

    $headingMarker = "## $Heading"
    $start = $Text.IndexOf($headingMarker, [StringComparison]::Ordinal)
    Assert-True -Condition ($start -ge 0) -Message "Missing markdown heading: $headingMarker"

    $next = $Text.IndexOf("`n## ", $start + $headingMarker.Length, [StringComparison]::Ordinal)
    if ($next -lt 0) {
        $next = $Text.Length
    }

    $section = $Text.Substring($start, $next - $start)
    $tableLines = @($section -split "\r?\n" | Where-Object { $_.Trim().StartsWith("|") })
    Assert-True -Condition ($tableLines.Count -ge 2) -Message "Markdown heading '$Heading' must contain a table."

    $header = Split-MarkdownTableLine -Line $tableLines[0]
    Assert-SequenceEqual -Actual $header -Expected $Columns -Context "$Heading table header"

    $separator = Split-MarkdownTableLine -Line $tableLines[1]
    Assert-True -Condition ($separator.Count -eq $Columns.Count) -Message "$Heading table separator column count mismatch."
    foreach ($cell in $separator) {
        Assert-True -Condition ($cell -match '^-+$') -Message "$Heading table separator must contain only dashes: $cell"
    }

    $rows = @()
    for ($i = 2; $i -lt $tableLines.Count; $i++) {
        $cells = Split-MarkdownTableLine -Line $tableLines[$i]
        Assert-True -Condition ($cells.Count -eq $Columns.Count) -Message "$Heading table row $($i - 1) column count mismatch: $($tableLines[$i])"

        $row = [ordered]@{}
        for ($columnIndex = 0; $columnIndex -lt $Columns.Count; $columnIndex++) {
            $row[$Columns[$columnIndex]] = $cells[$columnIndex]
        }

        $rows += [pscustomobject]$row
    }

    return $rows
}

function Get-MarkdownCodeValues {
    param([string]$Text)

    return @([regex]::Matches($Text, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
}

function Get-SingleMarkdownCodeValue {
    param(
        [string]$Text,
        [string]$Context
    )

    $values = @(Get-MarkdownCodeValues -Text $Text)
    Assert-True -Condition ($values.Count -eq 1) -Message "$Context must contain exactly one markdown code value. Actual=[$($values -join ', ')]"
    return $values[0]
}

function Get-CSharpEnumMembers {
    param(
        [string]$Text,
        [string]$EnumName
    )

    $start = $Text.IndexOf("public enum $EnumName", [StringComparison]::Ordinal)
    Assert-True -Condition ($start -ge 0) -Message "Missing enum: $EnumName"
    $openBrace = $Text.IndexOf("{", $start, [StringComparison]::Ordinal)
    $closeBrace = $Text.IndexOf("}", $openBrace, [StringComparison]::Ordinal)
    Assert-True -Condition ($openBrace -gt $start -and $closeBrace -gt $openBrace) -Message "Cannot slice enum body: $EnumName"

    $body = $Text.Substring($openBrace + 1, $closeBrace - $openBrace - 1)
    return @($body -split "\r?\n" |
        ForEach-Object { $_.Trim().TrimEnd(",") } |
        Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9_]*$' })
}

function Get-WorkspaceActionSurfaceArray {
    param(
        [string]$Text,
        [string]$ArrayName
    )

    $start = $Text.IndexOf("WorkspaceActionSurface[] $ArrayName", [StringComparison]::Ordinal)
    Assert-True -Condition ($start -ge 0) -Message "Missing WorkspaceActionSurface array: $ArrayName"
    $end = $Text.IndexOf("};", $start, [StringComparison]::Ordinal)
    Assert-True -Condition ($end -gt $start) -Message "Cannot slice WorkspaceActionSurface array: $ArrayName"

    $slice = $Text.Substring($start, $end - $start)
    return @([regex]::Matches($slice, 'WorkspaceActionSurface\.([A-Za-z0-9_]+)') |
        ForEach-Object { $_.Groups[1].Value })
}

function Get-MethodSlice {
    param(
        [string]$Text,
        [string]$MethodName
    )

    $signature = "private static IReadOnlyList<WorkspaceActionItem> $MethodName()"
    $start = $Text.IndexOf($signature, [StringComparison]::Ordinal)
    Assert-True -Condition ($start -ge 0) -Message "Missing action catalog method: $MethodName"

    $next = $Text.IndexOf("private static IReadOnlyList<WorkspaceActionItem>", $start + $signature.Length, [StringComparison]::Ordinal)
    if ($next -lt 0) {
        $next = $Text.Length
    }

    return $Text.Substring($start, $next - $start)
}

$matrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$featureCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FeatureCatalogClient.cs"
$actionCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs"
$actionOrderSmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-action-order.ps1"
$paritySmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-parity.ps1"

foreach ($path in @($matrixPath, $mainWindowPath, $featureCatalogPath, $actionCatalogPath, $actionOrderSmokePath, $paritySmokePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing UI parity matrix input: $path"
}

$matrix = Get-Content -Raw -LiteralPath $matrixPath
$mainWindow = Get-Content -Raw -LiteralPath $mainWindowPath
$featureCatalog = Get-Content -Raw -LiteralPath $featureCatalogPath
$actionCatalog = Get-Content -Raw -LiteralPath $actionCatalogPath
$actionOrderSmoke = Get-Content -Raw -LiteralPath $actionOrderSmokePath
$paritySmoke = Get-Content -Raw -LiteralPath $paritySmokePath

$macBaselineCommit = "23ba06343bbaa58c30ef6b9bbddd09bb4e80241c"
$macBaselinePaths = @(
    "Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/Sections/QuickActionsPanelView.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift"
)
$macBaselineSignals = @(
    [pscustomobject]@{
        Source = "NavigationItem.swift"
        Path = "Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift"
        Symbols = @(
            'case dashboard = "sidebar.dashboard"',
            'case deviceManagement = "sidebar.deviceDiscovery"',
            'case usbDeviceManagement = "sidebar.usbManagement"',
            'case fileTransfer = "sidebar.fileTransfer"',
            'case remoteDesktop = "sidebar.remoteDesktop"',
            'case quantumCommunication = "quantum.title"',
            'case systemMonitor = "sidebar.systemMonitor"',
            'case settings = "sidebar.settings"'
        )
        Anchors = @("FeatureCatalogClient.Entries")
    },
    [pscustomobject]@{
        Source = "DashboardContentView.swift"
        Path = "Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift"
        Symbols = @(
            "topStatsRow",
            "WeatherDashboardCard()",
            "DeviceDiscoveryPanelView(",
            'RemoteSessionsPanelView(selectedSession: $selectedSession)',
            'QuickActionsPanelView(selectedNavigation: $selectedNavigation)',
            "AppleSiliconInfoCardView()"
        )
        Anchors = @(
            "DashboardMetrics",
            "DeviceDiscoveryScan",
            "RemoteDesktopSessions",
            "DashboardQuickActions"
        )
    },
    [pscustomobject]@{
        Source = "QuickActionsPanelView.swift"
        Path = "Sources/SkyBridgeCompassApp/Dashboard/Sections/QuickActionsPanelView.swift"
        Symbols = @(
            "action.scanDevices",
            "appModel.triggerDiscoveryRefresh()",
            "dashboard.fileTransfer",
            "selectedNavigation = .fileTransfer",
            "action.systemMonitor",
            "selectedNavigation = .systemMonitor",
            "action.settings",
            "selectedNavigation = .settings"
        )
        Anchors = @("DashboardQuickActions")
    },
    [pscustomobject]@{
        Source = "TopNavigationBarView.swift"
        Path = "Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift"
        Symbols = @(
            "ipLocationIndicator",
            "networkSpeedIndicator",
            "networkLatencyIndicator",
            "connectionStatusIndicator",
            "fpsIndicator",
            "NotificationBellView()",
            "themeToggleButton",
            "manualConnect.title",
            "manualConnect.ipAddress",
            "manualConnect.port",
            "manualConnect.pairingCode",
            "action.cancel",
            "device.action.connect",
            "appModel.manualConnect(ip: manualIP, port: port, pairingCode: manualCode)"
        )
        Anchors = @("TopBarStatusClient", "TopBarStatusSlot", "TopBarActions", "DeviceDiscoveryScan", "ManualConnectionClient", "DeviceDiscoveryManualConnectFinal")
    }
)

Assert-Contains -Text $matrix -Needle "Mac baseline commit: ``$macBaselineCommit``" -Message "UI parity matrix must pin the mac baseline commit."
foreach ($macPath in $macBaselinePaths) {
    $macObject = "${macBaselineCommit}:$macPath"
    Assert-Contains -Text $matrix -Needle "``$macObject``" -Message "UI parity matrix must use immutable mac source object: $macObject"
    Assert-True -Condition (Test-GitObjectExists -ObjectName $macObject) -Message "Pinned mac source object is not available in this repository: $macObject"
}

$macSignalRows = Get-MarkdownTableRows `
    -Text $matrix `
    -Heading "Mac-To-Windows Baseline Signal Matrix" `
    -Columns @("Mac source", "Required ordered mac symbols", "Windows parity anchor")
Assert-True -Condition ($macSignalRows.Count -eq $macBaselineSignals.Count) -Message "Mac baseline signal matrix row count mismatch."
Assert-NoDuplicates -Values @($macSignalRows | ForEach-Object { Get-SingleMarkdownCodeValue -Text $_.'Mac source' -Context "Mac baseline signal source" }) -Context "Mac baseline signal source"

for ($macSignalIndex = 0; $macSignalIndex -lt $macBaselineSignals.Count; $macSignalIndex++) {
    $expected = $macBaselineSignals[$macSignalIndex]
    $actual = $macSignalRows[$macSignalIndex]
    Assert-SequenceEqual -Actual @(Get-SingleMarkdownCodeValue -Text $actual.'Mac source' -Context "Mac baseline signal source") -Expected @($expected.Source) -Context "Mac baseline signal source row $macSignalIndex"
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Required ordered mac symbols') -Expected $expected.Symbols -Context "Mac baseline signal symbols for $($expected.Source)"
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Windows parity anchor') -Expected $expected.Anchors -Context "Mac baseline Windows anchors for $($expected.Source)"

    $macObject = "${macBaselineCommit}:$($expected.Path)"
    $macText = Get-GitObjectText -ObjectName $macObject
    Assert-Ordered -Text $macText -Needles $expected.Symbols -Context "Pinned mac source signals for $($expected.Source)"
}

$featureRows = @(
    [pscustomobject]@{ Order = "1"; Id = "Dashboard"; Title = "Dashboard"; Gate = "IsDashboardSelected"; Heading = 'AutomationProperties.AutomationId="Skybridge.SelectedFeature.Title"'; Surfaces = @("DashboardQuickActions"); Anchors = @("Skybridge.Navigation.List", "Skybridge.SelectedFeature.Title", "Skybridge.Actions.DashboardQuickActions") },
    [pscustomobject]@{ Order = "2"; Id = "DeviceDiscovery"; Title = "Device Discovery"; Gate = "IsDeviceDiscoverySelected"; Heading = 'Text="Device Discovery"'; Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal", "CrossNetworkQr", "CrossNetworkCodePrimary", "CrossNetworkCodeConnect"); Anchors = @("WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt", "WorkspaceAction.DeviceDiscoveryScan.ManualConnect", "Skybridge.Actions.DeviceDiscoveryManualConnectFinal") },
    [pscustomobject]@{ Order = "3"; Id = "UsbManagement"; Title = "USB Management"; Gate = "IsUsbManagementSelected"; Heading = 'Text="USB Management"'; Surfaces = @("UsbManagementHeader"); Anchors = @("WorkspaceAction.UsbManagementHeader.RefreshDevices") },
    [pscustomobject]@{ Order = "4"; Id = "FileTransfer"; Title = "File Transfer"; Gate = "IsFileTransferSelected"; Heading = 'Text="File Transfer"'; Surfaces = @("FileTransferHeader", "FileTransfer"); Anchors = @("WorkspaceAction.FileTransfer.SelectFiles", "WorkspaceAction.FileTransfer.SelectFolder", "WorkspaceAction.FileTransfer.GenerateQr", "FileTransferShareQrPreview") },
    [pscustomobject]@{ Order = "5"; Id = "RemoteDesktop"; Title = "Remote Desktop"; Gate = "IsRemoteDesktopSelected"; Heading = 'Text="Remote Desktop"'; Surfaces = @("RemoteDesktopHeader", "RemoteDesktop"); Anchors = @("WorkspaceAction.RemoteDesktop.RecommendedConnect", "WorkspaceAction.RemoteDesktop.AdvancedConnect", "WorkspaceAction.RemoteDesktop.DisconnectSession") },
    [pscustomobject]@{ Order = "6"; Id = "SystemMonitor"; Title = "System Monitor"; Gate = "IsSystemMonitorSelected"; Heading = 'Text="System Monitor"'; Surfaces = @("SystemMonitorHeader", "SystemMonitorControls"); Anchors = @("WorkspaceAction.SystemMonitorControls.Monitoring", "WorkspaceAction.SystemMonitorControls.StopMonitoring", "WorkspaceAction.SystemMonitorControls.EnableAdvancedMonitoring") },
    [pscustomobject]@{ Order = "7"; Id = "Settings"; Title = "Settings"; Gate = "IsSettingsSelected"; Heading = 'Text="Settings"'; Surfaces = @("SettingsHeader", "SettingsToolbar", "SettingsMaintenance"); Anchors = @("WorkspaceAction.SettingsToolbar.ExportSettings", "WorkspaceAction.SettingsToolbar.OpenSystemPreferences", "WorkspaceAction.SettingsMaintenance.ApplySettings") }
)

$navigationMatrixRows = Get-MarkdownTableRows `
    -Text $matrix `
    -Heading "Navigation And Workspace Matrix" `
    -Columns @("Mac order", "Windows feature id", "Visible title", "XAML visibility gate", "Required action surfaces", "Required automation anchors")
Assert-True -Condition ($navigationMatrixRows.Count -eq $featureRows.Count) -Message "Navigation matrix row count must match the expected mac feature count."
Assert-NoDuplicates -Values @($navigationMatrixRows | ForEach-Object { $_.'Mac order' }) -Context "Navigation matrix mac order"
Assert-NoDuplicates -Values @($navigationMatrixRows | ForEach-Object { $_.'Windows feature id' }) -Context "Navigation matrix feature id"

for ($featureIndex = 0; $featureIndex -lt $featureRows.Count; $featureIndex++) {
    $expected = $featureRows[$featureIndex]
    $actual = $navigationMatrixRows[$featureIndex]

    Assert-True -Condition ($actual.'Mac order' -eq $expected.Order) -Message "Navigation matrix order mismatch for $($expected.Id)."
    Assert-True -Condition ($actual.'Windows feature id' -eq $expected.Id) -Message "Navigation matrix feature id mismatch at row $($expected.Order)."
    Assert-True -Condition ($actual.'Visible title' -eq $expected.Title) -Message "Navigation matrix title mismatch for $($expected.Id)."
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'XAML visibility gate') -Expected @($expected.Gate) -Context "Navigation matrix gate for $($expected.Id)"
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Required action surfaces') -Expected $expected.Surfaces -Context "Navigation matrix surfaces for $($expected.Id)"
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Required automation anchors') -Expected $expected.Anchors -Context "Navigation matrix anchors for $($expected.Id)"
}

foreach ($row in $featureRows) {
    Assert-Contains -Text $matrix -Needle "| $($row.Order) | $($row.Id) | $($row.Title) | ``$($row.Gate)`` |" -Message "UI parity matrix missing feature row: $($row.Id)"
    Assert-Contains -Text $mainWindow -Needle "Visibility=`"{Binding $($row.Gate)" -Message "MainWindow missing visibility gate: $($row.Gate)"
    Assert-Contains -Text $mainWindow -Needle $row.Heading -Message "MainWindow missing feature heading: $($row.Title)"
    Assert-Contains -Text $featureCatalog -Needle "FeatureEntryId.$($row.Id)" -Message "FeatureCatalog missing feature id: $($row.Id)"

    foreach ($surface in $row.Surfaces) {
        Assert-Contains -Text $matrix -Needle "``$surface``" -Message "UI parity matrix missing surface: $surface"
        Assert-Contains -Text $actionCatalog -Needle "WorkspaceActionSurface.$surface" -Message "WorkspaceActionCatalog missing surface: $surface"
    }

    foreach ($anchor in $row.Anchors) {
        Assert-Contains -Text $matrix -Needle "``$anchor``" -Message "UI parity matrix missing anchor: $anchor"
    }
}

Assert-Ordered -Text $featureCatalog -Context "FeatureCatalog mac navigation order" -Needles @(
    "FeatureEntryId.Dashboard",
    "FeatureEntryId.DeviceDiscovery",
    "FeatureEntryId.UsbManagement",
    "FeatureEntryId.FileTransfer",
    "FeatureEntryId.RemoteDesktop",
    "FeatureEntryId.SystemMonitor",
    "FeatureEntryId.Settings"
)

Assert-Ordered -Text $mainWindow -Context "MainWindow selected workspace visibility order" -Needles @(
    "Visibility=`"{Binding IsDashboardSelected",
    "Visibility=`"{Binding IsDeviceDiscoverySelected",
    "Visibility=`"{Binding IsUsbManagementSelected",
    "Visibility=`"{Binding IsFileTransferSelected",
    "Visibility=`"{Binding IsRemoteDesktopSelected",
    "Visibility=`"{Binding IsSystemMonitorSelected",
    "Visibility=`"{Binding IsSettingsSelected"
)

Assert-Ordered -Text $mainWindow -Context "MainWindow global shell anchor order" -Needles @(
    'AutomationProperties.AutomationId="Skybridge.Navigation.List"',
    'ItemsSource="{Binding NavigationItems}"',
    'AutomationProperties.AutomationId="Skybridge.SelectedFeature.Title"',
    'AutomationProperties.AutomationId="Skybridge.Status.Message"',
    'AutomationProperties.AutomationId="Skybridge.TopBar.ConnectionStatus"',
    'AutomationProperties.AutomationId="Skybridge.TopBar.DiagnosticsStatus"',
    'AutomationProperties.AutomationId="Skybridge.Actions.TopBar"',
    'ItemsSource="{Binding TopBarActions}"'
)

Assert-Ordered -Text $mainWindow -Context "MainWindow action binding order" -Needles @(
    'ItemsSource="{Binding DashboardQuickActions}"',
    'ItemsSource="{Binding DeviceDiscoveryPrimaryActions}"',
    'ItemsSource="{Binding DeviceDiscoveryScanActions}"',
    'ItemsSource="{Binding DeviceDiscoveryManualConnectFinalActions}"',
    'ItemsSource="{Binding CrossNetworkQrActions}"',
    'ItemsSource="{Binding CrossNetworkCodePrimaryActions}"',
    'ItemsSource="{Binding CrossNetworkCodeConnectActions}"',
    'ItemsSource="{Binding UsbManagementHeaderActions}"',
    'ItemsSource="{Binding FileTransferHeaderActions}"',
    'ItemsSource="{Binding FileTransferActions}"',
    'ItemsSource="{Binding RemoteDesktopHeaderActions}"',
    'ItemsSource="{Binding RemoteDesktopActions}"',
    'ItemsSource="{Binding SystemMonitorHeaderActions}"',
    'ItemsSource="{Binding SystemMonitorActions}"',
    'ItemsSource="{Binding SettingsHeaderActions}"',
    'ItemsSource="{Binding SettingsToolbarActions}"',
    'ItemsSource="{Binding SettingsMaintenanceActions}"',
    'ItemsSource="{Binding SessionControlActions}"'
)

foreach ($templateSignal in @(
    '<DataTemplate x:Key="WorkspaceActionButtonTemplate">',
    '<DataTemplate x:Key="WorkspaceActionButtonWithDetailTemplate">',
    '<DataTemplate x:Key="TopBarStatusActionButtonTemplate">',
    '<DataTemplate x:Key="DashboardQuickActionTemplate">',
    'AutomationProperties.AutomationId="{Binding AutomationId}"',
    'Command="{Binding Command}"',
    'Width="44"',
    'Height="36"',
    'ToolTipService.ToolTip="{Binding Title}"'
)) {
    Assert-Contains -Text $mainWindow -Needle $templateSignal -Message "MainWindow missing shared action-template signal: $templateSignal"
}

# 4 workspace-action buttons live inside the shared action templates (topbar /
# quick-action / detail / status). The weather hero card adds 2 card-local controls that are
# NOT workspace actions and have no place in those templates: the header Refresh button and
# the error-state Retry button. Those 2 are accounted for here (4 + 2 = 6); the shared-template
# usage itself is still enforced by the Assert-Ordered checks below.
Assert-Count -Text $mainWindow -Pattern '<Button\b' -ExpectedCount 6 -Message "MainWindow must render workspace-action buttons through the four shared action templates (plus the weather card's Refresh + Retry card-local buttons)."

Assert-Ordered -Text $mainWindow -Context "MainWindow shared action template usage" -Needles @(
    'ItemsSource="{Binding TopBarActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource TopBarStatusActionButtonTemplate}"',
    'ItemsSource="{Binding DashboardQuickActions}"',
    'ItemsPanel="{StaticResource DashboardQuickActionItemsPanel}"',
    'ItemTemplate="{StaticResource DashboardQuickActionTemplate}"',
    'ItemsSource="{Binding DeviceDiscoveryPrimaryActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource WorkspaceActionButtonTemplate}"',
    'ItemsSource="{Binding DeviceDiscoveryManualConnectFinalActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource WorkspaceActionButtonWithDetailTemplate}"'
)

foreach ($styleMatrixSignal in @(
    "Shared Style And Template Matrix",
    "Mac baseline commit",
    "WorkspaceActionButtonTemplate",
    "WorkspaceActionButtonWithDetailTemplate",
    "TopBarStatusActionButtonTemplate",
    "DashboardQuickActionTemplate",
    "Feature sections must not introduce inline ``Button`` controls"
)) {
    Assert-Contains -Text $matrix -Needle $styleMatrixSignal -Message "UI parity matrix doc missing style/template signal: $styleMatrixSignal"
}

Assert-Ordered -Text $actionCatalog -Context "WorkspaceActionCatalog initial surface order" -Needles @(
    "WorkspaceActionSurface.TopBarActions",
    "WorkspaceActionSurface.SessionControls",
    "WorkspaceActionSurface.DashboardQuickActions",
    "WorkspaceActionSurface.DeviceDiscoveryPrimary",
    "WorkspaceActionSurface.DeviceDiscoveryScan",
    "WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal",
    "WorkspaceActionSurface.CrossNetworkQr",
    "WorkspaceActionSurface.CrossNetworkCodePrimary",
    "WorkspaceActionSurface.CrossNetworkCodeConnect",
    "WorkspaceActionSurface.UsbManagementHeader",
    "WorkspaceActionSurface.FileTransferHeader",
    "WorkspaceActionSurface.FileTransfer",
    "WorkspaceActionSurface.RemoteDesktopHeader",
    "WorkspaceActionSurface.RemoteDesktop",
    "WorkspaceActionSurface.SystemMonitorHeader",
    "WorkspaceActionSurface.SystemMonitorControls",
    "WorkspaceActionSurface.SettingsHeader",
    "WorkspaceActionSurface.SettingsToolbar",
    "WorkspaceActionSurface.SettingsMaintenance"
)

$surfaceActions = @(
    [pscustomobject]@{ Surface = "TopBarActions"; Method = "BuildTopBarActions"; Keys = @('"Notifications"', '"Theme"') },
    [pscustomobject]@{ Surface = "SessionControls"; Method = "BuildSessionControlActions"; Keys = @('"Connect"', '"Heartbeat"', '"Disconnect"') },
    [pscustomobject]@{ Surface = "DashboardQuickActions"; Method = "BuildDashboardQuickActions"; Keys = @('"ScanDevices"', '"FileTransfer"', '"SystemMonitor"', '"Settings"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryPrimary"; Method = "BuildDeviceDiscoveryPrimaryActions"; Keys = @('"ParseTxt"', '"ValidatePairing"', '"PrepareConnection"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryScan"; Method = "BuildDeviceDiscoveryScanActions"; Keys = @('"ExtendedSearch"', '"ManualConnect"', '"StartScan"', '"StopScan"', '"Refresh"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryManualConnectFinal"; Method = "BuildDeviceDiscoveryManualConnectFinalActions"; Keys = @('"Cancel"', '"Connect"') },
    [pscustomobject]@{ Surface = "CrossNetworkQr"; Method = "BuildCrossNetworkQrActions"; Keys = @('"GenerateQrCode"', '"ScanQrCode"') },
    [pscustomobject]@{ Surface = "CrossNetworkCodePrimary"; Method = "BuildCrossNetworkCodePrimaryActions"; Keys = @('"GenerateCode"', '"CopyCode"', '"RegenerateCode"') },
    [pscustomobject]@{ Surface = "CrossNetworkCodeConnect"; Method = "BuildCrossNetworkCodeConnectActions"; Keys = @('"ConnectWithCode"') },
    [pscustomobject]@{ Surface = "UsbManagementHeader"; Method = "BuildUsbManagementHeaderActions"; Keys = @('"RefreshDevices"') },
    [pscustomobject]@{ Surface = "FileTransferHeader"; Method = "BuildFileTransferHeaderActions"; Keys = @('"RefreshPlan"') },
    [pscustomobject]@{ Surface = "FileTransfer"; Method = "BuildFileTransferActions"; Keys = @('"SelectFiles"', '"SelectFolder"', '"GenerateQr"') },
    [pscustomobject]@{ Surface = "RemoteDesktopHeader"; Method = "BuildRemoteDesktopHeaderActions"; Keys = @('"RefreshSessions"') },
    [pscustomobject]@{ Surface = "RemoteDesktop"; Method = "BuildRemoteDesktopActions"; Keys = @('"RecommendedConnect"', '"AdvancedConnect"', '"PerformanceOverlay"', '"Quality"', '"Settings"', '"FullScreen"', '"DisconnectSession"') },
    [pscustomobject]@{ Surface = "SystemMonitorHeader"; Method = "BuildSystemMonitorHeaderActions"; Keys = @('"RefreshMetrics"') },
    [pscustomobject]@{ Surface = "SystemMonitorControls"; Method = "BuildSystemMonitorControlActions"; Keys = @('"Monitoring"', '"StopMonitoring"', '"EnableAdvancedMonitoring"') },
    [pscustomobject]@{ Surface = "SettingsHeader"; Method = "BuildSettingsHeaderActions"; Keys = @('"RefreshStatus"') },
    [pscustomobject]@{ Surface = "SettingsToolbar"; Method = "BuildSettingsToolbarActions"; Keys = @('"ExportSettings"', '"ImportSettings"', '"ResetSettings"', '"RequestPermission"', '"OpenSystemPreferences"') },
    [pscustomobject]@{ Surface = "SettingsMaintenance"; Method = "BuildSettingsMaintenanceActions"; Keys = @('"ApplySettings"', '"RestoreDefaults"', '"ResetMonitorData"') }
)

$expectedSurfaceNames = @($surfaceActions | ForEach-Object { $_.Surface })
$expectedDynamicSurfaceNames = @(
    "TopBarActions",
    "SessionControls",
    "DeviceDiscoveryPrimary",
    "DeviceDiscoveryScan",
    "DeviceDiscoveryManualConnectFinal",
    "CrossNetworkQr",
    "CrossNetworkCodePrimary",
    "CrossNetworkCodeConnect",
    "UsbManagementHeader",
    "FileTransferHeader",
    "FileTransfer",
    "RemoteDesktopHeader",
    "RemoteDesktop",
    "SystemMonitorHeader",
    "SystemMonitorControls",
    "SettingsHeader",
    "SettingsToolbar",
    "SettingsMaintenance"
)
$actionMatrixRows = Get-MarkdownTableRows `
    -Text $matrix `
    -Heading "Action Order Matrix" `
    -Columns @("Surface", "Required action key order")
Assert-True -Condition ($actionMatrixRows.Count -eq $surfaceActions.Count) -Message "Action-order matrix row count must match expected surfaces."
$actionMatrixSurfaceNames = @($actionMatrixRows | ForEach-Object { Get-SingleMarkdownCodeValue -Text $_.Surface -Context "Action-order matrix surface" })
Assert-NoDuplicates -Values $actionMatrixSurfaceNames -Context "Action-order matrix surface"
Assert-SequenceEqual -Actual $actionMatrixSurfaceNames -Expected $expectedSurfaceNames -Context "Action-order matrix surface order"

$enumSurfaceNames = Get-CSharpEnumMembers -Text $actionCatalog -EnumName "WorkspaceActionSurface"
Assert-SequenceEqual -Actual $enumSurfaceNames -Expected $expectedSurfaceNames -Context "WorkspaceActionSurface enum order"
Assert-SequenceEqual -Actual (Get-WorkspaceActionSurfaceArray -Text $actionCatalog -ArrayName "InitialSurfaces") -Expected $expectedSurfaceNames -Context "WorkspaceActionCatalog InitialSurfaces order"
Assert-SequenceEqual -Actual (Get-WorkspaceActionSurfaceArray -Text $actionCatalog -ArrayName "DynamicRefreshSurfaces") -Expected $expectedDynamicSurfaceNames -Context "WorkspaceActionCatalog DynamicRefreshSurfaces order"

$dynamicMatrixRows = @(Get-MarkdownTableRows `
    -Text $matrix `
    -Heading "Dynamic Refresh Surface Matrix" `
    -Columns @("Source", "Required dynamic surface order"))
Assert-True -Condition ($dynamicMatrixRows.Count -eq 1) -Message "Dynamic refresh surface matrix must have exactly one row."
Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $dynamicMatrixRows[0].Source) -Expected @("WorkspaceActionCatalogClient.DynamicRefreshSurfaces") -Context "Dynamic refresh surface matrix source"
Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $dynamicMatrixRows[0].'Required dynamic surface order') -Expected $expectedDynamicSurfaceNames -Context "Dynamic refresh surface matrix order"

foreach ($surface in $surfaceActions) {
    $actionRow = @($actionMatrixRows | Where-Object { (Get-SingleMarkdownCodeValue -Text $_.Surface -Context "Action-order matrix surface") -eq $surface.Surface })
    Assert-True -Condition ($actionRow.Count -eq 1) -Message "Action-order matrix must have exactly one row for surface: $($surface.Surface)"
    $expectedKeys = @($surface.Keys | ForEach-Object { $_.Trim('"') })
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actionRow[0].'Required action key order') -Expected $expectedKeys -Context "Action-order matrix keys for $($surface.Surface)"

    $slice = Get-MethodSlice -Text $actionCatalog -MethodName $surface.Method
    Assert-Ordered -Text $slice -Context "$($surface.Surface) action order" -Needles $surface.Keys
    Assert-Contains -Text $matrix -Needle "| ``$($surface.Surface)`` |" -Message "UI parity matrix missing action-order row: $($surface.Surface)"
    Assert-Contains -Text $actionOrderSmoke -Needle "WorkspaceActionSurface.$($surface.Surface)" -Message "UI action-order smoke missing surface: $($surface.Surface)"
}

$styleRows = Get-MarkdownTableRows `
    -Text $matrix `
    -Heading "Shared Style And Template Matrix" `
    -Columns @("Region", "Required shared template", "Required panel/style ownership")
$expectedStyleRows = @(
    [pscustomobject]@{ Region = "Top-bar actions"; Template = "TopBarStatusActionButtonTemplate"; Panel = "HorizontalWorkspaceActionItemsPanel" },
    [pscustomobject]@{ Region = "Dashboard quick actions"; Template = "DashboardQuickActionTemplate"; Panel = "DashboardQuickActionItemsPanel" },
    [pscustomobject]@{ Region = "Workspace action surfaces"; Template = "WorkspaceActionButtonTemplate"; Panel = "HorizontalWorkspaceActionItemsPanel" },
    [pscustomobject]@{ Region = "Final/manual connect action"; Template = "WorkspaceActionButtonWithDetailTemplate"; Panel = "HorizontalWorkspaceActionItemsPanel" }
)
Assert-True -Condition ($styleRows.Count -eq $expectedStyleRows.Count) -Message "Shared style/template matrix row count mismatch."
Assert-NoDuplicates -Values @($styleRows | ForEach-Object { $_.Region }) -Context "Shared style/template matrix region"
for ($styleIndex = 0; $styleIndex -lt $expectedStyleRows.Count; $styleIndex++) {
    $expected = $expectedStyleRows[$styleIndex]
    $actual = $styleRows[$styleIndex]
    Assert-True -Condition ($actual.Region -eq $expected.Region) -Message "Shared style/template matrix region mismatch at row $styleIndex."
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Required shared template') -Expected @($expected.Template) -Context "Shared style/template template for $($expected.Region)"
    Assert-SequenceEqual -Actual (Get-MarkdownCodeValues -Text $actual.'Required panel/style ownership') -Expected @($expected.Panel) -Context "Shared style/template panel for $($expected.Region)"
}

foreach ($matrixSignal in @(
    "Windows UI parity matrix",
    "Fonts, rendering scale, and platform-specific pixel metrics are intentionally out of scope.",
    "Navigation And Workspace Matrix",
    "Global Shell Matrix",
    "Action Order Matrix",
    "Dynamic Refresh Surface Matrix",
    "runtimeActionBounds",
    "WorkspaceAction.<Surface>.<Key>",
    "minimum usable bounds",
    "verify-windows-ui-parity-matrix.ps1",
    "verify-windows-ui-action-order.ps1",
    "verify-windows-ui-parity.ps1"
)) {
    Assert-Contains -Text $matrix -Needle $matrixSignal -Message "UI parity matrix doc missing signal: $matrixSignal"
}

Assert-Contains -Text $paritySmoke -Needle "windows-ui-parity-matrix.md" -Message "Broad UI parity gate must know about the matrix doc."
Assert-Contains -Text $paritySmoke -Needle "verify-windows-ui-parity-matrix.ps1" -Message "Broad UI parity gate must know about the matrix smoke."

Write-Output "windows-ui-parity-matrix: ok"
