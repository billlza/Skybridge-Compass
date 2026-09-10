[CmdletBinding()]
param(
    [string]$WindowsLanAddress = "",
    [string]$MacLanAddress = "",
    [ValidateRange(1, 32)]
    [int]$LanPrefixLength = 24,
    [string]$MacLanInterface = "",
    [string]$WindowsLanInterfaceAlias = "",
    [string]$WindowsAccountName = "",
    [string]$RelayAccountName = "",
    [string]$ExpectedWindowsAccountSid = "",
    [string]$ExpectedRelayAccountSid = "",
    [string]$LanAuthorizedPublicKey = "",
    [string]$LanPublicKeyProvenanceRef = "",
    [string]$IdentityFile = "",
    [string]$ExpectedIdentityKeyFingerprint = "",
    [string]$KnownHostsPath = "",
    [string]$ExpectedWindowsHostKeyFingerprint = "",
    [ValidateRange(22, 22)]
    [int]$Port = 22,
    [string]$FirewallRuleName = "SkyBridge-Windows-LAN-SSH",
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 30,
    [string]$SshPath = "/usr/bin/ssh",
    [string]$SshKeygenPath = "/usr/bin/ssh-keygen",
    [string]$FixturePath = "",
    [switch]$ServerAudit,
    [string]$ServerAuditEvidencePath = "",
    [string]$ExpectedServerAuditSha256 = "",
    [ValidateRange(30, 3600)]
    [int]$ServerAuditMaxAgeSeconds = 300,
    [Parameter(Mandatory = $true)]
    [string]$PrivateEvidencePath,
    [string]$PublicEvidencePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$schema = "skybridge-windows-lan-ssh-lifecycle-v1"
$fixtureSchema = "skybridge-windows-lan-ssh-lifecycle-fixture-v1"
$serverAuditSchema = "skybridge-windows-lan-ssh-server-audit-v1"
$remoteSessionSchema = "skybridge-windows-lan-ssh-session-audit-v1"
$requiredKex = "mlkem768x25519-sha256"
$requiredHostKeyAlgorithm = "ssh-ed25519"
$remoteMarker = "SKYBRIDGE_LAN_SSH_EVIDENCE_V1:"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-CanonicalIPv4 {
    param(
        [string]$Value,
        [string]$Name
    )

    $parsed = $null
    Assert-True -Condition ([System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) -Message "$Name must be an IPv4 address."
    Assert-True -Condition ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -Message "$Name must be IPv4."
    $canonical = $parsed.ToString()
    Assert-True -Condition ($canonical -ceq $Value) -Message "$Name must use canonical dotted-decimal form."
    Assert-True -Condition (-not [System.Net.IPAddress]::IsLoopback($parsed)) -Message "$Name must not be loopback."
    $firstByte = $parsed.GetAddressBytes()[0]
    Assert-True -Condition ($firstByte -ne 0 -and $firstByte -lt 224) -Message "$Name must be a unicast IPv4 address."
    return $canonical
}

function Test-SameIPv4Prefix {
    param(
        [string]$Left,
        [string]$Right,
        [int]$PrefixLength
    )

    $leftBytes = [System.Net.IPAddress]::Parse($Left).GetAddressBytes()
    $rightBytes = [System.Net.IPAddress]::Parse($Right).GetAddressBytes()
    $wholeBytes = [math]::Floor($PrefixLength / 8)
    $remainingBits = $PrefixLength % 8
    for ($index = 0; $index -lt $wholeBytes; $index++) {
        if ($leftBytes[$index] -ne $rightBytes[$index]) {
            return $false
        }
    }
    if ($remainingBits -gt 0) {
        $mask = (0xff -shl (8 - $remainingBits)) -band 0xff
        if (($leftBytes[$wholeBytes] -band $mask) -ne ($rightBytes[$wholeBytes] -band $mask)) {
            return $false
        }
    }
    return $true
}

function Resolve-NativeCommandPath {
    param([string]$FileName)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($FileName)) -Message "Native command must not be empty."
    if ([System.IO.Path]::IsPathRooted($FileName) -or $FileName -match '[\\/]') {
        Assert-True -Condition (Test-Path -LiteralPath $FileName -PathType Leaf) -Message "Native command is missing: $FileName"
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FileName)
    }

    $command = Get-Command -Name $FileName -CommandType Application -ErrorAction Stop | Select-Object -First 1
    Assert-True -Condition ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) -Message "Native command is unavailable: $FileName"
    return $command.Source
}

function ConvertTo-ProcessArgument {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount += 1
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-NativeCapture {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [ValidateRange(1, 180)]
        [int]$CommandTimeoutSeconds = 30,
        [AllowNull()]
        [string]$StandardInputText = $null
    )

    $resolved = Resolve-NativeCommandPath -FileName $FileName
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolved
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputText
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join " ")

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True -Condition $process.Start() -Message "Native command did not start: $resolved"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInputText) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit($CommandTimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                $process.WaitForExit()
            }
            catch {
                throw "Native command timed out and could not be terminated: $resolved. $($_.Exception.Message)"
            }
            throw "Native command timed out: $resolved"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [ordered]@{
            exitCode = [int]$process.ExitCode
            stdout = $stdout
            stderr = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-StringSha256 {
    param([AllowEmptyString()][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FileSha256 {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") })
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-CanonicalTextFileSha256 {
    param([string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "Source file is missing."
    $text = [System.IO.File]::ReadAllText($Path)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return Get-StringSha256 -Value $normalized
}

function Assert-NoReparsePathChain {
    param([string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    if (Test-Path -LiteralPath $resolved) {
        $leafItem = Get-Item -LiteralPath $resolved -Force
        Assert-True -Condition (($leafItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "Protected path must not be a reparse point or symbolic link."
    }
    $current = if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { Split-Path -Parent $resolved }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($current) -and (Test-Path -LiteralPath $current -PathType Container)) -Message "Protected path parent directory is missing."
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force
        Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "Protected path parent chain contains a reparse point or symbolic link."
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
}

function Set-WindowsOwnerOnlyFileAcl {
    param([string]$Path)

    Assert-NoReparsePathChain -Path $Path
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $allowedSidValues = @($currentSid.Value, $systemSid.Value, $administratorsSid.Value)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    foreach ($identity in @($currentSid, $systemSid, $administratorsSid)) {
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($accessRule)
    }
    $acl.SetOwner($currentSid)
    Set-Acl -LiteralPath $Path -AclObject $acl

    $finalAcl = Get-Acl -LiteralPath $Path
    Assert-True -Condition $finalAcl.AreAccessRulesProtected -Message "Private evidence ACL inheritance remains enabled."
    foreach ($rule in $finalAcl.Access) {
        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        Assert-True -Condition ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and $allowedSidValues -contains $sid) -Message "Private evidence ACL contains an unexpected principal or rule."
    }
}

function Write-JsonAtomic {
    param(
        $Value,
        [string]$Path,
        [bool]$OwnerOnly
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($parent)) -Message "Evidence path must have a parent directory."
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) -Message "Evidence path must not be a directory."

    $leaf = Split-Path -Leaf $resolvedPath
    $tempPath = Join-Path $parent (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = Join-Path $parent (".$leaf." + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $json = ($Value | ConvertTo-Json -Depth 12) + "`n"
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        $isWindowsHost = $env:OS -eq "Windows_NT"
        if ($OwnerOnly -and $isWindowsHost) {
            if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
                Set-WindowsOwnerOnlyFileAcl -Path $resolvedPath
            }
            Set-WindowsOwnerOnlyFileAcl -Path $tempPath
        }
        if (-not $isWindowsHost) {
            $mode = if ($OwnerOnly) { "600" } else { "644" }
            & /bin/chmod $mode $tempPath
            Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "chmod failed for evidence temporary file."
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            [System.IO.File]::Replace($tempPath, $resolvedPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        }
        else {
            [System.IO.File]::Move($tempPath, $resolvedPath)
        }
        if ($OwnerOnly -and $isWindowsHost) {
            Set-WindowsOwnerOnlyFileAcl -Path $resolvedPath
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

function Get-ObservationValue {
    param(
        $Observation,
        [string]$Name
    )

    if ($Observation -is [System.Collections.IDictionary]) {
        Assert-True -Condition $Observation.Contains($Name) -Message "Observation is missing required field '$Name'."
        return $Observation[$Name]
    }
    $property = $Observation.PSObject.Properties[$Name]
    Assert-True -Condition ($null -ne $property) -Message "Observation is missing required field '$Name'."
    return $property.Value
}

function Get-LifecycleEvaluation {
    param($Observation)

    $checks = [ordered]@{}
    $checks.clientPlatformSupported = (Get-ObservationValue -Observation $Observation -Name "clientPlatform") -ceq "macOS"
    $checks.addressingBound = [bool](Get-ObservationValue -Observation $Observation -Name "addressesCanonical") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "addressesDistinct") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "samePrefix")
    $checks.physicalInterfaceBound = [bool](Get-ObservationValue -Observation $Observation -Name "interfaceMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "interfaceIsPhysical") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "interfaceActive") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "interfaceAddressMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "interfacePrefixMatches")
    $checks.directRouteBound = [bool](Get-ObservationValue -Observation $Observation -Name "routeInterfaceMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "routeDestinationMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "routeIsDirect") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "neighborMatches")
    $checks.hostPinTrusted = [bool](Get-ObservationValue -Observation $Observation -Name "pinDurable") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "pinOwnerSafe") -and
        [int](Get-ObservationValue -Observation $Observation -Name "pinActiveRecordCount") -eq 1 -and
        [bool](Get-ObservationValue -Observation $Observation -Name "pinTargetMatches") -and
        ([string](Get-ObservationValue -Observation $Observation -Name "pinAlgorithm")) -ceq $requiredHostKeyAlgorithm -and
        [bool](Get-ObservationValue -Observation $Observation -Name "pinDigestMatches")
    $checks.clientIdentityTrusted = [bool](Get-ObservationValue -Observation $Observation -Name "identityFileOwnerOnly") -and
        ([string](Get-ObservationValue -Observation $Observation -Name "identityAlgorithm")) -ceq $requiredHostKeyAlgorithm -and
        [bool](Get-ObservationValue -Observation $Observation -Name "identityDigestMatches")
    $checks.sshInvocationFailClosed = [bool](Get-ObservationValue -Observation $Observation -Name "sshConfigDisabled") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshNumericTarget") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshBoundSource") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshBoundInterface") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshStrictPin") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshPublicKeyOnly") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshAgentDisabled") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshPasswordsDisabled") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshNoProxyOrJump") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshForwardingDisabled") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshArgumentListBounded") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshRemoteScriptViaStandardInput") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshRemoteScriptBounded") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshRemotePowerShellAbsolute")
    $checks.hybridKexNegotiated = ([string](Get-ObservationValue -Observation $Observation -Name "requestedKex")) -ceq $requiredKex -and
        ([string](Get-ObservationValue -Observation $Observation -Name "negotiatedKex")) -ceq $requiredKex -and
        [int](Get-ObservationValue -Observation $Observation -Name "sshExitCode") -eq 0
    $checks.ed25519HostAuthenticated = ([string](Get-ObservationValue -Observation $Observation -Name "negotiatedHostKeyAlgorithm")) -ceq $requiredHostKeyAlgorithm -and
        [bool](Get-ObservationValue -Observation $Observation -Name "sshKnownHostMatched") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "negotiatedHostKeyDigestMatches")
    $checks.localAuthorityStable = [bool](Get-ObservationValue -Observation $Observation -Name "appleToolManifestTrusted") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "appleToolManifestStable") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "boundInputSnapshotsStable") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "routeSnapshotStable") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditStillFresh") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "evidenceParentsStable")
    $checks.serverAuditTrusted = [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditSchemaExact") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditDigestMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditFresh") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditBindingMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditPassed") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditAcceptedFalse") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "serverAuditFileOwnerSafe")
    $checks.remoteEvidenceBound = ([string](Get-ObservationValue -Observation $Observation -Name "remoteSchema")) -ceq $remoteSessionSchema -and
        [bool](Get-ObservationValue -Observation $Observation -Name "remoteWindows") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "remotePowerShellPathMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "remotePowerShellDigestMatches")
    $checks.accountLeastPrivilege = [bool](Get-ObservationValue -Observation $Observation -Name "remoteAccountEnabled") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "remoteAccountNameMatches") -and
        [bool](Get-ObservationValue -Observation $Observation -Name "remoteAccountSidMatches") -and
        -not [bool](Get-ObservationValue -Observation $Observation -Name "remoteAccountIsAdministrator")
    $checks.serverRuntimeExact = [bool](Get-ObservationValue -Observation $Observation -Name "serverRuntimeExact")
    $checks.serverKeysAndAclExact = [bool](Get-ObservationValue -Observation $Observation -Name "serverKeysAndAclExact")
    $checks.serverFirewallExact = [bool](Get-ObservationValue -Observation $Observation -Name "serverFirewallExact")
    $checks.serverAuthenticationPolicyExact = [bool](Get-ObservationValue -Observation $Observation -Name "serverAuthenticationPolicyExact")
    $checks.serverSourceManifestBound = [bool](Get-ObservationValue -Observation $Observation -Name "serverSourceManifestBound")
    $checks.sessionEndpointsBound = [bool](Get-ObservationValue -Observation $Observation -Name "remoteSshConnectionMatches")

    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $checks.GetEnumerator()) {
        if (-not [bool]$entry.Value) {
            $failed.Add([string]$entry.Key)
        }
    }
    return [ordered]@{
        checks = $checks
        failedCheckCodes = @($failed)
        evaluationPassed = ($failed.Count -eq 0)
    }
}

function Convert-HexNetmaskToPrefixLength {
    param([string]$HexValue)

    Assert-True -Condition ($HexValue -match '^0x[0-9a-fA-F]{8}$') -Message "Interface netmask is not a 32-bit hexadecimal mask."
    $value = [Convert]::ToUInt32($HexValue.Substring(2), 16)
    $bits = [Convert]::ToString($value, 2).PadLeft(32, '0')
    Assert-True -Condition ($bits -match '^1*0*$') -Message "Interface netmask is not contiguous."
    return ($bits -replace '0', '').Length
}

function Get-MacRouteObservation {
    param(
        [string]$TargetAddress,
        [string]$SourceAddress,
        [int]$PrefixLength,
        [string]$InterfaceName
    )

    Assert-True -Condition ($env:OS -ne "Windows_NT") -Message "Live Windows LAN SSH verification must run on macOS."
    $uname = Invoke-NativeCapture -FileName "/usr/bin/uname" -Arguments @("-s")
    Assert-True -Condition ($uname.exitCode -eq 0 -and $uname.stdout.Trim() -ceq "Darwin") -Message "Live Windows LAN SSH verification must run on macOS."
    Assert-True -Condition ($InterfaceName -match '^[A-Za-z0-9]+$') -Message "MacLanInterface contains unsupported characters."
    Assert-True -Condition ($InterfaceName -notmatch '^(?i:utun|tun|tap|ppp|ipsec|gif|stf|bridge|awdl|llw|lo)') -Message "MacLanInterface must identify a physical LAN interface."

    $ifconfig = Invoke-NativeCapture -FileName "/sbin/ifconfig" -Arguments @($InterfaceName)
    Assert-True -Condition ($ifconfig.exitCode -eq 0) -Message "ifconfig failed for the declared LAN interface."
    $addressMatch = [regex]::Match($ifconfig.stdout, "(?m)^\s*inet\s+(?<address>\d+(?:\.\d+){3})\s+netmask\s+(?<mask>0x[0-9a-fA-F]{8})\b")
    Assert-True -Condition $addressMatch.Success -Message "Declared LAN interface has no IPv4 address."
    $actualAddress = $addressMatch.Groups['address'].Value
    $actualPrefixLength = Convert-HexNetmaskToPrefixLength -HexValue $addressMatch.Groups['mask'].Value
    $interfaceActive = $ifconfig.stdout -match '(?m)^\s*status:\s*active\s*$'

    $networkSetup = Invoke-NativeCapture -FileName "/usr/sbin/networksetup" -Arguments @("-listallhardwareports")
    Assert-True -Condition ($networkSetup.exitCode -eq 0) -Message "networksetup could not enumerate hardware ports."
    $hardwareMatches = [regex]::Matches(
        $networkSetup.stdout,
        '(?ms)^Hardware Port:\s*(?<port>[^\r\n]+)\r?\nDevice:\s*(?<device>[^\r\n]+)')
    $hardwarePort = ""
    foreach ($match in $hardwareMatches) {
        if ($match.Groups['device'].Value.Trim() -ceq $InterfaceName) {
            Assert-True -Condition ([string]::IsNullOrWhiteSpace($hardwarePort)) -Message "Declared interface maps to multiple hardware ports."
            $hardwarePort = $match.Groups['port'].Value.Trim()
        }
    }
    $interfaceIsPhysical = -not [string]::IsNullOrWhiteSpace($hardwarePort) -and
        $hardwarePort -notmatch '(?i)bridge|vpn|bluetooth|loopback|tunnel'

    $route = Invoke-NativeCapture -FileName "/sbin/route" -Arguments @("-n", "get", $TargetAddress)
    Assert-True -Condition ($route.exitCode -eq 0) -Message "route could not resolve the numeric Windows target."
    $routeTarget = [regex]::Match($route.stdout, '(?m)^\s*route to:\s*(?<value>\d+(?:\.\d+){3})\s*$').Groups['value'].Value
    $routeInterface = [regex]::Match($route.stdout, '(?m)^\s*interface:\s*(?<value>\S+)\s*$').Groups['value'].Value
    $gatewayMatch = [regex]::Match($route.stdout, '(?m)^\s*gateway:\s*(?<value>\S+)\s*$')
    $routeGateway = if ($gatewayMatch.Success) { $gatewayMatch.Groups['value'].Value } else { "" }
    $routeIsDirect = -not $gatewayMatch.Success
    $bindingMaterial = "target=$routeTarget;interface=$routeInterface;source=$actualAddress;prefix=$actualPrefixLength;active=$interfaceActive;physical=$interfaceIsPhysical;hardware=$hardwarePort;gateway=$routeGateway"

    return [ordered]@{
        interfaceMatches = $true
        interfaceIsPhysical = [bool]$interfaceIsPhysical
        interfaceActive = [bool]$interfaceActive
        interfaceAddressMatches = ($actualAddress -ceq $SourceAddress)
        interfacePrefixMatches = ($actualPrefixLength -eq $PrefixLength)
        routeInterfaceMatches = ($routeInterface -ceq $InterfaceName)
        routeDestinationMatches = ($routeTarget -ceq $TargetAddress)
        routeIsDirect = [bool]$routeIsDirect
        hardwarePort = $hardwarePort
        routeGateway = $routeGateway
        bindingDigest = Get-StringSha256 -Value $bindingMaterial
    }
}

function Test-MacNeighborOutput {
    param(
        [string]$Output,
        [string]$TargetAddress,
        [string]$InterfaceName
    )

    $leadingToken = "(?:\?|" + [regex]::Escape($TargetAddress) + ")"
    $canonicalMac = "(?:[0-9a-f]{2}:){5}[0-9a-f]{2}"
    $pattern = "(?im)^" + $leadingToken + "\s+\(" + [regex]::Escape($TargetAddress) + "\)\s+at\s+" +
        $canonicalMac + "\s+on\s+" + [regex]::Escape($InterfaceName) + "(?:\s|$)"
    return $Output -match $pattern
}

function Test-MacNeighborOnInterface {
    param(
        [string]$TargetAddress,
        [string]$InterfaceName
    )

    $arp = Invoke-NativeCapture -FileName "/usr/sbin/arp" -Arguments @("-n", $TargetAddress)
    if ($arp.exitCode -ne 0) {
        return $false
    }
    return Test-MacNeighborOutput -Output $arp.stdout -TargetAddress $TargetAddress -InterfaceName $InterfaceName
}

function Get-UnixFileSecurityObservation {
    param(
        [string]$Path,
        [bool]$RequireMode0600
    )

    Assert-True -Condition ([System.IO.Path]::IsPathRooted($Path)) -Message "Security-sensitive file path must be absolute."
    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "Security-sensitive file is missing."
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$item.LinkType)) -Message "Security-sensitive file must not be a symbolic link."

    $modeResult = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%Lp", $Path)
    Assert-True -Condition ($modeResult.exitCode -eq 0) -Message "stat could not inspect file mode."
    $ownerResult = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%Su", $Path)
    Assert-True -Condition ($ownerResult.exitCode -eq 0) -Message "stat could not inspect file owner."
    $mode = $modeResult.stdout.Trim()
    Assert-True -Condition ($mode -match '^[0-7]{3,4}$') -Message "Unexpected Unix file mode."
    $permissionDigits = $mode.Substring($mode.Length - 3)
    $groupDigit = [int]::Parse($permissionDigits.Substring(1, 1))
    $otherDigit = [int]::Parse($permissionDigits.Substring(2, 1))
    $ownerMatches = $ownerResult.stdout.Trim() -ceq [Environment]::UserName
    $ownerSafe = $ownerMatches -and (($groupDigit -band 2) -eq 0) -and (($otherDigit -band 2) -eq 0)
    if ($RequireMode0600) {
        $ownerSafe = $ownerMatches -and $permissionDigits -ceq "600"
    }
    return [ordered]@{
        ownerSafe = [bool]$ownerSafe
        mode = $permissionDigits
        owner = $ownerResult.stdout.Trim()
    }
}

function Get-MacDirectoryChainSnapshot {
    param(
        [string]$LeafPath,
        [string]$TrustedRoot = ""
    )

    $profileRoot = if ([string]::IsNullOrWhiteSpace($TrustedRoot)) {
        [System.IO.Path]::GetFullPath([Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    }
    else {
        [System.IO.Path]::GetFullPath($TrustedRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    }
    $resolvedLeaf = [System.IO.Path]::GetFullPath($LeafPath)
    Assert-True -Condition ($resolvedLeaf.StartsWith($profileRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)) -Message "Protected Mac path must remain under the current user profile."
    $current = Split-Path -Parent $resolvedLeaf
    Assert-True -Condition (Test-Path -LiteralPath $current -PathType Container) -Message "Protected Mac path parent directory is missing."
    $records = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force
        Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$item.LinkType)) -Message "Protected Mac path parent chain contains a symbolic link."
        $stat = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%d:%i:%Lp:%Su", $current)
        Assert-True -Condition ($stat.exitCode -eq 0) -Message "stat failed for a protected Mac parent directory."
        $parts = @($stat.stdout.Trim() -split ':')
        Assert-True -Condition ($parts.Count -eq 4 -and $parts[2] -match '^[0-7]{3,4}$') -Message "Protected Mac parent stat output is malformed."
        $mode = $parts[2].Substring($parts[2].Length - 3)
        $groupDigit = [int]::Parse($mode.Substring(1, 1))
        $otherDigit = [int]::Parse($mode.Substring(2, 1))
        Assert-True -Condition ($parts[3] -ceq [Environment]::UserName) -Message "Protected Mac parent directory is not owned by the current user."
        Assert-True -Condition (($groupDigit -band 2) -eq 0 -and ($otherDigit -band 2) -eq 0) -Message "Protected Mac parent directory is group- or world-writable."
        $relative = if ($current -ceq $profileRoot) { "." } else { $current.Substring($profileRoot.Length + 1) }
        $records.Add($relative + ":" + ($parts[0..2] -join ':'))
        if ($current -ceq $profileRoot) { break }
        $parent = Split-Path -Parent $current
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($parent) -and $parent.Length -lt $current.Length) -Message "Protected Mac parent chain escaped the user profile."
        $current = $parent
    }
    return [ordered]@{
        safe = $true
        digest = Get-StringSha256 -Value ($records -join "`n")
        depth = $records.Count
    }
}

function Get-BoundFileSnapshot {
    param(
        [string]$Path,
        [bool]$RequireMode0600,
        [string]$TrustedRoot = ""
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $security = Get-UnixFileSecurityObservation -Path $resolved -RequireMode0600 $RequireMode0600
    Assert-True -Condition ([bool]$security.ownerSafe) -Message "Bound file owner or permissions are unsafe."
    $parentChain = Get-MacDirectoryChainSnapshot -LeafPath $resolved -TrustedRoot $TrustedRoot
    $stat = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%d:%i:%m:%c:%z", $resolved)
    Assert-True -Condition ($stat.exitCode -eq 0 -and $stat.stdout.Trim() -match '^\d+:\d+:\d+:\d+:\d+$') -Message "Bound file stat output is malformed."
    $contentSha256 = Get-FileSha256 -Path $resolved
    $snapshotMaterial = "content=$contentSha256;stat=$($stat.stdout.Trim());mode=$($security.mode);owner=$($security.owner);parents=$($parentChain.digest)"
    return [ordered]@{
        path = $resolved
        contentSha256 = $contentSha256
        statIdentity = $stat.stdout.Trim()
        mode = $security.mode
        owner = $security.owner
        parentChainDigest = $parentChain.digest
        snapshotDigest = Get-StringSha256 -Value $snapshotMaterial
    }
}

function Test-BoundFileSnapshotMatch {
    param(
        $Before,
        $After
    )

    return [string]$Before.path -ceq [string]$After.path -and
        [string]$Before.contentSha256 -ceq [string]$After.contentSha256 -and
        [string]$Before.statIdentity -ceq [string]$After.statIdentity -and
        [string]$Before.mode -ceq [string]$After.mode -and
        [string]$Before.owner -ceq [string]$After.owner -and
        [string]$Before.parentChainDigest -ceq [string]$After.parentChainDigest -and
        [string]$Before.snapshotDigest -ceq [string]$After.snapshotDigest
}

function Get-MacEvidenceTargetSnapshot {
    param(
        [string]$Path,
        [bool]$OwnerOnly
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $parentChain = Get-MacDirectoryChainSnapshot -LeafPath $resolved
    if (Test-Path -LiteralPath $resolved) {
        $security = Get-UnixFileSecurityObservation -Path $resolved -RequireMode0600 $OwnerOnly
        Assert-True -Condition ([bool]$security.ownerSafe) -Message "Existing evidence target owner or permissions are unsafe."
    }
    return [ordered]@{
        path = $resolved
        parentChainDigest = $parentChain.digest
    }
}

function Get-AppleToolManifestSnapshot {
    param()

    $paths = @(
        "/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/bin/uname", "/sbin/ifconfig",
        "/usr/sbin/networksetup", "/sbin/route", "/usr/sbin/arp", "/usr/bin/stat",
        "/bin/chmod", "/usr/bin/codesign"
    )
    $records = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Required Apple system tool is missing."
        Assert-NoReparsePathChain -Path $path
        $toolParent = Split-Path -Parent $path
        while (-not [string]::IsNullOrWhiteSpace($toolParent)) {
            $parentStat = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%Su:%Sg:%Lp", $toolParent)
            Assert-True -Condition ($parentStat.exitCode -eq 0) -Message "Unable to inspect an Apple system tool parent directory."
            $parentParts = @($parentStat.stdout.Trim() -split ':')
            Assert-True -Condition ($parentParts.Count -eq 3 -and $parentParts[0] -ceq "root" -and $parentParts[1] -ceq "wheel" -and $parentParts[2] -match '^[0-7]{3,4}$') -Message "Apple system tool parent owner, group, or mode is unexpected."
            $parentMode = $parentParts[2].Substring($parentParts[2].Length - 3)
            Assert-True -Condition (([int]::Parse($parentMode.Substring(1, 1)) -band 2) -eq 0 -and
                ([int]::Parse($parentMode.Substring(2, 1)) -band 2) -eq 0) -Message "Apple system tool parent is group- or world-writable."
            if ($toolParent -ceq "/") { break }
            $toolParent = Split-Path -Parent $toolParent
            if ([string]::IsNullOrWhiteSpace($toolParent)) { $toolParent = "/" }
        }
        $stat = Invoke-NativeCapture -FileName "/usr/bin/stat" -Arguments @("-f", "%Su:%Sg:%Lp:%d:%i", $path)
        Assert-True -Condition ($stat.exitCode -eq 0) -Message "Unable to inspect an Apple system tool."
        $parts = @($stat.stdout.Trim() -split ':')
        Assert-True -Condition ($parts.Count -eq 5 -and $parts[0] -ceq "root" -and $parts[1] -ceq "wheel" -and $parts[2] -match '^[0-7]{3,4}$') -Message "Apple system tool owner, group, or mode is unexpected."
        $mode = $parts[2].Substring($parts[2].Length - 3)
        $groupDigit = [int]::Parse($mode.Substring(1, 1))
        $otherDigit = [int]::Parse($mode.Substring(2, 1))
        Assert-True -Condition (($groupDigit -band 2) -eq 0 -and ($otherDigit -band 2) -eq 0) -Message "Apple system tool is group- or world-writable."
        $verify = Invoke-NativeCapture -FileName "/usr/bin/codesign" -Arguments @("--verify", "--strict", "--verbose=2", $path)
        Assert-True -Condition ($verify.exitCode -eq 0) -Message "Apple system tool code-signature verification failed."
        $details = Invoke-NativeCapture -FileName "/usr/bin/codesign" -Arguments @("-dv", "--verbose=4", $path)
        $detailText = $details.stdout + $details.stderr
        Assert-True -Condition ($details.exitCode -eq 0 -and $detailText -match '(?m)^Identifier=com\.apple\.' -and $detailText -match '(?m)^Authority=Apple Root CA\s*$') -Message "Apple system tool is not rooted in the expected Apple signing authority."
        $records.Add($path + ":" + ($parts[2..4] -join ':') + ":" + (Get-FileSha256 -Path $path))
    }
    return [ordered]@{
        count = $paths.Count
        digest = Get-StringSha256 -Value ($records -join "`n")
    }
}

function Get-ProtectedMacOutputSetSnapshot {
    param(
        [string]$PrivatePath,
        [string]$PublicPath,
        [string[]]$ProtectedPaths
    )

    $privateFull = [System.IO.Path]::GetFullPath($PrivatePath)
    $publicFull = [System.IO.Path]::GetFullPath($PublicPath)
    Assert-True -Condition (-not $privateFull.Equals($publicFull, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Private and public evidence targets must be distinct."
    $profileRoot = [System.IO.Path]::GetFullPath([Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $sshRoot = [System.IO.Path]::GetFullPath((Join-Path $profileRoot ".ssh"))
    foreach ($output in @($privateFull, $publicFull)) {
        Assert-True -Condition ($output.StartsWith($profileRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)) -Message "Evidence output must remain under the current user profile."
        Assert-True -Condition (-not $output.StartsWith($sshRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Evidence output must not be placed inside the SSH authority directory."
        Assert-True -Condition (-not (Test-Path -LiteralPath $output)) -Message "Evidence output must be a new file; overwrite is not allowed."
        foreach ($protected in $ProtectedPaths) {
            $protectedFull = [System.IO.Path]::GetFullPath($protected)
            Assert-True -Condition (-not $output.Equals($protectedFull, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Evidence output aliases a protected input or source path."
        }
    }
    $privateParent = Get-MacEvidenceTargetSnapshot -Path $privateFull -OwnerOnly $true
    $publicParent = Get-MacEvidenceTargetSnapshot -Path $publicFull -OwnerOnly $false
    return [ordered]@{
        privatePath = $privateFull
        publicPath = $publicFull
        privateParentChainDigest = $privateParent.parentChainDigest
        publicParentChainDigest = $publicParent.parentChainDigest
    }
}

function Assert-NewWindowsServerAuditOutputSafe {
    param(
        [string]$Path,
        [string[]]$ProtectedPaths
    )

    Assert-True -Condition ([System.IO.Path]::IsPathRooted($Path)) -Message "Windows server-audit output path must be absolute."
    $resolved = [System.IO.Path]::GetFullPath($Path)
    Assert-True -Condition (-not (Test-Path -LiteralPath $resolved)) -Message "Windows server-audit output must be a new file."
    $programDataSsh = [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData "ssh"))
    $windowsRoot = [System.IO.Path]::GetFullPath($env:WINDIR)
    Assert-True -Condition (-not $resolved.StartsWith($programDataSsh + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Server-audit output must not enter the OpenSSH authority directory."
    Assert-True -Condition (-not $resolved.StartsWith($windowsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Server-audit output must not enter the Windows system directory."
    Assert-True -Condition ($resolved -notmatch '(?i)[\\/]\.ssh[\\/]') -Message "Server-audit output must not enter an account SSH authority directory."
    foreach ($protected in $ProtectedPaths) {
        $protectedFull = [System.IO.Path]::GetFullPath($protected)
        Assert-True -Condition (-not $resolved.Equals($protectedFull, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Server-audit output aliases a protected source path."
    }
    Assert-NoReparsePathChain -Path $resolved
}

function Get-KeyListing {
    param(
        [string]$Path,
        [string]$KeygenPath
    )

    $result = Invoke-NativeCapture -FileName $KeygenPath -Arguments @("-lf", $Path, "-E", "sha256")
    Assert-True -Condition ($result.exitCode -eq 0) -Message "ssh-keygen could not inspect a required key file."
    $lines = @([regex]::Split($result.stdout.Trim(), '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True -Condition ($lines.Count -eq 1) -Message "Expected exactly one key fingerprint record."
    $digestMatch = [regex]::Match($lines[0], 'SHA256:[A-Za-z0-9+/]+={0,2}')
    $algorithmMatch = [regex]::Match($lines[0], '\((?<value>[^)]+)\)\s*$')
    Assert-True -Condition ($digestMatch.Success -and $algorithmMatch.Success) -Message "ssh-keygen output is missing an algorithm or SHA256 digest."
    $algorithm = switch ($algorithmMatch.Groups['value'].Value.ToUpperInvariant()) {
        "ED25519" { "ssh-ed25519" }
        default { $algorithmMatch.Groups['value'].Value.ToLowerInvariant() }
    }
    return [ordered]@{
        digest = $digestMatch.Value
        algorithm = $algorithm
    }
}

function Get-HostPinObservation {
    param(
        [string]$Path,
        [string]$TargetAddress,
        [int]$TargetPort,
        [string]$ExpectedDigest,
        [string]$KeygenPath
    )

    $security = Get-UnixFileSecurityObservation -Path $Path -RequireMode0600 $false
    $profileRoot = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    $sshRoot = [System.IO.Path]::GetFullPath((Join-Path $profileRoot ".ssh"))
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $pinDurable = $resolved.StartsWith($sshRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)
    $activeRecords = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        $activeRecords.Add($trimmed)
    }
    $expectedHostToken = if ($TargetPort -eq 22) { $TargetAddress } else { "[$TargetAddress]:$TargetPort" }
    $pinTargetMatches = $false
    $pinAlgorithm = ""
    if ($activeRecords.Count -eq 1) {
        $parts = @($activeRecords[0] -split '\s+')
        if ($parts.Count -ge 3) {
            $pinTargetMatches = $parts[0] -ceq $expectedHostToken -and -not $parts[0].Contains(",")
            $pinAlgorithm = $parts[1]
            Assert-True -Condition ($parts[2] -match '^[A-Za-z0-9+/]+={0,2}$') -Message "Pinned host-key record is malformed."
        }
    }
    $listing = Get-KeyListing -Path $Path -KeygenPath $KeygenPath
    return [ordered]@{
        pinDurable = [bool]$pinDurable
        pinOwnerSafe = [bool]$security.ownerSafe
        pinActiveRecordCount = $activeRecords.Count
        pinTargetMatches = [bool]$pinTargetMatches
        pinAlgorithm = $pinAlgorithm
        pinDigestMatches = ($listing.digest -ceq $ExpectedDigest)
        actualDigest = $listing.digest
        mode = $security.mode
        owner = $security.owner
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)
    Assert-True -Condition ($Value.IndexOf([char]0) -lt 0) -Message "Remote audit value contains a null byte."
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-RemoteSessionAuditScript {
    param(
        [string]$AccountName,
        [string]$AccountSid,
        [string]$ClientAddress,
        [string]$ServerAddress,
        [int]$SshPort,
        [string]$ExpectedPowerShellSha256
    )

    $template = @'
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$expectedAccount = __ACCOUNT__
$expectedAccountSid = __ACCOUNT_SID__
$expectedClientAddress = __CLIENT_ADDRESS__
$expectedServerAddress = __SERVER_ADDRESS__
$expectedPort = __PORT__
$expectedPowerShellSha256 = __POWERSHELL_SHA256__
if ($env:OS -ne "Windows_NT") { throw "Remote session audit requires Windows." }
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
$processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$stream = [System.IO.File]::OpenRead($processPath)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $processSha256 = -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") })
}
finally {
    $sha256.Dispose()
    $stream.Dispose()
}
$connectionParts = @($env:SSH_CONNECTION -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$connectionMatches = $connectionParts.Count -eq 4 -and
    $connectionParts[0] -ceq $expectedClientAddress -and
    $connectionParts[2] -ceq $expectedServerAddress -and
    $connectionParts[3] -ceq [string]$expectedPort
$result = [ordered]@{
    remoteSchema = "skybridge-windows-lan-ssh-session-audit-v1"
    remoteWindows = $true
    remoteAccountEnabled = $true
    remoteAccountNameMatches = [string]$env:USERNAME -ceq $expectedAccount
    remoteAccountSidMatches = $identity.User.Value -ceq $expectedAccountSid
    remoteAccountIsAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    remotePowerShellPathMatches = [System.IO.Path]::GetFullPath($processPath).Equals("C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", [System.StringComparison]::OrdinalIgnoreCase)
    remotePowerShellDigestMatches = $processSha256 -ceq $expectedPowerShellSha256
    remoteSshConnectionMatches = [bool]$connectionMatches
}
Write-Output ("SKYBRIDGE_LAN_SSH_EVIDENCE_V1:" + ($result | ConvertTo-Json -Compress -Depth 4))
'@
    $replacements = [ordered]@{
        "__ACCOUNT__" = ConvertTo-PowerShellSingleQuotedLiteral -Value $AccountName
        "__ACCOUNT_SID__" = ConvertTo-PowerShellSingleQuotedLiteral -Value $AccountSid
        "__CLIENT_ADDRESS__" = ConvertTo-PowerShellSingleQuotedLiteral -Value $ClientAddress
        "__SERVER_ADDRESS__" = ConvertTo-PowerShellSingleQuotedLiteral -Value $ServerAddress
        "__PORT__" = [string]$SshPort
        "__POWERSHELL_SHA256__" = ConvertTo-PowerShellSingleQuotedLiteral -Value $ExpectedPowerShellSha256
    }
    foreach ($replacement in $replacements.GetEnumerator()) {
        $template = $template.Replace([string]$replacement.Key, [string]$replacement.Value)
    }
    return $template
}

function Merge-ExactObservationFields {
    param(
        [System.Collections.IDictionary]$Destination,
        $Source,
        [string[]]$AllowedNames,
        [string]$Label
    )

    $properties = @($Source.PSObject.Properties)
    Assert-True -Condition ($properties.Count -eq $AllowedNames.Count) -Message "$Label returned an unexpected field count."
    foreach ($property in $properties) {
        Assert-True -Condition ($AllowedNames -ccontains $property.Name) -Message "$Label returned an unexpected field."
    }
    foreach ($name in $AllowedNames) {
        $property = $Source.PSObject.Properties[$name]
        Assert-True -Condition ($null -ne $property) -Message "$Label omitted a required field."
        $Destination[$name] = $property.Value
    }
}

function Get-RegistrationAuditAssessment {
    param(
        $Artifact,
        [string]$ExpectedLanAccount,
        [string]$ExpectedRelayAccount,
        [string]$ExpectedLanSid,
        [string]$ExpectedRelaySid,
        [string]$ExpectedWindowsAddress,
        [string]$ExpectedMacAddress,
        [int]$ExpectedPrefixLength,
        [string]$ExpectedInterfaceAlias,
        [int]$ExpectedPort,
        [string]$ExpectedFirewallRuleName,
        [string]$ExpectedHostDigest,
        [string]$ExpectedClientDigest,
        [string]$ExpectedProvenance
    )

    $requiredBooleanNames = @(
        "candidateConfigValid", "lanEffectivePolicyValid", "relayEffectivePolicyValid",
        "hostPrivateKeyAclValid", "lanAccountNonAdministrator", "relayAccountNonAdministrator",
        "managedFirewallExact", "preflightPassed", "finalPolicyInstalled", "finalListenerSetExact",
        "finalAuthorizedKeyExact", "finalAclExact"
    )
    $booleansExact = $true
    foreach ($name in $requiredBooleanNames) {
        $value = Get-ObservationValue -Observation $Artifact -Name $name
        $booleansExact = $booleansExact -and $value -is [bool] -and $value
    }
    $acceptedValue = Get-ObservationValue -Observation $Artifact -Name "accepted"
    $changedValue = Get-ObservationValue -Observation $Artifact -Name "changed"
    $rolledBackValue = Get-ObservationValue -Observation $Artifact -Name "rolledBack"
    $lifecycleFieldsExact =
        [string](Get-ObservationValue -Observation $Artifact -Name "schema") -ceq "skybridge-windows-lan-ssh-registration-v1" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "evidenceClass") -ceq "private-provisioning" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "mode") -ceq "verify-only" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "outcome") -ceq "succeeded" -and
        $acceptedValue -is [bool] -and -not $acceptedValue -and
        $changedValue -is [bool] -and -not $changedValue -and
        $rolledBackValue -is [bool] -and -not $rolledBackValue
    $bindingExact =
        [string](Get-ObservationValue -Observation $Artifact -Name "lanAccount") -ceq $ExpectedLanAccount -and
        [string](Get-ObservationValue -Observation $Artifact -Name "relayAccount") -ceq $ExpectedRelayAccount -and
        [string](Get-ObservationValue -Observation $Artifact -Name "lanAccountSid") -ceq $ExpectedLanSid -and
        [string](Get-ObservationValue -Observation $Artifact -Name "relayAccountSid") -ceq $ExpectedRelaySid -and
        [string](Get-ObservationValue -Observation $Artifact -Name "windowsLanAddress") -ceq $ExpectedWindowsAddress -and
        [string](Get-ObservationValue -Observation $Artifact -Name "macLanAddress") -ceq $ExpectedMacAddress -and
        [int](Get-ObservationValue -Observation $Artifact -Name "prefixLength") -eq $ExpectedPrefixLength -and
        [string](Get-ObservationValue -Observation $Artifact -Name "interfaceAlias") -ceq $ExpectedInterfaceAlias -and
        [int](Get-ObservationValue -Observation $Artifact -Name "port") -eq $ExpectedPort -and
        [string](Get-ObservationValue -Observation $Artifact -Name "firewallRuleName") -ceq $ExpectedFirewallRuleName
    Assert-True -Condition ($ExpectedPort -eq 22) -Message "Registration audit only supports port 22."
    $expectedHost = [string](Get-ObservationValue -Observation $Artifact -Name "expectedHostKeyFingerprint")
    $actualHost = [string](Get-ObservationValue -Observation $Artifact -Name "actualHostKeyFingerprint")
    $expectedClient = [string](Get-ObservationValue -Observation $Artifact -Name "expectedDirectPublicKeyFingerprint")
    $actualClient = [string](Get-ObservationValue -Observation $Artifact -Name "actualDirectPublicKeyFingerprint")
    $keysExact = $expectedHost -ceq $ExpectedHostDigest -and $actualHost -ceq $ExpectedHostDigest -and
        $expectedClient -ceq $ExpectedClientDigest -and $actualClient -ceq $ExpectedClientDigest -and
        [string](Get-ObservationValue -Observation $Artifact -Name "directPublicKeyProvenanceRef") -ceq $ExpectedProvenance
    $listenerAddresses = @(Get-ObservationValue -Observation $Artifact -Name "listenerAddresses")
    $runtimeExact =
        [string](Get-ObservationValue -Observation $Artifact -Name "sshdServiceState") -ceq "Running" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "sshdServiceStartMode") -ceq "Auto" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "sshdServiceStartName") -ceq "LocalSystem" -and
        [int](Get-ObservationValue -Observation $Artifact -Name "sshdServiceProcessId") -gt 0 -and
        [string](Get-ObservationValue -Observation $Artifact -Name "sshdSignatureStatus") -ceq "Valid" -and
        [string](Get-ObservationValue -Observation $Artifact -Name "sshdSignerSubject") -match '(?i)\bMicrosoft\b' -and
        $listenerAddresses.Count -eq 2 -and $listenerAddresses -contains "127.0.0.1" -and
        $listenerAddresses -contains $ExpectedWindowsAddress
    $hashFieldsExact = $true
    foreach ($name in @("sshdExecutableSha256", "sshdConfigSha256", "authorizedKeysSha256")) {
        $hashFieldsExact = $hashFieldsExact -and [string](Get-ObservationValue -Observation $Artifact -Name $name) -match '^[a-f0-9]{64}$'
    }
    $firewallConflicts = @(Get-ObservationValue -Observation $Artifact -Name "firewallConflicts")
    $firewallExact = [bool](Get-ObservationValue -Observation $Artifact -Name "managedFirewallExact") -and $firewallConflicts.Count -eq 0
    $generatedAt = [DateTimeOffset]::MinValue
    $generatedAtValid = [DateTimeOffset]::TryParse(
        [string](Get-ObservationValue -Observation $Artifact -Name "generatedAtUtc"),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$generatedAt)
    $authenticationPolicyExact = [bool](Get-ObservationValue -Observation $Artifact -Name "candidateConfigValid") -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "lanEffectivePolicyValid") -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "relayEffectivePolicyValid") -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "finalPolicyInstalled")
    $keysAndAclExact = $keysExact -and $hashFieldsExact -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "hostPrivateKeyAclValid") -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "finalAuthorizedKeyExact") -and
        [bool](Get-ObservationValue -Observation $Artifact -Name "finalAclExact")

    return [ordered]@{
        lifecycleFieldsExact = [bool]$lifecycleFieldsExact
        bindingExact = [bool]$bindingExact
        runtimeExact = [bool]$runtimeExact
        keysAndAclExact = [bool]$keysAndAclExact
        firewallExact = [bool]$firewallExact
        authenticationPolicyExact = [bool]$authenticationPolicyExact
        booleansExact = [bool]$booleansExact
        generatedAtValid = [bool]$generatedAtValid
        generatedAtUtc = $generatedAt
        passed = [bool]($lifecycleFieldsExact -and $bindingExact -and $runtimeExact -and $keysAndAclExact -and
            $firewallExact -and $authenticationPolicyExact -and $booleansExact -and $generatedAtValid)
    }
}

function Merge-Observation {
    param(
        [System.Collections.IDictionary]$Base,
        $Additional
    )

    if ($Additional -is [System.Collections.IDictionary]) {
        foreach ($entry in $Additional.GetEnumerator()) {
            $Base[[string]$entry.Key] = $entry.Value
        }
        return
    }
    foreach ($property in $Additional.PSObject.Properties) {
        $Base[$property.Name] = $property.Value
    }
}

function Assert-BindingInputs {
    Assert-True -Condition ($WindowsAccountName -match '^[A-Za-z0-9._-]+$') -Message "WindowsAccountName contains unsupported characters."
    Assert-True -Condition ($RelayAccountName -match '^[A-Za-z0-9._-]+$' -and $RelayAccountName -cne $WindowsAccountName) -Message "RelayAccountName must be a distinct supported local account name."
    Assert-True -Condition ($ExpectedWindowsAccountSid -match '^S-\d-\d+(?:-\d+)+$') -Message "ExpectedWindowsAccountSid is malformed."
    Assert-True -Condition ($ExpectedRelayAccountSid -match '^S-\d-\d+(?:-\d+)+$' -and $ExpectedRelayAccountSid -cne $ExpectedWindowsAccountSid) -Message "ExpectedRelayAccountSid must be a distinct Windows SID."
    Assert-True -Condition ($WindowsLanInterfaceAlias -match '^[^\x00-\x1f\x7f]+$') -Message "WindowsLanInterfaceAlias is empty or contains control characters."
    Assert-True -Condition ($FirewallRuleName -match '^[A-Za-z0-9._-]+$') -Message "FirewallRuleName contains unsupported characters."
    Assert-True -Condition ($ExpectedIdentityKeyFingerprint -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "ExpectedIdentityKeyFingerprint is malformed."
    Assert-True -Condition ($ExpectedWindowsHostKeyFingerprint -match '^SHA256:[A-Za-z0-9+/]+={0,2}$') -Message "ExpectedWindowsHostKeyFingerprint is malformed."
    Assert-True -Condition ($LanPublicKeyProvenanceRef -match '^[A-Za-z0-9._:-]{1,128}$') -Message "LanPublicKeyProvenanceRef is malformed."
}

function Assert-MacLiveInputs {
    Assert-BindingInputs
    Assert-True -Condition ($MacLanInterface -match '^[A-Za-z0-9]+$') -Message "MacLanInterface contains unsupported characters."
    foreach ($requiredPath in @($IdentityFile, $KnownHostsPath)) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($requiredPath)) -Message "IdentityFile and KnownHostsPath are required in live mode."
        Assert-True -Condition ([System.IO.Path]::IsPathRooted($requiredPath)) -Message "IdentityFile and KnownHostsPath must be absolute."
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ServerAuditEvidencePath) -and [System.IO.Path]::IsPathRooted($ServerAuditEvidencePath)) -Message "ServerAuditEvidencePath must be an absolute path in live mode."
    Assert-True -Condition ($ExpectedServerAuditSha256 -match '^[a-fA-F0-9]{64}$') -Message "ExpectedServerAuditSha256 must be an independently supplied SHA-256 digest."
}

$resolvedPrivateEvidence = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PrivateEvidencePath)
Assert-True -Condition (-not ($ServerAudit -and -not [string]::IsNullOrWhiteSpace($FixturePath))) -Message "ServerAudit and FixturePath are mutually exclusive."
$mode = if ($ServerAudit) { "server-audit" } elseif ([string]::IsNullOrWhiteSpace($FixturePath)) { "live" } else { "fixture" }
$resolvedPublicEvidence = ""
if ($mode -ne "server-audit") {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($PublicEvidencePath)) -Message "PublicEvidencePath is required in live and fixture modes."
    $resolvedPublicEvidence = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PublicEvidencePath)
    Assert-True -Condition (-not [System.IO.Path]::GetFullPath($resolvedPrivateEvidence).Equals([System.IO.Path]::GetFullPath($resolvedPublicEvidence), [System.StringComparison]::Ordinal)) -Message "Private and public evidence paths must differ."
}

$sessionFieldNames = @(
    "remoteSchema", "remoteWindows", "remoteAccountEnabled", "remoteAccountNameMatches",
    "remoteAccountSidMatches", "remoteAccountIsAdministrator", "remotePowerShellPathMatches",
    "remotePowerShellDigestMatches", "remoteSshConnectionMatches"
)

if ($mode -eq "server-audit") {
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($PublicEvidencePath)) -Message "ServerAudit writes private evidence only; do not pass PublicEvidencePath."
    Assert-True -Condition ($env:OS -eq "Windows_NT") -Message "ServerAudit must run locally on Windows."
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-True -Condition $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) -Message "ServerAudit requires an elevated Windows PowerShell session."
    Assert-BindingInputs
    Assert-True -Condition ($LanAuthorizedPublicKey -match '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [\x20-\x7e]{1,256})?$') -Message "LanAuthorizedPublicKey must be one ED25519 public-key record."
    $canonicalWindowsAddress = ConvertTo-CanonicalIPv4 -Value $WindowsLanAddress -Name "WindowsLanAddress"
    $canonicalMacAddress = ConvertTo-CanonicalIPv4 -Value $MacLanAddress -Name "MacLanAddress"
    Assert-True -Condition ($canonicalWindowsAddress -ne $canonicalMacAddress) -Message "Windows and Mac LAN addresses must differ."
    Assert-True -Condition (Test-SameIPv4Prefix -Left $canonicalWindowsAddress -Right $canonicalMacAddress -PrefixLength $LanPrefixLength) -Message "Windows and Mac addresses are not in the declared LAN prefix."

    $registrationScriptPath = Join-Path $PSScriptRoot "register-windows-lan-ssh-access.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $registrationScriptPath -PathType Leaf) -Message "LAN SSH registration authority is missing."
    $windowsPowerShellPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    Assert-NewWindowsServerAuditOutputSafe -Path $resolvedPrivateEvidence -ProtectedPaths @(
        $PSCommandPath,
        $registrationScriptPath,
        $windowsPowerShellPath,
        "C:\ProgramData\ssh\sshd_config",
        "C:\ProgramData\ssh\ssh_host_ed25519_key",
        "C:\ProgramData\ssh\ssh_host_ed25519_key.pub",
        "C:\ProgramData\ssh\administrators_authorized_keys"
    )
    Assert-True -Condition (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf) -Message "Fixed Windows PowerShell executable is missing."
    Assert-NoReparsePathChain -Path $windowsPowerShellPath
    $windowsPowerShellSignature = Get-AuthenticodeSignature -LiteralPath $windowsPowerShellPath
    Assert-True -Condition ($windowsPowerShellSignature.Status -eq "Valid" -and
        $null -ne $windowsPowerShellSignature.SignerCertificate -and
        [string]$windowsPowerShellSignature.SignerCertificate.Subject -match '(?i)\bMicrosoft\b') -Message "Fixed Windows PowerShell executable is not validly signed by Microsoft."
    $windowsPowerShellSha256 = Get-FileSha256 -Path $windowsPowerShellPath
    $openSshRegistryPath = "HKLM:\SOFTWARE\OpenSSH"
    $openSshDefaultShell = "<built-in-cmd-default>"
    if (Test-Path -LiteralPath $openSshRegistryPath) {
        $openSshRegistry = Get-ItemProperty -Path $openSshRegistryPath -ErrorAction Stop
        $defaultShellProperty = $openSshRegistry.PSObject.Properties["DefaultShell"]
        if ($null -ne $defaultShellProperty -and -not [string]::IsNullOrWhiteSpace([string]$defaultShellProperty.Value)) {
            $openSshDefaultShell = [System.IO.Path]::GetFullPath([string]$defaultShellProperty.Value)
        }
    }
    Assert-True -Condition ($openSshDefaultShell -ceq "<built-in-cmd-default>" -or
        $openSshDefaultShell -ceq "C:\Windows\System32\cmd.exe") -Message "OpenSSH DefaultShell must be the built-in cmd default for the absolute PowerShell audit command."
    $registrationScriptCanonicalSha256 = Get-CanonicalTextFileSha256 -Path $registrationScriptPath
    $verifierScriptCanonicalSha256 = Get-CanonicalTextFileSha256 -Path $PSCommandPath
    $sourceManifestSha256 = Get-StringSha256 -Value ("registration=" + $registrationScriptCanonicalSha256 + ";verifier=" + $verifierScriptCanonicalSha256)
    $registrationEvidencePath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-lan-ssh-registration-audit-" + [Guid]::NewGuid().ToString("N") + ".json")
    $invocationStartedAt = [DateTimeOffset]::UtcNow
    try {
        & $registrationScriptPath `
            -VerifyOnly `
            -LanAccountName $WindowsAccountName `
            -RelayAccountName $RelayAccountName `
            -WindowsLanAddress $canonicalWindowsAddress `
            -MacLanAddress $canonicalMacAddress `
            -LanPrefixLength $LanPrefixLength `
            -LanInterfaceAlias $WindowsLanInterfaceAlias `
            -LanAuthorizedPublicKey $LanAuthorizedPublicKey `
            -ExpectedLanPublicKeyFingerprint $ExpectedIdentityKeyFingerprint `
            -LanPublicKeyProvenanceRef $LanPublicKeyProvenanceRef `
            -ExpectedWindowsHostKeyFingerprint $ExpectedWindowsHostKeyFingerprint `
            -Port $Port `
            -FirewallRuleName $FirewallRuleName `
            -EvidencePath $registrationEvidencePath | Out-Null
        Assert-True -Condition (Test-Path -LiteralPath $registrationEvidencePath -PathType Leaf) -Message "Registration VerifyOnly did not write its private audit artifact."
        $registrationArtifactText = Get-Content -Raw -LiteralPath $registrationEvidencePath
        $registrationArtifactSha256 = Get-FileSha256 -Path $registrationEvidencePath
        $registrationArtifact = $registrationArtifactText | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $registrationEvidencePath) {
            Remove-Item -LiteralPath $registrationEvidencePath -Force
        }
    }
    $invocationFinishedAt = [DateTimeOffset]::UtcNow
    $registrationAssessment = Get-RegistrationAuditAssessment -Artifact $registrationArtifact `
        -ExpectedLanAccount $WindowsAccountName -ExpectedRelayAccount $RelayAccountName `
        -ExpectedLanSid $ExpectedWindowsAccountSid -ExpectedRelaySid $ExpectedRelayAccountSid `
        -ExpectedWindowsAddress $canonicalWindowsAddress `
        -ExpectedMacAddress $canonicalMacAddress -ExpectedPrefixLength $LanPrefixLength `
        -ExpectedInterfaceAlias $WindowsLanInterfaceAlias -ExpectedPort $Port -ExpectedFirewallRuleName $FirewallRuleName `
        -ExpectedHostDigest $ExpectedWindowsHostKeyFingerprint -ExpectedClientDigest $ExpectedIdentityKeyFingerprint `
        -ExpectedProvenance $LanPublicKeyProvenanceRef
    $registrationWithinInvocation = $registrationAssessment.generatedAtValid -and
        $registrationAssessment.generatedAtUtc -ge $invocationStartedAt.AddSeconds(-1) -and
        $registrationAssessment.generatedAtUtc -le $invocationFinishedAt.AddSeconds(1)
    $serverAuditPassed = [bool]$registrationAssessment.passed -and $registrationWithinInvocation
    $generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    $serverEvidence = [ordered]@{
        schema = $serverAuditSchema
        evidenceClass = "private-server-audit"
        generatedAtUtc = $generatedAtUtc
        nonce = [Guid]::NewGuid().ToString("D")
        invocationStartedAtUtc = $invocationStartedAt.ToString("o")
        invocationFinishedAtUtc = $invocationFinishedAt.ToString("o")
        registrationWithinInvocation = [bool]$registrationWithinInvocation
        registrationScriptCanonicalSha256 = $registrationScriptCanonicalSha256
        verifierScriptCanonicalSha256 = $verifierScriptCanonicalSha256
        sourceManifestSha256 = $sourceManifestSha256
        windowsPowerShellPath = $windowsPowerShellPath
        windowsPowerShellSha256 = $windowsPowerShellSha256
        windowsPowerShellSignatureStatus = [string]$windowsPowerShellSignature.Status
        windowsPowerShellSignerSubject = [string]$windowsPowerShellSignature.SignerCertificate.Subject
        openSshDefaultShell = $openSshDefaultShell
        registrationArtifactSha256 = $registrationArtifactSha256
        binding = [ordered]@{
            windowsLanAddress = $canonicalWindowsAddress
            macLanAddress = $canonicalMacAddress
            prefixLength = $LanPrefixLength
            windowsLanInterfaceAlias = $WindowsLanInterfaceAlias
            windowsAccountName = $WindowsAccountName
            windowsAccountSid = $ExpectedWindowsAccountSid
            relayAccountName = $RelayAccountName
            relayAccountSid = $ExpectedRelayAccountSid
            port = $Port
            firewallRuleName = $FirewallRuleName
            windowsHostKeyFingerprint = $ExpectedWindowsHostKeyFingerprint
            directClientKeyFingerprint = $ExpectedIdentityKeyFingerprint
            directClientKeyProvenanceRef = $LanPublicKeyProvenanceRef
        }
        registrationArtifact = $registrationArtifact
        checks = [ordered]@{
            registrationLifecycleExact = [bool]$registrationAssessment.lifecycleFieldsExact
            registrationBindingExact = [bool]$registrationAssessment.bindingExact
            serverRuntimeExact = [bool]$registrationAssessment.runtimeExact
            serverKeysAndAclExact = [bool]$registrationAssessment.keysAndAclExact
            serverFirewallExact = [bool]$registrationAssessment.firewallExact
            serverAuthenticationPolicyExact = [bool]$registrationAssessment.authenticationPolicyExact
            registrationBooleansExact = [bool]$registrationAssessment.booleansExact
            registrationWithinInvocation = [bool]$registrationWithinInvocation
        }
        serverAuditPassed = [bool]$serverAuditPassed
        accepted = $false
        notNetworkSessionProof = $true
        notProductTransportProof = $true
    }
    $serverPath = Write-JsonAtomic -Value $serverEvidence -Path $resolvedPrivateEvidence -OwnerOnly $true
    $serverDigest = Get-FileSha256 -Path $serverPath
    Write-Output "windows-lan-ssh-lifecycle: mode=server-audit serverAuditPassed=$serverAuditPassed accepted=false"
    Write-Output "windows-lan-ssh-lifecycle: private-evidence-written=true"
    Write-Output "windows-lan-ssh-lifecycle: server-audit-sha256=$serverDigest"
    if (-not $serverAuditPassed) {
        throw "Windows LAN SSH server audit did not pass the registration authority contract."
    }
    return
}
$observation = [ordered]@{}
$sensitive = [ordered]@{}

if ($mode -eq "fixture") {
    Assert-True -Condition (Test-Path -LiteralPath $FixturePath -PathType Leaf) -Message "FixturePath does not exist."
    $fixture = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
    Assert-True -Condition ([string]$fixture.schema -ceq $fixtureSchema) -Message "Fixture schema is not supported."
    Assert-True -Condition ($null -ne $fixture.observation) -Message "Fixture observation is missing."
    Merge-Observation -Base $observation -Additional $fixture.observation
    if ($null -ne $fixture.PSObject.Properties["sensitive"]) {
        Merge-Observation -Base $sensitive -Additional $fixture.sensitive
    }
}
else {
    Assert-MacLiveInputs
    $canonicalWindowsAddress = ConvertTo-CanonicalIPv4 -Value $WindowsLanAddress -Name "WindowsLanAddress"
    $canonicalMacAddress = ConvertTo-CanonicalIPv4 -Value $MacLanAddress -Name "MacLanAddress"
    Assert-True -Condition ($canonicalWindowsAddress -ne $canonicalMacAddress) -Message "Windows and Mac LAN addresses must differ."
    $samePrefix = Test-SameIPv4Prefix -Left $canonicalWindowsAddress -Right $canonicalMacAddress -PrefixLength $LanPrefixLength

    Assert-True -Condition ($SshPath -ceq "/usr/bin/ssh" -and $SshKeygenPath -ceq "/usr/bin/ssh-keygen") -Message "Live mode requires the fixed Apple SSH and ssh-keygen binaries."
    $identityFullPath = [System.IO.Path]::GetFullPath($IdentityFile)
    $knownHostsFullPath = [System.IO.Path]::GetFullPath($KnownHostsPath)
    $serverAuditFullPath = [System.IO.Path]::GetFullPath($ServerAuditEvidencePath)
    $registrationScriptPath = Join-Path $PSScriptRoot "register-windows-lan-ssh-access.ps1"
    $appleToolPaths = @(
        "/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/bin/uname", "/sbin/ifconfig",
        "/usr/sbin/networksetup", "/sbin/route", "/usr/sbin/arp", "/usr/bin/stat",
        "/bin/chmod", "/usr/bin/codesign"
    )
    $appleToolManifestBefore = Get-AppleToolManifestSnapshot
    $protectedOutputPaths = @($identityFullPath, $knownHostsFullPath, $serverAuditFullPath, $PSCommandPath, $registrationScriptPath) + $appleToolPaths
    $outputSetSnapshot = Get-ProtectedMacOutputSetSnapshot -PrivatePath $resolvedPrivateEvidence -PublicPath $resolvedPublicEvidence `
        -ProtectedPaths $protectedOutputPaths
    $privateFullPath = $outputSetSnapshot.privatePath
    $publicFullPath = $outputSetSnapshot.publicPath

    $serverAuditBefore = Get-BoundFileSnapshot -Path $serverAuditFullPath -RequireMode0600 $true
    $verifierSourceBefore = Get-BoundFileSnapshot -Path $PSCommandPath -RequireMode0600 $false
    $registrationSourceBefore = Get-BoundFileSnapshot -Path $registrationScriptPath -RequireMode0600 $false
    $actualServerAuditDigest = $serverAuditBefore.contentSha256
    $serverAuditOwnerSafe = $true
    $serverAuditArtifact = Get-Content -Raw -LiteralPath $serverAuditFullPath | ConvertFrom-Json
    $serverSchemaExact = [string]$serverAuditArtifact.schema -ceq $serverAuditSchema -and
        [string]$serverAuditArtifact.evidenceClass -ceq "private-server-audit"
    $serverDigestMatches = $actualServerAuditDigest -ceq $ExpectedServerAuditSha256.ToLowerInvariant()
    $serverGenerated = [DateTimeOffset]::MinValue
    $serverTimeParsed = [DateTimeOffset]::TryParse(
        [string]$serverAuditArtifact.generatedAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$serverGenerated)
    $serverAgeSeconds = if ($serverTimeParsed) { ([DateTimeOffset]::UtcNow - $serverGenerated.ToUniversalTime()).TotalSeconds } else { [double]::PositiveInfinity }
    $serverFresh = $serverTimeParsed -and $serverAgeSeconds -ge -60 -and $serverAgeSeconds -le $ServerAuditMaxAgeSeconds
    $bindingFieldNames = @(
        "windowsLanAddress", "macLanAddress", "prefixLength", "windowsLanInterfaceAlias",
        "windowsAccountName", "windowsAccountSid", "relayAccountName", "relayAccountSid", "port", "firewallRuleName",
        "windowsHostKeyFingerprint", "directClientKeyFingerprint", "directClientKeyProvenanceRef"
    )
    $binding = [ordered]@{}
    Merge-ExactObservationFields -Destination $binding -Source $serverAuditArtifact.binding `
        -AllowedNames $bindingFieldNames -Label "Server audit binding"
    $serverBindingMatches =
        [string]$binding.windowsLanAddress -ceq $canonicalWindowsAddress -and
        [string]$binding.macLanAddress -ceq $canonicalMacAddress -and
        [int]$binding.prefixLength -eq $LanPrefixLength -and
        [string]$binding.windowsLanInterfaceAlias -ceq $WindowsLanInterfaceAlias -and
        [string]$binding.windowsAccountName -ceq $WindowsAccountName -and
        [string]$binding.windowsAccountSid -ceq $ExpectedWindowsAccountSid -and
        [string]$binding.relayAccountName -ceq $RelayAccountName -and
        [string]$binding.relayAccountSid -ceq $ExpectedRelayAccountSid -and
        [int]$binding.port -eq $Port -and
        [string]$binding.firewallRuleName -ceq $FirewallRuleName -and
        [string]$binding.windowsHostKeyFingerprint -ceq $ExpectedWindowsHostKeyFingerprint -and
        [string]$binding.directClientKeyFingerprint -ceq $ExpectedIdentityKeyFingerprint -and
        [string]$binding.directClientKeyProvenanceRef -ceq $LanPublicKeyProvenanceRef

    $registrationArtifact = $serverAuditArtifact.registrationArtifact
    Assert-True -Condition ($null -ne $registrationArtifact) -Message "Server audit is missing the registration authority artifact."
    $registrationAssessment = Get-RegistrationAuditAssessment -Artifact $registrationArtifact `
        -ExpectedLanAccount $WindowsAccountName -ExpectedRelayAccount $RelayAccountName `
        -ExpectedLanSid $ExpectedWindowsAccountSid -ExpectedRelaySid $ExpectedRelayAccountSid `
        -ExpectedWindowsAddress $canonicalWindowsAddress `
        -ExpectedMacAddress $canonicalMacAddress -ExpectedPrefixLength $LanPrefixLength `
        -ExpectedInterfaceAlias $WindowsLanInterfaceAlias -ExpectedPort $Port -ExpectedFirewallRuleName $FirewallRuleName `
        -ExpectedHostDigest $ExpectedWindowsHostKeyFingerprint -ExpectedClientDigest $ExpectedIdentityKeyFingerprint `
        -ExpectedProvenance $LanPublicKeyProvenanceRef
    $invocationStarted = [DateTimeOffset]::MinValue
    $invocationFinished = [DateTimeOffset]::MinValue
    $invocationStartParsed = [DateTimeOffset]::TryParse(
        [string]$serverAuditArtifact.invocationStartedAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$invocationStarted)
    $invocationFinishParsed = [DateTimeOffset]::TryParse(
        [string]$serverAuditArtifact.invocationFinishedAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$invocationFinished)
    $registrationWithinInvocation = $invocationStartParsed -and $invocationFinishParsed -and
        $invocationStarted -le $invocationFinished -and $registrationAssessment.generatedAtValid -and
        $registrationAssessment.generatedAtUtc -ge $invocationStarted.AddSeconds(-1) -and
        $registrationAssessment.generatedAtUtc -le $invocationFinished.AddSeconds(1)
    $registrationScriptPath = Join-Path $PSScriptRoot "register-windows-lan-ssh-access.ps1"
    $registrationScriptCanonicalSha256 = Get-CanonicalTextFileSha256 -Path $registrationScriptPath
    $verifierScriptCanonicalSha256 = Get-CanonicalTextFileSha256 -Path $PSCommandPath
    $expectedSourceManifest = Get-StringSha256 -Value ("registration=" + $registrationScriptCanonicalSha256 + ";verifier=" + $verifierScriptCanonicalSha256)
    $serverSourceManifestBound =
        [string]$serverAuditArtifact.registrationScriptCanonicalSha256 -ceq $registrationScriptCanonicalSha256 -and
        [string]$serverAuditArtifact.verifierScriptCanonicalSha256 -ceq $verifierScriptCanonicalSha256 -and
        [string]$serverAuditArtifact.sourceManifestSha256 -ceq $expectedSourceManifest
    $windowsPowerShellBound =
        [string]$serverAuditArtifact.windowsPowerShellPath -ceq "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -and
        [string]$serverAuditArtifact.windowsPowerShellSha256 -match '^[a-f0-9]{64}$' -and
        [string]$serverAuditArtifact.windowsPowerShellSignatureStatus -ceq "Valid" -and
        [string]$serverAuditArtifact.windowsPowerShellSignerSubject -match '(?i)\bMicrosoft\b' -and
        [string]$serverAuditArtifact.openSshDefaultShell -cin @("<built-in-cmd-default>", "C:\Windows\System32\cmd.exe")
    $parsedNonce = [Guid]::Empty
    $nonceValid = [Guid]::TryParse([string]$serverAuditArtifact.nonce, [ref]$parsedNonce) -and $parsedNonce -ne [Guid]::Empty
    $registrationArtifactDigestRecorded = [string]$serverAuditArtifact.registrationArtifactSha256 -match '^[a-f0-9]{64}$'
    $serverDeclaredPassed = $serverAuditArtifact.serverAuditPassed -is [bool] -and
        [bool]$serverAuditArtifact.serverAuditPassed -and
        $serverAuditArtifact.accepted -is [bool] -and -not [bool]$serverAuditArtifact.accepted -and
        $serverAuditArtifact.registrationWithinInvocation -is [bool] -and
        [bool]$serverAuditArtifact.registrationWithinInvocation
    $serverAuditPassed = $serverDeclaredPassed -and [bool]$registrationAssessment.passed -and
        $registrationWithinInvocation -and $serverSourceManifestBound -and $windowsPowerShellBound -and $nonceValid -and
        $registrationArtifactDigestRecorded
    Assert-True -Condition $serverAuditOwnerSafe -Message "Server audit artifact must be an owner-only mode 0600 file."
    Assert-True -Condition $serverSchemaExact -Message "Server audit artifact schema is not supported."
    Assert-True -Condition $serverDigestMatches -Message "Server audit artifact does not match the independently supplied digest."
    Assert-True -Condition $serverFresh -Message "Server audit artifact is stale or has an invalid timestamp."
    Assert-True -Condition $serverBindingMatches -Message "Server audit artifact binding does not match the live connection contract."
    Assert-True -Condition $serverAuditPassed -Message "Server audit artifact did not pass the registration authority and source-manifest checks."
    $routeObservation = Get-MacRouteObservation -TargetAddress $canonicalWindowsAddress -SourceAddress $canonicalMacAddress `
        -PrefixLength $LanPrefixLength -InterfaceName $MacLanInterface
    $pinObservation = Get-HostPinObservation -Path $knownHostsFullPath -TargetAddress $canonicalWindowsAddress -TargetPort $Port `
        -ExpectedDigest $ExpectedWindowsHostKeyFingerprint -KeygenPath $SshKeygenPath
    $identitySecurity = Get-UnixFileSecurityObservation -Path $identityFullPath -RequireMode0600 $true
    $identityListing = Get-KeyListing -Path $identityFullPath -KeygenPath $SshKeygenPath
    $knownHostsBefore = Get-BoundFileSnapshot -Path $knownHostsFullPath -RequireMode0600 $false
    $identityBefore = Get-BoundFileSnapshot -Path $identityFullPath -RequireMode0600 $true

    Assert-True -Condition $samePrefix -Message "Windows and Mac addresses are not in the declared LAN prefix."
    foreach ($name in @("interfaceMatches", "interfaceIsPhysical", "interfaceActive", "interfaceAddressMatches", "interfacePrefixMatches", "routeInterfaceMatches", "routeDestinationMatches", "routeIsDirect")) {
        Assert-True -Condition ([bool]$routeObservation[$name]) -Message "Direct-LAN route preflight failed: $name"
    }
    foreach ($name in @("pinDurable", "pinOwnerSafe", "pinTargetMatches", "pinDigestMatches")) {
        Assert-True -Condition ([bool]$pinObservation[$name]) -Message "Pinned host-key preflight failed: $name"
    }
    Assert-True -Condition ($pinObservation.pinActiveRecordCount -eq 1 -and $pinObservation.pinAlgorithm -ceq $requiredHostKeyAlgorithm) -Message "Pinned host-key file must contain exactly one ED25519 record."
    Assert-True -Condition ([bool]$identitySecurity.ownerSafe) -Message "SSH identity must be an owner-only mode 0600 file."
    Assert-True -Condition ($identityListing.algorithm -ceq $requiredHostKeyAlgorithm -and $identityListing.digest -ceq $ExpectedIdentityKeyFingerprint) -Message "SSH identity key does not match the independently expected ED25519 key."

    $remoteScript = New-RemoteSessionAuditScript -AccountName $WindowsAccountName -AccountSid $ExpectedWindowsAccountSid `
        -ClientAddress $canonicalMacAddress -ServerAddress $canonicalWindowsAddress -SshPort $Port `
        -ExpectedPowerShellSha256 ([string]$serverAuditArtifact.windowsPowerShellSha256)
    $remoteScriptUtf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($remoteScript)
    Assert-True -Condition ($remoteScriptUtf8ByteCount -le 4096) -Message "Remote session audit script exceeds its bounded standard-input payload."
    $sshArguments = @(
        "-vvv",
        "-F", "/dev/null",
        "-o", "AddressFamily=inet",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PubkeyAuthentication=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "HostbasedAuthentication=no",
        "-o", "GSSAPIAuthentication=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "IdentitiesOnly=yes",
        "-o", "IdentityAgent=none",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "VerifyHostKeyDNS=no",
        "-o", "CheckHostIP=yes",
        "-o", "CanonicalizeHostname=no",
        "-o", "UserKnownHostsFile=$knownHostsFullPath",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "UpdateHostKeys=no",
        "-o", "HostKeyAlgorithms=$requiredHostKeyAlgorithm",
        "-o", "PubkeyAcceptedAlgorithms=$requiredHostKeyAlgorithm",
        "-o", "KexAlgorithms=$requiredKex",
        "-o", "ProxyCommand=none",
        "-o", "ProxyJump=none",
        "-o", "ControlMaster=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "Tunnel=no",
        "-o", "EscapeChar=none",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "PermitLocalCommand=no",
        "-o", "RequestTTY=no",
        "-o", "ConnectTimeout=$TimeoutSeconds",
        "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=2",
        "-o", "BindAddress=$canonicalMacAddress",
        "-o", "BindInterface=$MacLanInterface",
        "-p", [string]$Port,
        "-i", $identityFullPath,
        "$WindowsAccountName@$canonicalWindowsAddress",
        "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "-"
    )
    $sshArgumentUtf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount(($sshArguments -join [char]0))
    Assert-True -Condition ($sshArgumentUtf8ByteCount -le 8192) -Message "SSH argument list exceeds the lifecycle gate bound."
    $sshResult = Invoke-NativeCapture -FileName $SshPath -Arguments $sshArguments `
        -CommandTimeoutSeconds ($TimeoutSeconds + 15) -StandardInputText $remoteScript
    $kexMatch = [regex]::Match($sshResult.stderr, '(?m)^debug\d+: kex: algorithm: (?<value>\S+)\s*$')
    $hostKeyMatch = [regex]::Match($sshResult.stderr, '(?m)^debug\d+: Server host key: (?<algorithm>\S+)\s+(?<digest>SHA256:[A-Za-z0-9+/]+={0,2})\s*$')
    $knownHostMatched = $sshResult.stderr -match '(?im)^debug\d+: Host .+ is known and matches the ED25519 host key\.\s*$'
    $remoteLines = @([regex]::Split($sshResult.stdout, '\r?\n') | Where-Object { $_.StartsWith($remoteMarker, [System.StringComparison]::Ordinal) })
    Assert-True -Condition ($remoteLines.Count -eq 1) -Message "SSH command did not return exactly one structured remote audit record."
    $remoteObservation = $remoteLines[0].Substring($remoteMarker.Length) | ConvertFrom-Json
    $routeObservationAfter = Get-MacRouteObservation -TargetAddress $canonicalWindowsAddress -SourceAddress $canonicalMacAddress `
        -PrefixLength $LanPrefixLength -InterfaceName $MacLanInterface
    $neighborMatches = Test-MacNeighborOnInterface -TargetAddress $canonicalWindowsAddress -InterfaceName $MacLanInterface
    $knownHostsAfter = Get-BoundFileSnapshot -Path $knownHostsFullPath -RequireMode0600 $false
    $identityAfter = Get-BoundFileSnapshot -Path $identityFullPath -RequireMode0600 $true
    $serverAuditAfter = Get-BoundFileSnapshot -Path $serverAuditFullPath -RequireMode0600 $true
    $verifierSourceAfter = Get-BoundFileSnapshot -Path $PSCommandPath -RequireMode0600 $false
    $registrationSourceAfter = Get-BoundFileSnapshot -Path $registrationScriptPath -RequireMode0600 $false
    $appleToolManifestAfter = Get-AppleToolManifestSnapshot
    $privateParentAfter = Get-MacEvidenceTargetSnapshot -Path $privateFullPath -OwnerOnly $true
    $publicParentAfter = Get-MacEvidenceTargetSnapshot -Path $publicFullPath -OwnerOnly $false
    $evidenceTargetsStillAbsent = -not (Test-Path -LiteralPath $privateFullPath) -and -not (Test-Path -LiteralPath $publicFullPath)
    $boundInputSnapshotsStable = (Test-BoundFileSnapshotMatch -Before $knownHostsBefore -After $knownHostsAfter) -and
        (Test-BoundFileSnapshotMatch -Before $identityBefore -After $identityAfter) -and
        (Test-BoundFileSnapshotMatch -Before $serverAuditBefore -After $serverAuditAfter) -and
        (Test-BoundFileSnapshotMatch -Before $verifierSourceBefore -After $verifierSourceAfter) -and
        (Test-BoundFileSnapshotMatch -Before $registrationSourceBefore -After $registrationSourceAfter)
    $routeSnapshotStable = $routeObservation.bindingDigest -ceq $routeObservationAfter.bindingDigest
    foreach ($name in @("interfaceMatches", "interfaceIsPhysical", "interfaceActive", "interfaceAddressMatches", "interfacePrefixMatches", "routeInterfaceMatches", "routeDestinationMatches", "routeIsDirect")) {
        $routeSnapshotStable = $routeSnapshotStable -and [bool]$routeObservationAfter[$name]
    }
    $appleToolManifestStable = $appleToolManifestBefore.digest -ceq $appleToolManifestAfter.digest -and
        $appleToolManifestBefore.count -eq $appleToolManifestAfter.count
    $evidenceParentsStable = $outputSetSnapshot.privateParentChainDigest -ceq $privateParentAfter.parentChainDigest -and
        $outputSetSnapshot.publicParentChainDigest -ceq $publicParentAfter.parentChainDigest -and $evidenceTargetsStillAbsent
    $serverAgeSecondsAfter = ([DateTimeOffset]::UtcNow - $serverGenerated.ToUniversalTime()).TotalSeconds
    $serverAuditStillFresh = $serverAgeSecondsAfter -ge -60 -and $serverAgeSecondsAfter -le $ServerAuditMaxAgeSeconds -and
        $serverAuditAfter.contentSha256 -ceq $ExpectedServerAuditSha256.ToLowerInvariant()
    Assert-True -Condition $boundInputSnapshotsStable -Message "A bound SSH input or server-audit artifact changed during the live handshake."
    Assert-True -Condition $routeSnapshotStable -Message "The physical LAN route binding changed during the live handshake."
    Assert-True -Condition $appleToolManifestStable -Message "An Apple system tool changed during the live handshake."
    Assert-True -Condition $evidenceParentsStable -Message "An evidence parent-chain identity changed during the live handshake."
    Assert-True -Condition $serverAuditStillFresh -Message "The server audit expired or changed during the live handshake."

    $observation.clientPlatform = "macOS"
    $observation.addressesCanonical = $true
    $observation.addressesDistinct = $true
    $observation.samePrefix = [bool]$samePrefix
    foreach ($name in @("interfaceMatches", "interfaceIsPhysical", "interfaceActive", "interfaceAddressMatches", "interfacePrefixMatches", "routeInterfaceMatches", "routeDestinationMatches", "routeIsDirect")) {
        $observation[$name] = $routeObservationAfter[$name]
    }
    $observation.neighborMatches = [bool]$neighborMatches
    foreach ($name in @("pinDurable", "pinOwnerSafe", "pinActiveRecordCount", "pinTargetMatches", "pinAlgorithm", "pinDigestMatches")) {
        $observation[$name] = $pinObservation[$name]
    }
    $observation.identityFileOwnerOnly = [bool]$identitySecurity.ownerSafe
    $observation.identityAlgorithm = $identityListing.algorithm
    $observation.identityDigestMatches = $identityListing.digest -ceq $ExpectedIdentityKeyFingerprint
    $observation.sshConfigDisabled = $true
    $observation.sshNumericTarget = $true
    $observation.sshBoundSource = $true
    $observation.sshBoundInterface = $true
    $observation.sshStrictPin = $true
    $observation.sshPublicKeyOnly = $true
    $observation.sshAgentDisabled = $true
    $observation.sshPasswordsDisabled = $true
    $observation.sshNoProxyOrJump = $true
    $observation.sshForwardingDisabled = $true
    $observation.sshArgumentListBounded = ($sshArgumentUtf8ByteCount -le 8192)
    $observation.sshRemoteScriptViaStandardInput = $true
    $observation.sshRemoteScriptBounded = ($remoteScriptUtf8ByteCount -le 4096)
    $observation.sshRemotePowerShellAbsolute = $true
    $observation.requestedKex = $requiredKex
    $observation.sshExitCode = [int]$sshResult.exitCode
    $observation.negotiatedKex = if ($kexMatch.Success) { $kexMatch.Groups['value'].Value } else { "" }
    $observation.negotiatedHostKeyAlgorithm = if ($hostKeyMatch.Success) { $hostKeyMatch.Groups['algorithm'].Value } else { "" }
    $observation.sshKnownHostMatched = [bool]$knownHostMatched
    $observation.negotiatedHostKeyDigestMatches = $hostKeyMatch.Success -and $hostKeyMatch.Groups['digest'].Value -ceq $ExpectedWindowsHostKeyFingerprint
    $observation.appleToolManifestTrusted = $appleToolManifestBefore.count -eq 10
    $observation.appleToolManifestStable = [bool]$appleToolManifestStable
    $observation.boundInputSnapshotsStable = [bool]$boundInputSnapshotsStable
    $observation.routeSnapshotStable = [bool]$routeSnapshotStable
    $observation.serverAuditStillFresh = [bool]$serverAuditStillFresh
    $observation.evidenceParentsStable = [bool]$evidenceParentsStable
    $observation.serverAuditSchemaExact = [bool]$serverSchemaExact
    $observation.serverAuditDigestMatches = [bool]$serverDigestMatches
    $observation.serverAuditFresh = [bool]$serverFresh
    $observation.serverAuditBindingMatches = [bool]$serverBindingMatches
    $observation.serverAuditPassed = [bool]$serverAuditPassed
    $observation.serverAuditAcceptedFalse = -not [bool]$serverAuditArtifact.accepted
    $observation.serverAuditFileOwnerSafe = [bool]$serverAuditOwnerSafe
    $observation.serverRuntimeExact = [bool]$registrationAssessment.runtimeExact
    $observation.serverKeysAndAclExact = [bool]$registrationAssessment.keysAndAclExact
    $observation.serverFirewallExact = [bool]$registrationAssessment.firewallExact
    $observation.serverAuthenticationPolicyExact = [bool]$registrationAssessment.authenticationPolicyExact
    $observation.serverSourceManifestBound = [bool]$serverSourceManifestBound
    Merge-ExactObservationFields -Destination $observation -Source $remoteObservation `
        -AllowedNames $sessionFieldNames -Label "Remote SSH session audit"

    $sensitive.windowsLanAddress = $canonicalWindowsAddress
    $sensitive.macLanAddress = $canonicalMacAddress
    $sensitive.prefixLength = $LanPrefixLength
    $sensitive.macLanInterface = $MacLanInterface
    $sensitive.macHardwarePort = $routeObservationAfter.hardwarePort
    $sensitive.routeGateway = $routeObservationAfter.routeGateway
    $sensitive.routeBindingBeforeSha256 = $routeObservation.bindingDigest
    $sensitive.routeBindingAfterSha256 = $routeObservationAfter.bindingDigest
    $sensitive.windowsLanInterfaceAlias = $WindowsLanInterfaceAlias
    $sensitive.windowsAccountName = $WindowsAccountName
    $sensitive.windowsAccountSid = $ExpectedWindowsAccountSid
    $sensitive.identityFile = $identityFullPath
    $sensitive.identityFileMode = $identitySecurity.mode
    $sensitive.identityFileOwner = $identitySecurity.owner
    $sensitive.identityKeyFingerprint = $identityListing.digest
    $sensitive.knownHostsPath = $knownHostsFullPath
    $sensitive.knownHostsMode = $pinObservation.mode
    $sensitive.knownHostsOwner = $pinObservation.owner
    $sensitive.windowsHostKeyFingerprint = $pinObservation.actualDigest
    $sensitive.sshDiagnosticSha256 = Get-StringSha256 -Value $sshResult.stderr
    $sensitive.sshStandardOutputSha256 = Get-StringSha256 -Value $sshResult.stdout
    $sensitive.remoteAuditScriptSha256 = Get-StringSha256 -Value $remoteScript
    $sensitive.remoteAuditScriptUtf8ByteCount = $remoteScriptUtf8ByteCount
    $sensitive.sshArgumentUtf8ByteCount = $sshArgumentUtf8ByteCount
    $sensitive.serverAuditEvidencePath = $serverAuditFullPath
    $sensitive.serverAuditSha256 = $actualServerAuditDigest
    $sensitive.serverAuditAgeSeconds = $serverAgeSeconds
    $sensitive.serverAuditAgeSecondsAfter = $serverAgeSecondsAfter
    $sensitive.appleToolManifestSha256 = $appleToolManifestAfter.digest
    $sensitive.knownHostsSnapshotSha256 = $knownHostsAfter.snapshotDigest
    $sensitive.identitySnapshotSha256 = $identityAfter.snapshotDigest
}

$evaluation = Get-LifecycleEvaluation -Observation $observation
$accepted = $mode -eq "live" -and [bool]$evaluation.evaluationPassed
$generatedAtUtc = [DateTime]::UtcNow.ToString("o")
$privateEvidence = [ordered]@{
    schema = $schema
    generatedAtUtc = $generatedAtUtc
    scope = "MacToWindowsDirectLanSshManagementLifecycle"
    mode = $mode
    observation = $observation
    sensitive = $sensitive
    checks = $evaluation.checks
    failedCheckCodes = @($evaluation.failedCheckCodes)
    evaluationPassed = [bool]$evaluation.evaluationPassed
    accepted = [bool]$accepted
    fixtureEvidenceNotAccepted = ($mode -eq "fixture")
    notProductTransportProof = $true
    notRemoteFrameProof = $true
    notInputEffectProof = $true
    notFileTransferProof = $true
}
$privatePath = Write-JsonAtomic -Value $privateEvidence -Path $resolvedPrivateEvidence -OwnerOnly $true
$privateDigest = Get-FileSha256 -Path $privatePath
$publicEvidence = [ordered]@{
    schema = $schema
    generatedAtUtc = $generatedAtUtc
    scope = "MacToWindowsDirectLanSshManagementLifecycle"
    mode = $mode
    checks = $evaluation.checks
    failedCheckCodes = @($evaluation.failedCheckCodes)
    negotiatedKex = if ([bool]$evaluation.checks.hybridKexNegotiated) { $requiredKex } else { "" }
    evaluationPassed = [bool]$evaluation.evaluationPassed
    accepted = [bool]$accepted
    fixtureEvidenceNotAccepted = ($mode -eq "fixture")
    privateEvidenceSha256 = $privateDigest
    notProductTransportProof = $true
    notRemoteFrameProof = $true
    notInputEffectProof = $true
    notFileTransferProof = $true
}
$publicPath = Write-JsonAtomic -Value $publicEvidence -Path $resolvedPublicEvidence -OwnerOnly $false

Write-Output "windows-lan-ssh-lifecycle: mode=$mode evaluationPassed=$($evaluation.evaluationPassed) accepted=$accepted"
Write-Output "windows-lan-ssh-lifecycle: private-evidence-written=true private-evidence-sha256=$privateDigest"
Write-Output "windows-lan-ssh-lifecycle: public-evidence-written=true"
if (-not [bool]$evaluation.evaluationPassed) {
    throw "Windows direct-LAN SSH lifecycle evaluation failed: $($evaluation.failedCheckCodes -join ',')"
}
