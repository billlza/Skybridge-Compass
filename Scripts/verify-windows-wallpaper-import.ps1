param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir
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


Add-Type @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class WallpaperPickerInput {
 [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SetText(IntPtr h,uint message,IntPtr w,string text);
 [DllImport("user32.dll",EntryPoint="SendMessageW")] public static extern IntPtr Click(IntPtr h,uint message,IntPtr w,IntPtr l);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr ReadText(IntPtr h,uint message,IntPtr capacity,StringBuilder text);
}
'@
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$settingsPath=Join-Path $env:LOCALAPPDATA 'SkyBridge\settings.json'
$original=Get-Content $settingsPath -Raw | ConvertFrom-Json
$originalBackground=if($original.PSObject.Properties.Name -contains 'BackgroundTheme'){$original.BackgroundTheme}else{'weather'}
$originalCustom=if($original.PSObject.Properties.Name -contains 'CustomBackgroundPath'){$original.CustomBackgroundPath}else{$null}
$exe=Join-Path $RepoRoot 'windows\Skybridge.WinClient\bin\Release\net10.0-windows10.0.22621.0\win-x64\Skybridge.WinClient.exe'
$fixture=Join-Path $EvidenceDir 'wallpaper-fixture.png'
$bitmap=[System.Drawing.Bitmap]::new(1024,640)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
try{
    $graphics.Clear([System.Drawing.Color]::FromArgb(13,45,82))
    $brush=[System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(189,116,55))
    try{$graphics.FillRectangle($brush,512,0,512,640)}finally{$brush.Dispose()}
    $bitmap.Save($fixture,[System.Drawing.Imaging.ImageFormat]::Png)
}finally{$graphics.Dispose();$bitmap.Dispose()}
$fixtureHash=(Get-FileHash $fixture -Algorithm SHA256).Hash
$cache=Join-Path $env:LOCALAPPDATA "SkyBridge\wallpapers\$fixtureHash.png"
$cacheExisted=Test-Path $cache
$process=$null;$dialog=$null
function Wait-CustomBackground {
    $deadline=(Get-Date).AddSeconds(15)
    do {
        $button=Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Theme'
        if($button.Current.ItemStatus -eq 'custom'){return}
        Start-Sleep -Milliseconds 200
    }while((Get-Date) -lt $deadline)
    throw 'Custom wallpaper was not received by the renderer.'
}
try {
    $process=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
    $window=Wait-ForMainWindow -Process $process -TimeoutSeconds 60
    Restore-TestWindow -Window $window
    Invoke-OrClickElement (Assert-VisibleByAutomationId -Root $window -AutomationId 'WorkspaceAction.TopBarActions.Theme')
    $choose=Assert-VisibleByAutomationId -Root ([System.Windows.Automation.AutomationElement]::RootElement) -AutomationId 'Skybridge.Background.ChooseImage'
    Invoke-OrClickElement $choose
    $deadline=(Get-Date).AddSeconds(15)
    do{
        $dialogs=$window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'#32770'))
        $matches=@($dialogs|Where-Object{-not $_.Current.IsOffscreen -and $_.Current.Name -match '^(打开|Open)$'})
        if($matches.Count -eq 1){$dialog=$matches[0];break}
        Start-Sleep -Milliseconds 150
    }while((Get-Date) -lt $deadline)
    Assert-True ($null -ne $dialog) 'The native image picker did not open.'
    Activate-TestWindow -Window $dialog
    $editCondition=[System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'1148'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'Edit'))
    $edits=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,$editCondition)
    Assert-True ($edits.Count -eq 1) 'The native picker did not expose one file-name edit.'
    $focused=$edits[0]
    $editHandle=[IntPtr]$focused.Current.NativeWindowHandle
    Assert-True ($editHandle -ne [IntPtr]::Zero) 'The native file-name edit handle is missing.'
    Assert-True ([WallpaperPickerInput]::SetText($editHandle,0x000C,[IntPtr]::Zero,$fixture) -ne [IntPtr]::Zero) 'The file-name edit rejected the selected image path.'
    $typed=[Text.StringBuilder]::new(32768)
    [void][WallpaperPickerInput]::ReadText($editHandle,0x000D,[IntPtr]$typed.Capacity,$typed)
    Assert-True ($typed.ToString() -eq $fixture) 'The native picker input differs from the exact image path.'
    $buttonCondition=[System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'1'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'Button'))
    $buttons=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,$buttonCondition)
    Assert-True ($buttons.Count -eq 1) 'The picker did not expose exactly one native Open button.'
    $open=$buttons[0]
    Assert-True ([WallpaperPickerInput]::IsWindowEnabled([IntPtr]$open.Current.NativeWindowHandle)) 'The native Open button is disabled.'
    [void][WallpaperPickerInput]::Click([IntPtr]$open.Current.NativeWindowHandle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
    Wait-CustomBackground
    $dialog=$null
    Start-Sleep -Seconds 1
    $saved=Get-Content $settingsPath -Raw | ConvertFrom-Json
    Assert-True ($saved.BackgroundTheme -eq 'custom' -and $saved.CustomBackgroundPath -eq $cache) 'The custom image was not persisted as an app-owned wallpaper.'
    Assert-True ((Get-FileHash $cache -Algorithm SHA256).Hash -eq $fixtureHash) 'Imported wallpaper bytes do not match the selected image.'
    Save-WindowScreenshot -Window $window -Path (Join-Path $EvidenceDir 'custom-wallpaper.png') | Out-Null
    Close-TestWindow -Window $window -Process $process
    Move-Item $fixture (Join-Path $EvidenceDir 'wallpaper-original-moved.png')
    $process=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
    $window=Wait-ForMainWindow -Process $process -TimeoutSeconds 60
    Wait-CustomBackground
    Save-WindowScreenshot -Window $window -Path (Join-Path $EvidenceDir 'custom-wallpaper-after-relaunch.png') | Out-Null
    [pscustomobject]@{success=$true;selectedSha256=$fixtureHash;cachedSha256=(Get-FileHash $cache -Algorithm SHA256).Hash;rendererReceivedCustom=$true;retainedAfterOriginalMoved=$true;retainedAfterRelaunch=$true;assemblySha256=(Get-FileHash (Join-Path (Split-Path $exe) 'Skybridge.WinClient.dll') -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content (Join-Path $EvidenceDir 'wallpaper-import.json') -Encoding UTF8
}catch{
    [pscustomobject]@{success=$false;error=$_.Exception.ToString();scriptStack=$_.ScriptStackTrace}|ConvertTo-Json|Set-Content (Join-Path $EvidenceDir 'wallpaper-import-failed.json') -Encoding UTF8
    throw
}finally{
    if($dialog){
        $cancel=Find-ByAutomationId -Root $dialog -AutomationId '2'
        if($cancel -and $cancel.Current.NativeWindowHandle -ne 0){[void][WallpaperPickerInput]::Click([IntPtr]$cancel.Current.NativeWindowHandle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 300}
    }
    if($process -and -not $process.HasExited){Close-TestWindow -Window $window -Process $process}
    if(@(Get-Process Skybridge.WinClient -ErrorAction SilentlyContinue).Count -ne 0){throw 'Another app instance owns settings; preserve it and the wallpaper backup.'}
    # Restore only the two preferences this test changes, after the app has flushed
    # and closed. Preserve every other live setting and the original image choice.
    $current=Get-Content $settingsPath -Raw | ConvertFrom-Json
    $current | Add-Member NoteProperty BackgroundTheme $originalBackground -Force
    $current | Add-Member NoteProperty CustomBackgroundPath $originalCustom -Force
    $temporary=$settingsPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($current|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    Move-Item $temporary $settingsPath -Force
    if(-not $cacheExisted -and (Test-Path $cache) -and $cache -ne $originalCustom){Remove-Item -LiteralPath $cache}
}
