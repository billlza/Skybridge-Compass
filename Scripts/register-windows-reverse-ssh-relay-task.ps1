param(
    [string]$RepoRoot = "",
    [string]$TaskName = "SkyBridgeReverseSshTunnel",
    [Parameter(Mandatory = $true)]
    [string]$RelayHostName,
    [string]$RelayUserName = "ubuntu",
    [ValidateRange(1, 65535)]
    [int]$RelayPort = 22,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRelayHostKeyFingerprint,
    [string]$IdentityFile = "C:\ProgramData\ssh\skybridge-relay-ed25519",
    [string]$KnownHostsPath = "C:\ProgramData\ssh\skybridge-relay-known_hosts",
    [string]$StartScriptPath = "",
    [string]$InstalledStartScriptPath = "C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1",
    [string]$PowerShellPath = "",
    [string]$SshPath = "ssh",
    [string]$SshKeyscanPath = "ssh-keyscan",
    [string]$SshKeygenPath = "ssh-keygen",
    [string]$RemoteForwardBindAddress = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$RemoteForwardPort = 2222,
    [string]$LocalSshHost = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$LocalSshPort = 22,
    [string]$TaskUserId = "NT AUTHORITY\LOCAL SERVICE",
    [string]$LogPath = "C:\ProgramData\SkyBridge\reverse-ssh-relay\logs\skybridge-relay-tunnel.log",
    [string]$EvidencePath = "",
    [switch]$RepairPrivateKeyAcl,
    [switch]$StartAfterRegister
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-SecurityIdentifierValue {
    param([string]$Account)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Account)) -Message "Account must not be empty."
    if ($Account -match '^S-\d-\d+-.+') {
        return ([System.Security.Principal.SecurityIdentifier]::new($Account)).Value
    }

    return ([System.Security.Principal.NTAccount]::new($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function ConvertTo-SecurityIdentifier {
    param([string]$Account)

    return [System.Security.Principal.SecurityIdentifier]::new((ConvertTo-SecurityIdentifierValue -Account $Account))
}

function New-FileAllowRule {
    param(
        [string]$Account,
        [System.Security.AccessControl.FileSystemRights]$Rights
    )

    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        (ConvertTo-SecurityIdentifier -Account $Account),
        $Rights,
        [System.Security.AccessControl.AccessControlType]::Allow)
}

function New-DirectoryAllowRule {
    param(
        [string]$Account,
        [System.Security.AccessControl.FileSystemRights]$Rights
    )

    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        (ConvertTo-SecurityIdentifier -Account $Account),
        $Rights,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
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

function ConvertTo-NativeArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Join-NativeArguments {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument -Argument $_ }) -join " ")
}

function Invoke-NativeCapture {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $resolvedFileName = Resolve-NativeCommandPath -FileName $FileName
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-native-stdout-" + [Guid]::NewGuid().ToString("N") + ".log")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-native-stderr-" + [Guid]::NewGuid().ToString("N") + ".log")
    $process = $null
    try {
        $process = Start-Process `
            -FilePath $resolvedFileName `
            -ArgumentList (Join-NativeArguments -Arguments $Arguments) `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $killFailure = ""
            try {
                $process.Kill()
            }
            catch {
                $killFailure = $_.Exception.Message
            }

            if (-not [string]::IsNullOrWhiteSpace($killFailure)) {
                throw "Native command timed out after $TimeoutSeconds seconds and could not be terminated: $resolvedFileName $($Arguments -join ' ') killError=$killFailure"
            }

            throw "Native command timed out after $TimeoutSeconds seconds: $resolvedFileName $($Arguments -join ' ')"
        }

        $process.WaitForExit()
        $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
        return [ordered]@{
            exitCode = [int]$process.ExitCode
            text = ($stdoutText + $stderrText)
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
        if (Test-Path -LiteralPath $stdoutPath) {
            Remove-Item -LiteralPath $stdoutPath -Force
        }
        if (Test-Path -LiteralPath $stderrPath) {
            Remove-Item -LiteralPath $stderrPath -Force
        }
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

function Get-HostKeyLineFingerprint {
    param(
        [string]$HostKeyLine,
        [string]$ResolvedSshKeygenPath
    )

    $tempKeyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-relay-host-key-" + [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($tempKeyFile, ($HostKeyLine + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $fingerprintResult = Invoke-NativeCapture -FileName $ResolvedSshKeygenPath -Arguments @("-lf", $tempKeyFile) -TimeoutSeconds 20
        Assert-True -Condition ($fingerprintResult.exitCode -eq 0) -Message "ssh-keygen could not read scanned relay host key record."
        if ($fingerprintResult.text -match 'SHA256:[A-Za-z0-9+/]+={0,2}') {
            return $Matches[0]
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempKeyFile) {
            Remove-Item -LiteralPath $tempKeyFile -Force
        }
    }

    throw "ssh-keygen did not emit a SHA256 fingerprint for scanned relay host key record."
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

function Set-StrictReadableFileAcl {
    param(
        [string]$Path,
        [string]$TaskUserId
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Cannot set ACL for missing file: $Path"
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $acl.AddAccessRule((New-FileAllowRule -Account "NT AUTHORITY\SYSTEM" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-FileAllowRule -Account "BUILTIN\Administrators" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-FileAllowRule -Account $TaskUserId -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-StrictWritableDirectoryAcl {
    param(
        [string]$Path,
        [string]$TaskUserId
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $acl.AddAccessRule((New-DirectoryAllowRule -Account "NT AUTHORITY\SYSTEM" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-DirectoryAllowRule -Account "BUILTIN\Administrators" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-DirectoryAllowRule -Account $TaskUserId -Rights ([System.Security.AccessControl.FileSystemRights]::Modify)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-StrictReadableDirectoryAcl {
    param(
        [string]$Path,
        [string]$TaskUserId
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $acl.AddAccessRule((New-DirectoryAllowRule -Account "NT AUTHORITY\SYSTEM" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-DirectoryAllowRule -Account "BUILTIN\Administrators" -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)))
    $acl.AddAccessRule((New-DirectoryAllowRule -Account $TaskUserId -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-FileSha256 {
    param([string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Cannot hash missing file: $Path"
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

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Path)) -Message "Path must not be empty."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Root)) -Message "Root path must not be empty."
    $fullPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)).TrimEnd('\')
    $fullRoot = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)).TrimEnd('\')
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NotReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "Path must not be a reparse point: $Path"
}

function ConvertTo-TaskArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

Assert-True -Condition (Test-IsAdministrator) -Message "register-windows-reverse-ssh-relay-task.ps1 must run from an elevated PowerShell session."

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($scriptRoot)) -Message "RepoRoot must be supplied when the script path cannot be resolved."
    $RepoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
}
else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

if ([string]::IsNullOrWhiteSpace($StartScriptPath)) {
    $StartScriptPath = Join-Path $RepoRoot "Scripts/start-windows-reverse-ssh-relay.ps1"
}
if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
    $PowerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
}

$normalizedExpectedFingerprint = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $ExpectedRelayHostKeyFingerprint
Assert-True -Condition ($normalizedExpectedFingerprint -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "ExpectedRelayHostKeyFingerprint must be a pinned SHA256 host key fingerprint."
Assert-True -Condition (Test-Path -LiteralPath $StartScriptPath) -Message "StartScriptPath does not exist: $StartScriptPath"
Assert-True -Condition (Test-Path -LiteralPath $PowerShellPath) -Message "PowerShellPath does not exist: $PowerShellPath"
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($InstalledStartScriptPath)) -Message "InstalledStartScriptPath must not be empty."
Assert-True -Condition (Test-TcpConnect -HostName $LocalSshHost -Port $LocalSshPort) -Message "Local SSH endpoint is not reachable: $LocalSshHost`:$LocalSshPort"
$taskUserSid = ConvertTo-SecurityIdentifierValue -Account $TaskUserId
Assert-True -Condition ($taskUserSid -ne "S-1-5-18") -Message "Reverse relay scheduled task must use a least-privilege service account, not SYSTEM."
$allowedKeyReadSids = @("S-1-5-18", "S-1-5-32-544", $taskUserSid)
$managedRelayRoot = Join-Path $env:ProgramData "SkyBridge\reverse-ssh-relay"
$identityFileFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IdentityFile)
$sourceStartScriptFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StartScriptPath)
$installedStartScriptFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstalledStartScriptPath)
$powerShellFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PowerShellPath)
$sshFullPath = Resolve-NativeCommandPath -FileName $SshPath
$sshKeyscanFullPath = Resolve-NativeCommandPath -FileName $SshKeyscanPath
$sshKeygenFullPath = Resolve-NativeCommandPath -FileName $SshKeygenPath
$repoRootFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
Assert-True -Condition (Test-Path -LiteralPath $identityFileFullPath) -Message "IdentityFile does not exist: $identityFileFullPath"
Assert-NotReparsePoint -Path $identityFileFullPath
Assert-NotReparsePoint -Path $sourceStartScriptFullPath
Assert-True -Condition (-not $installedStartScriptFullPath.StartsWith($repoRootFullPath.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) -Message "InstalledStartScriptPath must not live inside RepoRoot; install the task-owned script under ProgramData."
Assert-True -Condition (Test-PathUnderRoot -Path $installedStartScriptFullPath -Root $managedRelayRoot) -Message "InstalledStartScriptPath must live under the managed reverse relay root: $managedRelayRoot"

$keyAcl = Test-PrivateKeyAcl -Path $identityFileFullPath -AllowedReadSids $allowedKeyReadSids -RequiredReadSids @($taskUserSid)
if ((-not [bool]$keyAcl.ok) -and $RepairPrivateKeyAcl) {
    Set-StrictReadableFileAcl -Path $identityFileFullPath -TaskUserId $TaskUserId
    $keyAcl = Test-PrivateKeyAcl -Path $identityFileFullPath -AllowedReadSids $allowedKeyReadSids -RequiredReadSids @($taskUserSid)
}
Assert-True -Condition ([bool]$keyAcl.ok) -Message "IdentityFile ACL is not restricted to SYSTEM, BUILTIN\Administrators, and the task service account $TaskUserId ($taskUserSid): $($keyAcl.violations -join ', ')"

$installedStartScriptDirectory = Split-Path -Parent $installedStartScriptFullPath
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($installedStartScriptDirectory)) -Message "InstalledStartScriptPath must include a directory: $InstalledStartScriptPath"
Assert-NotReparsePoint -Path $managedRelayRoot
Assert-NotReparsePoint -Path $installedStartScriptDirectory
Assert-NotReparsePoint -Path $installedStartScriptFullPath
Set-StrictReadableDirectoryAcl -Path $managedRelayRoot -TaskUserId $TaskUserId
Set-StrictReadableDirectoryAcl -Path $installedStartScriptDirectory -TaskUserId $TaskUserId
Copy-Item -LiteralPath $sourceStartScriptFullPath -Destination $installedStartScriptFullPath -Force
Set-StrictReadableFileAcl -Path $installedStartScriptFullPath -TaskUserId $TaskUserId
$sourceStartScriptSha256 = Get-FileSha256 -Path $sourceStartScriptFullPath
$installedStartScriptSha256 = Get-FileSha256 -Path $installedStartScriptFullPath
Assert-True -Condition ($sourceStartScriptSha256 -eq $installedStartScriptSha256) -Message "Installed reverse relay start script hash does not match repo source script."

$scanResult = Invoke-NativeCapture -FileName $sshKeyscanFullPath -Arguments @("-p", "$RelayPort", "-T", "10", $RelayHostName) -TimeoutSeconds 20
Assert-True -Condition ($scanResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($scanResult.text)) -Message "ssh-keyscan failed for relay $RelayHostName`:$RelayPort."
$hostKeyLines = @(
    $scanResult.text -split "`r?`n" |
        Where-Object { $_ -match '^\S+\s+(ssh|ecdsa|sk)-[A-Za-z0-9@._+-]+' }
)
Assert-True -Condition ($hostKeyLines.Count -gt 0) -Message "ssh-keyscan did not return relay host key records for $RelayHostName`:$RelayPort."
$allFingerprints = [System.Collections.Generic.List[string]]::new()
$pinnedHostKeyLines = [System.Collections.Generic.List[string]]::new()
$pinnedFingerprints = [System.Collections.Generic.List[string]]::new()
foreach ($line in $hostKeyLines) {
    $fingerprint = Get-HostKeyLineFingerprint -HostKeyLine $line -ResolvedSshKeygenPath $sshKeygenFullPath
    $allFingerprints.Add($fingerprint)
    if ($fingerprint -eq $normalizedExpectedFingerprint) {
        $pinnedHostKeyLines.Add($line)
        $pinnedFingerprints.Add($fingerprint)
    }
}
Assert-True -Condition ($pinnedHostKeyLines.Count -gt 0) -Message "Scanned relay host keys did not include expected fingerprint $normalizedExpectedFingerprint."

$knownHostsFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KnownHostsPath)
$knownHostsDirectory = Split-Path -Parent $knownHostsFullPath
if (-not [string]::IsNullOrWhiteSpace($knownHostsDirectory)) {
    Assert-NotReparsePoint -Path $knownHostsDirectory
    New-Item -ItemType Directory -Force -Path $knownHostsDirectory | Out-Null
}
[System.IO.File]::WriteAllText($knownHostsFullPath, (($pinnedHostKeyLines -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
Set-StrictReadableFileAcl -Path $knownHostsFullPath -TaskUserId $TaskUserId

$logFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
$logDirectory = Split-Path -Parent $logFullPath
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($logDirectory)) -Message "LogPath must include a directory: $LogPath"
Assert-True -Condition (Test-PathUnderRoot -Path $logFullPath -Root $managedRelayRoot) -Message "LogPath must live under the managed reverse relay root: $managedRelayRoot"
Assert-True -Condition (-not $installedStartScriptDirectory.Equals($logDirectory, [System.StringComparison]::OrdinalIgnoreCase)) -Message "InstalledStartScriptPath must not share the writable log directory."
Assert-NotReparsePoint -Path $logDirectory
Assert-NotReparsePoint -Path $logFullPath
Set-StrictWritableDirectoryAcl -Path $logDirectory -TaskUserId $TaskUserId

$taskArgumentsList = @(
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
$taskArgumentString = ($taskArgumentsList | ForEach-Object { ConvertTo-TaskArgument -Value $_ }) -join " "
$action = New-ScheduledTaskAction -Execute $powerShellFullPath -Argument $taskArgumentString
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $TaskUserId -LogonType ServiceAccount -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
if ($StartAfterRegister) {
    Start-ScheduledTask -TaskName $TaskName
}

$task = Get-ScheduledTask -TaskName $TaskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
$evidence = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    script = "register-windows-reverse-ssh-relay-task.ps1"
    taskName = $TaskName
    taskState = [string]$task.State
    taskLastTaskResult = [int]$taskInfo.LastTaskResult
    taskActionExecute = [string]$task.Actions[0].Execute
    taskActionArguments = [string]$task.Actions[0].Arguments
    taskPrincipalUserId = [string]$task.Principal.UserId
    taskPrincipalRunLevel = [string]$task.Principal.RunLevel
    taskPrincipalSid = $taskUserSid
    relayHostName = $RelayHostName
    relayUserName = $RelayUserName
    relayPort = $RelayPort
    expectedRelayHostKeyFingerprint = $normalizedExpectedFingerprint
    relayHostKeyFingerprints = @($allFingerprints)
    pinnedRelayHostKeyFingerprints = @($pinnedFingerprints)
    pinnedKnownHostsRecordCount = $pinnedHostKeyLines.Count
    knownHostsPath = $knownHostsFullPath
    identityFile = $identityFileFullPath
    identityFileAclOk = [bool]$keyAcl.ok
    identityFileAclRepaired = [bool]$RepairPrivateKeyAcl
    localSshEndpoint = "$LocalSshHost`:$LocalSshPort"
    remoteForward = ("{0}:{1}:{2}:{3}" -f $RemoteForwardBindAddress, $RemoteForwardPort, $LocalSshHost, $LocalSshPort)
    sourceStartScriptPath = $sourceStartScriptFullPath
    installedStartScriptPath = $installedStartScriptFullPath
    sourceStartScriptSha256 = $sourceStartScriptSha256
    installedStartScriptSha256 = $installedStartScriptSha256
    startScriptInstalledAndCurrent = [bool]($sourceStartScriptSha256 -eq $installedStartScriptSha256)
    managedRelayRoot = $managedRelayRoot
    installedStartScriptUnderManagedRoot = [bool](Test-PathUnderRoot -Path $installedStartScriptFullPath -Root $managedRelayRoot)
    powershellPath = $powerShellFullPath
    sshPath = $sshFullPath
    logPath = $logFullPath
    startAfterRegister = [bool]$StartAfterRegister
    accepted = $true
}
$resolvedEvidencePath = Write-JsonFileAtomic -Value $evidence -Path $EvidencePath
if (-not [string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
    Write-Output "windows-reverse-ssh-relay-register: evidence=$resolvedEvidencePath"
}
Write-Output "windows-reverse-ssh-relay-register: ok task=$TaskName relay=$RelayHostName remoteForward=$($evidence.remoteForward)"
