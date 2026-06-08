param(
    [string]$HostName = "192.168.0.102",
    [int]$Port = 22,
    [string[]]$UserNames = @("Lza", "bill"),
    [string]$KeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$KnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [int]$ConnectTimeoutSeconds = 5,
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Probe {
    param([string]$Message)

    Write-Output "mac-ssh-probe: $Message"
}

function Invoke-SshCommand {
    param([string]$UserName)

    $target = "$UserName@$HostName"
    $output = & ssh `
        -o BatchMode=yes `
        -o PreferredAuthentications=publickey `
        -o PasswordAuthentication=no `
        -o NumberOfPasswordPrompts=0 `
        -o ConnectTimeout=$ConnectTimeoutSeconds `
        -o ConnectionAttempts=1 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=$KnownHostsPath `
        -p $Port `
        -i $KeyPath `
        $target `
        "whoami; hostname; pwd" 2>&1

    $text = ($output -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        UserName = $UserName
        ExitCode = $LASTEXITCODE
        Text = $text
    }
}

if (-not (Test-Path -LiteralPath $KeyPath)) {
    Write-Probe "missing SSH key: $KeyPath"
    if ($RequireReady) {
        exit 2
    }

    exit 0
}

$tcp = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    Write-Probe "tcp not ready: ${HostName}:$Port"
    if ($RequireReady) {
        exit 2
    }

    exit 0
}

Write-Probe "tcp ready: ${HostName}:$Port"

$ready = $false
foreach ($userName in $UserNames) {
    $probe = Invoke-SshCommand -UserName $userName
    if ($probe.ExitCode -eq 0) {
        $ready = $true
        Write-Probe "$($probe.UserName) ready"
        Write-Output $probe.Text
        continue
    }

    if ($probe.Text -match "Permission denied \(publickey\)") {
        Write-Probe "$($probe.UserName) not authorized: add the public key or check the username"
    }
    elseif ($probe.Text -match "timed out during banner exchange") {
        Write-Probe "$($probe.UserName) banner timeout: TCP accepts connections but sshd did not send an SSH banner"
    }
    elseif ($probe.Text -match "Connection timed out") {
        Write-Probe "$($probe.UserName) timeout"
    }
    else {
        Write-Probe "$($probe.UserName) failed: $($probe.Text)"
    }
}

if ($ready) {
    Write-Probe "ready"
    exit 0
}

Write-Probe "not ready"
if ($RequireReady) {
    exit 2
}
