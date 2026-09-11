param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [ValidateSet('Debug','Release')][string]$Configuration='Release',
    [string]$ExecutablePath
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms

# Reuse the repository's window, input and screenshot helpers without running
# its build/launch body. This lane exercises popups and actual wallpaper changes.
$smoke=Join-Path $RepoRoot 'Scripts\verify-windows-ui-automation-smoke.ps1'
$parseErrors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($smoke,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'UI helper script did not parse.'}
foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $definition.Extent.Text
}
$nativeBlocks=@($ast.FindAll({param($node) ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $node -is [Management.Automation.Language.StringConstantExpressionAst]) -and $node.Value.Contains('public static class NativeMethods')},$true))
if($nativeBlocks.Count -ne 1){throw 'Expected the repository native window helper.'}
Add-Type -TypeDefinition $nativeBlocks[0].Value
Assert-True ([NativeMethods]::SetThreadDpiAwarenessContext([IntPtr](-4)) -ne [IntPtr]::Zero) "Physical UI verification DPI context is unavailable."

$destination=[IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$exe=Join-Path $RepoRoot "windows\Skybridge.WinClient\bin\$Configuration\net10.0-windows10.0.22621.0\win-x64\Skybridge.WinClient.exe"
if ($ExecutablePath) {$exe=[IO.Path]::GetFullPath($ExecutablePath)}
$process=$null;$window=$null
$changes=[Collections.Generic.List[object]]::new()
$settingsPath=Join-Path $env:LOCALAPPDATA 'SkyBridge\settings.json'
$settings=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$originalMode=if($settings.PSObject.Properties.Name -contains 'AppearanceMode' -and $settings.AppearanceMode){$settings.AppearanceMode}elseif($settings.UseDarkMode){'dark'}else{'light'}
$originalBackground=if($settings.PSObject.Properties.Name -contains 'BackgroundTheme'){$settings.BackgroundTheme}else{'weather'}

function Wait-AppElement([string]$Id) {
    $condition=[System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$process.Id),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$Id))
    $deadline=(Get-Date).AddSeconds(10)
    do {
        $found=[System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
        if($found -and -not $found.Current.IsOffscreen){return $found}
        Start-Sleep -Milliseconds 100
    } while((Get-Date) -lt $deadline)
    throw "App popup control was not visible: $Id"
}

function Choose-AppearanceItem([string]$Id) {
    Activate-TestWindow -Window $window
    Invoke-OrClickElement (Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Theme')
    $item=Wait-AppElement $Id
    Invoke-OrClickElement $item
    Start-Sleep -Milliseconds 800
}

function Assert-Capsules([int]$Width,[int]$Height) {
    Set-TestWindowLogicalSize -Window $window -Width $Width -Height $Height
    Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0
    Start-Sleep -Milliseconds 300
    $heading=Assert-VisibleByAutomationId -Root $window -AutomationId 'Skybridge.SelectedFeature.Title'
    $bell=Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Notifications'
    $rects=@()
    foreach($id in @('Skybridge.TopBar.NetworkSpeed','Skybridge.TopBar.NetworkLatency','Skybridge.TopBar.IpLocation')) {
        $element=Assert-VisibleByAutomationId -Root $window -AutomationId $id
        $bounds=$element.Current.BoundingRectangle
        Assert-True ($bounds.Left -gt $heading.Current.BoundingRectangle.Right -and $bounds.Right -lt $bell.Current.BoundingRectangle.Left) "Status capsule overlaps another column at ${Width}x${Height}: $id"
        foreach($prior in $rects){Assert-True (-not $bounds.IntersectsWith($prior)) "Status text overlaps another capsule at ${Width}x${Height}: $id"}
        $rects+=,$bounds
        $changes.Add([pscustomobject]@{size="${Width}x${Height}";id=$id;text=$element.Current.Name;bounds=@($bounds.X,$bounds.Y,$bounds.Width,$bounds.Height)})
    }
    Save-WindowScreenshot -Window $window -Path (Join-Path $destination "${Width}x${Height}-dashboard-top.png") | Out-Null
}

try {
    $started=Get-Date
    $process=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
    $window=Wait-ForMainWindow -Process $process -TimeoutSeconds 60
    Activate-TestWindow -Window $window
    $readyMs=((Get-Date)-$started).TotalMilliseconds
    Restore-TestWindow -Window $window
    Assert-Capsules 1200 800
    Assert-Capsules 960 720
    Set-TestWindowLogicalSize -Window $window -Width 1200 -Height 800
    Invoke-OrClickElement (Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Notifications')
    $list=Wait-AppElement 'Skybridge.Notifications.List'
    $clear=Wait-AppElement 'Skybridge.Notifications.Clear'
    Save-WindowScreenshot -Window $window -Path (Join-Path $destination 'notification-center.png') | Out-Null
    Invoke-OrClickElement $clear
    $children=$list.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::ListItem))
    Assert-True ($children.Count -eq 0) 'Clear did not empty the real notification list.'
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')

    Invoke-OrClickElement (Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Theme')
    [void](Wait-AppElement 'Skybridge.Appearance.system')
    [void](Wait-AppElement 'Skybridge.Background.ChooseImage')
    Save-WindowScreenshot -Window $window -Path (Join-Path $destination 'appearance-menu.png') | Out-Null
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    foreach($mode in @('system','light','dark')) {
        Choose-AppearanceItem "Skybridge.Appearance.$mode"
        $saved=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Assert-True ($saved.AppearanceMode -eq $mode) "Appearance mode did not persist: $mode"
        Invoke-OrClickElement (Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Theme')
        [void](Wait-AppElement "Skybridge.Appearance.$mode")
        Save-WindowScreenshot -Window $window -Path (Join-Path $destination "appearance-$mode.png") | Out-Null
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    }
    foreach($background in @('aurora','starryNight','weather')) {
        Choose-AppearanceItem "Skybridge.Background.$background"
        $saved=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Assert-True ($saved.BackgroundTheme -eq $background) "Background choice did not persist: $background"
        Set-WorkspaceScrollPercent -Window $window -VerticalPercent 0
        Save-WindowScreenshot -Window $window -Path (Join-Path $destination "background-$background.png") | Out-Null
    }
    Set-WorkspaceScrollPercent -Window $window -VerticalPercent 35
    Save-WindowScreenshot -Window $window -Path (Join-Path $destination 'weather-panel.png') | Out-Null
    [pscustomobject]@{success=$true;exe=$exe;exeSha256=(Get-FileHash $exe -Algorithm SHA256).Hash;windowReadyMs=$readyMs;checks=$changes;utc=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $destination 'shell-interactions.json') -Encoding UTF8
} catch {
    [pscustomobject]@{success=$false;error=$_.Exception.ToString();scriptStack=$_.ScriptStackTrace;checks=$changes} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $destination 'shell-interactions-failed.json') -Encoding UTF8
    throw
} finally {
    if($window -and $process -and -not $process.HasExited) {
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        try {
            Choose-AppearanceItem "Skybridge.Appearance.$originalMode"
            if($originalBackground -ne 'custom'){Choose-AppearanceItem "Skybridge.Background.$originalBackground"}
        } finally {
            Close-TestWindow -Window $window -Process $process
        }
    }
}
