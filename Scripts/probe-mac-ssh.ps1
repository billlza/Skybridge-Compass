param(
    [string]$HostName = "192.168.0.102",
    [string[]]$AlternateHostNames = @("LzadeMacBook-Pro.local", "bill.local"),
    [int]$Port = 22,
    [string[]]$UserNames = @("bill", "Lza"),
    [string]$KeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$KnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [switch]$RequireKnownHost,
    [string]$ExpectedHostKeyFingerprint = "",
    [string]$ExpectedHostAddress = "",
    [string]$DirectSourceAddress = "",
    [string]$EvidencePath = "",
    [int]$ConnectTimeoutSeconds = 5,
    [switch]$RequireDirectLan,
    [switch]$RequireRustCliSmoke,
    [string]$RemoteRepoRoot = "",
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:CurrentHostName = $HostName
$script:MacSshProbeMessages = [System.Collections.Generic.List[string]]::new()
$script:MacSshProbeReady = $false
$script:MacSshProbeReadyHostName = ""
$script:MacSshProbeReadyUserName = ""
$script:MacSshProbeHostKeyPinned = $false
$script:MacSshProbeHostKeySource = ""
$script:MacSshProbeHostKeyFingerprints = [System.Collections.Generic.List[string]]::new()

function Write-Probe {
    param([string]$Message)

    $line = "mac-ssh-probe: $Message"
    $script:MacSshProbeMessages.Add($line)
    Write-Output $line
}

function ConvertTo-PowerShellSingleQuotedArgument {
    param([string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-ProbeTargetAddressesFromMessages {
    param([string[]]$Messages)

    @($Messages |
        ForEach-Object {
            $match = [regex]::Match([string]$_, "target: address=([^\s]+)")
            if ($match.Success) {
                $match.Groups[1].Value
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
}

function Get-RecommendedDirectSourceAddresses {
    param(
        [object[]]$LanCandidates,
        [string[]]$TargetAddresses
    )

    $recommendations = [System.Collections.Generic.List[object]]::new()
    foreach ($targetAddress in $TargetAddresses) {
        if (-not (Test-IsIPv4Address -Address $targetAddress)) {
            continue
        }

        foreach ($candidate in $LanCandidates) {
            $candidateAddress = [string]$candidate.ipAddress
            $prefixLength = [int]$candidate.prefixLength
            if (Test-IsSameIPv4Subnet -LeftAddress $targetAddress -RightAddress $candidateAddress -PrefixLength $prefixLength) {
                $recommendations.Add([ordered]@{
                    targetAddress = $targetAddress
                    directSourceAddress = $candidateAddress
                    prefixLength = $prefixLength
                    interfaceAlias = [string]$candidate.interfaceAlias
                })
            }
        }
    }

    return @($recommendations | Sort-Object targetAddress, directSourceAddress -Unique)
}

function New-MacRustCliCodbgCommand {
    param([object[]]$RecommendedDirectSources)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("Scripts\prepare-mac-rust-cli-codbg.ps1")
    $parts.Add("-MacHostName")
    $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value $HostName))
    $parts.Add("-MacPort $Port")

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHostAddress)) {
        $parts.Add("-MacExpectedHostAddress")
        $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value $ExpectedHostAddress))
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHostKeyFingerprint)) {
        $parts.Add("-MacExpectedHostKeyFingerprint")
        $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value (ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $ExpectedHostKeyFingerprint)))
    }
    else {
        $parts.Add("-MacExpectedHostKeyFingerprint <SHA256:mac-host-key-fingerprint>")
    }

    if ($RecommendedDirectSources.Count -eq 1) {
        $parts.Add("-MacDirectSourceAddress")
        $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value ([string]$RecommendedDirectSources[0].directSourceAddress)))
    }

    $parts.Add("-ProbeEvidencePath")
    $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value "artifacts\mac-ssh-evidence.json"))
    $parts.Add("-SummaryPath")
    $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value "artifacts\mac-rust-cli-codbg-summary.json"))
    $parts.Add("-RequireDirectLan")

    if ($RequireRustCliSmoke -or -not [string]::IsNullOrWhiteSpace($RemoteRepoRoot)) {
        $parts.Add("-RequireRustCliSmoke")
        if (-not [string]::IsNullOrWhiteSpace($RemoteRepoRoot)) {
            $parts.Add("-MacRemoteRepoRoot")
            $parts.Add((ConvertTo-PowerShellSingleQuotedArgument -Value $RemoteRepoRoot))
        }
        else {
            $parts.Add("-MacRemoteRepoRoot <mac-repo-root>")
        }
    }

    return ($parts -join " ")
}

function New-LanRemediationEvidence {
    param(
        [string[]]$Messages,
        [object[]]$LanCandidates,
        [bool]$ProxyTunnelRouteDetected,
        [bool]$LocalNameProxyResolutionDetected,
        [bool]$SameSubnetLanCandidateDetected,
        [bool]$RouteFirstFailureDetected
    )

    $targetAddresses = @(Get-ProbeTargetAddressesFromMessages -Messages $Messages)
    $recommendedDirectSources = @(Get-RecommendedDirectSourceAddresses -LanCandidates $LanCandidates -TargetAddresses $targetAddresses)
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $recommendedActions = [System.Collections.Generic.List[string]]::new()

    if ($ProxyTunnelRouteDetected) {
        $reasonCodes.Add("proxy-tunnel-route")
        $recommendedActions.Add("Bypass or disable the 198.18.0.0/15 proxy/TUN route for the Mac private address before treating SSH or product interop as ready.")
    }

    if ($LocalNameProxyResolutionDetected) {
        $reasonCodes.Add("local-name-proxy-resolution")
        $recommendedActions.Add("Use the Mac private LAN IPv4 until .local resolves to a private LAN address instead of 198.18.0.0/15.")
    }

    if (-not $SameSubnetLanCandidateDetected) {
        $reasonCodes.Add("no-same-subnet-lan-candidate")
        $recommendedActions.Add("Put Windows and the Mac on the same non-proxy LAN subnet, then rerun the probe with -MacDirectSourceAddress if more than one Windows LAN address exists.")
    }

    if ($RouteFirstFailureDetected) {
        $reasonCodes.Add("route-first-failure")
        $recommendedActions.Add("Fix the direct LAN route or proxy bypass before treating banner timeouts as SSH key, Rust CLI, or product defects.")
    }

    if ($RequireKnownHost -and -not $script:MacSshProbeHostKeyPinned) {
        $reasonCodes.Add("host-key-not-pinned")
        $recommendedActions.Add("Keep -MacExpectedHostKeyFingerprint set; the host key can only be pinned after ssh-keyscan reaches the real Mac endpoint.")
    }

    if (-not $script:MacSshProbeReady) {
        $reasonCodes.Add("ssh-not-ready")
        $recommendedActions.Add("After direct LAN and host-key pinning pass, ensure the Windows Mac debug public key is authorized for the Mac login user.")
    }

    return [ordered]@{
        status = if ($script:MacSshProbeReady -and $SameSubnetLanCandidateDetected -and -not $ProxyTunnelRouteDetected -and $script:MacSshProbeHostKeyPinned) { "ready" } else { "blocked" }
        reasonCodes = @($reasonCodes | Select-Object -Unique)
        targetAddresses = @($targetAddresses)
        recommendedDirectSourceAddresses = @($recommendedDirectSources)
        recommendedActions = @($recommendedActions | Select-Object -Unique)
        nextProbeCommand = New-MacRustCliCodbgCommand -RecommendedDirectSources $recommendedDirectSources
    }
}

function Write-ProbeEvidence {
    if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
        return
    }

    $resolvedEvidencePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidencePath)
    $evidenceDirectory = Split-Path -Parent $resolvedEvidencePath
    if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
        New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    }

    $lanCandidates = @(Get-NonProxyLanIPv4Addresses |
        ForEach-Object {
            [ordered]@{
                ipAddress = [string]$_.IPAddress
                prefixLength = [int]$_.PrefixLength
                interfaceAlias = [string]$_.InterfaceAlias
            }
        })

    $messages = @($script:MacSshProbeMessages)
    $hostCandidates = @($HostName) + @($AlternateHostNames) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    $proxyTunnelRouteDetected = @($messages | Where-Object { $_ -match "route warning: source address is in 198\.18\.0\.0/15" }).Count -gt 0
    $localNameProxyResolutionDetected = @($messages | Where-Object { $_ -match "resolve warning: .* resolved to .* in 198\.18\.0\.0/15" }).Count -gt 0
    $sameSubnetLanCandidateDetected = @($messages | Where-Object { $_ -match "sameSubnet=True" }).Count -gt 0
    $routeFirstFailureDetected = @($messages | Where-Object { $_ -match "route action: fix the direct LAN route or proxy bypass" }).Count -gt 0
    $remediation = New-LanRemediationEvidence `
        -Messages $messages `
        -LanCandidates $lanCandidates `
        -ProxyTunnelRouteDetected $proxyTunnelRouteDetected `
        -LocalNameProxyResolutionDetected $localNameProxyResolutionDetected `
        -SameSubnetLanCandidateDetected $sameSubnetLanCandidateDetected `
        -RouteFirstFailureDetected $routeFirstFailureDetected

    $evidence = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        hostName = $HostName
        alternateHostNames = @($AlternateHostNames)
        hostCandidates = @($hostCandidates)
        port = $Port
        userNames = @($UserNames)
        expectedHostAddress = $ExpectedHostAddress
        directSourceAddress = $DirectSourceAddress
        connectTimeoutSeconds = $ConnectTimeoutSeconds
        requireReady = [bool]$RequireReady
        requireDirectLan = [bool]$RequireDirectLan
        requireRustCliSmoke = [bool]$RequireRustCliSmoke
        requireKnownHost = [bool]$RequireKnownHost
        remoteRepoRoot = $RemoteRepoRoot
        keyPath = $KeyPath
        keyPresent = Test-Path -LiteralPath $KeyPath
        knownHostsPath = $KnownHostsPath
        expectedHostKeyFingerprint = $ExpectedHostKeyFingerprint
        hostKeyPinned = [bool]$script:MacSshProbeHostKeyPinned
        hostKeySource = $script:MacSshProbeHostKeySource
        hostKeyFingerprints = @($script:MacSshProbeHostKeyFingerprints)
        windowsLanCandidates = $lanCandidates
        proxyTunnelRouteDetected = $proxyTunnelRouteDetected
        localNameProxyResolutionDetected = $localNameProxyResolutionDetected
        sameSubnetLanCandidateDetected = $sameSubnetLanCandidateDetected
        routeFirstFailureDetected = $routeFirstFailureDetected
        directLanLikely = [bool]($sameSubnetLanCandidateDetected -and -not $proxyTunnelRouteDetected)
        remediation = $remediation
        ready = [bool]$script:MacSshProbeReady
        readyHostName = $script:MacSshProbeReadyHostName
        readyUserName = $script:MacSshProbeReadyUserName
        messages = @($messages)
    }

    $evidence |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8
    Write-Output "mac-ssh-probe: evidence=$resolvedEvidencePath"
}

function ConvertFrom-CommaSeparatedList {
    param([string[]]$Values)

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($item in ($value -split ",")) {
            $trimmed = $item.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $items.Add($trimmed)
            }
        }
    }

    return @($items | Select-Object -Unique)
}

function ConvertTo-PosixSingleQuoted {
    param([string]$Value)

    if ($Value.Contains("'")) {
        throw "Mac remote path cannot contain a single quote: $Value"
    }

    return "'$Value'"
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

function Get-NonProxyLanIPv4Addresses {
    @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -notmatch "^(127\.|169\.254\.)" -and
            -not (Test-IsProxySourceAddress -Address $_.IPAddress)
        } |
        Sort-Object InterfaceAlias, IPAddress)
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

    if (Test-IsIPv4Address -Address $script:CurrentHostName) {
        return $script:CurrentHostName
    }

    return ""
}

function Get-KnownHostLookupNames {
    $names = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentHostName)) {
        $names.Add($script:CurrentHostName)
        if ($Port -ne 22) {
            $names.Add("[$script:CurrentHostName]:$Port")
        }
    }

    return @($names | Select-Object -Unique)
}

function Test-KnownHostEntryPresent {
    if (-not (Test-Path -LiteralPath $KnownHostsPath)) {
        return $false
    }

    foreach ($lookupName in Get-KnownHostLookupNames) {
        try {
            $output = & ssh-keygen -F $lookupName -f $KnownHostsPath 2>$null
            $exitCode = $LASTEXITCODE
        }
        catch {
            $output = @()
            $exitCode = 255
        }

        if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($output | Out-String))) {
            return $true
        }
    }

    return $false
}

function Get-ScannedHostKeyLines {
    $scanArgs = @(
        "-T", "$ConnectTimeoutSeconds",
        "-p", "$Port",
        "-t", "ed25519,ecdsa,rsa",
        $script:CurrentHostName
    )

    try {
        $scanOutput = & ssh-keyscan @scanArgs 2>&1
    }
    catch {
        $scanOutput = @($_.Exception.Message)
    }

    return @($scanOutput |
        ForEach-Object { [string]$_ } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.StartsWith("#") -and
            ($_ -match "\s(ssh-ed25519|ecdsa-sha2-|ssh-rsa)\s")
        })
}

function Get-HostKeyFingerprints {
    param([string[]]$HostKeyLines)

    if ($HostKeyLines.Count -eq 0) {
        return @()
    }

    $tempKeyFile = Join-Path $env:TEMP ("skybridge-host-keyscan-" + [Guid]::NewGuid().ToString("N"))
    try {
        $HostKeyLines | Set-Content -LiteralPath $tempKeyFile -Encoding ASCII
        try {
            $fingerprintOutput = & ssh-keygen -l -E sha256 -f $tempKeyFile 2>$null
        }
        catch {
            $fingerprintOutput = @()
        }

        return @($fingerprintOutput |
            ForEach-Object {
                $match = [regex]::Match([string]$_, "SHA256:[^\s]+")
                if ($match.Success) {
                    $match.Value
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
    }
    finally {
        if (Test-Path -LiteralPath $tempKeyFile) {
            Remove-Item -LiteralPath $tempKeyFile -Force
        }
    }
}

function Add-HostKeyLinesToKnownHosts {
    param([string[]]$HostKeyLines)

    $knownHostsDirectory = Split-Path -Parent $KnownHostsPath
    if (-not [string]::IsNullOrWhiteSpace($knownHostsDirectory)) {
        New-Item -ItemType Directory -Force -Path $knownHostsDirectory | Out-Null
    }

    if (-not (Test-Path -LiteralPath $KnownHostsPath)) {
        $HostKeyLines | Set-Content -LiteralPath $KnownHostsPath -Encoding ASCII
        return
    }

    $HostKeyLines | Add-Content -LiteralPath $KnownHostsPath -Encoding ASCII
}

function Confirm-HostKeyPin {
    $script:HostProbeHostKeyPinConfirmed = $false
    $expectedFingerprint = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $ExpectedHostKeyFingerprint

    if ([string]::IsNullOrWhiteSpace($expectedFingerprint)) {
        if (Test-KnownHostEntryPresent) {
            $script:MacSshProbeHostKeyPinned = $true
            $script:MacSshProbeHostKeySource = "known-hosts-file"
            $script:HostProbeHostKeyPinConfirmed = $true
            Write-Probe "host-key pinned: known_hosts entry exists for $script:CurrentHostName"
            return
        }

        Write-Probe "host-key required: no known_hosts entry exists for $script:CurrentHostName; pass -ExpectedHostKeyFingerprint or pre-populate -KnownHostsPath"
        return
    }

    $hostKeyLines = @(Get-ScannedHostKeyLines)
    if ($hostKeyLines.Count -eq 0) {
        Write-Probe "host-key required: ssh-keyscan returned no usable host key for $script:CurrentHostName"
        return
    }

    $fingerprints = @(Get-HostKeyFingerprints -HostKeyLines $hostKeyLines)
    foreach ($fingerprint in $fingerprints) {
        if (-not $script:MacSshProbeHostKeyFingerprints.Contains($fingerprint)) {
            $script:MacSshProbeHostKeyFingerprints.Add($fingerprint)
        }

        Write-Probe "host-key scan: $script:CurrentHostName fingerprint=$fingerprint"
    }

    if (-not ($fingerprints -contains $expectedFingerprint)) {
        Write-Probe "host-key required: expected $expectedFingerprint was not found for $script:CurrentHostName"
        return
    }

    Add-HostKeyLinesToKnownHosts -HostKeyLines $hostKeyLines
    $script:MacSshProbeHostKeyPinned = $true
    $script:MacSshProbeHostKeySource = "ssh-keyscan-expected-fingerprint"
    $script:HostProbeHostKeyPinConfirmed = $true
    Write-Probe "host-key pinned: matched expected fingerprint $expectedFingerprint for $script:CurrentHostName"
}

function Write-NameResolutionDiagnostics {
    if (Test-IsIPv4Address -Address $script:CurrentHostName) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHostAddress) -and $script:CurrentHostName -ne $ExpectedHostAddress) {
            Write-Probe "host warning: target $script:CurrentHostName does not match expected Mac address $ExpectedHostAddress"
        }

        return
    }

    try {
        $records = @(Resolve-DnsName -Name $script:CurrentHostName -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            ForEach-Object { [string]$_.IPAddress })
    }
    catch {
        Write-Probe "resolve warning: could not resolve $script:CurrentHostName as an IPv4 host: $($_.Exception.Message)"
        return
    }

    if ($records.Count -eq 0) {
        Write-Probe "resolve warning: $script:CurrentHostName returned no IPv4 A records"
        return
    }

    foreach ($address in $records) {
        Write-Probe "resolve: $script:CurrentHostName -> $address"
        if (Test-IsProxySourceAddress -Address $address) {
            Write-Probe "resolve warning: $script:CurrentHostName resolved to $address in 198.18.0.0/15; prefer the Mac private LAN IPv4 for Rust CLI co-debugging"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHostAddress) -and -not ($records -contains $ExpectedHostAddress)) {
        Write-Probe "resolve warning: expected Mac address $ExpectedHostAddress was not returned for $script:CurrentHostName"
    }
}

function Write-LanRouteDiagnostics {
    param(
        [string]$TargetAddress,
        [string]$SourceAddress
    )

    if (-not (Test-IsIPv4Address -Address $TargetAddress)) {
        return
    }

    $lanAddresses = @(Get-NonProxyLanIPv4Addresses)
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

    $script:HostProbeHasSameSubnetLanCandidate = $sameSubnet
}

function Write-DirectSourceDiagnostics {
    param([string]$TargetAddress)

    if ([string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
        return
    }

    $script:HostProbeDirectSourceIsValid = $false

    if (-not (Test-IsIPv4Address -Address $DirectSourceAddress)) {
        Write-Probe "direct-source warning: $DirectSourceAddress is not an IPv4 address"
        return
    }

    if (Test-IsProxySourceAddress -Address $DirectSourceAddress) {
        Write-Probe "direct-source warning: $DirectSourceAddress is in 198.18.0.0/15; choose a non-proxy Windows LAN IPv4"
        return
    }

    if (-not (Test-IsIPv4Address -Address $TargetAddress)) {
        Write-Probe "direct-source warning: cannot validate $DirectSourceAddress because the target address is not IPv4"
        return
    }

    $matches = @(Get-NonProxyLanIPv4Addresses |
        Where-Object { $_.IPAddress -eq $DirectSourceAddress })

    if ($matches.Count -eq 0) {
        Write-Probe "direct-source warning: $DirectSourceAddress is not assigned to a non-proxy Windows IPv4 interface"
        return
    }

    foreach ($address in $matches) {
        $isSameSubnet = Test-IsSameIPv4Subnet `
            -LeftAddress $TargetAddress `
            -RightAddress $address.IPAddress `
            -PrefixLength ([int]$address.PrefixLength)

        Write-Probe "direct-source candidate: source=$($address.IPAddress)/$($address.PrefixLength) interface=$($address.InterfaceAlias) sameSubnet=$isSameSubnet"
        if ($isSameSubnet) {
            $script:HostProbeDirectSourceIsValid = $true
        }
    }

    if (-not $script:HostProbeDirectSourceIsValid) {
        Write-Probe "direct-source warning: $DirectSourceAddress is not in the same subnet as $TargetAddress"
    }
}

function Invoke-SshCommand {
    param(
        [string]$UserName,
        [string]$Command = "whoami; hostname; pwd"
    )

    $target = "$UserName@$script:CurrentHostName"
    $strictHostKeyChecking = if ($RequireKnownHost -or $script:MacSshProbeHostKeyPinned -or -not [string]::IsNullOrWhiteSpace($ExpectedHostKeyFingerprint)) { "yes" } else { "no" }
    $sshArgs = @(
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=$ConnectTimeoutSeconds",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=$strictHostKeyChecking",
        "-o", "UserKnownHostsFile=$KnownHostsPath",
        "-p", "$Port",
        "-i", "$KeyPath")

    if (-not [string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
        $sshArgs += @("-b", $DirectSourceAddress)
    }

    $sshArgs += @($target, $Command)

    $nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($nativeErrorPreference) {
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
    }

    try {
        $output = & ssh @sshArgs 2>&1
        $sshExitCode = $LASTEXITCODE
    }
    catch {
        $lastNativeExitCode = $LASTEXITCODE
        $sshExitCode = if ($lastNativeExitCode -ne 0) { $lastNativeExitCode } else { 255 }
        $output = @($_.Exception.Message)
    }
    finally {
        if ($nativeErrorPreference) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $nativeErrorPreference.Value -Scope Local
        }
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        UserName = $UserName
        ExitCode = $sshExitCode
        Text = $text
    }
}

function Invoke-MacRustCliSmoke {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace($RemoteRepoRoot)) {
        throw "Mac Rust CLI smoke requires -RemoteRepoRoot with the Skybridge-Compass path on the Mac."
    }

    $remoteRepo = ConvertTo-PosixSingleQuoted -Value $RemoteRepoRoot
    $command = "set -eu; cd $remoteRepo; cargo test --manifest-path core/skybridge-core/Cargo.toml --test cli_smoke cli_apple_to_apple_selects_apple_native -- --exact"
    $probe = Invoke-SshCommand -UserName $UserName -Command $command
    if ($probe.ExitCode -ne 0) {
        throw "Mac Rust CLI smoke failed for $UserName@$script:CurrentHostName`: $($probe.Text)"
    }

    Write-Probe "$UserName rust cli smoke ready: cli_apple_to_apple_selects_apple_native"
    Write-Output $probe.Text
}

function Test-IsReadyProbeResult {
    param($Probe)

    if ($Probe.ExitCode -ne 0) {
        return $false
    }

    if ($Probe.Text -match "Connection closed by") {
        return $false
    }

    $lines = @($Probe.Text -split "\r?\n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return ($lines -contains $Probe.UserName) -and ($lines.Count -ge 3)
}

function Write-RouteFirstActionIfNeeded {
    param([string]$UserName)

    if ($script:HostProbeUsesProxySourceRoute -or -not $script:HostProbeHasSameSubnetLanCandidate) {
        Write-Probe "$UserName route action: fix the direct LAN route or proxy bypass before treating this as an SSH key, Rust CLI, or product defect"
    }
}

function Invoke-HostReadinessProbe {
    param([string]$CandidateHostName)

    $script:CurrentHostName = $CandidateHostName
    $script:HostProbeReady = $false
    $script:HostProbeUserName = ""
    $script:HostProbeHostName = $script:CurrentHostName
    $script:HostProbeHasSameSubnetLanCandidate = $false
    $script:HostProbeUsesProxySourceRoute = $false
    $script:HostProbeDirectSourceIsValid = [string]::IsNullOrWhiteSpace($DirectSourceAddress)
    $script:HostProbeHostKeyPinConfirmed = $false

    Write-Probe "candidate: host=$script:CurrentHostName port=$Port"
    Write-NameResolutionDiagnostics

    $tcp = Test-NetConnection -ComputerName $script:CurrentHostName -Port $Port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Probe "tcp not ready: ${script:CurrentHostName}:$Port"
        Write-Probe "tcp readiness failure: Mac SSH TCP endpoint is not ready for $script:CurrentHostName"
        return
    }

    Write-Probe "tcp ready: ${script:CurrentHostName}:$Port"
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
            Write-DirectSourceDiagnostics -TargetAddress $targetAddress
        }

        if (Test-IsProxySourceAddress -Address $sourceAddress) {
            $script:HostProbeUsesProxySourceRoute = $true
            Write-Probe "route warning: source address is in 198.18.0.0/15, which is commonly used by proxy or virtual routing; this is not proof of direct LAN reachability"
        }
    }

    if ($RequireDirectLan) {
        if (-not $script:HostProbeHasSameSubnetLanCandidate) {
            Write-Probe "direct-lan required: no non-proxy Windows IPv4 interface is in the same subnet as $script:CurrentHostName"
            return
        }

        if ($script:HostProbeUsesProxySourceRoute -and [string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
            Write-Probe "direct-lan required: current route uses a 198.18.0.0/15 proxy source; pass -DirectSourceAddress with the same-subnet Windows LAN IPv4 after bypassing the proxy route"
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($DirectSourceAddress) -and -not $script:HostProbeDirectSourceIsValid) {
            Write-Probe "direct-lan required: direct source address is not a validated same-subnet Windows LAN IPv4"
            return
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DirectSourceAddress)) {
        Write-Probe "direct bind: ssh will use source=$DirectSourceAddress"
    }

    if ($RequireKnownHost -or -not [string]::IsNullOrWhiteSpace($ExpectedHostKeyFingerprint)) {
        Confirm-HostKeyPin
        if (-not $script:HostProbeHostKeyPinConfirmed) {
            return
        }
    }

    $readyUserName = ""
    foreach ($userName in $UserNames) {
        $probe = Invoke-SshCommand -UserName $userName
        if (Test-IsReadyProbeResult -Probe $probe) {
            if ([string]::IsNullOrWhiteSpace($readyUserName)) {
                $readyUserName = $probe.UserName
            }

            Write-Probe "$($probe.UserName) ready"
            Write-Output $probe.Text
            continue
        }

        if ($probe.Text -match "Permission denied \(publickey\)") {
            Write-Probe "$($probe.UserName) not authorized: add the public key or check the username"
        }
        elseif ($probe.Text -match "timed out during banner exchange") {
            Write-Probe "$($probe.UserName) banner timeout: TCP accepts connections but sshd did not send an SSH banner"
            Write-RouteFirstActionIfNeeded -UserName $probe.UserName
        }
        elseif ($probe.Text -match "Connection closed by") {
            Write-Probe "$($probe.UserName) connection closed: $($probe.Text)"
            Write-RouteFirstActionIfNeeded -UserName $probe.UserName
        }
        elseif ($probe.Text -match "Host key verification failed") {
            Write-Probe "$($probe.UserName) host-key failed: known_hosts does not match $script:CurrentHostName"
        }
        elseif ($probe.ExitCode -eq 0) {
            Write-Probe "$($probe.UserName) failed readiness transcript: $($probe.Text)"
        }
        elseif ($probe.Text -match "Connection timed out") {
            Write-Probe "$($probe.UserName) timeout"
        }
        else {
            Write-Probe "$($probe.UserName) failed: $($probe.Text)"
        }
    }

    $script:HostProbeReady = -not [string]::IsNullOrWhiteSpace($readyUserName)
    $script:HostProbeUserName = $readyUserName
    $script:HostProbeHostName = $script:CurrentHostName
}

$AlternateHostNames = @(ConvertFrom-CommaSeparatedList -Values $AlternateHostNames)
$UserNames = @(ConvertFrom-CommaSeparatedList -Values $UserNames)

if ($UserNames.Count -eq 0) {
    throw "Mac SSH probe requires at least one username."
}

if (-not (Test-Path -LiteralPath $KeyPath)) {
    Write-Probe "missing SSH key: $KeyPath"
    Write-ProbeEvidence
    if ($RequireReady) {
        throw "Mac SSH probe missing SSH key: $KeyPath"
    }

    return
}

$hostCandidates = @($HostName) + @($AlternateHostNames) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique

foreach ($candidateHostName in $hostCandidates) {
    Invoke-HostReadinessProbe -CandidateHostName $candidateHostName
    if (-not $script:HostProbeReady) {
        continue
    }

    $script:CurrentHostName = $script:HostProbeHostName
    if ($RequireRustCliSmoke) {
        Invoke-MacRustCliSmoke -UserName $script:HostProbeUserName
    }

    $script:MacSshProbeReady = $true
    $script:MacSshProbeReadyHostName = $script:HostProbeHostName
    $script:MacSshProbeReadyUserName = $script:HostProbeUserName
    Write-Probe "ready"
    Write-ProbeEvidence
    return
}

Write-Probe "not ready"
Write-ProbeEvidence
if ($RequireReady -or $RequireRustCliSmoke -or $RequireDirectLan -or $RequireKnownHost -or -not [string]::IsNullOrWhiteSpace($ExpectedHostKeyFingerprint)) {
    throw "Mac SSH probe is not ready"
}
