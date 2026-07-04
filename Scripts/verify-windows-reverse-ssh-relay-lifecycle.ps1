param(
    [string]$RepoRoot = "",
    [string]$TaskName = "SkyBridgeReverseSshTunnel",
    [string]$RelayHostName = "54.92.79.99",
    [string]$RelayUserName = "ubuntu",
    [ValidateRange(1, 65535)]
    [int]$RelayPort = 22,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRelayHostKeyFingerprint,
    [string]$IdentityFile = "C:\ProgramData\ssh\skybridge-relay-ed25519",
    [string]$KnownHostsPath = "C:\ProgramData\ssh\skybridge-relay-known_hosts",
    [string]$InstalledStartScriptPath = "C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1",
    [string]$PowerShellPath = "",
    [string]$SshPath = "ssh",
    [string]$SshKeygenPath = "ssh-keygen",
    [string]$LogPath = "C:\ProgramData\SkyBridge\reverse-ssh-relay\logs\skybridge-relay-tunnel.log",
    [string]$RemoteForwardBindAddress = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$RemoteForwardPort = 2222,
    [string]$LocalSshHost = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$LocalSshPort = 22,
    [string]$TaskUserId = "NT AUTHORITY\LOCAL SERVICE",
    [string]$EvidencePath = "",
    [switch]$RequireRunning
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

function ConvertTo-NormalizedHostKeyFingerprint {
    param([string]$Fingerprint)

    $trimmed = $Fingerprint.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ""
    }
    if ($trimmed.StartsWith("SHA256:", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "SHA256:" + $trimmed.Substring(7)
    }
    return "SHA256:$trimmed"
}

function ConvertTo-SecurityIdentifierValue {
    param([string]$Account)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Account)) -Message "Account must not be empty."
    if ($Account -match '^S-\d-\d+-.+') {
        return ([System.Security.Principal.SecurityIdentifier]::new($Account)).Value
    }

    return ([System.Security.Principal.NTAccount]::new($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Write-JsonFileAtomic {
    param(
        $Value,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $leaf = Split-Path -Leaf $resolvedPath
    $tempPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $resolvedPath) {
            [System.IO.File]::Replace($tempPath, $resolvedPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        }
        else {
            [System.IO.File]::Move($tempPath, $resolvedPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }

    return $resolvedPath
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Resolve-NativeCommandPath {
    param([string]$FileName)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($FileName)) -Message "Native command path must not be empty."
    if ($FileName -match '[\\/]' -or [System.IO.Path]::IsPathRooted($FileName)) {
        Assert-True -Condition (Test-Path -LiteralPath $FileName) -Message "Native command does not exist: $FileName"
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FileName)
    }

    $command = Get-Command -Name $FileName -CommandType Application -ErrorAction Stop | Select-Object -First 1
    Assert-True -Condition ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) -Message "Native command not found: $FileName"
    return $command.Source
}

function ConvertTo-TaskArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)).TrimEnd('\')
    $fullRoot = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)).TrimEnd('\')
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-TcpConnect {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-KnownHostsFingerprints {
    param(
        [string]$Path,
        [string]$SshKeygenPath = "ssh-keygen"
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "KnownHostsPath does not exist: $Path"
    $resolvedSshKeygenPath = Resolve-NativeCommandPath -FileName $SshKeygenPath
    $text = & $resolvedSshKeygenPath -lf $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        $boundedOutput = (($text | Out-String).Trim())
        if ($boundedOutput.Length -gt 1000) {
            $boundedOutput = $boundedOutput.Substring(0, 1000)
        }
        throw "ssh-keygen failed to inspect KnownHostsPath '$Path': $boundedOutput"
    }

    return @($text | ForEach-Object {
        $match = [regex]::Match([string]$_, 'SHA256:[A-Za-z0-9+/]+={0,2}')
        if ($match.Success) { $match.Value }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-PrivateKeyAcl {
    param(
        [string]$Path,
        [string[]]$AllowedReadSids,
        [string[]]$RequiredReadSids,
        [string[]]$AllowedWriteSids = @("S-1-5-18", "S-1-5-32-544")
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ ok = $false; sddl = ""; violations = @("missing") }
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [ordered]@{ ok = $false; sddl = ""; violations = @("reparsePoint") }
    }

    $acl = Get-Acl -LiteralPath $Path
    $allowedSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($allowedSid in $AllowedReadSids) {
        [void]$allowedSids.Add($allowedSid)
    }
    $allowedWriteSidsSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($allowedWriteSid in $AllowedWriteSids) {
        [void]$allowedWriteSidsSet.Add($allowedWriteSid)
    }
    $broadSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @("S-1-1-0", "S-1-5-11", "S-1-5-32-545")) {
        [void]$broadSids.Add($sid)
    }

    $violations = [System.Collections.Generic.List[string]]::new()
    $readableSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $rights = [System.Security.AccessControl.FileSystemRights]$rule.FileSystemRights
        $canRead = (($rights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0) -or (($rights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) -or (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
        $canWrite = (($rights -band [System.Security.AccessControl.FileSystemRights]::Write) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::WriteData) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::AppendData) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::Delete) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::ChangePermissions) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::TakeOwnership) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
        if ($canRead) {
            [void]$readableSids.Add($sid)
        }
        if ($canRead -and ($broadSids.Contains($sid) -or -not $allowedSids.Contains($sid))) {
            $violations.Add(("{0}:{1}" -f $rule.IdentityReference.Value, $rights))
        }
        if ($canWrite -and -not $allowedWriteSidsSet.Contains($sid)) {
            $violations.Add(("unexpectedWrite:{0}:{1}" -f $rule.IdentityReference.Value, $rights))
        }
    }

    foreach ($requiredSid in $RequiredReadSids) {
        if (-not $readableSids.Contains($requiredSid)) {
            $violations.Add("missingRequiredRead:$requiredSid")
        }
    }

    return [ordered]@{
        ok = $violations.Count -eq 0
        sddl = $acl.Sddl
        violations = @($violations)
    }
}

function Test-TaskDirectoryAcl {
    param(
        [string]$Path,
        [string]$TaskUserSid,
        [bool]$TaskMayWrite
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ ok = $false; sddl = ""; violations = @("missing") }
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [ordered]@{ ok = $false; sddl = ""; violations = @("reparsePoint") }
    }

    $acl = Get-Acl -LiteralPath $Path
    $allowedSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544", $TaskUserSid)) {
        [void]$allowedSids.Add($sid)
    }
    $broadSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @("S-1-1-0", "S-1-5-11", "S-1-5-32-545")) {
        [void]$broadSids.Add($sid)
    }

    $violations = [System.Collections.Generic.List[string]]::new()
    $taskReadable = $false
    $taskWritable = $false
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $rights = [System.Security.AccessControl.FileSystemRights]$rule.FileSystemRights
        $canRead = (($rights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
        $canWrite = (($rights -band [System.Security.AccessControl.FileSystemRights]::Write) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::Delete) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::ChangePermissions) -ne 0) -or
            (($rights -band [System.Security.AccessControl.FileSystemRights]::TakeOwnership) -ne 0)
        if (-not $allowedSids.Contains($sid) -or $broadSids.Contains($sid)) {
            $violations.Add(("unexpectedAce:{0}:{1}" -f $rule.IdentityReference.Value, $rights))
        }
        if ($sid -eq $TaskUserSid) {
            $taskReadable = $taskReadable -or $canRead
            $taskWritable = $taskWritable -or $canWrite
        }
    }

    if (-not $taskReadable) {
        $violations.Add("missingTaskRead:$TaskUserSid")
    }
    if ($TaskMayWrite -and -not $taskWritable) {
        $violations.Add("missingTaskWrite:$TaskUserSid")
    }
    if ((-not $TaskMayWrite) -and $taskWritable) {
        $violations.Add("unexpectedTaskWrite:$TaskUserSid")
    }

    return [ordered]@{
        ok = $violations.Count -eq 0
        sddl = $acl.Sddl
        violations = @($violations)
    }
}

function Get-ProcessOwnerSid {
    param($Process)

    try {
        $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop
        if ([int]$owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
            return [string]$owner.Sid
        }
    }
    catch {
        return ""
    }

    return ""
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($scriptRoot)) -Message "RepoRoot must be supplied when the script path cannot be resolved."
    $RepoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
}
else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
    $PowerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
}

$startScriptPath = Join-Path $RepoRoot "Scripts/start-windows-reverse-ssh-relay.ps1"
Assert-True -Condition (Test-Path -LiteralPath $startScriptPath) -Message "Missing reverse relay start script: $startScriptPath"
$managedRelayRoot = Join-Path $env:ProgramData "SkyBridge\reverse-ssh-relay"
$installedStartScriptFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstalledStartScriptPath)
$identityFileFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IdentityFile)
$knownHostsFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KnownHostsPath)
$logFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
$powerShellFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PowerShellPath)
$sshFullPath = Resolve-NativeCommandPath -FileName $SshPath
$sshKeygenFullPath = Resolve-NativeCommandPath -FileName $SshKeygenPath
Assert-True -Condition (Test-Path -LiteralPath $installedStartScriptFullPath) -Message "Installed reverse relay start script is missing: $installedStartScriptFullPath"
Assert-True -Condition (Test-PathUnderRoot -Path $installedStartScriptFullPath -Root $managedRelayRoot) -Message "Installed reverse relay start script must live under $managedRelayRoot"
Assert-True -Condition (Test-PathUnderRoot -Path $logFullPath -Root $managedRelayRoot) -Message "Reverse relay log must live under $managedRelayRoot"
$startScript = Get-Content -Raw -LiteralPath $startScriptPath
foreach ($requiredStartSignal in @(
    "StrictHostKeyChecking=yes",
    "UserKnownHostsFile=",
    "ExitOnForwardFailure=yes",
    "BatchMode=yes",
    "PasswordAuthentication=no",
    "IdentityAgent=none",
    "NumberOfPasswordPrompts=0"
)) {
    Assert-True -Condition ($startScript.Contains($requiredStartSignal)) -Message "Reverse relay start script missing fail-closed signal: $requiredStartSignal"
}
$sourceStartScriptSha256 = Get-FileSha256 -Path $startScriptPath
$installedStartScriptSha256 = Get-FileSha256 -Path $installedStartScriptFullPath
$startScriptInstalledAndCurrent = -not [string]::IsNullOrWhiteSpace($sourceStartScriptSha256) -and ($sourceStartScriptSha256 -eq $installedStartScriptSha256)

$normalizedExpectedFingerprint = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $ExpectedRelayHostKeyFingerprint
Assert-True -Condition ($normalizedExpectedFingerprint -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "ExpectedRelayHostKeyFingerprint must be a pinned SHA256 host key fingerprint."
$taskUserSid = ConvertTo-SecurityIdentifierValue -Account $TaskUserId
Assert-True -Condition ($taskUserSid -eq "S-1-5-19") -Message "Reverse relay scheduled task must use NT AUTHORITY\LOCAL SERVICE (S-1-5-19), got $TaskUserId ($taskUserSid)."
$allowedKeyReadSids = @("S-1-5-18", "S-1-5-32-544", $taskUserSid)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
$actions = @($task.Actions)
Assert-True -Condition ($actions.Count -eq 1) -Message "Reverse relay task must have exactly one action, found $($actions.Count)."
$action = $actions[0]
$remoteForward = ("{0}:{1}:{2}:{3}" -f $RemoteForwardBindAddress, $RemoteForwardPort, $LocalSshHost, $LocalSshPort)
$knownHostFingerprints = @(Get-KnownHostsFingerprints -Path $knownHostsFullPath -SshKeygenPath $sshKeygenFullPath)
$keyAcl = Test-PrivateKeyAcl -Path $identityFileFullPath -AllowedReadSids $allowedKeyReadSids -RequiredReadSids @($taskUserSid)
$knownHostsAcl = Test-PrivateKeyAcl -Path $knownHostsFullPath -AllowedReadSids $allowedKeyReadSids -RequiredReadSids @($taskUserSid)
$installedStartScriptAcl = Test-PrivateKeyAcl -Path $installedStartScriptFullPath -AllowedReadSids $allowedKeyReadSids -RequiredReadSids @($taskUserSid)
$installedStartScriptDirectory = Split-Path -Parent $installedStartScriptFullPath
$logDirectory = Split-Path -Parent $logFullPath
$managedRelayRootAcl = Test-TaskDirectoryAcl -Path $managedRelayRoot -TaskUserSid $taskUserSid -TaskMayWrite $false
$installedStartScriptDirectoryAcl = Test-TaskDirectoryAcl -Path $installedStartScriptDirectory -TaskUserSid $taskUserSid -TaskMayWrite $false
$logDirectoryAcl = Test-TaskDirectoryAcl -Path $logDirectory -TaskUserSid $taskUserSid -TaskMayWrite $true
$localSshEndpointReachable = Test-TcpConnect -HostName $LocalSshHost -Port $LocalSshPort
$expectedSshProcessSignals = @(
    $RelayHostName,
    $remoteForward,
    "StrictHostKeyChecking=yes",
    "UserKnownHostsFile=$knownHostsFullPath",
    "UpdateHostKeys=no",
    "ExitOnForwardFailure=yes",
    $identityFileFullPath
)
$sshProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $executableMatches = ([string]$_.ExecutablePath).Equals($sshFullPath, [System.StringComparison]::OrdinalIgnoreCase)
            $allSignalsPresent = $true
            foreach ($signal in $expectedSshProcessSignals) {
                $allSignalsPresent = $allSignalsPresent -and $commandLine.Contains($signal)
            }
            $executableMatches -and $allSignalsPresent
        }
)
$sshProcessesWithOwner = @($sshProcesses | ForEach-Object {
    [ordered]@{
        process = $_
        ownerSid = Get-ProcessOwnerSid -Process $_
    }
})
$sshProcessOwnerExpected = ($sshProcessesWithOwner.Count -gt 0) -and (@($sshProcessesWithOwner | Where-Object { $_.ownerSid -ne $taskUserSid }).Count -eq 0)
$taskActionArguments = [string]$action.Arguments
$taskPrincipalSid = ConvertTo-SecurityIdentifierValue -Account ([string]$task.Principal.UserId)
$expectedTaskArgumentsList = @(
    "-NoProfile",
    "-NonInteractive",
    "-File", $installedStartScriptFullPath,
    "-RelayHostName", $RelayHostName,
    "-RelayUserName", $RelayUserName,
    "-RelayPort", "$RelayPort",
    "-IdentityFile", $identityFileFullPath,
    "-KnownHostsPath", $knownHostsFullPath,
    "-RemoteForwardBindAddress", $RemoteForwardBindAddress,
    "-RemoteForwardPort", "$RemoteForwardPort",
    "-LocalSshHost", $LocalSshHost,
    "-LocalSshPort", "$LocalSshPort",
    "-SshPath", $sshFullPath,
    "-LogPath", $logFullPath
)
$expectedTaskArgumentString = ($expectedTaskArgumentsList | ForEach-Object { ConvertTo-TaskArgument -Value $_ }) -join " "
$taskActionExpected = ([string]$action.Execute).Equals($powerShellFullPath, [System.StringComparison]::OrdinalIgnoreCase) -and ($taskActionArguments -eq $expectedTaskArgumentString)
$taskActionFailClosed = $taskActionArguments.Contains("-NonInteractive") -and
    $taskActionArguments.Contains("-NoProfile") -and
    $taskActionArguments.Contains("-File") -and
    (-not ($taskActionArguments -match '(?i)(EncodedCommand|ExecutionPolicy|Unrestricted|Bypass|\s-Command\s|cmd\.exe|wscript|cscript)'))
$taskPrincipalExpected = ($taskPrincipalSid -eq $taskUserSid) -and
    ([string]$task.Principal.RunLevel -eq "Limited")
$relayHostKeyPinnedStrict = ($knownHostFingerprints.Count -eq 1) -and ($knownHostFingerprints[0] -eq $normalizedExpectedFingerprint)
$runtimeAclOk = ([bool]$keyAcl.ok) -and
    ([bool]$knownHostsAcl.ok) -and
    ([bool]$installedStartScriptAcl.ok) -and
    ([bool]$managedRelayRootAcl.ok) -and
    ([bool]$installedStartScriptDirectoryAcl.ok) -and
    ([bool]$logDirectoryAcl.ok)

$accepted = $taskActionExpected -and
    $taskActionFailClosed -and
    $taskPrincipalExpected -and
    $startScriptInstalledAndCurrent -and
    $runtimeAclOk -and
    $localSshEndpointReachable -and
    $relayHostKeyPinnedStrict -and
    ((-not $RequireRunning) -or ([string]$task.State -eq "Running" -and $sshProcesses.Count -eq 1 -and $sshProcessOwnerExpected))

$evidence = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    script = "verify-windows-reverse-ssh-relay-lifecycle.ps1"
    taskName = $TaskName
    taskState = [string]$task.State
    taskLastTaskResult = [int]$taskInfo.LastTaskResult
    taskActionExecute = [string]$action.Execute
    taskActionArguments = $taskActionArguments
    expectedTaskActionExecute = $powerShellFullPath
    expectedTaskActionArguments = $expectedTaskArgumentString
    taskActionExpected = [bool]$taskActionExpected
    taskActionFailClosed = [bool]$taskActionFailClosed
    taskPrincipalUserId = [string]$task.Principal.UserId
    taskPrincipalRunLevel = [string]$task.Principal.RunLevel
    taskPrincipalSid = $taskPrincipalSid
    expectedTaskPrincipalUserId = $TaskUserId
    expectedTaskPrincipalSid = $taskUserSid
    taskPrincipalExpected = [bool]$taskPrincipalExpected
    relayHostName = $RelayHostName
    relayUserName = $RelayUserName
    relayPort = $RelayPort
    expectedRelayHostKeyFingerprint = $normalizedExpectedFingerprint
    knownHostsPath = $knownHostsFullPath
    knownHostFingerprints = @($knownHostFingerprints)
    relayHostKeyPinned = [bool]$relayHostKeyPinnedStrict
    identityFile = $identityFileFullPath
    identityFileAclOk = [bool]$keyAcl.ok
    identityFileAclViolations = @($keyAcl.violations)
    knownHostsAclOk = [bool]$knownHostsAcl.ok
    knownHostsAclViolations = @($knownHostsAcl.violations)
    sourceStartScriptPath = $startScriptPath
    installedStartScriptPath = $installedStartScriptFullPath
    sourceStartScriptSha256 = $sourceStartScriptSha256
    installedStartScriptSha256 = $installedStartScriptSha256
    startScriptInstalledAndCurrent = [bool]$startScriptInstalledAndCurrent
    installedStartScriptAclOk = [bool]$installedStartScriptAcl.ok
    installedStartScriptAclViolations = @($installedStartScriptAcl.violations)
    managedRelayRoot = $managedRelayRoot
    managedRelayRootAclOk = [bool]$managedRelayRootAcl.ok
    managedRelayRootAclViolations = @($managedRelayRootAcl.violations)
    installedStartScriptDirectoryAclOk = [bool]$installedStartScriptDirectoryAcl.ok
    installedStartScriptDirectoryAclViolations = @($installedStartScriptDirectoryAcl.violations)
    logPath = $logFullPath
    logDirectoryAclOk = [bool]$logDirectoryAcl.ok
    logDirectoryAclViolations = @($logDirectoryAcl.violations)
    runtimeAclOk = [bool]$runtimeAclOk
    localSshEndpoint = "$LocalSshHost`:$LocalSshPort"
    localSshEndpointReachable = [bool]$localSshEndpointReachable
    remoteForward = $remoteForward
    sshProcessCount = $sshProcesses.Count
    sshProcessOwnerExpected = [bool]$sshProcessOwnerExpected
    sshPath = $sshFullPath
    sshProcesses = @($sshProcessesWithOwner | ForEach-Object {
        $process = $_.process
        [ordered]@{
            processId = [int]$process.ProcessId
            parentProcessId = [int]$process.ParentProcessId
            ownerSid = [string]$_.ownerSid
            ownerExpected = [bool]([string]$_.ownerSid -eq $taskUserSid)
            executablePathMatchesExpected = [bool](([string]$process.ExecutablePath).Equals($sshFullPath, [System.StringComparison]::OrdinalIgnoreCase))
            executablePathSha256 = if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
                ""
            } else {
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                try {
                    -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$process.ExecutablePath)) | ForEach-Object { $_.ToString("x2") })
                }
                finally {
                    $sha256.Dispose()
                }
            }
            commandLineSha256 = if ([string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
                ""
            } else {
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                try {
                    -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$process.CommandLine)) | ForEach-Object { $_.ToString("x2") })
                }
                finally {
                    $sha256.Dispose()
                }
            }
        }
    })
    requireRunning = [bool]$RequireRunning
    accepted = [bool]$accepted
}

$resolvedEvidencePath = Write-JsonFileAtomic -Value $evidence -Path $EvidencePath
if (-not [string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
    Write-Output "windows-reverse-ssh-relay-lifecycle: evidence=$resolvedEvidencePath"
}

Assert-True -Condition $taskActionExpected -Message "Reverse relay task action does not match expected script and relay parameters."
Assert-True -Condition $taskActionFailClosed -Message "Reverse relay task action must use non-interactive PowerShell without EncodedCommand or ExecutionPolicy Bypass."
Assert-True -Condition $taskPrincipalExpected -Message "Reverse relay task must run as $TaskUserId ($taskUserSid) with least privilege, got user=$($task.Principal.UserId) sid=$taskPrincipalSid runLevel=$($task.Principal.RunLevel)."
Assert-True -Condition $startScriptInstalledAndCurrent -Message "Installed reverse relay start script does not match repo source script: source=$sourceStartScriptSha256 installed=$installedStartScriptSha256"
Assert-True -Condition ([bool]$keyAcl.ok) -Message "IdentityFile ACL is not restricted to SYSTEM, BUILTIN\Administrators, and the task service account $TaskUserId ($taskUserSid): $($keyAcl.violations -join ', ')"
Assert-True -Condition ([bool]$knownHostsAcl.ok) -Message "KnownHostsPath ACL is not restricted to SYSTEM, BUILTIN\Administrators, and the task service account $TaskUserId ($taskUserSid): $($knownHostsAcl.violations -join ', ')"
Assert-True -Condition ([bool]$installedStartScriptAcl.ok) -Message "Installed start script ACL is not restricted to SYSTEM, BUILTIN\Administrators, and the task service account $TaskUserId ($taskUserSid): $($installedStartScriptAcl.violations -join ', ')"
Assert-True -Condition ([bool]$managedRelayRootAcl.ok) -Message "Managed reverse relay root ACL is not restricted: $($managedRelayRootAcl.violations -join ', ')"
Assert-True -Condition ([bool]$installedStartScriptDirectoryAcl.ok) -Message "Installed start script directory ACL is not restricted: $($installedStartScriptDirectoryAcl.violations -join ', ')"
Assert-True -Condition ([bool]$logDirectoryAcl.ok) -Message "Log directory ACL is not restricted to task write and administrator control: $($logDirectoryAcl.violations -join ', ')"
Assert-True -Condition $localSshEndpointReachable -Message "Local SSH endpoint is not reachable: $LocalSshHost`:$LocalSshPort"
Assert-True -Condition $relayHostKeyPinnedStrict -Message "KnownHostsPath must contain only the expected relay host key fingerprint: $normalizedExpectedFingerprint actual=$($knownHostFingerprints -join ',')"
if ($RequireRunning) {
    Assert-True -Condition ([string]$task.State -eq "Running") -Message "Reverse relay task is not running: state=$($task.State)"
    Assert-True -Condition ($sshProcesses.Count -eq 1) -Message "Expected exactly one ssh.exe process containing expected reverse forward and fail-closed signature: $remoteForward count=$($sshProcesses.Count)"
    Assert-True -Condition $sshProcessOwnerExpected -Message "Matching ssh.exe process must run as $TaskUserId ($taskUserSid)."
}

Write-Output "windows-reverse-ssh-relay-lifecycle: ok task=$TaskName state=$($task.State) runningProcesses=$($sshProcesses.Count) remoteForward=$remoteForward"
