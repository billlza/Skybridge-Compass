param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [string]$UserName = "",
    [int]$Port = 22,
    [string]$IdentityFile = "",
    [Parameter(Mandatory = $true)]
    [string]$ExpectedHostKeyFingerprint,
    [string]$KnownHostsPath = "",
    [string]$EvidencePath = "",
    [string]$RemoteCommand = "cmd /c echo openssh-pq-kex-ok",
    [string]$SshPath = "ssh",
    [string]$SshKeygenPath = "ssh-keygen",
    [string]$SshKeyscanPath = "ssh-keyscan",
    [int]$ConnectTimeoutSeconds = 15,
    [int]$NativeCommandTimeoutSeconds = 60,
    [string[]]$PqKexAlgorithms = @(
        "mlkem768x25519-sha256",
        "sntrup761x25519-sha512",
        "sntrup761x25519-sha512@openssh.com"
    ),
    [switch]$AllowAuthenticationFailureAfterKex,
    [switch]$KeepKnownHosts
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

function Invoke-NativeCapture {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $resolvedFileName = Resolve-NativeCommandPath -FileName $FileName
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-native-stdout-" + [Guid]::NewGuid().ToString("N") + ".log")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-native-stderr-" + [Guid]::NewGuid().ToString("N") + ".log")
    $argumentString = Join-NativeArguments -Arguments $Arguments
    $process = $null
    try {
        $process = Start-Process `
            -FilePath $resolvedFileName `
            -ArgumentList $argumentString `
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
                throw "Native command timed out after $TimeoutSeconds seconds and could not be killed: $resolvedFileName $($Arguments -join ' '). KillError=$killFailure"
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

function ConvertTo-JsonFileUtf8 {
    param(
        $Value,
        [string]$Path
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).ProviderPath
        $resolvedPath = Join-Path $directory (Split-Path -Leaf $resolvedPath)
    }

    New-Item -ItemType Directory -Force -Path $directory | Out-Null
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

function Get-Sha256Hex {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-BoundedLines {
    param(
        [string]$Text,
        [string[]]$Patterns,
        [int]$MaxLines = 80
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        foreach ($pattern in $Patterns) {
            if ($line -match $pattern) {
                $lines.Add($line)
                break
            }
        }
        if ($lines.Count -ge $MaxLines) {
            break
        }
    }

    return @($lines)
}

Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($HostName)) -Message "HostName must not be empty."
Assert-True -Condition ($Port -gt 0 -and $Port -le 65535) -Message "Port must be in 1..65535."
Assert-True -Condition ($ConnectTimeoutSeconds -gt 0 -and $ConnectTimeoutSeconds -le 300) -Message "ConnectTimeoutSeconds must be in 1..300."
Assert-True -Condition ($NativeCommandTimeoutSeconds -gt 0 -and $NativeCommandTimeoutSeconds -le 900) -Message "NativeCommandTimeoutSeconds must be in 1..900."
Assert-True -Condition ($PqKexAlgorithms.Count -gt 0) -Message "At least one PQ/hybrid KEX algorithm is required."
foreach ($algorithm in $PqKexAlgorithms) {
    Assert-True -Condition ($algorithm -match '^(mlkem768x25519-sha256|sntrup761x25519-sha512(@openssh\.com)?)$') -Message "Unsupported PQ KEX algorithm: $algorithm"
}

$normalizedExpectedFingerprint = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $ExpectedHostKeyFingerprint
Assert-True -Condition ($normalizedExpectedFingerprint -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "ExpectedHostKeyFingerprint must be a pinned SHA256 host key fingerprint."

$ownedKnownHosts = $false
if ([string]::IsNullOrWhiteSpace($KnownHostsPath)) {
    $KnownHostsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-openssh-pq-kex-known-hosts-" + [Guid]::NewGuid().ToString("N"))
    $ownedKnownHosts = $true
}
$knownHostsFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KnownHostsPath)
$knownHostsDirectory = Split-Path -Parent $knownHostsFullPath
if (-not [string]::IsNullOrWhiteSpace($knownHostsDirectory)) {
    New-Item -ItemType Directory -Force -Path $knownHostsDirectory | Out-Null
}

$clientVersionResult = Invoke-NativeCapture -FileName $SshPath -Arguments @("-V") -TimeoutSeconds 20
$clientVersionText = $clientVersionResult.text.Trim()
$clientKexResult = Invoke-NativeCapture -FileName $SshPath -Arguments @("-Q", "kex") -TimeoutSeconds 20
$clientKex = @($clientKexResult.text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$clientSupportedPqKex = @($clientKex | Where-Object { $PqKexAlgorithms -contains $_ })
Assert-True -Condition ($clientSupportedPqKex.Count -gt 0) -Message "Local OpenSSH client does not support the requested PQ/hybrid KEX algorithms."

$scanResult = Invoke-NativeCapture -FileName $SshKeyscanPath -Arguments @("-p", "$Port", "-T", "10", $HostName) -TimeoutSeconds 20
Assert-True -Condition ($scanResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($scanResult.text)) -Message "ssh-keyscan failed for $HostName`:$Port."
$hostKeyLines = @(
    $scanResult.text -split "`r?`n" |
        Where-Object { $_ -match '^\S+\s+(ssh|ecdsa|sk)-[A-Za-z0-9@._+-]+' }
)
Assert-True -Condition ($hostKeyLines.Count -gt 0) -Message "ssh-keyscan did not return any host key records for $HostName`:$Port."
[System.IO.File]::WriteAllText($knownHostsFullPath, (($hostKeyLines -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

$fingerprintResult = Invoke-NativeCapture -FileName $SshKeygenPath -Arguments @("-lf", $knownHostsFullPath) -TimeoutSeconds 20
Assert-True -Condition ($fingerprintResult.exitCode -eq 0) -Message "ssh-keygen could not read scanned host keys."
$hostKeyFingerprints = New-Object System.Collections.Generic.List[string]
foreach ($line in ($fingerprintResult.text -split "`r?`n")) {
    if ($line -match 'SHA256:[A-Za-z0-9+/]+={0,2}') {
        $hostKeyFingerprints.Add($Matches[0])
    }
}
$hostKeyFingerprints = @($hostKeyFingerprints)
Assert-True -Condition ($hostKeyFingerprints -contains $normalizedExpectedFingerprint) -Message "Scanned host key fingerprints did not include expected fingerprint $normalizedExpectedFingerprint."

$target = if ([string]::IsNullOrWhiteSpace($UserName)) { $HostName } else { "$UserName@$HostName" }
$kexAlgorithmList = $PqKexAlgorithms -join ","
$sshArguments = @(
    "-n",
    "-F", "none",
    "-vvv",
    "-p", "$Port",
    "-o", "KexAlgorithms=$kexAlgorithmList",
    "-o", "BatchMode=yes",
    "-o", "PreferredAuthentications=publickey",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "NumberOfPasswordPrompts=0",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=$knownHostsFullPath",
    "-o", "UpdateHostKeys=no",
    "-o", "ConnectTimeout=$ConnectTimeoutSeconds",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=10",
    "-o", "ServerAliveCountMax=1"
)
if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
    Assert-True -Condition (Test-Path -LiteralPath $IdentityFile) -Message "IdentityFile does not exist: $IdentityFile"
    $sshArguments += @("-i", $IdentityFile)
}
$sshArguments += @($target, $RemoteCommand)

$sshResult = Invoke-NativeCapture -FileName $SshPath -Arguments $sshArguments -TimeoutSeconds $NativeCommandTimeoutSeconds
$negotiatedKex = ""
if ($sshResult.text -match 'kex: algorithm: (?<algorithm>[A-Za-z0-9@._+-]+)') {
    $negotiatedKex = $Matches["algorithm"]
}
$negotiatedPqKex = $PqKexAlgorithms -contains $negotiatedKex
$authFailureAfterKex = $sshResult.text -match '(?i)(permission denied|no more authentication methods|publickey)'
$commandSucceeded = $sshResult.exitCode -eq 0 -and -not $authFailureAfterKex
$acceptableExit = $commandSucceeded -or ($AllowAuthenticationFailureAfterKex -and $negotiatedPqKex -and $authFailureAfterKex)

$evidence = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    script = "verify-openssh-pq-kex.ps1"
    hostName = $HostName
    port = $Port
    userName = $UserName
    clientVersion = $clientVersionText
    clientSupportedPqKex = @($clientSupportedPqKex)
    requiredPqKexAlgorithms = @($PqKexAlgorithms)
    expectedHostKeyFingerprint = $normalizedExpectedFingerprint
    hostKeyPinned = $hostKeyFingerprints -contains $normalizedExpectedFingerprint
    hostKeyFingerprints = @($hostKeyFingerprints)
    negotiatedKexAlgorithm = $negotiatedKex
    negotiatedPqKex = [bool]$negotiatedPqKex
    commandExitCode = $sshResult.exitCode
    commandSucceeded = [bool]$commandSucceeded
    allowAuthenticationFailureAfterKex = [bool]$AllowAuthenticationFailureAfterKex
    authenticationFailureAfterKex = [bool]$authFailureAfterKex
    connectTimeoutSeconds = $ConnectTimeoutSeconds
    nativeCommandTimeoutSeconds = $NativeCommandTimeoutSeconds
    accepted = [bool]($acceptableExit -and $negotiatedPqKex)
    sshVerboseOutputSha256 = Get-Sha256Hex -Text $sshResult.text
    sshVerboseSignals = Get-BoundedLines -Text $sshResult.text -Patterns @(
        'OpenSSH',
        'Remote protocol',
        'remote software',
        'peer server KEXINIT',
        'KEX algorithms:',
        'kex: algorithm:',
        'Server host key:',
        'Permission denied',
        'pq-kex'
    )
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $resolvedEvidencePath = ConvertTo-JsonFileUtf8 -Value $evidence -Path $EvidencePath
    Write-Output "openssh-pq-kex: evidence=$resolvedEvidencePath"
}

try {
    Assert-True -Condition $evidence.hostKeyPinned -Message "OpenSSH PQ KEX evidence requires a pinned host key."
    Assert-True -Condition $negotiatedPqKex -Message "SSH did not negotiate a PQ/hybrid KEX algorithm. Negotiated='$negotiatedKex'."
    Assert-True -Condition $acceptableExit -Message "SSH command failed before acceptable completion. ExitCode=$($sshResult.exitCode)."

    Write-Output "openssh-pq-kex: ok host=$HostName port=$Port kex=$negotiatedKex"
}
finally {
    if ($ownedKnownHosts -and -not $KeepKnownHosts -and (Test-Path -LiteralPath $knownHostsFullPath)) {
        Remove-Item -LiteralPath $knownHostsFullPath -Force
    }
}
