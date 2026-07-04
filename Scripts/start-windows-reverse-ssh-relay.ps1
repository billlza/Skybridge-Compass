param(
    [Parameter(Mandatory = $true)]
    [string]$RelayHostName,
    [string]$RelayUserName = "ubuntu",
    [ValidateRange(1, 65535)]
    [int]$RelayPort = 22,
    [Parameter(Mandatory = $true)]
    [string]$IdentityFile,
    [Parameter(Mandatory = $true)]
    [string]$KnownHostsPath,
    [string]$RemoteForwardBindAddress = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$RemoteForwardPort = 2222,
    [string]$LocalSshHost = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$LocalSshPort = 22,
    [string]$SshPath = "ssh",
    [string]$LogPath = "",
    [ValidateRange(1, 300)]
    [int]$ConnectTimeoutSeconds = 15,
    [ValidateRange(1, 3600)]
    [int]$ServerAliveIntervalSeconds = 30,
    [ValidateRange(1, 60)]
    [int]$ServerAliveCountMax = 3
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

function Write-RelayLog {
    param(
        [string]$Path,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Add-Content -LiteralPath $resolvedPath -Encoding UTF8 -Value ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Message)
}

function Write-RelayEvent {
    param(
        [string]$Path,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Output $Message
        return
    }

    Write-RelayLog -Path $Path -Message $Message
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

Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($RelayHostName)) -Message "RelayHostName must not be empty."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($RelayUserName)) -Message "RelayUserName must not be empty."
Assert-True -Condition (Test-Path -LiteralPath $IdentityFile) -Message "IdentityFile does not exist: $IdentityFile"
Assert-True -Condition (Test-Path -LiteralPath $KnownHostsPath) -Message "KnownHostsPath does not exist: $KnownHostsPath"
Assert-True -Condition (Test-TcpConnect -HostName $LocalSshHost -Port $LocalSshPort) -Message "Local SSH endpoint is not reachable: $LocalSshHost`:$LocalSshPort"

$sshFullPath = Resolve-NativeCommandPath -FileName $SshPath
$remoteForward = "{0}:{1}:{2}:{3}" -f $RemoteForwardBindAddress, $RemoteForwardPort, $LocalSshHost, $LocalSshPort
$target = "{0}@{1}" -f $RelayUserName, $RelayHostName
$sshArguments = @(
    "-N",
    "-T",
    "-F", "none",
    "-p", "$RelayPort",
    "-o", "BatchMode=yes",
    "-o", "PreferredAuthentications=publickey",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "NumberOfPasswordPrompts=0",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=$KnownHostsPath",
    "-o", "UpdateHostKeys=no",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ConnectTimeout=$ConnectTimeoutSeconds",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=$ServerAliveIntervalSeconds",
    "-o", "ServerAliveCountMax=$ServerAliveCountMax",
    "-i", $IdentityFile,
    "-R", $remoteForward,
    $target
)

Write-RelayEvent -Path $LogPath -Message ("starting reverse relay target={0} remoteForward={1} ssh={2}" -f $target, $remoteForward, $sshFullPath)
& $sshFullPath @sshArguments 2>&1 | ForEach-Object {
    Write-RelayEvent -Path $LogPath -Message ([string]$_)
}
$exitCode = [int]$LASTEXITCODE
Write-RelayEvent -Path $LogPath -Message ("reverse relay exited exitCode={0}" -f $exitCode)
exit $exitCode
