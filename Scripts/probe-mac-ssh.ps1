param(
    [string]$HostName = "192.168.0.102",
    [int]$Port = 22,
    [string[]]$UserNames = @("Lza", "bill"),
    [string]$KeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$KnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [string]$DirectSourceAddress = "",
    [int]$ConnectTimeoutSeconds = 5,
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Probe {
    param([string]$Message)

    Write-Output "mac-ssh-probe: $Message"
}

function Test-IsProxySourceAddress {
    param([string]$Address)

    $Address -match "^(198\.18\.|198\.19\.)"
}

function ConvertTo-IPv4UInt32 {
    param([string]$Address)

    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IsIPv4Address {
    param([string]$Address)

    $parsed = [System.Net.IPAddress]::None
    return [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-IsPrivateIPv4Address {
    param([string]$Address)

    if (-not (Test-IsIPv4Address -Address $Address)) {
        return $false
    }

    return $Address -match "^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"
}

function Test-IsSameIPv4Subnet {
    param(
        [string]$LeftAddress,
        [string]$RightAddress,
        [int]$PrefixLength
    )

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        return $false
    }

    $left = ConvertTo-IPv4UInt32 -Address $LeftAddress
    $right = ConvertTo-IPv4UInt32 -Address $RightAddress
    $mask = if ($PrefixLength -eq 0) { 0u } else { [uint32]::MaxValue -shl (32 - $PrefixLength) }

    return (($left -band $mask) -eq ($right -band $mask))
}

function Get-TcpRemoteAddress {
    param($TcpResult)

    if ($TcpResult.RemoteAddress) {
        return [string]$TcpResult.RemoteAddress
    }

    if (Test-IsIPv4Address -Address $HostName) {
        return $HostName
    }

    return ""
}

function Write-LanRouteDiagnostics {
    param(
        [string]$TargetAddress,
        [string]$SourceAddress
    )

    if (-not (Test-IsIPv4Address -Address $TargetAddress)) {
        return
    }

    $lanAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -notmatch "^(127\.|169\.254\.)" -and
            -not (Test-IsProxySourceAddress -Address $_.IPAddress)
        } |
        Sort-Object InterfaceAlias, IPAddress)

    if ($lanAddresses.Count -eq 0) {
        Write-Probe "lan warning: no non-proxy IPv4 interface was found on Windows"
        return
    }

    $sameSubnet = $false
    foreach ($address in $lanAddresses) {
        $isSameSubnet = Test-IsSameIPv4Subnet `
            -LeftAddress $TargetAddress `
            -RightAddress $address.IPAddress `
            -PrefixLength ([int]$address.PrefixLength)
        if ($isSameSubnet) {
            $sameSubnet = $true
        }

        Write-Probe "lan candidate: source=$($address.IPAddress)/$($address.PrefixLength) interface=$($address.InterfaceAlias) sameSubnet=$isSameSubnet"
    }

    if ((Test-IsPrivateIPv4Address -Address $TargetAddress) -and -not $sameSubnet) {
        Write-Probe "lan warning: target $TargetAddress is private IPv4, but no non-proxy Windows IPv4 interface is in the same subnet; direct same-LAN SSH is unlikely"
    }

    if ((Test-IsProxySourceAddress -Address $SourceAddress) -and -not $sameSubnet) {
        Write-Probe "lan action: bypass or disable the proxy/tunnel route, or put Windows and the Mac on the same LAN before Rust CLI co-debugging"
    }
}

function Invoke-SshCommand {
    param([string]$UserName)

    $target = "$UserName@$HostName"
    $sshArgs = @(
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=$ConnectTimeoutSeconds",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=$KnownHostsPath",
        "-p", "$Port",
        "-i", "$KeyPath")

    if (-not [string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
        $sshArgs += @("-b", $DirectSourceAddress)
    }

    $sshArgs += @($target, "whoami; hostname; pwd")
    $output = & ssh @sshArgs 2>&1

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
if ($tcp.SourceAddress) {
    $sourceAddress = [string]$tcp.SourceAddress
    if ($tcp.SourceAddress.PSObject.Properties.Name -contains "IPAddress") {
        $sourceAddress = [string]$tcp.SourceAddress.IPAddress
    }

    $nextHop = ""
    if ($tcp.NetRoute -and $tcp.NetRoute.NextHop) {
        $nextHop = $tcp.NetRoute.NextHop
    }

    Write-Probe "route: source=$sourceAddress interface=$($tcp.InterfaceAlias) nextHop=$nextHop context=$($tcp.NetworkIsolationContext)"
    $targetAddress = Get-TcpRemoteAddress -TcpResult $tcp
    if ($targetAddress) {
        Write-Probe "target: address=$targetAddress"
        Write-LanRouteDiagnostics -TargetAddress $targetAddress -SourceAddress $sourceAddress
    }

    if (Test-IsProxySourceAddress -Address $sourceAddress) {
        Write-Probe "route warning: source address is in 198.18.0.0/15, which is commonly used by proxy or virtual routing; this is not proof of direct LAN reachability"
    }
}

if (-not [string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
    Write-Probe "direct bind: ssh will use source=$DirectSourceAddress"
}

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
