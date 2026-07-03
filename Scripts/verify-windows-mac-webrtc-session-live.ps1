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
    [Parameter(Mandatory = $true)]
    [string]$WindowsBindAddress,
    [Parameter(Mandatory = $true)]
    [string]$MacBindAddress,
    [ValidateRange(1, 64)]
    [int]$SessionMessageCount = 8,
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 180,
    [switch]$UseWindowsProductRuntime,
    [switch]$UseProductControlProfile,
    [string]$ProductSmokePeerDeviceId = "mac-helper-runtime-smoke",
    [string]$ProductSmokePeerFingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
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

if ($UseWindowsProductRuntime -and $UseProductControlProfile) {
    throw "-UseWindowsProductRuntime and -UseProductControlProfile are mutually exclusive; choose one explicit profile."
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

function Protect-CurrentUserDirectory {
    param([string]$Path)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Path)) -Message "Private directory path must not be empty."
    Assert-True -Condition ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) -Message "This live session gate must run on Windows."

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $currentUser,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetAccessRule($accessRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
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

function ConvertTo-PowerShellSingleQuoted {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Join-WindowsProcessArguments {
    param([string[]]$Arguments)

    $rendered = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        $rendered.Add((ConvertTo-WindowsProcessArgument -Value $argument))
    }

    return [string]::Join(" ", $rendered)
}

function Redact-SensitiveText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $redacted = [regex]::Replace(
        $Text,
        '\b([A-Z0-9_]*(?:TOKEN|SECRET|PRIVATE_KEY|BEARER|PASSWORD|CONNECTION_CODE)[A-Z0-9_]*\s*[:=]\s*)[^\s,;]+',
        '$1<redacted>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $redacted = [regex]::Replace(
        $redacted,
        '\b(Authorization\s*:\s*Bearer\s+)[^\s,;]+',
        '$1<redacted>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return [regex]::Replace(
        $redacted,
        '([?&](?:token|authToken|sessionToken|bearer|code|connectionCode)=)[^&\s]+',
        '$1<redacted>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-FileTextBestEffort {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path) {
            return Redact-SensitiveText -Text (Get-Content -Raw -LiteralPath $Path)
        }
    }
    catch {
        return "[failed to read '$Path': $(Redact-SensitiveText -Text $_.Exception.Message)]"
    }

    return ""
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
        throw "$FileName exited ${exitCode}: $($Arguments -join ' ')`noutput:`n$(Redact-SensitiveText -Text $text)"
    }

    return Redact-SensitiveText -Text $text
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
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
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
        Write-Output "windows-mac-webrtc-session-live: cleanup warning: $($_.Exception.Message)"
    }
    finally {
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

function Wait-FileInteger {
    param(
        [string]$Path,
        [int]$TimeoutSeconds,
        [scriptblock]$OnPoll = { }
    )

    Wait-File -Path $Path -TimeoutSeconds $TimeoutSeconds -OnPoll $OnPoll
    $raw = (Get-Content -Raw -LiteralPath $Path).Trim()
    $port = 0
    Assert-True -Condition ([int]::TryParse($raw, [ref]$port) -and $port -ge 1 -and $port -le 65535) -Message "Invalid TCP port in $Path`: '$raw'"
    return $port
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

function Assert-CleanDotNetBuildLog {
    param(
        [string]$Description,
        [string]$Text
    )

    if (-not (Test-CleanDotNetBuildLog -Text $Text)) {
        throw "$Description did not report 0 warnings and 0 errors. Build output:`n$Text"
    }
}

function Wait-MacBuildResult {
    param(
        [string]$RemoteBuildLog,
        [string]$RemoteBuildExit,
        [string]$LocalBuildLog,
        [string]$LocalBuildExit,
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

        if (Test-RemoteFile -RemotePath $RemoteBuildExit) {
            Copy-RemoteFile -RemotePath $RemoteBuildExit -LocalPath $LocalBuildExit
            $rawExit = (Get-Content -Raw -LiteralPath $LocalBuildExit).Trim()
            $exitCode = 0
            if ([int]::TryParse($rawExit, [ref]$exitCode)) {
                if ($exitCode -ne 0) {
                    throw "Mac WebRTC helper build failed with exit code $exitCode. Build output:`n$lastText"
                }

                Assert-CleanDotNetBuildLog -Description "Mac WebRTC helper build" -Text $lastText
                return $lastText
            }
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for Mac WebRTC helper build. Last log:`n$lastText"
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

function Get-FreeLoopbackTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Assert-SignalEvidence {
    param(
        [string]$OfferPath,
        [string]$AnswerPath
    )

    $text = (Get-Content -Raw -LiteralPath $OfferPath) + "`n" + (Get-Content -Raw -LiteralPath $AnswerPath)
    Assert-True -Condition ($text.Contains($WindowsBindAddress)) -Message "Session signaling does not include expected Windows bind address $WindowsBindAddress."
    Assert-True -Condition ($text.Contains($MacBindAddress)) -Message "Session signaling does not include expected Mac bind address $MacBindAddress."
    Assert-True -Condition ($text.IndexOf("198.18.", [StringComparison]::Ordinal) -lt 0) -Message "Session signaling selected a proxy/test-network candidate instead of direct LAN."
}

Write-Output "windows-mac-webrtc-session-live: starting"
Assert-True -Condition (Test-Path -LiteralPath $MacSshKeyPath) -Message "Missing Mac SSH key: $MacSshKeyPath"
Write-Output "windows-mac-webrtc-session-live: mac-ssh-key-ok"
Assert-True -Condition (Test-Path -LiteralPath $MacKnownHostsPath) -Message "Missing pinned Mac known_hosts file: $MacKnownHostsPath"
Write-Output "windows-mac-webrtc-session-live: mac-known-hosts-ok"

$normalizedHostKey = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $MacExpectedHostKeyFingerprint
Assert-True -Condition ($normalizedHostKey -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "MacExpectedHostKeyFingerprint must be a pinned SHA256 host key."
Assert-KnownHostsFingerprint -KnownHostsPath $MacKnownHostsPath -ExpectedFingerprint $normalizedHostKey
Write-Output "windows-mac-webrtc-session-live: known-hosts-fingerprint-ok"

$helperProject = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/Skybridge.WebRtcHelper.csproj"
$helperSource = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper"
$runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
$requiredPaths = @($helperProject, $helperSource)
if ($UseWindowsProductRuntime) {
    Assert-True -Condition ($ProductSmokePeerFingerprint -match '^[0-9a-f]{64}$') -Message "ProductSmokePeerFingerprint must be 64 lowercase hex characters."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ProductSmokePeerDeviceId)) -Message "ProductSmokePeerDeviceId must not be empty."
    $requiredPaths += $runtimeSmokeProject
}
foreach ($requiredPath in $requiredPaths) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath) -Message "Missing required live WebRTC session path: $requiredPath"
}
Write-Output "windows-mac-webrtc-session-live: required-paths-ok"

$windowsRoot = Join-Path $env:TEMP ("skybridge-live-webrtc-session-" + [Guid]::NewGuid().ToString("N"))
$windowsOffer = Join-Path $windowsRoot "offer.json"
$windowsAnswer = Join-Path $windowsRoot "answer.json"
$windowsOfferPort = Join-Path $windowsRoot "windows-offer.ipc-port"
$macAnswerPort = Join-Path $windowsRoot "mac-answer.ipc-port"
$windowsOfferStdout = Join-Path $windowsRoot "offer.stdout.txt"
$windowsOfferStderr = Join-Path $windowsRoot "offer.stderr.txt"
$macAnswerStdout = Join-Path $windowsRoot "mac-answer.stdout.txt"
$macAnswerStderr = Join-Path $windowsRoot "mac-answer.stderr.txt"
$macForwardStdout = Join-Path $windowsRoot "mac-forward.stdout.txt"
$macForwardStderr = Join-Path $windowsRoot "mac-forward.stderr.txt"
$macEchoStdout = Join-Path $windowsRoot "mac-echo.stdout.txt"
$macEchoStderr = Join-Path $windowsRoot "mac-echo.stderr.txt"
$macEchoExit = Join-Path $windowsRoot "mac-echo.exit"
$productSmokeEvidence = Join-Path $windowsRoot "windows-product-data-plane-evidence.json"
$productSmokeExit = Join-Path $windowsRoot "windows-product-data-plane.exit"
$macBuildLog = Join-Path $windowsRoot "mac-build.log"
$macBuildExit = Join-Path $windowsRoot "mac-build.exit"
$productControlIpcAuthVariable = "SKYBRIDGE_PRODUCT_CONTROL_IPC_AUTH_TOKEN"
$productControlIpcAuthToken = ""
$productControlIpcAuthTokenFile = Join-Path $windowsRoot "product-control-ipc-token.txt"
New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null
Protect-CurrentUserDirectory -Path $windowsRoot
if ($UseProductControlProfile -or $UseWindowsProductRuntime) {
    $tokenBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
    try {
        $productControlIpcAuthToken = [Convert]::ToBase64String($tokenBytes)
        Set-Content -LiteralPath $productControlIpcAuthTokenFile -Value $productControlIpcAuthToken -NoNewline
    }
    finally {
        [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
    }
}
Write-Output "windows-mac-webrtc-session-live: windows-temp-ok"

$remoteRoot = ""
$remoteProductControlIpcAuthTokenFile = ""
$offerProcess = $null
$answerProcess = $null
$forwardProcess = $null
$echoProcess = $null
try {
    Write-Output "windows-mac-webrtc-session-live: build-windows-helper"
    Assert-DotNet10Sdk -Description "Windows live WebRTC session gate" -SdkList (Invoke-Native -FileName "dotnet" -TimeoutSeconds 20 -Arguments @("--list-sdks"))
    $windowsBuildOutput = & dotnet build $helperProject -c Debug --disable-build-servers /p:UseSharedCompilation=false 2>&1
    $windowsBuildExitCode = $LASTEXITCODE
    $windowsBuildText = ($windowsBuildOutput | Out-String)
    $windowsBuildText | Write-Output
    Assert-True -Condition ($windowsBuildExitCode -eq 0) -Message "Windows WebRTC helper build failed."
    Assert-CleanDotNetBuildLog -Description "Windows WebRTC helper build" -Text $windowsBuildText

    if ($UseWindowsProductRuntime) {
        Write-Output "windows-mac-webrtc-session-live: build-windows-product-runtime-smoke"
        $smokeBuildOutput = & dotnet build $runtimeSmokeProject -c Debug --disable-build-servers /p:UseSharedCompilation=false /warnaserror 2>&1
        $smokeBuildExitCode = $LASTEXITCODE
        $smokeBuildText = ($smokeBuildOutput | Out-String)
        $smokeBuildText | Write-Output
        Assert-True -Condition ($smokeBuildExitCode -eq 0) -Message "Windows product runtime smoke build failed."
        Assert-CleanDotNetBuildLog -Description "Windows product runtime smoke build" -Text $smokeBuildText
    }

    Write-Output "windows-mac-webrtc-session-live: prepare-mac-temp"
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

    Write-Output "windows-mac-webrtc-session-live: copy-helper-to-mac"
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
    $remoteAnswerPort = "$remoteLive/mac-answer.ipc-port"
    $remoteEchoExit = "$remoteLive/echo.exit"
    $remoteProductControlIpcAuthTokenFile = "$remoteLive/product-control-ipc-token.txt"
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
    Write-Output "windows-mac-webrtc-session-live: build-mac-helper"
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
    $macBuildText = Wait-MacBuildResult -RemoteBuildLog $remoteBuildLog -RemoteBuildExit $remoteBuildExit -LocalBuildLog $macBuildLog -LocalBuildExit $macBuildExit -TimeoutSeconds 180
    Wait-RemoteFile -RemotePath $remoteHelperDll -TimeoutSeconds 30
    $macBuildText | Write-Output
    if ($UseProductControlProfile -or $UseWindowsProductRuntime) {
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
            $productControlIpcAuthTokenFile,
            "${MacUserName}@${MacHostName}:$remoteProductControlIpcAuthTokenFile") | Out-Null
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
            "chmod 600 " + (ConvertTo-PosixSingleQuoted -Value $remoteProductControlIpcAuthTokenFile)) | Out-Null
    }

    $helperDll = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/Debug/net10.0/skybridge-webrtc-helper.dll"
    $helperExe = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/Debug/net10.0/skybridge-webrtc-helper.exe"
    $runtimeSmokeDll = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/bin/Debug/net10.0-windows10.0.22621.0/win-x64/Skybridge.WinClient.RuntimeSmoke.dll"
    $holdSeconds = [Math]::Max($TimeoutSeconds + 30, 120)
    if ($UseWindowsProductRuntime) {
        Assert-True -Condition (Test-Path -LiteralPath $helperExe) -Message "Windows product runtime smoke requires the built helper exe: $helperExe"
        Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeDll) -Message "Windows product runtime smoke dll was not found: $runtimeSmokeDll"
        Write-Output "windows-mac-webrtc-session-live: start-windows-product-runtime-smoke"
        $productSmokeArguments = @(
            $runtimeSmokeDll,
            "--profile", "product-control",
            "--helper-path", $helperExe,
            "--signaling-dir", $windowsRoot,
            "--offer-file", "offer.json",
            "--answer-file", "answer.json",
            "--bind-address", $WindowsBindAddress,
            "--peer-device-id", $ProductSmokePeerDeviceId,
            "--peer-fingerprint", $ProductSmokePeerFingerprint,
            "--evidence-out", $productSmokeEvidence,
            "--timeout-seconds", "$TimeoutSeconds")
        $productSmokeCommand =
            "& dotnet " + (Join-WindowsProcessArguments -Arguments $productSmokeArguments) +
            "; `$code = `$LASTEXITCODE; Set-Content -LiteralPath " +
            (ConvertTo-PowerShellSingleQuoted -Value $productSmokeExit) +
            " -Value `$code; exit `$code"
        $offerProcess = Start-Native -FileName "powershell" -StdoutPath $windowsOfferStdout -StderrPath $windowsOfferStderr -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", $productSmokeCommand)
    }
    elseif ($UseProductControlProfile) {
        Write-Output "windows-mac-webrtc-session-live: start-windows-product-control-offer"
        [Environment]::SetEnvironmentVariable($productControlIpcAuthVariable, $productControlIpcAuthToken, "Process")
        $offerProcess = Start-Native -FileName "dotnet" -StdoutPath $windowsOfferStdout -StderrPath $windowsOfferStderr -Arguments @(
            $helperDll,
            "--mode", "product-control-offer",
            "--bind-address", $WindowsBindAddress,
            "--offer-out", $windowsOffer,
            "--answer-in", $windowsAnswer,
            "--ipc-port", "0",
            "--ipc-port-out", $windowsOfferPort,
            "--ipc-auth-token-env", $productControlIpcAuthVariable,
            "--hold-seconds", "$holdSeconds")
    }
    else {
        Write-Output "windows-mac-webrtc-session-live: start-windows-session-offer"
        $offerProcess = Start-Native -FileName "dotnet" -StdoutPath $windowsOfferStdout -StderrPath $windowsOfferStderr -Arguments @(
            $helperDll,
            "--mode", "session-offer",
            "--bind-address", $WindowsBindAddress,
            "--offer-out", $windowsOffer,
            "--answer-in", $windowsAnswer,
            "--ipc-port", "0",
            "--ipc-port-out", $windowsOfferPort,
            "--hold-seconds", "$holdSeconds")
    }

    Wait-File -Path $windowsOffer -TimeoutSeconds 30 -OnPoll {
        if ($offerProcess.Process.HasExited) {
            throw "Windows WebRTC offer process exited before writing offer. stdout=$(Get-FileTextBestEffort -Path $windowsOfferStdout) stderr=$(Get-FileTextBestEffort -Path $windowsOfferStderr)"
        }
    }

    Write-Output "windows-mac-webrtc-session-live: copy-offer-to-mac"
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

    $macAnswerMode = if ($UseProductControlProfile -or $UseWindowsProductRuntime) { "product-control-answer" } else { "session-answer" }
    $answerAuthPrelude = ""
    $answerAuthArgs = ""
    if ($UseProductControlProfile -or $UseWindowsProductRuntime) {
        $answerAuthPrelude =
            "; export " + $productControlIpcAuthVariable + "=`$(cat " +
            (ConvertTo-PosixSingleQuoted -Value $remoteProductControlIpcAuthTokenFile) + ")"
        $answerAuthArgs = " --ipc-auth-token-env " + $productControlIpcAuthVariable
    }
    $answerCommand =
        "set -eu; " + $remoteDotNetPrelude +
        $answerAuthPrelude +
        '; "$DOTNET" ' + (ConvertTo-PosixSingleQuoted -Value $remoteHelperDll) +
        " --mode $macAnswerMode" +
        " --bind-address " + (ConvertTo-PosixSingleQuoted -Value $MacBindAddress) +
        " --offer-in " + (ConvertTo-PosixSingleQuoted -Value $remoteOffer) +
        " --answer-out " + (ConvertTo-PosixSingleQuoted -Value $remoteAnswer) +
        " --ipc-port 0" +
        " --ipc-port-out " + (ConvertTo-PosixSingleQuoted -Value $remoteAnswerPort) +
        $answerAuthArgs +
        " --hold-seconds $holdSeconds"
    Write-Output "windows-mac-webrtc-session-live: start-mac-session-answer"
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

    Write-Output "windows-mac-webrtc-session-live: wait-mac-answer"
    Wait-RemoteFile -RemotePath $remoteAnswer -TimeoutSeconds 45
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

    Assert-SignalEvidence -OfferPath $windowsOffer -AnswerPath $windowsAnswer
    Write-Output "windows-mac-webrtc-session-live: signaling-direct-lan-ok"

    Write-Output "windows-mac-webrtc-session-live: wait-session-ports"
    Wait-RemoteFile -RemotePath $remoteAnswerPort -TimeoutSeconds 60
    Copy-RemoteFile -RemotePath $remoteAnswerPort -LocalPath $macAnswerPort
    $macIpcPort = Wait-FileInteger -Path $macAnswerPort -TimeoutSeconds 5
    Write-Output "windows-mac-webrtc-session-live: mac-ipc-port=$macIpcPort"

    if ($UseWindowsProductRuntime) {
        $echoCommand =
            "set -u; " + $remoteDotNetPrelude +
            "; set +e; " +
            "export " + $productControlIpcAuthVariable + "=`$(cat " +
            (ConvertTo-PosixSingleQuoted -Value $remoteProductControlIpcAuthTokenFile) + "); " +
            ' "$DOTNET" ' + (ConvertTo-PosixSingleQuoted -Value $remoteHelperDll) +
            " --mode product-control-echo" +
            " --port $macIpcPort" +
            " --count 1" +
            " --ipc-auth-token-env " + $productControlIpcAuthVariable +
            " --timeout-seconds $TimeoutSeconds" +
            "; rc=`$?; echo `$rc > " + (ConvertTo-PosixSingleQuoted -Value $remoteEchoExit) +
            "; exit `$rc"
        Write-Output "windows-mac-webrtc-session-live: start-mac-product-control-echo"
        $echoProcess = Start-Native -FileName "ssh" -StdoutPath $macEchoStdout -StderrPath $macEchoStderr -Arguments @(
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
            $echoCommand)

        Write-Output "windows-mac-webrtc-session-live: wait-windows-product-runtime-smoke"
        $productWaitMs = [Math]::Max(($TimeoutSeconds + 30) * 1000, 60000)
        Assert-True -Condition ($offerProcess.Process.WaitForExit($productWaitMs)) -Message "Windows product runtime smoke timed out. stdout=$(Get-FileTextBestEffort -Path $windowsOfferStdout) stderr=$(Get-FileTextBestEffort -Path $windowsOfferStderr)"
        $productText = (Get-FileTextBestEffort -Path $windowsOfferStdout) + "`n" + (Get-FileTextBestEffort -Path $windowsOfferStderr)
        $productText | Write-Output
        Wait-File -Path $productSmokeExit -TimeoutSeconds 5
        $productExitCode = [int](Get-Content -Raw -LiteralPath $productSmokeExit).Trim()
        Assert-True -Condition ($productExitCode -eq 0) -Message "Windows product runtime smoke failed with exit code $productExitCode. Output:`n$productText"
        Assert-True -Condition ($productText.Contains("windows-product-control-smoke: ok")) -Message "Windows product runtime smoke did not report OK. Output:`n$productText"
        Wait-File -Path $productSmokeEvidence -TimeoutSeconds 5
        $evidence = Get-Content -Raw -LiteralPath $productSmokeEvidence | ConvertFrom-Json
        Assert-True -Condition ($evidence.FactoryMode -eq "webrtc-product-control") -Message "Product smoke evidence did not record factoryMode=webrtc-product-control."
        Assert-True -Condition ($evidence.Consumer -eq "WebRtcProductControlSmokeClient") -Message "Product smoke evidence did not record WebRtcProductControlSmokeClient."
        Assert-True -Condition ($evidence.SecureSessionState -eq "TransportOnly") -Message "Product smoke evidence must record secureSessionState=TransportOnly until the Mac handshake installs SBWC keys."
        Assert-True -Condition ($evidence.ProductSendCount -eq 1 -and $evidence.ProductReceiveCount -eq 1) -Message "Product smoke evidence did not record one send and one receive."

        $echoWaitMs = [Math]::Max(($TimeoutSeconds + 10) * 1000, 30000)
        Assert-True -Condition ($echoProcess.Process.WaitForExit($echoWaitMs)) -Message "Mac product-control-echo timed out. stdout=$(Get-FileTextBestEffort -Path $macEchoStdout) stderr=$(Get-FileTextBestEffort -Path $macEchoStderr)"
        $echoText = (Get-FileTextBestEffort -Path $macEchoStdout) + "`n" + (Get-FileTextBestEffort -Path $macEchoStderr)
        $echoText | Write-Output
        Wait-RemoteFile -RemotePath $remoteEchoExit -TimeoutSeconds 5
        Copy-RemoteFile -RemotePath $remoteEchoExit -LocalPath $macEchoExit
        Wait-File -Path $macEchoExit -TimeoutSeconds 5
        $echoExitCode = [int](Get-Content -Raw -LiteralPath $macEchoExit).Trim()
        Assert-True -Condition ($echoExitCode -eq 0) -Message "Mac product-control-echo failed with exit code $echoExitCode. Output:`n$echoText"
        Assert-True -Condition ($echoText.Contains("[product-control-echo] OK:")) -Message "Mac product-control-echo did not report OK. Output:`n$echoText"

        Write-Output "windows-mac-webrtc-session-live: product-control-runtime-ok"
        Write-Output "windows-mac-webrtc-session-live: product-evidence=$productSmokeEvidence"
        return
    }

    $windowsIpcPort = Wait-FileInteger -Path $windowsOfferPort -TimeoutSeconds 60 -OnPoll {
        if ($offerProcess.Process.HasExited) {
            throw "Windows session-offer helper exited before reporting IPC port. stdout=$(Get-FileTextBestEffort -Path $windowsOfferStdout) stderr=$(Get-FileTextBestEffort -Path $windowsOfferStderr)"
        }
    }
    Write-Output "windows-mac-webrtc-session-live: windows-ipc-port=$windowsIpcPort"

    $localForwardPort = Get-FreeLoopbackTcpPort
    $forwardSpec = "127.0.0.1:{0}:127.0.0.1:{1}" -f $localForwardPort, $macIpcPort
    Write-Output "windows-mac-webrtc-session-live: start-mac-ipc-forward=$forwardSpec"
    $forwardProcess = Start-Native -FileName "ssh" -StdoutPath $macForwardStdout -StderrPath $macForwardStderr -Arguments @(
        "-N",
        "-T",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$MacKnownHostsPath",
        "-o", "UpdateHostKeys=no",
        "-p", "$MacPort",
        "-i", $MacSshKeyPath,
        "-L", $forwardSpec,
        "$MacUserName@$MacHostName")

    Start-Sleep -Milliseconds 750
    if ($forwardProcess.Process.HasExited) {
        throw "SSH local forward exited before session-driver. stdout=$(Get-FileTextBestEffort -Path $macForwardStdout) stderr=$(Get-FileTextBestEffort -Path $macForwardStderr)"
    }

    if ($UseProductControlProfile) {
        Write-Output "windows-mac-webrtc-session-live: run-product-control-driver-windows-to-mac"
        [Environment]::SetEnvironmentVariable($productControlIpcAuthVariable, $productControlIpcAuthToken, "Process")
        $productDriverOutput = & dotnet $helperDll `
            --mode product-control-driver `
            --send-port "$windowsIpcPort" `
            --recv-port "$localForwardPort" `
            --ipc-auth-token-env "$productControlIpcAuthVariable" `
            --timeout-seconds "$TimeoutSeconds" 2>&1
        $productDriverExitCode = $LASTEXITCODE
        $productDriverText = Redact-SensitiveText -Text ($productDriverOutput | Out-String)
        $productDriverText | Write-Output
        Assert-True -Condition ($productDriverExitCode -eq 0) -Message "WebRTC product-control driver Windows->Mac failed with exit code $productDriverExitCode. Output:`n$productDriverText"
        Assert-True -Condition ($productDriverText.Contains("[product-control-driver] OK:")) -Message "WebRTC product-control driver Windows->Mac did not report the expected OK line. Output:`n$productDriverText"

        Write-Output "windows-mac-webrtc-session-live: run-product-control-driver-mac-to-windows"
        [Environment]::SetEnvironmentVariable($productControlIpcAuthVariable, $productControlIpcAuthToken, "Process")
        $reverseProductDriverOutput = & dotnet $helperDll `
            --mode product-control-driver `
            --send-port "$localForwardPort" `
            --recv-port "$windowsIpcPort" `
            --ipc-auth-token-env "$productControlIpcAuthVariable" `
            --timeout-seconds "$TimeoutSeconds" 2>&1
        $reverseProductDriverExitCode = $LASTEXITCODE
        $reverseProductDriverText = Redact-SensitiveText -Text ($reverseProductDriverOutput | Out-String)
        $reverseProductDriverText | Write-Output
        Assert-True -Condition ($reverseProductDriverExitCode -eq 0) -Message "WebRTC product-control driver Mac->Windows failed with exit code $reverseProductDriverExitCode. Output:`n$reverseProductDriverText"
        Assert-True -Condition ($reverseProductDriverText.Contains("[product-control-driver] OK:")) -Message "WebRTC product-control driver Mac->Windows did not report the expected OK line. Output:`n$reverseProductDriverText"

        $windowsOfferText = (Get-FileTextBestEffort -Path $windowsOfferStdout) + "`n" + (Get-FileTextBestEffort -Path $windowsOfferStderr)
        $macAnswerText = (Get-FileTextBestEffort -Path $macAnswerStdout) + "`n" + (Get-FileTextBestEffort -Path $macAnswerStderr)
        $windowsOfferText | Write-Output
        $macAnswerText | Write-Output
        Assert-True -Condition ($windowsOfferText.Contains("SKYBRIDGE_PRODUCT_CONTROL_PORT=")) -Message "Windows product-control offer did not report product-control port. Output:`n$windowsOfferText"
        Assert-True -Condition ($macAnswerText.Contains("SKYBRIDGE_PRODUCT_CONTROL_PORT=")) -Message "Mac product-control answer did not report product-control port. Output:`n$macAnswerText"
        Write-Output "windows-mac-webrtc-session-live: product-control-ok"
        return
    }

    Write-Output "windows-mac-webrtc-session-live: run-session-driver-windows-to-mac"
    $driverOutput = & dotnet $helperDll `
        --mode session-driver `
        --send-port "$windowsIpcPort" `
        --recv-port "$localForwardPort" `
        --count "$SessionMessageCount" `
        --timeout-seconds "$TimeoutSeconds" 2>&1
    $driverExitCode = $LASTEXITCODE
    $driverText = ($driverOutput | Out-String)
    $driverText | Write-Output
    Assert-True -Condition ($driverExitCode -eq 0) -Message "WebRTC session-driver Windows->Mac failed with exit code $driverExitCode. Output:`n$driverText"
    Assert-True -Condition ($driverText.Contains("[driver] OK:")) -Message "WebRTC session-driver Windows->Mac did not report the expected OK line. Output:`n$driverText"

    Write-Output "windows-mac-webrtc-session-live: run-session-driver-mac-to-windows"
    $reverseDriverOutput = & dotnet $helperDll `
        --mode session-driver `
        --send-port "$localForwardPort" `
        --recv-port "$windowsIpcPort" `
        --count "$SessionMessageCount" `
        --timeout-seconds "$TimeoutSeconds" 2>&1
    $reverseDriverExitCode = $LASTEXITCODE
    $reverseDriverText = ($reverseDriverOutput | Out-String)
    $reverseDriverText | Write-Output
    Assert-True -Condition ($reverseDriverExitCode -eq 0) -Message "WebRTC session-driver Mac->Windows failed with exit code $reverseDriverExitCode. Output:`n$reverseDriverText"
    Assert-True -Condition ($reverseDriverText.Contains("[driver] OK:")) -Message "WebRTC session-driver Mac->Windows did not report the expected OK line. Output:`n$reverseDriverText"

    Write-Output "windows-mac-webrtc-session-live: ok"
    Write-Output "windows-mac-webrtc-session-live: windows-ipc=127.0.0.1:$windowsIpcPort"
    Write-Output "windows-mac-webrtc-session-live: mac-ipc-forward=127.0.0.1:$localForwardPort->${MacHostName}:127.0.0.1:$macIpcPort"
}
finally {
    Stop-StartedProcess -Started $forwardProcess
    Stop-StartedProcess -Started $echoProcess
    Stop-StartedProcess -Started $offerProcess
    Stop-StartedProcess -Started $answerProcess
    [Environment]::SetEnvironmentVariable($productControlIpcAuthVariable, $null, "Process")
    if (Test-Path -LiteralPath $productControlIpcAuthTokenFile) {
        Remove-Item -LiteralPath $productControlIpcAuthTokenFile -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($remoteProductControlIpcAuthTokenFile)) {
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
                "rm -f -- " + (ConvertTo-PosixSingleQuoted -Value $remoteProductControlIpcAuthTokenFile)) | Out-Null
        }
        catch {
            Write-Output "windows-mac-webrtc-session-live: token cleanup warning: $(Redact-SensitiveText -Text $_.Exception.Message)"
        }
    }

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
                Write-Output "windows-mac-webrtc-session-live: cleanup warning: $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $windowsRoot) {
            Remove-Item -LiteralPath $windowsRoot -Recurse -Force
        }
    }
    else {
        Write-Output "windows-mac-webrtc-session-live: kept-windows-artifacts=$windowsRoot"
        if (-not [string]::IsNullOrWhiteSpace($remoteRoot)) {
            Write-Output "windows-mac-webrtc-session-live: kept-mac-artifacts=$remoteRoot"
        }
    }
}
