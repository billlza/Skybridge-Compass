[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$LanAccountName,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$RelayAccountName,
    [Parameter(Mandatory = $true)]
    [string]$WindowsLanAddress,
    [Parameter(Mandatory = $true)]
    [string]$MacLanAddress,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 32)]
    [int]$LanPrefixLength,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\x00-\x1f\x7f]+$')]
    [ValidateLength(1, 256)]
    [string]$LanInterfaceAlias,
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 512)]
    [ValidatePattern('^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [\x20-\x7e]{1,256})?$')]
    [string]$LanAuthorizedPublicKey,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^SHA256:[A-Za-z0-9+/]+={0,2}$')]
    [string]$ExpectedLanPublicKeyFingerprint,
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 128)]
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [string]$LanPublicKeyProvenanceRef,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^SHA256:[A-Za-z0-9+/]+={0,2}$')]
    [string]$ExpectedWindowsHostKeyFingerprint,
    [ValidateRange(22, 22)]
    [int]$Port = 22,
    [string]$SshdConfigPath = "C:\ProgramData\ssh\sshd_config",
    [string]$FirewallRuleName = "SkyBridge-Windows-LAN-SSH",
    [string[]]$DisableConflictingRuleName = @(),
    [string]$EvidencePath = "",
    [switch]$VerifyOnly,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$managedBegin = "# BEGIN SkyBridge Windows LAN SSH lifecycle"
$managedEnd = "# END SkyBridge Windows LAN SSH lifecycle"
$systemSid = "S-1-5-18"
$administratorsSid = "S-1-5-32-544"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Windows {
    Assert-True -Condition ($env:OS -eq "Windows_NT") -Message "This registration script must run on Windows."
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-CanonicalIPv4 {
    param([string]$Value, [string]$Name)

    $parsed = $null
    Assert-True -Condition ([System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) -Message "$Name must be an IPv4 address."
    Assert-True -Condition ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -Message "$Name must be IPv4."
    $canonical = $parsed.ToString()
    Assert-True -Condition ($canonical -ceq $Value) -Message "$Name must use canonical dotted-decimal form."
    Assert-True -Condition (-not [System.Net.IPAddress]::IsLoopback($parsed)) -Message "$Name must not be loopback."
    $first = $parsed.GetAddressBytes()[0]
    Assert-True -Condition ($first -ne 0 -and $first -lt 224) -Message "$Name must be a unicast IPv4 address."
    return $canonical
}

function Test-SameIPv4Prefix {
    param([string]$Left, [string]$Right, [int]$PrefixLength)

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

function ConvertTo-NativeArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-NativeCapture {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $resolved = Resolve-NativeCommandPath -FileName $FileName
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-lan-ssh-out-" + [Guid]::NewGuid().ToString("N"))
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-lan-ssh-err-" + [Guid]::NewGuid().ToString("N"))
    $process = $null
    try {
        $argumentText = (($Arguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join " ")
        $process = Start-Process -FilePath $resolved -ArgumentList $argumentText -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                $process.WaitForExit()
            }
            catch {
                throw "Native command timed out and could not be terminated: $resolved ($($_.Exception.Message))"
            }
            throw "Native command timed out: $resolved"
        }
        $process.WaitForExit()
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
        return [ordered]@{ exitCode = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force }
        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force }
    }
}

function Get-PublicKeyFingerprint {
    param([string]$PublicKeyLine, [string]$SshKeygenPath)

    $keyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-lan-public-key-" + [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($keyFile, ($PublicKeyLine.Trim() + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-NativeCapture -FileName $SshKeygenPath -Arguments @("-lf", $keyFile, "-E", "sha256")
        Assert-True -Condition ($result.exitCode -eq 0) -Message "ssh-keygen could not read the supplied public key."
        $match = [regex]::Match(($result.stdout + $result.stderr), 'SHA256:[A-Za-z0-9+/]+={0,2}')
        Assert-True -Condition $match.Success -Message "ssh-keygen did not emit a SHA256 fingerprint."
        return $match.Value
    }
    finally {
        if (Test-Path -LiteralPath $keyFile) { Remove-Item -LiteralPath $keyFile -Force }
    }
}

function Get-ServiceExecutablePath {
    param($ServiceRecord)

    $pathName = [string]$ServiceRecord.PathName
    $match = [regex]::Match($pathName, '^\s*(?:"(?<quoted>[^"]+\.exe)"|(?<plain>\S+\.exe))\s*(?<args>.*)$', 'IgnoreCase')
    Assert-True -Condition $match.Success -Message "sshd service PathName is not an executable path."
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($match.Groups['args'].Value)) -Message "sshd service must not contain unmanaged command-line arguments."
    $candidate = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    return Resolve-NativeCommandPath -FileName $candidate
}

function Get-LocalUserByName {
    param([string]$Name)
    $user = Get-LocalUser -Name $Name -ErrorAction Stop
    Assert-True -Condition $user.Enabled -Message "Local account is disabled: $Name"
    return $user
}

function Test-LocalUserInAdministrators {
    param([string]$UserSid)

    # Both managed SSH identities are local SAM accounts, so local Administrators
    # membership is represented by a direct SID entry; this cmdlet has no
    # supported recursive parameter.
    $members = @(Get-LocalGroupMember -SID $administratorsSid -ErrorAction Stop)
    foreach ($member in $members) {
        if ($null -ne $member.SID -and $member.SID.Value -eq $UserSid) {
            return $true
        }
    }
    return $false
}

function Get-LocalUserProfilePath {
    param([string]$UserSid)

    $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $UserSid -and -not $_.Special })
    Assert-True -Condition ($profiles.Count -eq 1) -Message "Expected one existing local profile for LAN account."
    Assert-True -Condition (Test-Path -LiteralPath $profiles[0].LocalPath -PathType Container) -Message "LAN account profile directory is missing."
    return $profiles[0].LocalPath
}

function Assert-NotReparsePoint {
    param([string]$Path, [string]$Label)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "$Label must not be a reparse point."
    }
}

function ConvertTo-SidValue {
    param($Identity)

    if ($Identity -is [System.Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    if ($Identity -is [string]) {
        return ([System.Security.Principal.NTAccount]::new($Identity)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
    return $Identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Test-PrivateHostKeyAcl {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-NotReparsePoint -Path $Path -Label "Host private key"
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @($systemSid, $administratorsSid)
    $ownerSid = ConvertTo-SidValue -Identity $acl.Owner
    if ($allowed -notcontains $ownerSid -or -not $acl.AreAccessRulesProtected) { return $false }
    $fullControlSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rule in $acl.Access) {
        $sid = ConvertTo-SidValue -Identity $rule.IdentityReference
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $allowed -notcontains $sid) { return $false }
        if (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl) {
            [void]$fullControlSids.Add($sid)
        }
    }
    return ($fullControlSids.Count -eq $allowed.Count -and @($allowed | Where-Object { -not $fullControlSids.Contains($_) }).Count -eq 0)
}

function Test-ExactLanSshPathAcl {
    param([string]$Path, [string]$UserSid)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Assert-NotReparsePoint -Path $Path -Label "LAN SSH path"
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @($UserSid, $systemSid, $administratorsSid)
    $ownerSid = ConvertTo-SidValue -Identity $acl.Owner
    if ($ownerSid -ne $UserSid -or -not $acl.AreAccessRulesProtected) { return $false }
    $fullControlSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rule in $acl.Access) {
        $sid = ConvertTo-SidValue -Identity $rule.IdentityReference
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $allowed -notcontains $sid) {
            return $false
        }
        if (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl) {
            [void]$fullControlSids.Add($sid)
        }
    }
    return ($fullControlSids.Count -eq $allowed.Count -and @($allowed | Where-Object { -not $fullControlSids.Contains($_) }).Count -eq 0)
}

function Test-SshdConfigAcl {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-NotReparsePoint -Path $Path -Label "sshd_config"
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @($systemSid, $administratorsSid)
    $ownerSid = ConvertTo-SidValue -Identity $acl.Owner
    if ($allowed -notcontains $ownerSid) { return $false }
    $dangerousRights = [System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $fullControlSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rule in $acl.Access) {
        $sid = ConvertTo-SidValue -Identity $rule.IdentityReference
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $allowed -notcontains $sid -and
            ($rule.FileSystemRights -band $dangerousRights) -ne 0) {
            return $false
        }
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $allowed -contains $sid -and
            ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl) {
            [void]$fullControlSids.Add($sid)
        }
    }
    return ($fullControlSids.Count -eq $allowed.Count -and @($allowed | Where-Object { -not $fullControlSids.Contains($_) }).Count -eq 0)
}

function Get-AuthorizedKeyRecords {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $records = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(?:\s+.*)?$') {
            throw "LAN authorized_keys contains an unsupported or malformed active record."
        }
        $parts = $trimmed -split '\s+'
        $records.Add(($parts[0] + " " + $parts[1]))
    }
    return @($records)
}

function Set-ExactSshPathAcl {
    param([string]$Path, [string]$UserSid, [bool]$Directory)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    $userIdentity = [System.Security.Principal.SecurityIdentifier]::new($UserSid)
    $systemIdentity = [System.Security.Principal.SecurityIdentifier]::new($systemSid)
    $adminIdentity = [System.Security.Principal.SecurityIdentifier]::new($administratorsSid)
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($identity in @($userIdentity, $systemIdentity, $adminIdentity)) {
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($accessRule)
    }
    $acl.SetOwner($userIdentity)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-TextAtomic {
    param([string]$Path, [string]$Content)

    $directory = Split-Path -Parent $Path
    Assert-True -Condition (Test-Path -LiteralPath $directory -PathType Container) -Message "Atomic write parent directory is missing: $directory"
    $leaf = Split-Path -Leaf $Path
    $temp = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        [System.IO.File]::WriteAllText($temp, $Content, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temp, $Path, $backup, $true)
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function New-ManagedSshdConfig {
    param(
        [string]$ExistingContent,
        [string]$LanUser,
        [string]$RelayUser,
        [string]$MacAddress,
        [string]$LanAddress,
        [int]$SshPort,
        [string]$AuthorizedKeysPath
    )

    $managedBeginCount = [regex]::Matches($ExistingContent, '(?m)^# BEGIN SkyBridge Windows LAN SSH lifecycle\s*$').Count
    $managedEndCount = [regex]::Matches($ExistingContent, '(?m)^# END SkyBridge Windows LAN SSH lifecycle\s*$').Count
    Assert-True -Condition ($managedBeginCount -eq $managedEndCount -and $managedBeginCount -le 1) `
        -Message "sshd_config contains an incomplete or duplicate managed block."
    Assert-True -Condition (-not [regex]::IsMatch($ExistingContent, '(?im)^\s*Include\s+')) `
        -Message "sshd_config Include directives are unsupported because they split configuration authority."

    $withoutManaged = [regex]::Replace(
        $ExistingContent,
        '(?ms)^# BEGIN SkyBridge Windows LAN SSH lifecycle\r?\n.*?^# END SkyBridge Windows LAN SSH lifecycle\r?\n?',
        '')
    $managedGlobalNames = @(
        'port', 'listenaddress', 'pubkeyauthentication', 'passwordauthentication',
        'kbdinteractiveauthentication', 'hostbasedauthentication', 'permitemptypasswords', 'authenticationmethods',
        'authorizedkeyscommand', 'authorizedkeyscommanduser', 'trustedusercakeys',
        'authorizedprincipalscommand', 'authorizedprincipalscommanduser', 'authorizedprincipalsfile',
        'allowusers', 'denyusers', 'allowgroups', 'denygroups',
        'allowagentforwarding', 'allowtcpforwarding', 'gatewayports',
        'allowstreamlocalforwarding', 'permittunnel', 'x11forwarding',
        'permituserenvironment', 'maxauthtries', 'logingracetime'
    )
    $kept = [System.Collections.Generic.List[string]]::new()
    $insideMatch = $false
    foreach ($line in [regex]::Split($withoutManaged, '\r?\n')) {
        if ($line -match '^\s*Match\s+') { $insideMatch = $true }
        if (-not $insideMatch -and $line -match '^\s*(?<name>[A-Za-z][A-Za-z0-9]*)\b') {
            if ($managedGlobalNames -contains $Matches['name'].ToLowerInvariant()) { continue }
            if ($Matches['name'].Equals('AuthorizedKeysFile', [System.StringComparison]::OrdinalIgnoreCase) -and
                $line -match [regex]::Escape($LanUser)) { continue }
        }
        $kept.Add($line)
    }

    $authorizedKeysNormalized = $AuthorizedKeysPath.Replace('\', '/')
    $block = @(
        $managedBegin,
        "Port $SshPort",
        "ListenAddress 127.0.0.1`:$SshPort",
        "ListenAddress $LanAddress`:$SshPort",
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        'HostbasedAuthentication no',
        'PermitEmptyPasswords no',
        'AuthenticationMethods publickey',
        'AuthorizedKeysCommand none',
        'AuthorizedKeysCommandUser none',
        'TrustedUserCAKeys none',
        'AuthorizedPrincipalsCommand none',
        'AuthorizedPrincipalsCommandUser none',
        'AuthorizedPrincipalsFile none',
        "AllowUsers $LanUser@$MacAddress $RelayUser@127.0.0.1",
        'AllowAgentForwarding no',
        'AllowTcpForwarding no',
        'AllowStreamLocalForwarding no',
        'GatewayPorts no',
        'PermitTunnel no',
        'X11Forwarding no',
        'PermitUserEnvironment no',
        'MaxAuthTries 2',
        'LoginGraceTime 20',
        "Match User $LanUser",
        "    AuthorizedKeysFile `"$authorizedKeysNormalized`"",
        '    AllowAgentForwarding no',
        '    AllowTcpForwarding no',
        '    AllowStreamLocalForwarding no',
        '    PermitTunnel no',
        '    X11Forwarding no',
        '    PermitUserEnvironment no',
        'Match all',
        $managedEnd
    )

    $firstMatchIndex = -1
    for ($index = 0; $index -lt $kept.Count; $index++) {
        if ($kept[$index] -match '^\s*Match\s+') { $firstMatchIndex = $index; break }
    }
    $result = [System.Collections.Generic.List[string]]::new()
    if ($firstMatchIndex -lt 0) {
        foreach ($line in $kept) { $result.Add($line) }
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) { $result.Add('') }
        foreach ($line in $block) { $result.Add($line) }
    } else {
        for ($index = 0; $index -lt $firstMatchIndex; $index++) { $result.Add($kept[$index]) }
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) { $result.Add('') }
        foreach ($line in $block) { $result.Add($line) }
        $result.Add('')
        for ($index = $firstMatchIndex; $index -lt $kept.Count; $index++) { $result.Add($kept[$index]) }
    }
    return (($result -join "`r`n").TrimEnd() + "`r`n")
}

function Get-EffectiveSshdConfig {
    param(
        [string]$SshdPath,
        [string]$ConfigPath,
        [string]$User,
        [string]$RemoteAddress,
        [string]$LocalAddress,
        [int]$SshPort
    )

    $criterion = "user=$User,host=$env:COMPUTERNAME,addr=$RemoteAddress,laddr=$LocalAddress,lport=$SshPort"
    $result = Invoke-NativeCapture -FileName $SshdPath -Arguments @('-T', '-f', $ConfigPath, '-C', $criterion)
    Assert-True -Condition ($result.exitCode -eq 0) -Message "sshd effective-config validation failed."
    $values = @{}
    foreach ($line in [regex]::Split($result.stdout, '\r?\n')) {
        if ($line -match '^(?<name>\S+)\s+(?<value>.*)$') {
            $values[$Matches['name'].ToLowerInvariant()] = $Matches['value'].Trim()
        }
    }
    return $values
}

function Assert-EffectivePolicy {
    param(
        $Values,
        [string]$LanAuthorizedKeysPath,
        [bool]$LanUser,
        [string[]]$ExpectedAllowUsers,
        [int]$SshPort
    )

    Assert-True -Condition ($Values['port'] -eq "$SshPort") -Message "Effective SSH port is not exact."
    Assert-True -Condition ($Values['pubkeyauthentication'] -eq 'yes') -Message "Effective PubkeyAuthentication must be yes."
    Assert-True -Condition ($Values['passwordauthentication'] -eq 'no') -Message "Effective PasswordAuthentication must be no."
    Assert-True -Condition ($Values['kbdinteractiveauthentication'] -eq 'no') -Message "Effective KbdInteractiveAuthentication must be no."
    Assert-True -Condition ($Values['hostbasedauthentication'] -eq 'no') -Message "Effective HostbasedAuthentication must be no."
    Assert-True -Condition ($Values['permitemptypasswords'] -eq 'no') -Message "Effective PermitEmptyPasswords must be no."
    Assert-True -Condition ($Values['authenticationmethods'] -eq 'publickey') -Message "Effective AuthenticationMethods must be publickey."
    Assert-True -Condition ($Values['authorizedkeyscommand'] -eq 'none') -Message "Effective AuthorizedKeysCommand must be none."
    Assert-True -Condition ($Values['authorizedkeyscommanduser'] -eq 'none') -Message "Effective AuthorizedKeysCommandUser must be none."
    Assert-True -Condition ($Values['trustedusercakeys'] -eq 'none') -Message "Effective TrustedUserCAKeys must be none."
    Assert-True -Condition ($Values['authorizedprincipalscommand'] -eq 'none') -Message "Effective AuthorizedPrincipalsCommand must be none."
    Assert-True -Condition ($Values['authorizedprincipalscommanduser'] -eq 'none') -Message "Effective AuthorizedPrincipalsCommandUser must be none."
    Assert-True -Condition ($Values['authorizedprincipalsfile'] -eq 'none') -Message "Effective AuthorizedPrincipalsFile must be none."
    Assert-True -Condition ($Values['allowagentforwarding'] -eq 'no') -Message "Effective AllowAgentForwarding must be no."
    Assert-True -Condition ($Values['allowtcpforwarding'] -eq 'no') -Message "Effective AllowTcpForwarding must be no."
    Assert-True -Condition ($Values['allowstreamlocalforwarding'] -eq 'no') -Message "Effective AllowStreamLocalForwarding must be no."
    Assert-True -Condition ($Values['gatewayports'] -eq 'no') -Message "Effective GatewayPorts must be no."
    Assert-True -Condition ($Values['permittunnel'] -eq 'no') -Message "Effective PermitTunnel must be no."
    Assert-True -Condition ($Values['x11forwarding'] -eq 'no') -Message "Effective X11Forwarding must be no."
    Assert-True -Condition ($Values['permituserenvironment'] -eq 'no') -Message "Effective PermitUserEnvironment must be no."
    Assert-True -Condition ($Values['maxauthtries'] -eq '2') -Message "Effective MaxAuthTries must be two."
    Assert-True -Condition ($Values['logingracetime'] -eq '20') -Message "Effective LoginGraceTime must be twenty seconds."
    $actualAllowUsers = @(([string]$Values['allowusers'] -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $expectedUsers = @($ExpectedAllowUsers | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    Assert-True -Condition ($actualAllowUsers.Count -eq $expectedUsers.Count -and
        @($expectedUsers | Where-Object { $actualAllowUsers -notcontains $_ }).Count -eq 0) `
        -Message "Effective AllowUsers is not the exact LAN and relay source-bound set."
    foreach ($emptyPolicyName in @('denyusers', 'allowgroups', 'denygroups')) {
        Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$Values[$emptyPolicyName])) `
            -Message "Effective $emptyPolicyName must be empty."
    }
    if ($LanUser) {
        $expected = $LanAuthorizedKeysPath.Replace('\', '/').ToLowerInvariant()
        Assert-True -Condition ($Values['authorizedkeysfile'].ToLowerInvariant() -eq $expected) -Message "LAN account AuthorizedKeysFile is not exact."
    } else {
        Assert-True -Condition (-not $Values['authorizedkeysfile'].ToLowerInvariant().Contains($LanAuthorizedKeysPath.Replace('\', '/').ToLowerInvariant())) -Message "Relay account inherited the LAN AuthorizedKeysFile."
    }
}

function Test-PortFilterMayInclude {
    param($Value, [int]$Port)

    foreach ($entryValue in @($Value)) {
        $entry = ([string]$entryValue).Trim()
        if ($entry -eq 'Any' -or $entry -eq "$Port") { return $true }
        $range = [regex]::Match($entry, '^(?<start>\d+)-(?<end>\d+)$')
        if ($range.Success -and $Port -ge [int]$range.Groups['start'].Value -and
            $Port -le [int]$range.Groups['end'].Value) {
            return $true
        }
        if ($entry -notmatch '^\d+$') {
            return $true
        }
    }
    return $false
}

function Test-AddressFilterMayInclude {
    param($Value, [string]$Address)

    foreach ($entryValue in @($Value)) {
        $entry = ([string]$entryValue).Trim()
        if ($entry -in @('Any', 'LocalSubnet')) { return $true }
        if ($entry -ceq $Address) { return $true }
        $cidr = [regex]::Match($entry, '^(?<address>\d{1,3}(?:\.\d{1,3}){3})/(?<prefix>\d{1,2})$')
        if ($cidr.Success) {
            $network = $null
            $prefix = [int]$cidr.Groups['prefix'].Value
            if ($prefix -ge 0 -and $prefix -le 32 -and
                [System.Net.IPAddress]::TryParse($cidr.Groups['address'].Value, [ref]$network) -and
                $network.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                (Test-SameIPv4Prefix -Left $network.ToString() -Right $Address -PrefixLength $prefix)) {
                return $true
            }
            continue
        }
        if ($entry -match '-') {
            return $true
        }
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($entry, [ref]$parsed)) {
            return $true
        }
    }
    return $false
}

function Get-FirewallConflicts {
    param([string]$ManagedRuleName, [string]$LanAddress, [string]$SourceAddress, [int]$SshPort)

    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Name -ne $ManagedRuleName
    })) {
        $ports = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop)
        $addresses = @(Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop)
        Assert-True -Condition ($ports.Count -eq 1 -and $addresses.Count -eq 1) `
            -Message "An active inbound allow rule has an ambiguous firewall filter shape."
        $portMatches = $false
        foreach ($filter in $ports) {
            if (($filter.Protocol -eq 'TCP' -or $filter.Protocol -eq 6 -or
                $filter.Protocol -eq 'Any' -or $filter.Protocol -eq 256) -and
                (Test-PortFilterMayInclude -Value $filter.LocalPort -Port $SshPort)) {
                $portMatches = $true
            }
        }
        if (-not $portMatches) { continue }
        foreach ($filter in $addresses) {
            $localMatches = Test-AddressFilterMayInclude -Value $filter.LocalAddress -Address $LanAddress
            $remoteMatches = Test-AddressFilterMayInclude -Value $filter.RemoteAddress -Address $SourceAddress
            if ($localMatches -and $remoteMatches) { $conflicts.Add($rule); break }
        }
    }
    return @($conflicts)
}

function Test-ManagedFirewallRule {
    param(
        [string]$Name,
        [string]$LanAddress,
        [string]$SourceAddress,
        [string]$InterfaceAlias,
        [int]$SshPort,
        [string]$SshdPath
    )

    $rules = @(Get-NetFirewallRule -Name $Name -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1) { return $false }
    $rule = $rules[0]
    if ([string]$rule.Enabled -ne 'True' -or [string]$rule.Direction -ne 'Inbound' -or
        [string]$rule.Action -ne 'Allow' -or [string]$rule.Profile -ne 'Private' -or
        [string]$rule.EdgeTraversalPolicy -ne 'Block' -or [bool]$rule.LooseSourceMapping -or
        [bool]$rule.LocalOnlyMapping) { return $false }
    $ports = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule)
    $addresses = @(Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule)
    $interfaces = @(Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule)
    $applications = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule)
    $services = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $rule)
    if ($ports.Count -ne 1 -or $addresses.Count -ne 1 -or $interfaces.Count -ne 1 -or
        $applications.Count -ne 1 -or $services.Count -ne 1) { return $false }
    $port = $ports[0]
    $address = $addresses[0]
    $interface = $interfaces[0]
    $application = $applications[0]
    $service = $services[0]
    $localAddresses = @($address.LocalAddress)
    $remoteAddresses = @($address.RemoteAddress)
    $interfaceAliases = @($interface.InterfaceAlias)
    return (($port.Protocol -eq 'TCP' -or $port.Protocol -eq 6) -and "$($port.LocalPort)" -eq "$SshPort" -and
        [string]$port.RemotePort -eq 'Any' -and
        $localAddresses.Count -eq 1 -and $localAddresses[0] -ceq $LanAddress -and
        $remoteAddresses.Count -eq 1 -and $remoteAddresses[0] -ceq $SourceAddress -and
        $interfaceAliases.Count -eq 1 -and $interfaceAliases[0] -ceq $InterfaceAlias -and
        [System.IO.Path]::GetFullPath([string]$application.Program) -ieq [System.IO.Path]::GetFullPath($SshdPath) -and
        [string]$service.Service -eq 'sshd')
}

function Set-PrivateEvidenceFileAcl {
    param([string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    $systemIdentity = [System.Security.Principal.SecurityIdentifier]::new($systemSid)
    $adminIdentity = [System.Security.Principal.SecurityIdentifier]::new($administratorsSid)
    $acl.SetOwner($adminIdentity)
    foreach ($identity in @($systemIdentity, $adminIdentity)) {
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($accessRule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-PrivateEvidenceDirectoryAcl {
    param([string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedWriters = @($systemSid, $administratorsSid, $currentSid)
    $dangerousRights = [System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        $sid = ConvertTo-SidValue -Identity $rule.IdentityReference
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $allowedWriters -notcontains $sid -and ($rule.FileSystemRights -band $dangerousRights) -ne 0) {
            return $false
        }
    }
    return $true
}

function Write-JsonAtomic {
    param($Value, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = Split-Path -Parent $resolved
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Assert-NotReparsePoint -Path $parent -Label "Registration evidence directory"
    Assert-NotReparsePoint -Path $resolved -Label "Registration evidence file"
    Assert-True -Condition (Test-PrivateEvidenceDirectoryAcl -Path $parent) `
        -Message "Registration evidence directory permits an unexpected writer."
    $leaf = Split-Path -Leaf $resolved
    $temp = Join-Path $parent (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $parent (".$leaf." + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $stream = [System.IO.File]::Create($temp)
        $stream.Dispose()
        Set-PrivateEvidenceFileAcl -Path $temp
        [System.IO.File]::WriteAllText($temp, (($Value | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $resolved) {
            [System.IO.File]::Replace($temp, $resolved, $backup, $true)
        } else {
            [System.IO.File]::Move($temp, $resolved)
        }
        Set-PrivateEvidenceFileAcl -Path $resolved
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
    return $resolved
}

function Set-SshdStartupType {
    param([ValidateSet('Auto', 'Manual', 'Disabled')][string]$StartMode)

    $startupType = switch ($StartMode) {
        'Auto' { 'Automatic' }
        'Manual' { 'Manual' }
        'Disabled' { 'Disabled' }
    }
    Set-Service -Name sshd -StartupType $startupType -ErrorAction Stop
}

function Restore-SshdServiceState {
    param([string]$OriginalState, [string]$OriginalStartMode)

    if ($OriginalState -eq 'Running') {
        if ($OriginalStartMode -eq 'Disabled') { Set-Service -Name sshd -StartupType Manual -ErrorAction Stop }
        $current = Get-Service -Name sshd -ErrorAction Stop
        if ($current.Status -eq 'Running') {
            Restart-Service -Name sshd -ErrorAction Stop
        } else {
            Start-Service -Name sshd -ErrorAction Stop
        }
        Set-SshdStartupType -StartMode $OriginalStartMode
        return
    }
    $current = Get-Service -Name sshd -ErrorAction Stop
    if ($current.Status -ne 'Stopped') { Stop-Service -Name sshd -Force -ErrorAction Stop }
    Set-SshdStartupType -StartMode $OriginalStartMode
}

function Test-ByteSequenceEqual {
    param([byte[]]$Left, [byte[]]$Right)

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-FileSha256 {
    param([string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "Cannot hash a missing file."
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-WindowsSshAuthoritySnapshot {
    param(
        [string]$LanAccountName,
        [string]$ExpectedLanSid,
        [string]$RelayAccountName,
        [string]$ExpectedRelaySid,
        [string]$WindowsAddress,
        [int]$PrefixLength,
        [string]$InterfaceAlias,
        [string]$SshdConfigPath,
        [string]$ExpectedHostKeyFingerprint
    )

    $currentLanUser = Get-LocalUserByName -Name $LanAccountName
    $currentRelayUser = Get-LocalUserByName -Name $RelayAccountName
    Assert-True -Condition ($currentLanUser.SID.Value -ceq $ExpectedLanSid) -Message "LAN account SID changed."
    Assert-True -Condition ($currentRelayUser.SID.Value -ceq $ExpectedRelaySid) -Message "Relay account SID changed."
    Assert-True -Condition (-not (Test-LocalUserInAdministrators -UserSid $ExpectedLanSid)) `
        -Message "LAN account must not belong to Administrators."
    Assert-True -Condition (-not (Test-LocalUserInAdministrators -UserSid $ExpectedRelaySid)) `
        -Message "Relay account must not belong to Administrators."

    $addressRecords = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $WindowsAddress -ErrorAction Stop)
    Assert-True -Condition ($addressRecords.Count -eq 1) -Message "Windows LAN address must belong to exactly one interface."
    $addressRecord = $addressRecords[0]
    Assert-True -Condition ($addressRecord.PrefixLength -eq $PrefixLength) `
        -Message "Windows LAN prefix length does not match the declared prefix."
    $adapter = Get-NetAdapter -InterfaceIndex $addressRecord.InterfaceIndex -ErrorAction Stop
    Assert-True -Condition ($adapter.Status -eq 'Up' -and $adapter.HardwareInterface -and -not $adapter.Virtual) `
        -Message "LAN interface must be an up physical adapter."
    Assert-True -Condition ($adapter.Name -ceq $InterfaceAlias) -Message "LAN interface alias mismatch."
    $profile = Get-NetConnectionProfile -InterfaceIndex $addressRecord.InterfaceIndex -ErrorAction Stop
    Assert-True -Condition ($profile.NetworkCategory -eq 'Private') -Message "LAN interface must use the Private network category."

    $serviceRecord = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop
    Assert-True -Condition ($null -ne $serviceRecord) -Message "The single Windows sshd service is missing."
    Assert-True -Condition ([string]$serviceRecord.StartName -in @('LocalSystem', 'NT AUTHORITY\SYSTEM')) `
        -Message "sshd service must run as LocalSystem."
    $sshdPath = Get-ServiceExecutablePath -ServiceRecord $serviceRecord
    $expectedSshdPath = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    Assert-True -Condition ([System.IO.Path]::GetFullPath($sshdPath) -ieq [System.IO.Path]::GetFullPath($expectedSshdPath)) `
        -Message "sshd service must use the built-in System32 OpenSSH executable."
    Assert-NotReparsePoint -Path $sshdPath -Label "sshd executable"
    $signature = Get-AuthenticodeSignature -LiteralPath $sshdPath
    Assert-True -Condition ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match 'Microsoft') -Message "sshd executable must have a valid Microsoft signature."

    $sshKeygenPath = Join-Path (Split-Path -Parent $sshdPath) 'ssh-keygen.exe'
    Assert-True -Condition (Test-Path -LiteralPath $sshKeygenPath -PathType Leaf) `
        -Message "ssh-keygen is missing beside the verified sshd executable."
    Assert-NotReparsePoint -Path $sshKeygenPath -Label "ssh-keygen executable"
    $sshKeygenSignature = Get-AuthenticodeSignature -LiteralPath $sshKeygenPath
    Assert-True -Condition ($sshKeygenSignature.Status -eq 'Valid' -and $null -ne $sshKeygenSignature.SignerCertificate -and
        $sshKeygenSignature.SignerCertificate.Subject -match 'Microsoft') `
        -Message "ssh-keygen must have a valid Microsoft signature."

    $hostPublicKeyPath = Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub'
    $hostPrivateKeyPath = Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key'
    Assert-NotReparsePoint -Path $hostPublicKeyPath -Label "Host public key"
    Assert-True -Condition (Test-PrivateHostKeyAcl -Path $hostPrivateKeyPath) `
        -Message "Windows ED25519 host private-key ACL is too broad."
    $actualHostFingerprint = Get-PublicKeyFingerprint -PublicKeyLine (Get-Content -Raw -LiteralPath $hostPublicKeyPath) `
        -SshKeygenPath $sshKeygenPath
    Assert-True -Condition ($actualHostFingerprint -ceq $ExpectedHostKeyFingerprint) `
        -Message "Windows host-key fingerprint does not match the independent expected value."
    Assert-True -Condition (Test-SshdConfigAcl -Path $SshdConfigPath) `
        -Message "sshd_config ACL permits an unexpected writer."

    return [pscustomobject]@{
        lanUser = $currentLanUser
        relayUser = $currentRelayUser
        addressRecord = $addressRecord
        serviceRecord = $serviceRecord
        sshdPath = $sshdPath
        sshKeygenPath = $sshKeygenPath
        hostPublicKeyPath = $hostPublicKeyPath
        hostPrivateKeyPath = $hostPrivateKeyPath
        actualHostFingerprint = $actualHostFingerprint
    }
}

$registrationMutex = [System.Threading.Mutex]::new($false, 'Global\SkyBridgeWindowsLanSshLifecycleV1')
$registrationLockTaken = $false
try {
    try {
        $registrationLockTaken = $registrationMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $registrationLockTaken = $true
        throw "A previous Windows LAN SSH lifecycle transaction was abandoned; audit config, firewall, keys, and service state before retrying."
    }
    Assert-True -Condition $registrationLockTaken -Message "Another Windows LAN SSH lifecycle transaction is active."

Assert-Windows
Assert-True -Condition (Test-IsAdministrator) -Message "Windows LAN SSH registration requires an elevated PowerShell session."
Assert-True -Condition ($VerifyOnly.IsPresent -xor $Apply.IsPresent) -Message "Specify exactly one of -VerifyOnly or -Apply."
if ($Apply -and -not $WhatIfPreference) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($EvidencePath)) `
        -Message "EvidencePath is required for a real apply transaction."
}
Assert-True -Condition ($LanAccountName -ne $RelayAccountName) -Message "LAN and relay accounts must be distinct."
$expectedSshdConfigPath = Join-Path $env:ProgramData 'ssh\sshd_config'
Assert-True -Condition ([System.IO.Path]::GetFullPath($SshdConfigPath) -ieq [System.IO.Path]::GetFullPath($expectedSshdConfigPath)) `
    -Message "SshdConfigPath must be the active built-in OpenSSH configuration path."
$canonicalWindowsAddress = ConvertTo-CanonicalIPv4 -Value $WindowsLanAddress -Name "WindowsLanAddress"
$canonicalMacAddress = ConvertTo-CanonicalIPv4 -Value $MacLanAddress -Name "MacLanAddress"
Assert-True -Condition ($canonicalWindowsAddress -ne $canonicalMacAddress) -Message "Windows and Mac LAN addresses must differ."
Assert-True -Condition (Test-SameIPv4Prefix -Left $canonicalWindowsAddress -Right $canonicalMacAddress -PrefixLength $LanPrefixLength) -Message "Windows and Mac addresses are not in the declared LAN prefix."

$lanUser = Get-LocalUserByName -Name $LanAccountName
$relayUser = Get-LocalUserByName -Name $RelayAccountName
$authoritySnapshot = Get-WindowsSshAuthoritySnapshot -LanAccountName $LanAccountName -ExpectedLanSid $lanUser.SID.Value `
    -RelayAccountName $RelayAccountName -ExpectedRelaySid $relayUser.SID.Value -WindowsAddress $canonicalWindowsAddress `
    -PrefixLength $LanPrefixLength -InterfaceAlias $LanInterfaceAlias -SshdConfigPath $SshdConfigPath `
    -ExpectedHostKeyFingerprint $ExpectedWindowsHostKeyFingerprint
$lanUser = $authoritySnapshot.lanUser
$relayUser = $authoritySnapshot.relayUser
$serviceRecord = $authoritySnapshot.serviceRecord
$sshdPath = $authoritySnapshot.sshdPath
$sshKeygenPath = $authoritySnapshot.sshKeygenPath
$hostPublicKeyPath = $authoritySnapshot.hostPublicKeyPath
$hostPrivateKeyPath = $authoritySnapshot.hostPrivateKeyPath
$actualHostFingerprint = $authoritySnapshot.actualHostFingerprint
$profilePath = Get-LocalUserProfilePath -UserSid $lanUser.SID.Value
$sshDirectory = Join-Path $profilePath '.ssh'
$authorizedKeysPath = Join-Path $sshDirectory 'authorized_keys'
Assert-NotReparsePoint -Path $profilePath -Label "LAN account profile"
Assert-NotReparsePoint -Path $sshDirectory -Label "LAN account SSH directory"
Assert-NotReparsePoint -Path $authorizedKeysPath -Label "LAN authorized_keys"

$normalizedLanKey = (($LanAuthorizedPublicKey.Trim() -split '\s+')[0..1] -join ' ')
$directKeyFingerprint = Get-PublicKeyFingerprint -PublicKeyLine $normalizedLanKey -SshKeygenPath $sshKeygenPath
Assert-True -Condition ($directKeyFingerprint -ceq $ExpectedLanPublicKeyFingerprint) `
    -Message "LAN public-key fingerprint does not match the independent expected value."
$existingAuthorizedRecords = Get-AuthorizedKeyRecords -Path $authorizedKeysPath
Assert-True -Condition ($existingAuthorizedRecords.Count -le 1) -Message "LAN authorized_keys must not contain multiple active keys."
if ($existingAuthorizedRecords.Count -eq 1) {
    Assert-True -Condition ($existingAuthorizedRecords[0] -ceq $normalizedLanKey) -Message "LAN authorized_keys contains a different active key."
}

Assert-True -Condition (Test-Path -LiteralPath $SshdConfigPath -PathType Leaf) -Message "sshd_config is missing."
Assert-NotReparsePoint -Path $SshdConfigPath -Label "sshd_config"
Assert-True -Condition (Test-SshdConfigAcl -Path $SshdConfigPath) -Message "sshd_config ACL permits an unexpected writer."
$existingConfig = Get-Content -Raw -LiteralPath $SshdConfigPath
$existingRelayEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $SshdConfigPath -User $RelayAccountName `
    -RemoteAddress '127.0.0.1' -LocalAddress '127.0.0.1' -SshPort $Port
$existingRelayAuthorizedKeysFile = [string]$existingRelayEffective['authorizedkeysfile']
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($existingRelayAuthorizedKeysFile)) `
    -Message "Existing relay AuthorizedKeysFile cannot be resolved."
$candidateConfig = New-ManagedSshdConfig -ExistingContent $existingConfig -LanUser $LanAccountName -RelayUser $RelayAccountName `
    -MacAddress $canonicalMacAddress -LanAddress $canonicalWindowsAddress -SshPort $Port -AuthorizedKeysPath $authorizedKeysPath
$candidatePath = Join-Path (Split-Path -Parent $SshdConfigPath) ('.sshd_config.skybridge.' + [Guid]::NewGuid().ToString('N') + '.candidate')
try {
    [System.IO.File]::WriteAllText($candidatePath, $candidateConfig, [System.Text.UTF8Encoding]::new($false))
    $syntax = Invoke-NativeCapture -FileName $sshdPath -Arguments @('-t', '-f', $candidatePath)
    Assert-True -Condition ($syntax.exitCode -eq 0) -Message "Candidate sshd_config failed syntax validation."
    $lanEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $candidatePath -User $LanAccountName `
        -RemoteAddress $canonicalMacAddress -LocalAddress $canonicalWindowsAddress -SshPort $Port
    $relayEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $candidatePath -User $RelayAccountName `
        -RemoteAddress '127.0.0.1' -LocalAddress '127.0.0.1' -SshPort $Port
    $expectedAllowUsers = @("$LanAccountName@$canonicalMacAddress", "$RelayAccountName@127.0.0.1")
    Assert-EffectivePolicy -Values $lanEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $true `
        -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
    Assert-EffectivePolicy -Values $relayEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $false `
        -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
    Assert-True -Condition ([string]$relayEffective['authorizedkeysfile'] -ceq $existingRelayAuthorizedKeysFile) `
        -Message "Candidate policy changes the relay account AuthorizedKeysFile."
}
finally {
    if (Test-Path -LiteralPath $candidatePath) { Remove-Item -LiteralPath $candidatePath -Force }
}

$firewallExact = Test-ManagedFirewallRule -Name $FirewallRuleName -LanAddress $canonicalWindowsAddress `
    -SourceAddress $canonicalMacAddress -InterfaceAlias $LanInterfaceAlias -SshPort $Port -SshdPath $sshdPath
$conflictRules = @(Get-FirewallConflicts -ManagedRuleName $FirewallRuleName -LanAddress $canonicalWindowsAddress `
    -SourceAddress $canonicalMacAddress -SshPort $Port)
$conflicts = @($conflictRules | ForEach-Object { [string]$_.Name })
Assert-True -Condition (@($conflicts | Sort-Object -Unique).Count -eq $conflictRules.Count) `
    -Message "Active SSH firewall conflicts must have unique rule names before explicit disable."
$explicitDisable = @($DisableConflictingRuleName | Sort-Object -Unique)
$unapprovedConflicts = @($conflicts | Where-Object { $explicitDisable -notcontains $_ })
Assert-True -Condition ($unapprovedConflicts.Count -eq 0) -Message "Broad SSH firewall rules require explicit names in -DisableConflictingRuleName."
$unrelatedExplicitRules = @($explicitDisable | Where-Object { $conflicts -notcontains $_ })
Assert-True -Condition ($unrelatedExplicitRules.Count -eq 0) -Message "-DisableConflictingRuleName contains a rule that is not an observed SSH conflict."

$changed = $false
$rolledBack = $false
$createdFirewallRule = $null
$disabledRules = [System.Collections.Generic.List[object]]::new()
$originalConfigBytes = [System.IO.File]::ReadAllBytes($SshdConfigPath)
$originalConfigSddl = (Get-Acl -LiteralPath $SshdConfigPath).Sddl
$authorizedKeysExisted = Test-Path -LiteralPath $authorizedKeysPath -PathType Leaf
$sshDirectoryExisted = Test-Path -LiteralPath $sshDirectory -PathType Container
$originalAuthorizedBytes = if ($authorizedKeysExisted) { [System.IO.File]::ReadAllBytes($authorizedKeysPath) } else { $null }
$originalAuthorizedSddl = if ($authorizedKeysExisted) { (Get-Acl -LiteralPath $authorizedKeysPath).Sddl } else { "" }
$originalSshDirectorySddl = if ($sshDirectoryExisted) { (Get-Acl -LiteralPath $sshDirectory).Sddl } else { "" }
$originalServiceState = [string]$serviceRecord.State
$originalServiceStartMode = [string]$serviceRecord.StartMode
Assert-True -Condition ($originalServiceStartMode -in @('Auto', 'Manual', 'Disabled')) -Message "Unsupported sshd service start mode."
$finalPolicyInstalled = $false
$finalListenerSetExact = $false
$finalAuthorizedKeyExact = $false
$finalAclExact = $false
$finalListenerAddresses = @()

if ($VerifyOnly) {
    Assert-True -Condition ($existingConfig -ceq $candidateConfig) `
        -Message "Installed sshd_config does not equal the validated managed candidate."
    Assert-True -Condition ($serviceRecord.State -eq 'Running' -and $serviceRecord.StartMode -eq 'Auto') `
        -Message "sshd service lifecycle is not Running/Automatic."
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    $finalListenerAddresses = @($listeners.LocalAddress | Sort-Object -Unique)
    Assert-True -Condition ($finalListenerAddresses.Count -eq 2 -and
        $finalListenerAddresses -contains '127.0.0.1' -and
        $finalListenerAddresses -contains $canonicalWindowsAddress) `
        -Message "sshd listener set must be exactly loopback and the frozen LAN address."
    Assert-True -Condition (@($listeners | Where-Object { $_.OwningProcess -ne $serviceRecord.ProcessId }).Count -eq 0) `
        -Message "A listener is not owned by the sshd service process."
    $finalListenerSetExact = $true
    Assert-True -Condition $firewallExact -Message "Managed firewall rule is not exact."
    Assert-True -Condition ($conflictRules.Count -eq 0) -Message "A broad active SSH firewall rule conflicts with the managed rule."
    $installedLanEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $SshdConfigPath `
        -User $LanAccountName -RemoteAddress $canonicalMacAddress -LocalAddress $canonicalWindowsAddress -SshPort $Port
    $installedRelayEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $SshdConfigPath `
        -User $RelayAccountName -RemoteAddress '127.0.0.1' -LocalAddress '127.0.0.1' -SshPort $Port
    Assert-EffectivePolicy -Values $installedLanEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $true `
        -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
    Assert-EffectivePolicy -Values $installedRelayEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $false `
        -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
    Assert-True -Condition ([string]$installedRelayEffective['authorizedkeysfile'] -ceq $existingRelayAuthorizedKeysFile) `
        -Message "Installed policy changed the relay account AuthorizedKeysFile."
    $finalPolicyInstalled = $true
    $finalAuthorizedKeyExact = $existingAuthorizedRecords.Count -eq 1 -and
        $existingAuthorizedRecords[0] -ceq $normalizedLanKey
    Assert-True -Condition $finalAuthorizedKeyExact -Message "LAN authorized key is not exact."
    $finalAclExact = (Test-ExactLanSshPathAcl -Path $sshDirectory -UserSid $lanUser.SID.Value) -and
        (Test-ExactLanSshPathAcl -Path $authorizedKeysPath -UserSid $lanUser.SID.Value) -and
        (Test-SshdConfigAcl -Path $SshdConfigPath) -and
        (Test-PrivateHostKeyAcl -Path $hostPrivateKeyPath)
    Assert-True -Condition $finalAclExact -Message "An SSH lifecycle ACL is not exact."
}

if ($Apply) {
    if ($PSCmdlet.ShouldProcess("Windows sshd LAN lifecycle", "Apply exact LAN and relay SSH policy")) {
        try {
            Assert-True -Condition (Test-ByteSequenceEqual -Left ([System.IO.File]::ReadAllBytes($SshdConfigPath)) -Right $originalConfigBytes) `
                -Message "sshd_config changed after preflight."
            Assert-True -Condition ((Get-Acl -LiteralPath $SshdConfigPath).Sddl -ceq $originalConfigSddl) `
                -Message "sshd_config ACL changed after preflight."
            $freshAuthoritySnapshot = Get-WindowsSshAuthoritySnapshot -LanAccountName $LanAccountName `
                -ExpectedLanSid $lanUser.SID.Value -RelayAccountName $RelayAccountName `
                -ExpectedRelaySid $relayUser.SID.Value -WindowsAddress $canonicalWindowsAddress `
                -PrefixLength $LanPrefixLength -InterfaceAlias $LanInterfaceAlias -SshdConfigPath $SshdConfigPath `
                -ExpectedHostKeyFingerprint $ExpectedWindowsHostKeyFingerprint
            $freshServiceRecord = $freshAuthoritySnapshot.serviceRecord
            Assert-True -Condition ([string]$freshServiceRecord.State -ceq $originalServiceState -and
                [string]$freshServiceRecord.StartMode -ceq $originalServiceStartMode -and
                [string]$freshServiceRecord.PathName -ceq [string]$serviceRecord.PathName) `
                -Message "sshd service state changed after preflight."
            if ($authorizedKeysExisted) {
                Assert-True -Condition (Test-ByteSequenceEqual -Left ([System.IO.File]::ReadAllBytes($authorizedKeysPath)) `
                    -Right $originalAuthorizedBytes) -Message "LAN authorized_keys changed after preflight."
                Assert-True -Condition ((Get-Acl -LiteralPath $authorizedKeysPath).Sddl -ceq $originalAuthorizedSddl) `
                    -Message "LAN authorized_keys ACL changed after preflight."
            } else {
                Assert-True -Condition (-not (Test-Path -LiteralPath $authorizedKeysPath)) `
                    -Message "LAN authorized_keys appeared after preflight."
            }
            if ($sshDirectoryExisted) {
                Assert-True -Condition ((Get-Acl -LiteralPath $sshDirectory).Sddl -ceq $originalSshDirectorySddl) `
                    -Message "LAN SSH directory ACL changed after preflight."
            } else {
                Assert-True -Condition (-not (Test-Path -LiteralPath $sshDirectory)) `
                    -Message "LAN SSH directory appeared after preflight."
            }
            if (-not $sshDirectoryExisted) { New-Item -ItemType Directory -Path $sshDirectory | Out-Null }
            if (-not $authorizedKeysExisted -or $existingAuthorizedRecords.Count -eq 0) {
                [System.IO.File]::WriteAllText($authorizedKeysPath, ($LanAuthorizedPublicKey.Trim() + "`r`n"), [System.Text.ASCIIEncoding]::new())
            }
            Set-ExactSshPathAcl -Path $sshDirectory -UserSid $lanUser.SID.Value -Directory $true
            Set-ExactSshPathAcl -Path $authorizedKeysPath -UserSid $lanUser.SID.Value -Directory $false
            Write-TextAtomic -Path $SshdConfigPath -Content $candidateConfig

            if (-not $firewallExact) {
                $existingManaged = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
                Assert-True -Condition ($null -eq $existingManaged) -Message "Existing managed firewall rule has a non-exact shape."
                $createdFirewallRule = New-NetFirewallRule -Name $FirewallRuleName -DisplayName 'SkyBridge Windows LAN SSH' -Direction Inbound `
                    -Action Allow -Enabled True -Profile Private -Protocol TCP -LocalPort $Port `
                    -LocalAddress $canonicalWindowsAddress -RemoteAddress $canonicalMacAddress `
                    -InterfaceAlias $LanInterfaceAlias -Program $sshdPath -Service 'sshd' `
                    -EdgeTraversalPolicy Block -LooseSourceMapping $false -LocalOnlyMapping $false
            }
            foreach ($conflictRule in $conflictRules) {
                Disable-NetFirewallRule -InputObject $conflictRule -ErrorAction Stop | Out-Null
                $disabledRules.Add($conflictRule)
            }

            $finalSyntax = Invoke-NativeCapture -FileName $sshdPath -Arguments @('-t', '-f', $SshdConfigPath)
            Assert-True -Condition ($finalSyntax.exitCode -eq 0) -Message "Installed sshd_config failed syntax validation."
            Set-Service -Name sshd -StartupType Automatic
            Restart-Service -Name sshd
            $service = Get-Service -Name sshd -ErrorAction Stop
            Assert-True -Condition ($service.Status -eq 'Running') -Message "sshd did not return to Running."
            $installedAuthoritySnapshot = Get-WindowsSshAuthoritySnapshot -LanAccountName $LanAccountName `
                -ExpectedLanSid $lanUser.SID.Value -RelayAccountName $RelayAccountName `
                -ExpectedRelaySid $relayUser.SID.Value -WindowsAddress $canonicalWindowsAddress `
                -PrefixLength $LanPrefixLength -InterfaceAlias $LanInterfaceAlias -SshdConfigPath $SshdConfigPath `
                -ExpectedHostKeyFingerprint $ExpectedWindowsHostKeyFingerprint
            $serviceRecord = $installedAuthoritySnapshot.serviceRecord
            Assert-True -Condition ($serviceRecord.State -eq 'Running' -and $serviceRecord.StartMode -eq 'Auto') `
                -Message "sshd service lifecycle is not Running/Automatic."
            Assert-True -Condition ([System.IO.Path]::GetFullPath((Get-ServiceExecutablePath -ServiceRecord $serviceRecord)) -ieq `
                [System.IO.Path]::GetFullPath($sshdPath)) -Message "sshd service executable changed during apply."
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
            $listenerAddresses = @($listeners.LocalAddress | Sort-Object -Unique)
            $finalListenerAddresses = $listenerAddresses
            Assert-True -Condition ($listenerAddresses.Count -eq 2 -and $listenerAddresses -contains '127.0.0.1' -and $listenerAddresses -contains $canonicalWindowsAddress) -Message "sshd listener set must be exactly loopback and the frozen LAN address."
            Assert-True -Condition (@($listeners | Where-Object { $_.OwningProcess -ne $serviceRecord.ProcessId }).Count -eq 0) -Message "A listener is not owned by the sshd service process."
            $finalListenerSetExact = $true
            $firewallExact = Test-ManagedFirewallRule -Name $FirewallRuleName -LanAddress $canonicalWindowsAddress `
                -SourceAddress $canonicalMacAddress -InterfaceAlias $LanInterfaceAlias -SshPort $Port -SshdPath $sshdPath
            Assert-True -Condition $firewallExact -Message "Managed firewall rule is not exact after apply."
            $remainingConflicts = @(Get-FirewallConflicts -ManagedRuleName $FirewallRuleName -LanAddress $canonicalWindowsAddress `
                -SourceAddress $canonicalMacAddress -SshPort $Port)
            Assert-True -Condition ($remainingConflicts.Count -eq 0) -Message "A broad active SSH firewall rule remains after apply."
            $installedLanEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $SshdConfigPath `
                -User $LanAccountName -RemoteAddress $canonicalMacAddress -LocalAddress $canonicalWindowsAddress -SshPort $Port
            $installedRelayEffective = Get-EffectiveSshdConfig -SshdPath $sshdPath -ConfigPath $SshdConfigPath `
                -User $RelayAccountName -RemoteAddress '127.0.0.1' -LocalAddress '127.0.0.1' -SshPort $Port
            Assert-EffectivePolicy -Values $installedLanEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $true `
                -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
            Assert-EffectivePolicy -Values $installedRelayEffective -LanAuthorizedKeysPath $authorizedKeysPath -LanUser $false `
                -ExpectedAllowUsers $expectedAllowUsers -SshPort $Port
            Assert-True -Condition ([string]$installedRelayEffective['authorizedkeysfile'] -ceq $existingRelayAuthorizedKeysFile) `
                -Message "Installed policy changed the relay account AuthorizedKeysFile."
            Assert-True -Condition ((Get-Content -Raw -LiteralPath $SshdConfigPath) -ceq $candidateConfig) `
                -Message "Installed sshd_config does not equal the validated candidate."
            $finalPolicyInstalled = $true
            $finalAuthorizedRecords = @(Get-AuthorizedKeyRecords -Path $authorizedKeysPath)
            $finalAuthorizedKeyExact = $finalAuthorizedRecords.Count -eq 1 -and $finalAuthorizedRecords[0] -ceq $normalizedLanKey
            Assert-True -Condition $finalAuthorizedKeyExact -Message "LAN authorized key is not exact after apply."
            $finalAclExact = (Test-ExactLanSshPathAcl -Path $sshDirectory -UserSid $lanUser.SID.Value) -and
                (Test-ExactLanSshPathAcl -Path $authorizedKeysPath -UserSid $lanUser.SID.Value) -and
                (Test-SshdConfigAcl -Path $SshdConfigPath) -and
                (Test-PrivateHostKeyAcl -Path $hostPrivateKeyPath)
            Assert-True -Condition $finalAclExact -Message "An SSH lifecycle ACL is not exact after apply."
            $changed = $true
        }
        catch {
            $primaryError = $_.Exception.Message
            $rollbackErrors = [System.Collections.Generic.List[string]]::new()
            try { [System.IO.File]::WriteAllBytes($SshdConfigPath, $originalConfigBytes) } catch { $rollbackErrors.Add("config-bytes") }
            try {
                $acl = Get-Acl -LiteralPath $SshdConfigPath
                $acl.SetSecurityDescriptorSddlForm($originalConfigSddl)
                Set-Acl -LiteralPath $SshdConfigPath -AclObject $acl
            } catch { $rollbackErrors.Add("config-acl") }
            try {
                if ($authorizedKeysExisted) {
                    [System.IO.File]::WriteAllBytes($authorizedKeysPath, $originalAuthorizedBytes)
                    $acl = Get-Acl -LiteralPath $authorizedKeysPath
                    $acl.SetSecurityDescriptorSddlForm($originalAuthorizedSddl)
                    Set-Acl -LiteralPath $authorizedKeysPath -AclObject $acl
                } elseif (Test-Path -LiteralPath $authorizedKeysPath) {
                    Remove-Item -LiteralPath $authorizedKeysPath -Force
                }
                if ($sshDirectoryExisted) {
                    $acl = Get-Acl -LiteralPath $sshDirectory
                    $acl.SetSecurityDescriptorSddlForm($originalSshDirectorySddl)
                    Set-Acl -LiteralPath $sshDirectory -AclObject $acl
                } elseif (Test-Path -LiteralPath $sshDirectory) {
                    Remove-Item -LiteralPath $sshDirectory -Force
                }
            } catch { $rollbackErrors.Add("authorized-keys") }
            try { if ($null -ne $createdFirewallRule) { Remove-NetFirewallRule -InputObject $createdFirewallRule -ErrorAction Stop } } catch { $rollbackErrors.Add("firewall-created") }
            foreach ($disabledRule in $disabledRules) {
                try { Enable-NetFirewallRule -InputObject $disabledRule -ErrorAction Stop | Out-Null } catch { $rollbackErrors.Add("firewall-$($disabledRule.Name)") }
            }
            try {
                Restore-SshdServiceState -OriginalState $originalServiceState -OriginalStartMode $originalServiceStartMode
            } catch { $rollbackErrors.Add("sshd-service-state") }
            $rolledBack = $rollbackErrors.Count -eq 0
            $failureEvidenceError = ""
            if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
                $failureEvidence = [ordered]@{
                    schema = 'skybridge-windows-lan-ssh-registration-v1'
                    evidenceClass = 'private-provisioning'
                    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
                    mode = 'apply'
                    outcome = 'failed'
                    primaryError = $primaryError
                    rollbackSucceeded = [bool]$rolledBack
                    rollbackErrors = @($rollbackErrors)
                    expectedHostKeyFingerprint = $ExpectedWindowsHostKeyFingerprint
                    expectedDirectPublicKeyFingerprint = $ExpectedLanPublicKeyFingerprint
                    directPublicKeyProvenanceRef = $LanPublicKeyProvenanceRef
                    accepted = $false
                }
                try {
                    [void](Write-JsonAtomic -Value $failureEvidence -Path $EvidencePath)
                }
                catch {
                    $failureEvidenceError = $_.Exception.Message
                }
            }
            $failureMessage = if ($rolledBack) {
                "LAN SSH registration failed and was rolled back: $primaryError"
            } else {
                "LAN SSH registration failed: $primaryError; rollback also failed: $($rollbackErrors -join ',')"
            }
            if (-not [string]::IsNullOrWhiteSpace($failureEvidenceError)) {
                $failureMessage += "; private failure evidence also failed: $failureEvidenceError"
            }
            throw $failureMessage
        }
    }
}

$evidenceAuthoritySnapshot = Get-WindowsSshAuthoritySnapshot -LanAccountName $LanAccountName `
    -ExpectedLanSid $lanUser.SID.Value -RelayAccountName $RelayAccountName `
    -ExpectedRelaySid $relayUser.SID.Value -WindowsAddress $canonicalWindowsAddress `
    -PrefixLength $LanPrefixLength -InterfaceAlias $LanInterfaceAlias -SshdConfigPath $SshdConfigPath `
    -ExpectedHostKeyFingerprint $ExpectedWindowsHostKeyFingerprint
$serviceRecord = $evidenceAuthoritySnapshot.serviceRecord
$sshdPath = $evidenceAuthoritySnapshot.sshdPath
$actualHostFingerprint = $evidenceAuthoritySnapshot.actualHostFingerprint
$finalServiceSignature = Get-AuthenticodeSignature -LiteralPath $sshdPath
Assert-True -Condition ($finalServiceSignature.Status -eq 'Valid' -and $null -ne $finalServiceSignature.SignerCertificate -and
    $finalServiceSignature.SignerCertificate.Subject -match 'Microsoft') `
    -Message "sshd executable signature changed before evidence commit."
$sshdExecutableSha256 = Get-FileSha256 -Path $sshdPath
$sshdConfigSha256 = Get-FileSha256 -Path $SshdConfigPath
$authorizedKeysSha256 = if (Test-Path -LiteralPath $authorizedKeysPath -PathType Leaf) {
    Get-FileSha256 -Path $authorizedKeysPath
} else { "" }
$evidence = [ordered]@{
    schema = 'skybridge-windows-lan-ssh-registration-v1'
    evidenceClass = 'private-provisioning'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    mode = if ($VerifyOnly) { 'verify-only' } elseif ($WhatIfPreference) { 'what-if' } else { 'apply' }
    outcome = 'succeeded'
    lanAccount = $LanAccountName
    relayAccount = $RelayAccountName
    lanAccountSid = $lanUser.SID.Value
    relayAccountSid = $relayUser.SID.Value
    windowsLanAddress = $canonicalWindowsAddress
    macLanAddress = $canonicalMacAddress
    prefixLength = $LanPrefixLength
    interfaceAlias = $LanInterfaceAlias
    port = $Port
    firewallRuleName = $FirewallRuleName
    sshdServiceState = [string]$serviceRecord.State
    sshdServiceStartMode = [string]$serviceRecord.StartMode
    sshdServiceStartName = [string]$serviceRecord.StartName
    sshdServiceProcessId = [int]$serviceRecord.ProcessId
    sshdExecutableSha256 = $sshdExecutableSha256
    sshdSignatureStatus = [string]$finalServiceSignature.Status
    sshdSignerSubject = [string]$finalServiceSignature.SignerCertificate.Subject
    sshdConfigSha256 = $sshdConfigSha256
    authorizedKeysSha256 = $authorizedKeysSha256
    listenerAddresses = @($finalListenerAddresses)
    expectedHostKeyFingerprint = $ExpectedWindowsHostKeyFingerprint
    actualHostKeyFingerprint = $actualHostFingerprint
    expectedDirectPublicKeyFingerprint = $ExpectedLanPublicKeyFingerprint
    actualDirectPublicKeyFingerprint = $directKeyFingerprint
    directPublicKeyProvenanceRef = $LanPublicKeyProvenanceRef
    candidateConfigValid = $true
    lanEffectivePolicyValid = $true
    relayEffectivePolicyValid = $true
    hostPrivateKeyAclValid = $true
    lanAccountNonAdministrator = $true
    relayAccountNonAdministrator = $true
    managedFirewallExact = [bool]$firewallExact
    firewallConflicts = @($conflicts)
    preflightPassed = $true
    finalPolicyInstalled = [bool]$finalPolicyInstalled
    finalListenerSetExact = [bool]$finalListenerSetExact
    finalAuthorizedKeyExact = [bool]$finalAuthorizedKeyExact
    finalAclExact = [bool]$finalAclExact
    changed = [bool]$changed
    rolledBack = [bool]$rolledBack
    accepted = $false
}
$resolvedEvidence = Write-JsonAtomic -Value $evidence -Path $EvidencePath
Write-Output "windows-lan-ssh-registration: mode=$($evidence.mode) accepted=$($evidence.accepted) changed=$changed"
if (-not [string]::IsNullOrWhiteSpace($resolvedEvidence)) { Write-Output "windows-lan-ssh-registration: privateEvidenceWritten=true" }
}
finally {
    if ($registrationLockTaken) { $registrationMutex.ReleaseMutex() }
    $registrationMutex.Dispose()
}
