param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [int]$TimeoutSeconds = 20,
    [string]$EvidenceDir = "",
    [string]$EvidenceBranch = "",
    [string]$EvidenceHead = ""
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

function Get-GitText {
    param(
        [string[]]$Arguments,
        [string]$Context
    )

    $output = & git -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve $Context for WinUI visual evidence: git $($Arguments -join ' ') failed with exit code $LASTEXITCODE. $($output -join ' ')"
    }

    $value = (($output | Select-Object -First 1) -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Unable to resolve $Context for WinUI visual evidence: git $($Arguments -join ' ') returned an empty value."
    }

    return $value
}

function Get-EvidenceBranch {
    if (-not [string]::IsNullOrWhiteSpace($EvidenceBranch)) {
        return $EvidenceBranch.Trim()
    }

    return Get-GitText -Arguments @("rev-parse", "--abbrev-ref", "HEAD") -Context "repo branch"
}

function Get-EvidenceHead {
    if (-not [string]::IsNullOrWhiteSpace($EvidenceHead)) {
        Assert-True -Condition ($EvidenceHead -match '^[0-9a-f]{40}$') -Message "EvidenceHead must be a 40-character git SHA: $EvidenceHead"
        return $EvidenceHead.Trim()
    }

    $head = Get-GitText -Arguments @("rev-parse", "HEAD") -Context "repo head"
    Assert-True -Condition ($head -match '^[0-9a-f]{40}$') -Message "Resolved repo head must be a 40-character git SHA: $head"
    return $head
}

function Assert-UnpackagedDefaultWindowsPackageType {
    param([xml]$Project)

    $packageTypes = @($Project.Project.PropertyGroup |
        ForEach-Object { $_.WindowsPackageType } |
        Where-Object { $null -ne $_ })
    $unpackagedDefaults = @($packageTypes |
        Where-Object {
            $_.InnerText.Trim() -eq "None" -and
            $_.Condition -match [regex]::Escape('$(EnableMsixTooling)') -and
            $_.Condition -match "!=" -and
            $_.Condition -match "true"
        })

    Assert-True `
        -Condition ($unpackagedDefaults.Count -eq 1) `
        -Message "WinUI automation smoke requires exactly one conditional unpackaged WindowsPackageType=None default path."
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

function Get-AncestorByControlType {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [System.Windows.Automation.ControlType]$ControlType
    )

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Element
    while ($null -ne $current) {
        if ($current.Current.ControlType -eq $ControlType) {
            return $current
        }

        $current = $walker.GetParent($current)
    }

    return $null
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

function Get-NavigationItemByFeatureId {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$FeatureId
    )

    $featureAnchor = Assert-VisibleByAutomationId -Root $Window -AutomationId $FeatureId
    $navigationItem = Get-AncestorByControlType -Element $featureAnchor -ControlType ([System.Windows.Automation.ControlType]::ListItem)
    Assert-True -Condition ($null -ne $navigationItem) -Message "Navigation item ancestor is missing for feature id: $FeatureId"
    return [pscustomobject]@{
        Item = $navigationItem
        Anchor = $featureAnchor
    }
}

function Assert-SelectedFeature {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$FeatureId
    )

    $navigation = Get-NavigationItemByFeatureId -Window $Window -FeatureId $FeatureId
    $selectionPattern = $navigation.Item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    Assert-True -Condition ([bool]$selectionPattern.Current.IsSelected) -Message "Navigation feature is not selected: $FeatureId"

    $heading = Assert-PresentByAutomationId -Root $Window -AutomationId "Skybridge.SelectedFeature.Title"
    $expectedHeading = $navigation.Anchor.Current.Name
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($expectedHeading)) -Message "Navigation feature name is empty: $FeatureId"
    Assert-True -Condition ($heading.Current.Name -eq $expectedHeading) -Message "Selected heading mismatch for $FeatureId. expected=$expectedHeading actual=$($heading.Current.Name)"
    return $heading
}

function Assert-StatusMessageNotEmpty {
    param([System.Windows.Automation.AutomationElement]$Window)

    $status = Assert-PresentByAutomationId -Root $Window -AutomationId "Skybridge.Status.Message"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($status.Current.Name)) -Message "Status message is empty."
    return $status
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

function Set-WorkspaceScrollPercent {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [double]$VerticalPercent,
        [switch]$Required
    )

    $scrollViewer = Assert-PresentByAutomationId -Root $Window -AutomationId "Skybridge.Workspace.ScrollViewer" -TimeoutSeconds 5
    try {
        $scrollPattern = $scrollViewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    }
    catch {
        if ($Required) {
            throw "Workspace ScrollViewer does not expose ScrollPattern: $($_.Exception.Message)"
        }

        return
    }

    if (-not [bool]$scrollPattern.Current.VerticallyScrollable) {
        if ($Required) {
            throw "Workspace ScrollViewer is not vertically scrollable for requested percent: $VerticalPercent"
        }

        return
    }

    $boundedPercent = [Math]::Min(100.0, [Math]::Max(0.0, $VerticalPercent))
    $scrollPattern.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, $boundedPercent)
    Start-Sleep -Milliseconds 250
}

function Invoke-OrClickElement {
    param([System.Windows.Automation.AutomationElement]$Element)

    try {
        $invokePattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invokePattern.Invoke()
        Start-Sleep -Milliseconds 300
        return
    }
    catch {
        Write-Verbose "InvokePattern unavailable for $($Element.Current.AutomationId): $($_.Exception.Message)"
    }

    $rect = $Element.Current.BoundingRectangle
    Assert-True `
        -Condition (-not $Element.Current.IsOffscreen -and $rect.Width -gt 0 -and $rect.Height -gt 0) `
        -Message "Cannot click offscreen or zero-sized element: $($Element.Current.AutomationId)"
    $x = [int][Math]::Round($rect.Left + ($rect.Width / 2))
    $y = [int][Math]::Round($rect.Top + ($rect.Height / 2))
    [void][NativeMethods]::SetCursorPos($x, $y)
    [NativeMethods]::MouseEvent(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeMethods]::MouseEvent(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
}

function Select-DiscoveryMode {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Mode,
        [string]$ExpectedAutomationId
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return
    }

    $modeTab = Assert-PresentAndVisibleByAutomationId -Root $Window -AutomationId "Skybridge.DeviceDiscovery.Mode.$Mode"
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Invoke-OrClickElement -Element $modeTab

        if ([string]::IsNullOrWhiteSpace($ExpectedAutomationId)) {
            return
        }

        try {
            [void](Assert-PresentAndVisibleByAutomationId -Root $Window -AutomationId $ExpectedAutomationId -TimeoutSeconds 2)
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds (250 * $attempt)
            $modeTab = Assert-PresentAndVisibleByAutomationId -Root $Window -AutomationId "Skybridge.DeviceDiscovery.Mode.$Mode"
        }
    }

    throw "Discovery mode did not reveal expected automation id after click: mode=$Mode expected=$ExpectedAutomationId lastError=$lastError"
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
        [string]$FeatureId,
        [string]$AnchorAutomationId
    )

    $navigation = Get-NavigationItemByFeatureId -Window $Window -FeatureId $FeatureId
    $selectionPattern = $navigation.Item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selectionPattern.Select()
    Start-Sleep -Milliseconds 250
    Set-WorkspaceScrollPercent -Window $Window -VerticalPercent 0

    [void](Assert-SelectedFeature -Window $Window -FeatureId $FeatureId)
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
    [void](Assert-SelectedFeature -Window $Window -FeatureId "Dashboard")
    $navigation = Assert-VisibleByAutomationId -Root $Window -AutomationId "Skybridge.Navigation.List"
    $topBar = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.TopBarActions.Notifications"
    $themeAction = Assert-VisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.TopBarActions.Theme"
    $dashboardAction = Assert-PresentAndVisibleByAutomationId -Root $Window -AutomationId "WorkspaceAction.DashboardQuickActions.ScanDevices"
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

function Get-ActionBoundsSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Surface,
        [string[]]$Keys,
        [string]$Context,
        [int]$MinimumUsableActionWidth,
        [int]$MinimumUsableActionHeight
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Keys.Count; $index++) {
        $key = $Keys[$index]
        $automationId = "WorkspaceAction.$Surface.$key"
        $element = Assert-PresentByAutomationId -Root $Root -AutomationId $automationId -TimeoutSeconds 5
        $rect = $element.Current.BoundingRectangle

        $actions.Add([pscustomobject]@{
            order = $index + 1
            key = $key
            automationId = $automationId
            name = $element.Current.Name
            isEnabled = [bool]$element.Current.IsEnabled
            isOffscreen = [bool]$element.Current.IsOffscreen
            usable = (-not $element.Current.IsOffscreen -and
                $rect.Width -ge $MinimumUsableActionWidth -and
                $rect.Height -ge $MinimumUsableActionHeight)
            bounds = [pscustomobject]@{
                left = [double]$rect.Left
                top = [double]$rect.Top
                width = [double]$rect.Width
                height = [double]$rect.Height
            }
        })
    }

    return @($actions)
}

function Test-ActionBoundsSnapshotUsable {
    param(
        [object[]]$Actions
    )

    foreach ($action in @($Actions)) {
        if (-not $action.usable) {
            return $false
        }
    }

    return $true
}

function Format-ActionBoundsSnapshot {
    param([object[]]$Actions)

    return (@($Actions | ForEach-Object {
                "$($_.automationId) offscreen=$($_.isOffscreen) usable=$($_.usable) bounds=left:$($_.bounds.left),top:$($_.bounds.top),width:$($_.bounds.width),height:$($_.bounds.height)"
            }) -join "; ")
}

function Assert-ActionBoundsSnapshotUsable {
    param(
        [object[]]$Actions,
        [string]$Context,
        [int]$MinimumUsableActionWidth,
        [int]$MinimumUsableActionHeight
    )

    foreach ($action in @($Actions)) {
        Assert-True -Condition ($action.bounds.width -gt 0 -and $action.bounds.height -gt 0) -Message "Runtime action has invalid bounds: $($action.automationId) context=$Context"
        Assert-True `
            -Condition ($action.usable) `
            -Message "Runtime action is clipped, offscreen, or below minimum usable bounds in every stable surface viewport: $($action.automationId) context=$Context isOffscreen=$($action.isOffscreen) width=$($action.bounds.width) height=$($action.bounds.height) minimumWidth=$MinimumUsableActionWidth minimumHeight=$MinimumUsableActionHeight allBounds=$(Format-ActionBoundsSnapshot -Actions $Actions). Split the surface into an explicit SurfaceGroups entry or fix the layout instead of sampling mixed scroll states."
    }
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
        Assert-True -Condition ($keys.Count -gt 0) -Message "Runtime action surface has no keys: $surface"

        $anchorKeys = [System.Collections.Generic.List[string]]::new()
        $anchorKeys.Add($keys[0]) | Out-Null
        if ($keys.Count -gt 1 -and $keys[$keys.Count - 1] -ne $keys[0]) {
            $anchorKeys.Add($keys[$keys.Count - 1]) | Out-Null
        }

        $actions = $null
        $lastActions = $null
        foreach ($anchorKey in $anchorKeys) {
            $anchorAutomationId = "WorkspaceAction.$surface.$anchorKey"
            $anchorElement = Assert-PresentByAutomationId -Root $Root -AutomationId $anchorAutomationId -TimeoutSeconds 5
            if ($anchorElement.Current.IsOffscreen -or
                $anchorElement.Current.BoundingRectangle.Width -lt $minimumUsableActionWidth -or
                $anchorElement.Current.BoundingRectangle.Height -lt $minimumUsableActionHeight) {
                Try-ScrollIntoView -Element $anchorElement
            }

            $candidateActions = @(Get-ActionBoundsSnapshot `
                    -Root $Root `
                    -Surface $surface `
                    -Keys $keys `
                    -Context $Context `
                    -MinimumUsableActionWidth $minimumUsableActionWidth `
                    -MinimumUsableActionHeight $minimumUsableActionHeight)
            $lastActions = $candidateActions
            if (Test-ActionBoundsSnapshotUsable -Actions $candidateActions) {
                $actions = $candidateActions
                break
            }
        }

        if ($null -eq $actions) {
            $actions = $lastActions
        }

        Assert-ActionBoundsSnapshotUsable `
            -Actions $actions `
            -Context $Context `
            -MinimumUsableActionWidth $minimumUsableActionWidth `
            -MinimumUsableActionHeight $minimumUsableActionHeight

        for ($index = 1; $index -lt $actions.Count; $index++) {
            $previous = $actions[$index - 1]
            $current = $actions[$index]
            Assert-True `
                -Condition (Test-ActionBoundsFollow -PreviousBounds $previous.bounds -CurrentBounds $current.bounds) `
                -Message "Runtime action bounds order drifted for $surface in $Context`: $($previous.automationId) bounds=left:$($previous.bounds.left),top:$($previous.bounds.top),width:$($previous.bounds.width),height:$($previous.bounds.height) must precede $($current.automationId) bounds=left:$($current.bounds.left),top:$($current.bounds.top),width:$($current.bounds.width),height:$($current.bounds.height)."
        }

        [pscustomobject]@{
            surface = $surface
            context = $Context
            actionCount = $actions.Count
            actions = @($actions)
        }
    })
}

function Get-FeatureSurfaceGroups {
    param($Feature)

    if ($Feature.ContainsKey("SurfaceGroups")) {
        return @($Feature.SurfaceGroups)
    }

    return @(@{
            Mode = ""
            Surfaces = @($Feature.Surfaces)
        })
}

function Get-FirstRuntimeActionAutomationId {
    param(
        [System.Collections.IDictionary]$ActionOrderBySurface,
        [string[]]$Surfaces
    )

    Assert-True -Condition ($Surfaces.Count -gt 0) -Message "Surface group must contain at least one surface."
    $surface = $Surfaces[0]
    Assert-True -Condition $ActionOrderBySurface.ContainsKey($surface) -Message "Runtime action surface is missing from Action Order Matrix: $surface"
    $keys = @($ActionOrderBySurface[$surface])
    Assert-True -Condition ($keys.Count -gt 0) -Message "Runtime action surface must contain at least one action key: $surface"
    return "WorkspaceAction.$surface.$($keys[0])"
}

function Get-FeatureRuntimeActionSurfaceSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [System.Collections.IDictionary]$ActionOrderBySurface,
        $Feature,
        [string]$ContextSuffix
    )

    $snapshots = [System.Collections.Generic.List[object]]::new()
    foreach ($surfaceGroup in (Get-FeatureSurfaceGroups -Feature $Feature)) {
        if ($surfaceGroup.ContainsKey("ScrollPercent")) {
            Set-WorkspaceScrollPercent -Window $Window -VerticalPercent ([double]$surfaceGroup.ScrollPercent) -Required
        }

        $expectedAutomationId = if ([string]::IsNullOrWhiteSpace($surfaceGroup.Mode)) {
            ""
        }
        else {
            Get-FirstRuntimeActionAutomationId -ActionOrderBySurface $ActionOrderBySurface -Surfaces $surfaceGroup.Surfaces
        }
        Select-DiscoveryMode -Window $Window -Mode $surfaceGroup.Mode -ExpectedAutomationId $expectedAutomationId
        $groupSnapshots = @(Get-RuntimeActionSurfaceSnapshot `
                -Root $Window `
                -ActionOrderBySurface $ActionOrderBySurface `
                -Surfaces $surfaceGroup.Surfaces `
                -Context "$($Feature.Title) $ContextSuffix")
        foreach ($snapshot in $groupSnapshots) {
            $snapshots.Add($snapshot) | Out-Null
        }
    }

    return @($snapshots)
}

function Get-RuntimeActionSurfaceGroupSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [System.Collections.IDictionary]$ActionOrderBySurface,
        $SurfaceGroups,
        [string]$Context
    )

    $snapshots = [System.Collections.Generic.List[object]]::new()
    foreach ($surfaceGroup in @($SurfaceGroups)) {
        if ($surfaceGroup.ContainsKey("ScrollPercent")) {
            Set-WorkspaceScrollPercent -Window $Window -VerticalPercent ([double]$surfaceGroup.ScrollPercent) -Required
        }

        $groupSnapshots = @(Get-RuntimeActionSurfaceSnapshot `
                -Root $Window `
                -ActionOrderBySurface $ActionOrderBySurface `
                -Surfaces $surfaceGroup.Surfaces `
                -Context $Context)
        foreach ($snapshot in $groupSnapshots) {
            $snapshots.Add($snapshot) | Out-Null
        }
    }

    return @($snapshots)
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

    $minimumUsefulPngBytes = 1024
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Activate-TestWindow -Window $Window
        Start-Sleep -Milliseconds (250 * $attempt)
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

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

        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt $minimumUsefulPngBytes) {
            return [pscustomobject]@{
                width = $width
                height = $height
            }
        }
    }

    $actualLength = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).Length } else { 0 }
    throw "Screenshot evidence remained too small after retries: $Path length=$actualLength"
}

$projectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
$projectText = Get-Content -Raw -LiteralPath $projectPath
$project = [xml]$projectText
Assert-UnpackagedDefaultWindowsPackageType -Project $project
$matrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$actionOrderBySurface = Get-ActionOrderMatrix -MatrixPath $matrixPath

& dotnet restore $projectPath | Write-Output
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WinUI automation smoke restore failed."

& dotnet build $projectPath --configuration $Configuration --no-restore /p:TreatWarningsAsErrors=true | Write-Output
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WinUI automation smoke build failed."

$targetFramework = "net10.0-windows10.0.22621.0"
$runtimeIdentifiers = @($project.Project.PropertyGroup |
    ForEach-Object { $_.RuntimeIdentifier } |
    Where-Object { $null -ne $_ } |
    ForEach-Object { $_.InnerText.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-True -Condition ($runtimeIdentifiers.Count -eq 1) -Message "WinUI automation smoke requires exactly one default RuntimeIdentifier; actual=[$($runtimeIdentifiers -join ', ')]"
$exePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/bin/$Configuration/$targetFramework/$($runtimeIdentifiers[0])/Skybridge.WinClient.exe"
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

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", EntryPoint = "mouse_event", SetLastError = true)]
    public static extern void MouseEvent(int dwFlags, int dx, int dy, int dwData, UIntPtr dwExtraInfo);
}
"@

$process = $null
$stdoutTask = $null
$stderrTask = $null
try {
    $features = @(
        @{ Id = "Dashboard"; Title = "Dashboard"; Anchor = "WorkspaceAction.DashboardQuickActions.ScanDevices"; Surfaces = @("DashboardQuickActions") },
        @{
            Id = "DeviceDiscovery"
            Title = "Device Discovery"
            Anchor = "WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt"
            Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal", "CrossNetworkQr", "CrossNetworkCodePrimary", "CrossNetworkCodeConnect")
            SurfaceGroups = @(
                @{ Mode = "LocalScan"; Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal") },
                @{ Mode = "Qr"; Surfaces = @("CrossNetworkQr") },
                @{ Mode = "Code"; Surfaces = @("CrossNetworkCodePrimary", "CrossNetworkCodeConnect") }
            )
        },
        @{ Id = "UsbManagement"; Title = "USB Management"; Anchor = "WorkspaceAction.UsbManagementHeader.RefreshDevices"; Surfaces = @("UsbManagementHeader") },
        @{ Id = "FileTransfer"; Title = "File Transfer"; Anchor = "WorkspaceAction.FileTransfer.GenerateQr"; Surfaces = @("FileTransferHeader", "FileTransfer") },
        @{ Id = "RemoteDesktop"; Title = "Remote Desktop"; Anchor = "WorkspaceAction.RemoteDesktop.RecommendedConnect"; Surfaces = @("RemoteDesktopHeader", "RemoteDesktop") },
        @{ Id = "Quantum"; Title = "Quantum"; Anchor = "WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics"; Surfaces = @("QuantumDiagnosticsHeader") },
        @{ Id = "SystemMonitor"; Title = "System Monitor"; Anchor = "WorkspaceAction.SystemMonitorControls.Monitoring"; Surfaces = @("SystemMonitorHeader", "SystemMonitorControls") },
        @{
            Id = "Settings"
            Title = "Settings"
            Anchor = "WorkspaceAction.SettingsToolbar.ExportSettings"
            Surfaces = @("SettingsHeader", "SettingsToolbar", "SettingsMaintenance")
            SurfaceGroups = @(
                @{ ScrollPercent = 0; Surfaces = @("SettingsHeader", "SettingsToolbar") },
                @{ ScrollPercent = 100; Surfaces = @("SettingsMaintenance") }
            )
        }
    )
    $globalActionSurfaceGroups = @(
        @{ ScrollPercent = 0; Surfaces = @("TopBarActions") },
        @{ ScrollPercent = 100; Surfaces = @("SessionControls") }
    )

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
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
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
        "WorkspaceAction.TopBarActions.Notifications",
        "WorkspaceAction.TopBarActions.Theme"
    )) {
        [void](Assert-VisibleByAutomationId -Root $window -AutomationId $requiredAnchor)
    }
    [void](Assert-SelectedFeature -Window $window -FeatureId "Dashboard")
    [void](Assert-StatusMessageNotEmpty -Window $window)

    Assert-BasicLayout -Window $window -Width 1280 -Height 900
    [void](Get-RuntimeActionSurfaceGroupSnapshot -Window $window -ActionOrderBySurface $actionOrderBySurface -SurfaceGroups $globalActionSurfaceGroups -Context "global 1280x900")
    Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0
    Assert-BasicLayout -Window $window -Width 1366 -Height 768
    [void](Get-RuntimeActionSurfaceGroupSnapshot -Window $window -ActionOrderBySurface $actionOrderBySurface -SurfaceGroups $globalActionSurfaceGroups -Context "global 1366x768")
    Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0

    foreach ($feature in $features) {
        Select-Feature -Window $window -FeatureId $feature.Id -AnchorAutomationId $feature.Anchor
        [void](Get-FeatureRuntimeActionSurfaceSnapshot -Window $window -ActionOrderBySurface $actionOrderBySurface -Feature $feature -ContextSuffix "runtime")
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
            $globalActionBounds = Get-RuntimeActionSurfaceGroupSnapshot -Window $window -ActionOrderBySurface $actionOrderBySurface -SurfaceGroups $globalActionSurfaceGroups -Context "global $($size.Width)x$($size.Height)"
            Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0

            foreach ($feature in $features) {
                Select-Feature -Window $window -FeatureId $feature.Id -AnchorAutomationId $feature.Anchor
                $featureActionBounds = Get-FeatureRuntimeActionSurfaceSnapshot -Window $window -ActionOrderBySurface $actionOrderBySurface -Feature $feature -ContextSuffix "$($size.Width)x$($size.Height)"
                Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0
                [void](Assert-PresentAndVisibleByAutomationId -Root $window -AutomationId $feature.Anchor)
                $fileName = "{0}x{1}-{2}.png" -f $size.Width, $size.Height, (ConvertTo-SafeFileName -Value $feature.Title)
                $screenshotPath = Join-Path $resolvedEvidenceDir $fileName
                $screenshot = Save-WindowScreenshot -Window $window -Path $screenshotPath
                Assert-True -Condition (Test-Path -LiteralPath $screenshotPath) -Message "Missing evidence screenshot: $screenshotPath"

                $anchorIds = @(
                    "Skybridge.Navigation.List",
                    $feature.Id,
                    "WorkspaceAction.TopBarActions.Notifications",
                    "WorkspaceAction.TopBarActions.Theme",
                    $feature.Anchor
                )

                $captures.Add([pscustomobject]@{
                    feature = $feature.Title
                    featureId = $feature.Id
                    heading = $feature.Title
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
            repoBranch = Get-EvidenceBranch
            repoHead = Get-EvidenceHead
            captureCount = $captures.Count
            actionOrderMatrix = "docs/windows-ui-parity-matrix.md#action-order-matrix"
            captures = @($captures)
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message "Missing visual evidence manifest: $manifestPath"
        $visualEvidenceVerifier = Join-Path $RepoRoot "Scripts/verify-windows-ui-visual-evidence.ps1"
        Assert-True -Condition (Test-Path -LiteralPath $visualEvidenceVerifier) -Message "Missing visual evidence verifier: $visualEvidenceVerifier"
        & $visualEvidenceVerifier -RepoRoot $RepoRoot -EvidenceDir $resolvedEvidenceDir | Write-Output
        Write-Output "windows-ui-visual-evidence: ok dir=$resolvedEvidenceDir manifest=$manifestPath captures=$($captures.Count)"
    }

    Select-Feature -Window $window -FeatureId "FileTransfer" -AnchorAutomationId "WorkspaceAction.FileTransfer.GenerateQr"
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
        $stdout = if ($stdoutTask) { $stdoutTask.GetAwaiter().GetResult() } else { "" }
        $stderr = if ($stderrTask) { $stderrTask.GetAwaiter().GetResult() } else { "" }
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
