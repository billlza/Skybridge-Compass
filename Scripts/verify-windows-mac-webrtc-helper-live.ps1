param(
    [string]$RepoRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$MacHostName,
    [string]$MacUserName = "bill",
    [int]$MacPort = 22,
    [string]$MacSshKeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$MacKnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [Parameter(Mandatory = $true)]
    [string]$MacExpectedHostKeyFingerprint,
    [string]$WindowsBindAddress = "",
    [string]$MacBindAddress = "",
    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint,
    [string]$ProofOutPath = "",
    [string]$IceServers = "",
    [string]$IceServerCredentialsPath = "",
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 120,
    [switch]$AllowCrossNetworkIce,
    [switch]$IceIncludeAllInterfaces,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Split-Path -Parent $PSCommandPath
    } else {
        $PSScriptRoot
    }
    $RepoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

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

    if ($trimmed.StartsWith("SHA256:", [StringComparison]::OrdinalIgnoreCase)) {
        return "SHA256:" + $trimmed.Substring(7)
    }

    return "SHA256:$trimmed"
}

function ConvertTo-PosixSingleQuoted {
    param([string]$Value)

    if ($Value.Contains("'")) {
        throw "Remote path cannot contain a single quote: $Value"
    }

    return "'$Value'"
}

function ConvertTo-WindowsProcessArgument {
    param([string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount += 1
            continue
        }

        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append('\' * ($backslashCount * 2))
                $backslashCount = 0
            }

            [void]$builder.Append('\"')
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append('\' * $backslashCount)
            $backslashCount = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append('\' * ($backslashCount * 2))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsProcessArguments {
    param([string[]]$Arguments)

    $rendered = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        $rendered.Add((ConvertTo-WindowsProcessArgument -Value $argument))
    }

    return [string]::Join(" ", $rendered)
}

function Get-NetworkPathName {
    if ($AllowCrossNetworkIce) {
        return "cross-nat"
    }

    return "same-lan"
}

function Test-PublicHostCandidateEndpoint {
    param([string]$Endpoint)

    $addressText = $Endpoint
    if ($addressText.StartsWith("[", [StringComparison]::Ordinal) -and $addressText.Contains("]")) {
        $addressText = $addressText.Substring(1, $addressText.IndexOf("]", [StringComparison]::Ordinal) - 1)
    }

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($addressText, [ref]$address)) {
        return $false
    }

    if ([System.Net.IPAddress]::IsLoopback($address)) {
        return $false
    }

    $bytes = $address.GetAddressBytes()
    if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($address.Equals([System.Net.IPAddress]::IPv6Any) -or
            $address.Equals([System.Net.IPAddress]::IPv6Loopback) -or
            $address.IsIPv6LinkLocal -or
            $address.IsIPv6SiteLocal -or
            $address.IsIPv6Multicast) {
            return $false
        }

        $isUniqueLocal = (($bytes[0] -band 0xfe) -eq 0xfc)
        $isGlobalUnicast = (($bytes[0] -band 0xe0) -eq 0x20)
        return (-not $isUniqueLocal) -and $isGlobalUnicast
    }

    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $first = [int]$bytes[0]
    $second = [int]$bytes[1]
    if ($first -eq 0 -or $first -eq 10 -or $first -eq 127 -or
        ($first -eq 100 -and $second -ge 64 -and $second -le 127) -or
        ($first -eq 169 -and $second -eq 254) -or
        ($first -eq 172 -and $second -ge 16 -and $second -le 31) -or
        ($first -eq 192 -and $second -eq 168) -or
        ($first -eq 198 -and ($second -eq 18 -or $second -eq 19)) -or
        $first -ge 224) {
        return $false
    }

    return $true
}

function Test-CrossNetworkSelectedPairEvidence {
    param([string]$SelectedCandidatePair)

    if ($SelectedCandidatePair -match '(?i)(local|remote)=(srflx|relay):') {
        return $true
    }

    $matches = [regex]::Matches($SelectedCandidatePair, '(?i)(?:local|remote)=host:(?<endpoint>\[[^\]]+\]|[^;:]+):\d+')
    foreach ($match in $matches) {
        if (Test-PublicHostCandidateEndpoint -Endpoint $match.Groups["endpoint"].Value) {
            return $true
        }
    }

    return $false
}

function Add-HelperIceArguments {
    param([string[]]$Arguments)

    $result = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($IceServers)) {
        $result += @("--ice-servers", $IceServers)
    }
    if (-not [string]::IsNullOrWhiteSpace($IceServerCredentialsPath)) {
        $result += @("--ice-server-credentials", $IceServerCredentialsPath)
    }
    if ($IceIncludeAllInterfaces -or $AllowCrossNetworkIce) {
        $result += @("--ice-include-all-interfaces", "true")
    }

    $result += @("--network-path", (Get-NetworkPathName))
    return $result
}

function Add-RemoteHelperIceArguments {
    param([string]$CommandText)

    $result = $CommandText
    if (-not [string]::IsNullOrWhiteSpace($IceServers)) {
        $result += " --ice-servers " + (ConvertTo-PosixSingleQuoted -Value $IceServers)
    }
    if (-not [string]::IsNullOrWhiteSpace($script:RemoteIceServerCredentialsPath)) {
        $result += " --ice-server-credentials " + (ConvertTo-PosixSingleQuoted -Value $script:RemoteIceServerCredentialsPath)
    }
    if ($IceIncludeAllInterfaces -or $AllowCrossNetworkIce) {
        $result += " --ice-include-all-interfaces true"
    }

    $result += " --network-path " + (Get-NetworkPathName)
    return $result
}

function Stop-ProcessTreeBestEffort {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process -or $Process.HasExited) {
        return
    }

    $taskkill = Get-Command "taskkill.exe" -ErrorAction SilentlyContinue
    if ($null -ne $taskkill) {
        & $taskkill.Source /PID $Process.Id /T /F | Out-Null
        if ($LASTEXITCODE -eq 0 -or $Process.HasExited) {
            return
        }
    }

    $Process.Kill()
}

function Invoke-Native {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    if ($FileName -in @("ssh", "scp")) {
        & $FileName @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$FileName exited ${exitCode}: $($Arguments -join ' ')"
        }

        return ""
    }

    $output = & $FileName @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)
    if ($exitCode -ne 0) {
        throw "$FileName exited ${exitCode}: $($Arguments -join ' ')`noutput:`n$text"
    }

    return $text
}

function Assert-DotNet10Sdk {
    param(
        [string]$Description,
        [string]$SdkList
    )

    if ($SdkList -notmatch '(?m)^10\.') {
        throw "$Description requires .NET 10 SDK. dotnet --list-sdks output:`n$SdkList"
    }
}

function Start-Native {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $process = Start-Process `
        -FilePath $FileName `
        -ArgumentList (Join-WindowsProcessArguments -Arguments $Arguments) `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -NoNewWindow `
        -PassThru

    return [pscustomobject]@{
        Process = $process
    }
}

function Stop-StartedProcess {
    param($Started)

    if ($null -eq $Started) {
        return
    }

    try {
        if (-not $Started.Process.HasExited) {
            Stop-ProcessTreeBestEffort -Process $Started.Process
            $Started.Process.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        # Best-effort cleanup for remote helper SSH sessions.
    }
    finally {
        if ($Started.PSObject.Properties.Name -contains "StdoutWriter" -and $null -ne $Started.StdoutWriter) {
            $Started.StdoutWriter.Dispose()
        }
        if ($Started.PSObject.Properties.Name -contains "StderrWriter" -and $null -ne $Started.StderrWriter) {
            $Started.StderrWriter.Dispose()
        }
        $Started.Process.Dispose()
    }
}

function Wait-File {
    param(
        [string]$Path,
        [int]$TimeoutSeconds,
        [scriptblock]$OnPoll = { }
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path
            if ($item.Length -gt 0) {
                return
            }
        }

        & $OnPoll
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for file: $Path"
}

function Wait-RemoteFile {
    param(
        [string]$RemotePath,
        [int]$TimeoutSeconds
    )

    $quotedPath = ConvertTo-PosixSingleQuoted -Value $RemotePath
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastErrorMessage = ""
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            Invoke-Native -FileName "ssh" -TimeoutSeconds 10 -Arguments @(
                "-n",
                "-T",
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=$MacKnownHostsPath",
                "-o", "UpdateHostKeys=no",
                "-p", "$MacPort",
                "-i", $MacSshKeyPath,
                "$MacUserName@$MacHostName",
                "test -s $quotedPath") | Out-Null
            return
        }
        catch {
            $lastErrorMessage = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Timed out waiting for remote file: $RemotePath lastError=$lastErrorMessage"
}

function Test-RemoteFile {
    param([string]$RemotePath)

    $quotedPath = ConvertTo-PosixSingleQuoted -Value $RemotePath
    try {
        Invoke-Native -FileName "ssh" -TimeoutSeconds 10 -Arguments @(
            "-n",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "IdentitiesOnly=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=$MacKnownHostsPath",
            "-o", "UpdateHostKeys=no",
            "-p", "$MacPort",
            "-i", $MacSshKeyPath,
            "$MacUserName@$MacHostName",
            "test -s $quotedPath") | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Copy-RemoteFile {
    param(
        [string]$RemotePath,
        [string]$LocalPath
    )

    Invoke-Native -FileName "scp" -TimeoutSeconds 30 -Arguments @(
        "-P", "$MacPort",
        "-i", $MacSshKeyPath,
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "${MacUserName}@${MacHostName}:$RemotePath",
        $LocalPath) | Out-Null
}

function Test-CleanDotNetBuildLog {
    param([string]$Text)

    $hasZeroWarnings = $Text -match '0\s+个警' -or $Text -match '0\s+Warning'
    $hasZeroErrors = $Text -match '0\s+个错' -or $Text -match '0\s+Error'
    return $hasZeroWarnings -and $hasZeroErrors
}

function Wait-MacBuildLog {
    param(
        [string]$RemoteBuildLog,
        [string]$LocalBuildLog,
        [int]$TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastText = ""
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-RemoteFile -RemotePath $RemoteBuildLog) {
            Copy-RemoteFile -RemotePath $RemoteBuildLog -LocalPath $LocalBuildLog
            $lastText = Get-Content -Raw -LiteralPath $LocalBuildLog
            if (Test-CleanDotNetBuildLog -Text $lastText) {
                return $lastText
            }
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for clean Mac WebRTC helper build log. Last log: $lastText"
}

function Assert-KnownHostsFingerprint {
    param(
        [string]$KnownHostsPath,
        [string]$ExpectedFingerprint
    )

    try {
        $listing = Invoke-Native -FileName "ssh-keygen" -TimeoutSeconds 10 -Arguments @(
            "-lf", $KnownHostsPath)
    }
    catch {
        throw "Unable to inspect pinned Mac known_hosts file '$KnownHostsPath': $($_.Exception.Message)"
    }

    if ($listing.IndexOf($ExpectedFingerprint, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Pinned Mac known_hosts file '$KnownHostsPath' does not contain expected host key fingerprint $ExpectedFingerprint. ssh-keygen output:`n$listing"
    }
}

Write-Output "windows-mac-webrtc-helper-live: starting"
Assert-True -Condition (Test-Path -LiteralPath $MacSshKeyPath) -Message "Missing Mac SSH key: $MacSshKeyPath"
Write-Output "windows-mac-webrtc-helper-live: mac-ssh-key-ok"
Assert-True -Condition (Test-Path -LiteralPath $MacKnownHostsPath) -Message "Missing pinned Mac known_hosts file: $MacKnownHostsPath"
Write-Output "windows-mac-webrtc-helper-live: mac-known-hosts-ok"

$normalizedHostKey = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $MacExpectedHostKeyFingerprint
Assert-True -Condition ($normalizedHostKey -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "MacExpectedHostKeyFingerprint must be a pinned SHA256 host key."
Write-Output "windows-mac-webrtc-helper-live: expected-host-key-shape-ok"
Assert-KnownHostsFingerprint -KnownHostsPath $MacKnownHostsPath -ExpectedFingerprint $normalizedHostKey
Write-Output "windows-mac-webrtc-helper-live: known-hosts-fingerprint-ok"

Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) -Message "ExpectedDeviceId must be the explicit paired Mac identity for this live proof."
Assert-True -Condition ($ExpectedFingerprint -match '^[0-9a-f]{64}$') -Message "ExpectedFingerprint must be 64 lowercase hex characters."
Write-Output "windows-mac-webrtc-helper-live: expected-peer-identity-ok"
if ($AllowCrossNetworkIce) {
    Assert-True -Condition ((-not [string]::IsNullOrWhiteSpace($IceServers)) -or (-not [string]::IsNullOrWhiteSpace($IceServerCredentialsPath))) -Message "-AllowCrossNetworkIce requires -IceServers with STUN or -IceServerCredentialsPath with authenticated TURN/STUN JSON; TURN credentials must not be passed on argv."
    if (-not [string]::IsNullOrWhiteSpace($IceServerCredentialsPath)) {
        Assert-True -Condition (Test-Path -LiteralPath $IceServerCredentialsPath) -Message "Missing ICE server credentials JSON: $IceServerCredentialsPath"
    }
    Write-Output "windows-mac-webrtc-helper-live: cross-network-ice-enabled"
}
else {
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($IceServerCredentialsPath)) -Message "-IceServerCredentialsPath is only valid with -AllowCrossNetworkIce."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($WindowsBindAddress)) -Message "Direct-LAN helper proof requires -WindowsBindAddress. Use -AllowCrossNetworkIce -IceServers <stun:...> or -IceServerCredentialsPath <turn-credentials.json> for cross-network WebRTC."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($MacBindAddress)) -Message "Direct-LAN helper proof requires -MacBindAddress. Use -AllowCrossNetworkIce -IceServers <stun:...> or -IceServerCredentialsPath <turn-credentials.json> for cross-network WebRTC."
    Write-Output "windows-mac-webrtc-helper-live: direct-lan-bind-addresses-ok"
}

$helperProject = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/Skybridge.WebRtcHelper.csproj"
$helperSource = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper"
$proofGate = Join-Path $RepoRoot "Scripts/verify-windows-webrtc-proof.ps1"
$rustGate = Join-Path $RepoRoot "Scripts/verify-rust-webrtc-proof-cli.ps1"
foreach ($requiredPath in @($helperProject, $helperSource, $proofGate, $rustGate)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath) -Message "Missing required live WebRTC gate path: $requiredPath"
}
Write-Output "windows-mac-webrtc-helper-live: required-paths-ok"

$windowsRoot = Join-Path $env:TEMP ("skybridge-live-webrtc-" + [Guid]::NewGuid().ToString("N"))
$windowsOffer = Join-Path $windowsRoot "offer.json"
$windowsAnswer = Join-Path $windowsRoot "answer.json"
$windowsProof = Join-Path $windowsRoot "proof.json"
$windowsOfferStdout = Join-Path $windowsRoot "offer.stdout.txt"
$windowsOfferStderr = Join-Path $windowsRoot "offer.stderr.txt"
$macAnswerStdout = Join-Path $windowsRoot "mac-answer.stdout.txt"
$macAnswerStderr = Join-Path $windowsRoot "mac-answer.stderr.txt"
$macBuildLog = Join-Path $windowsRoot "mac-build.log"
New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null
Write-Output "windows-mac-webrtc-helper-live: windows-temp-ok"

$remoteRoot = ""
$script:RemoteIceServerCredentialsPath = ""
$offerProcess = $null
$answerProcess = $null
try {
    Write-Output "windows-mac-webrtc-helper-live: build-windows-helper"
    Assert-DotNet10Sdk -Description "Windows live WebRTC helper gate" -SdkList (Invoke-Native -FileName "dotnet" -TimeoutSeconds 20 -Arguments @("--list-sdks"))
    & dotnet build $helperProject -c Debug | Write-Output
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC helper build failed."

    Write-Output "windows-mac-webrtc-helper-live: prepare-mac-temp"
    $remoteRoot = "/tmp/skybridge-mac-webrtc-helper." + [Guid]::NewGuid().ToString("N")
    $quotedRemoteRoot = ConvertTo-PosixSingleQuoted -Value $remoteRoot
    Invoke-Native -FileName "ssh" -TimeoutSeconds 30 -Arguments @(
        "-n",
        "-T",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "-p", "$MacPort",
        "-i", $MacSshKeyPath,
        "$MacUserName@$MacHostName",
        "rm -rf -- $quotedRemoteRoot; mkdir -p $quotedRemoteRoot") | Out-Null
    Assert-True -Condition ($remoteRoot -match '^/tmp/skybridge-mac-webrtc-helper\.') -Message "Unexpected Mac temp root: $remoteRoot"

    Write-Output "windows-mac-webrtc-helper-live: copy-helper-to-mac"
    Invoke-Native -FileName "scp" -TimeoutSeconds 120 -Arguments @(
        "-r",
        "-P", "$MacPort",
        "-i", $MacSshKeyPath,
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        $helperSource,
        "${MacUserName}@${MacHostName}:$remoteRoot/") | Out-Null

    $remoteHelperSource = "$remoteRoot/Skybridge.WebRtcHelper"
    $remoteHelperDll = "$remoteHelperSource/bin/Debug/net10.0/skybridge-webrtc-helper.dll"
    $remoteLive = "$remoteRoot/live"
    $remoteOffer = "$remoteLive/offer.json"
    $remoteAnswer = "$remoteLive/answer.json"
    $script:RemoteIceServerCredentialsPath = if ([string]::IsNullOrWhiteSpace($IceServerCredentialsPath)) { "" } else { "$remoteLive/ice-server-credentials.json" }
    $remoteBuildLog = "$remoteRoot/build.log"
    $remoteBuildExit = "$remoteRoot/build.exit"
    $remoteBuildPid = "$remoteRoot/build.pid"
    $remoteDotNetPrelude = 'if command -v dotnet >/dev/null 2>&1; then DOTNET="$(command -v dotnet)"; elif [ -x /opt/homebrew/bin/dotnet ]; then DOTNET=/opt/homebrew/bin/dotnet; elif [ -x /usr/local/bin/dotnet ]; then DOTNET=/usr/local/bin/dotnet; else echo "dotnet not found on Mac PATH or standard Homebrew locations" >&2; exit 127; fi'
    $remoteBuildCommand =
        "set -eu; " + $remoteDotNetPrelude +
        "; mkdir -p " + (ConvertTo-PosixSingleQuoted -Value $remoteLive) +
        "; cd " + (ConvertTo-PosixSingleQuoted -Value $remoteHelperSource) +
        "; rm -rf bin obj" +
        "; rm -f " + (ConvertTo-PosixSingleQuoted -Value $remoteBuildLog) + " " + (ConvertTo-PosixSingleQuoted -Value $remoteBuildExit) + " " + (ConvertTo-PosixSingleQuoted -Value $remoteBuildPid) +
        '; ( set +e; echo started > ' + (ConvertTo-PosixSingleQuoted -Value ($remoteBuildExit + ".started")) + '; "$DOTNET" --list-sdks | grep ''^10\.'' >/dev/null && "$DOTNET" build Skybridge.WebRtcHelper.csproj -c Debug --disable-build-servers /p:UseSharedCompilation=false > ' + (ConvertTo-PosixSingleQuoted -Value $remoteBuildLog) + ' 2>&1; status=$?; echo "$status" > ' + (ConvertTo-PosixSingleQuoted -Value $remoteBuildExit) + ' ) </dev/null >/dev/null 2>&1 &'
    $remoteBuildCommand += ' echo $! > ' + (ConvertTo-PosixSingleQuoted -Value $remoteBuildPid)
    Write-Output "windows-mac-webrtc-helper-live: build-mac-helper"
    Invoke-Native -FileName "ssh" -TimeoutSeconds 180 -Arguments @(
        "-n",
        "-T",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "-p", "$MacPort",
        "-i", $MacSshKeyPath,
        "$MacUserName@$MacHostName",
        $remoteBuildCommand) | Write-Output
    $macBuildText = Wait-MacBuildLog -RemoteBuildLog $remoteBuildLog -LocalBuildLog $macBuildLog -TimeoutSeconds 180
    Wait-RemoteFile -RemotePath $remoteHelperDll -TimeoutSeconds 30
    $macBuildText | Write-Output

    if (-not [string]::IsNullOrWhiteSpace($IceServerCredentialsPath)) {
        Write-Output "windows-mac-webrtc-helper-live: copy-ice-server-credentials-to-mac"
        Invoke-Native -FileName "scp" -TimeoutSeconds 30 -Arguments @(
            "-P", "$MacPort",
            "-i", $MacSshKeyPath,
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "IdentitiesOnly=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=$MacKnownHostsPath",
            "-o", "UpdateHostKeys=no",
            $IceServerCredentialsPath,
            "${MacUserName}@${MacHostName}:$script:RemoteIceServerCredentialsPath") | Out-Null
    }

    Write-Output "windows-mac-webrtc-helper-live: start-windows-offer"
    $helperDll = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/Debug/net10.0/skybridge-webrtc-helper.dll"
    $offerArguments = @(
        $helperDll,
        "--mode", "offer",
        "--offer-out", $windowsOffer,
        "--answer-in", $windowsAnswer,
        "--proof-out", $windowsProof,
        "--peer-device-id", $ExpectedDeviceId,
        "--peer-fingerprint", $ExpectedFingerprint)
    if (-not [string]::IsNullOrWhiteSpace($WindowsBindAddress)) {
        $offerArguments += @("--bind-address", $WindowsBindAddress)
    }
    $offerArguments = Add-HelperIceArguments -Arguments $offerArguments
    $offerProcess = Start-Native -FileName "dotnet" -StdoutPath $windowsOfferStdout -StderrPath $windowsOfferStderr -Arguments $offerArguments

    Wait-File -Path $windowsOffer -TimeoutSeconds 20 -OnPoll {
        if ($offerProcess.Process.HasExited) {
            throw "Windows offer helper exited before writing offer. stdout=$(Get-Content -Raw -LiteralPath $windowsOfferStdout -ErrorAction SilentlyContinue) stderr=$(Get-Content -Raw -LiteralPath $windowsOfferStderr -ErrorAction SilentlyContinue)"
        }
    }

    Write-Output "windows-mac-webrtc-helper-live: copy-offer-to-mac"
    Invoke-Native -FileName "scp" -TimeoutSeconds 30 -Arguments @(
        "-P", "$MacPort",
        "-i", $MacSshKeyPath,
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        $windowsOffer,
        "${MacUserName}@${MacHostName}:$remoteOffer") | Out-Null

    $answerCommand =
        "set -eu; " + $remoteDotNetPrelude +
        '; "$DOTNET" ' + (ConvertTo-PosixSingleQuoted -Value $remoteHelperDll) +
        " --mode answer" +
        " --offer-in " + (ConvertTo-PosixSingleQuoted -Value $remoteOffer) +
        " --answer-out " + (ConvertTo-PosixSingleQuoted -Value $remoteAnswer) +
        " --hold-seconds 45"
    if (-not [string]::IsNullOrWhiteSpace($MacBindAddress)) {
        $answerCommand += " --bind-address " + (ConvertTo-PosixSingleQuoted -Value $MacBindAddress)
    }
    $answerCommand = Add-RemoteHelperIceArguments -CommandText $answerCommand
    Write-Output "windows-mac-webrtc-helper-live: start-mac-answer"
    $answerProcess = Start-Native -FileName "ssh" -StdoutPath $macAnswerStdout -StderrPath $macAnswerStderr -Arguments @(
        "-n",
        "-T",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "-p", "$MacPort",
        "-i", $MacSshKeyPath,
        "$MacUserName@$MacHostName",
        $answerCommand)

    Write-Output "windows-mac-webrtc-helper-live: wait-mac-answer"
    Wait-RemoteFile -RemotePath $remoteAnswer -TimeoutSeconds 30
    Invoke-Native -FileName "scp" -TimeoutSeconds 30 -Arguments @(
        "-P", "$MacPort",
        "-i", $MacSshKeyPath,
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "${MacUserName}@${MacHostName}:$remoteAnswer",
        $windowsAnswer) | Out-Null

    Write-Output "windows-mac-webrtc-helper-live: wait-windows-proof"
    if (-not $offerProcess.Process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Windows offer helper timed out. stdout=$(Get-Content -Raw -LiteralPath $windowsOfferStdout -ErrorAction SilentlyContinue) stderr=$(Get-Content -Raw -LiteralPath $windowsOfferStderr -ErrorAction SilentlyContinue)"
    }

    Assert-True -Condition (Test-Path -LiteralPath $windowsProof) -Message "Windows offer helper completed without writing proof: $windowsProof"

    Write-Output "windows-mac-webrtc-helper-live: verify-csharp-proof"
    & $proofGate -RepoRoot $RepoRoot -ProofPath $windowsProof -ExpectedDeviceId $ExpectedDeviceId -ExpectedFingerprint $ExpectedFingerprint -MaxProofAgeMs 600000
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC proof C# gate failed."

    Write-Output "windows-mac-webrtc-helper-live: verify-rust-proof"
    & $rustGate -RepoRoot $RepoRoot -ProofPath $windowsProof -ExpectedDeviceId $ExpectedDeviceId -ExpectedFingerprint $ExpectedFingerprint -MaxProofAgeMs 600000
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Rust WebRTC proof CLI gate failed."

    $proof = Get-Content -Raw -LiteralPath $windowsProof | ConvertFrom-Json
    $endpointEvidence = "$($proof.localEndpoint) $($proof.remoteEndpoint) $($proof.selectedCandidatePair)"
    if ($AllowCrossNetworkIce) {
        $signalEvidence = (Get-Content -Raw -LiteralPath $windowsOffer) + "`n" + (Get-Content -Raw -LiteralPath $windowsAnswer)
        Assert-True -Condition ($endpointEvidence.Contains("path=cross-nat")) -Message "Fresh proof did not record network-path=cross-nat: $endpointEvidence"
        Assert-True -Condition ($signalEvidence -match '\btyp\s+(srflx|relay)\b') -Message "Cross-network proof requires server-reflexive or relay ICE candidates in offer/answer signaling."
        Assert-True -Condition (Test-CrossNetworkSelectedPairEvidence -SelectedCandidatePair $proof.selectedCandidatePair) -Message "Cross-network proof requires the actual nominated selected candidate pair to include srflx, relay, or a public host candidate: $($proof.selectedCandidatePair)"
        Assert-True -Condition ($endpointEvidence.IndexOf("127.0.0.1:0", [StringComparison]::Ordinal) -lt 0) -Message "Fresh proof did not record ICE endpoints: $endpointEvidence"
    }
    else {
        Assert-True -Condition ($endpointEvidence.Contains($WindowsBindAddress)) -Message "Fresh proof does not include expected Windows bind address $WindowsBindAddress`: $endpointEvidence"
        Assert-True -Condition ($endpointEvidence.Contains($MacBindAddress)) -Message "Fresh proof does not include expected Mac bind address $MacBindAddress`: $endpointEvidence"
        Assert-True -Condition ($endpointEvidence.Contains("path=same-lan")) -Message "Fresh proof did not record network-path=same-lan: $endpointEvidence"
        Assert-True -Condition ($endpointEvidence.IndexOf("198.18.", [StringComparison]::Ordinal) -lt 0) -Message "Fresh proof selected a proxy/test-network candidate instead of direct LAN: $endpointEvidence"
    }

    if (-not [string]::IsNullOrWhiteSpace($ProofOutPath)) {
        $resolvedProofOutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProofOutPath)
        $proofOutDirectory = Split-Path -Parent $resolvedProofOutPath
        if (-not [string]::IsNullOrWhiteSpace($proofOutDirectory)) {
            New-Item -ItemType Directory -Force -Path $proofOutDirectory | Out-Null
        }

        Copy-Item -LiteralPath $windowsProof -Destination $resolvedProofOutPath -Force
        Write-Output "windows-mac-webrtc-helper-live: proof-copy=$resolvedProofOutPath"
    }

    Write-Output "windows-mac-webrtc-helper-live: ok"
    Write-Output "windows-mac-webrtc-helper-live: proof=$windowsProof"
    Write-Output "windows-mac-webrtc-helper-live: endpoints=$($proof.localEndpoint)->$($proof.remoteEndpoint)"
    Write-Output "windows-mac-webrtc-helper-live: candidate=$($proof.selectedCandidatePair)"
}
finally {
    Stop-StartedProcess -Started $offerProcess
    Stop-StartedProcess -Started $answerProcess

    if (-not $KeepArtifacts) {
        if (-not [string]::IsNullOrWhiteSpace($remoteRoot)) {
            try {
                $quotedRemoteRoot = ConvertTo-PosixSingleQuoted -Value $remoteRoot
                $quotedRemoteBuildPid = ConvertTo-PosixSingleQuoted -Value ($remoteRoot + "/build.pid")
                $remoteCleanupCommand =
                    'if test -s ' + $quotedRemoteBuildPid +
                    '; then pid=$(cat ' + $quotedRemoteBuildPid +
                    '); case "$pid" in *[!0-9]*|' + "''" + ') ;; *) kill "$pid" 2>/dev/null || true ;; esac; fi; ' +
                    'for pid in $(pgrep -f ' + $quotedRemoteRoot + ' 2>/dev/null || true); do if [ "$pid" != "$$" ]; then kill "$pid" 2>/dev/null || true; fi; done; ' +
                    'rm -rf -- ' +
                    $quotedRemoteRoot
                Invoke-Native -FileName "ssh" -TimeoutSeconds 20 -Arguments @(
                    "-n",
                    "-T",
                    "-o", "BatchMode=yes",
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "IdentitiesOnly=yes",
                    "-o", "PasswordAuthentication=no",
                    "-o", "NumberOfPasswordPrompts=0",
                    "-o", "ConnectTimeout=10",
                    "-o", "ConnectionAttempts=1",
                    "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=$MacKnownHostsPath",
                    "-o", "UpdateHostKeys=no",
                    "-p", "$MacPort",
                    "-i", $MacSshKeyPath,
                    "$MacUserName@$MacHostName",
                    $remoteCleanupCommand) | Out-Null
            }
            catch {
                Write-Output "windows-mac-webrtc-helper-live: cleanup warning: $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $windowsRoot) {
            Remove-Item -LiteralPath $windowsRoot -Recurse -Force
        }
    }
    else {
        Write-Output "windows-mac-webrtc-helper-live: kept-windows-artifacts=$windowsRoot"
        if (-not [string]::IsNullOrWhiteSpace($remoteRoot)) {
            Write-Output "windows-mac-webrtc-helper-live: kept-mac-artifacts=$remoteRoot"
        }
    }
}
