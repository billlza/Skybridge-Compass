param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected='$Expected' Actual='$Actual'"
    }
}

function Get-ParsedScript {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors)
    if ($errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" })
        throw "PowerShell parse failed for '$Path': $($messages -join '; ')"
    }
    return $ast
}

function Assert-NoEmptyCatch {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$Label
    )

    $emptyCatches = @($Ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.CatchClauseAst] -and $node.Body.Statements.Count -eq 0
    }, $true))
    Assert-Equal -Expected 0 -Actual $emptyCatches.Count -Message "$Label must not contain an empty catch block."
}

function Assert-NoForbiddenCommand {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string[]]$Names,
        [string]$Label
    )

    $forbidden = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        [void]$forbidden.Add($name)
    }
    $matches = @($Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
        $commandName = $node.GetCommandName()
        return -not [string]::IsNullOrWhiteSpace($commandName) -and $forbidden.Contains($commandName)
    }, $true))
    Assert-Equal -Expected 0 -Actual $matches.Count -Message "$Label invokes a forbidden command."
}

function New-PositiveObservation {
    return [ordered]@{
        clientPlatform = "macOS"
        addressesCanonical = $true
        addressesDistinct = $true
        samePrefix = $true
        interfaceMatches = $true
        interfaceIsPhysical = $true
        interfaceActive = $true
        interfaceAddressMatches = $true
        interfacePrefixMatches = $true
        routeInterfaceMatches = $true
        routeDestinationMatches = $true
        routeIsDirect = $true
        neighborMatches = $true
        pinDurable = $true
        pinOwnerSafe = $true
        pinActiveRecordCount = 1
        pinTargetMatches = $true
        pinAlgorithm = "ssh-ed25519"
        pinDigestMatches = $true
        identityFileOwnerOnly = $true
        identityAlgorithm = "ssh-ed25519"
        identityDigestMatches = $true
        sshConfigDisabled = $true
        sshNumericTarget = $true
        sshBoundSource = $true
        sshBoundInterface = $true
        sshStrictPin = $true
        sshPublicKeyOnly = $true
        sshAgentDisabled = $true
        sshPasswordsDisabled = $true
        sshNoProxyOrJump = $true
        sshForwardingDisabled = $true
        sshArgumentListBounded = $true
        sshRemoteScriptViaStandardInput = $true
        sshRemoteScriptBounded = $true
        sshRemotePowerShellAbsolute = $true
        requestedKex = "mlkem768x25519-sha256"
        sshExitCode = 0
        negotiatedKex = "mlkem768x25519-sha256"
        negotiatedHostKeyAlgorithm = "ssh-ed25519"
        sshKnownHostMatched = $true
        negotiatedHostKeyDigestMatches = $true
        appleToolManifestTrusted = $true
        appleToolManifestStable = $true
        boundInputSnapshotsStable = $true
        routeSnapshotStable = $true
        serverAuditStillFresh = $true
        evidenceParentsStable = $true
        serverAuditSchemaExact = $true
        serverAuditDigestMatches = $true
        serverAuditFresh = $true
        serverAuditBindingMatches = $true
        serverAuditPassed = $true
        serverAuditAcceptedFalse = $true
        serverAuditFileOwnerSafe = $true
        serverRuntimeExact = $true
        serverKeysAndAclExact = $true
        serverFirewallExact = $true
        serverAuthenticationPolicyExact = $true
        serverSourceManifestBound = $true
        remoteSchema = "skybridge-windows-lan-ssh-session-audit-v1"
        remoteWindows = $true
        remoteAccountEnabled = $true
        remoteAccountNameMatches = $true
        remoteAccountSidMatches = $true
        remoteAccountIsAdministrator = $false
        remotePowerShellPathMatches = $true
        remotePowerShellDigestMatches = $true
        remoteSshConnectionMatches = $true
    }
}

function New-PositiveRegistrationArtifact {
    $hostDigest = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    $clientDigest = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    return [pscustomobject][ordered]@{
        schema = "skybridge-windows-lan-ssh-registration-v1"
        evidenceClass = "private-provisioning"
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        mode = "verify-only"
        outcome = "succeeded"
        lanAccount = "lanuser"
        relayAccount = "relayuser"
        lanAccountSid = "S-1-5-21-111111111-222222222-333333333-4444"
        relayAccountSid = "S-1-5-21-111111111-222222222-333333333-5555"
        windowsLanAddress = "192.0.2.20"
        macLanAddress = "192.0.2.10"
        prefixLength = 24
        interfaceAlias = "Ethernet"
        port = 22
        firewallRuleName = "SkyBridge-Windows-LAN-SSH"
        sshdServiceState = "Running"
        sshdServiceStartMode = "Auto"
        sshdServiceStartName = "LocalSystem"
        sshdServiceProcessId = 4242
        sshdExecutableSha256 = ("a" * 64)
        sshdSignatureStatus = "Valid"
        sshdSignerSubject = "CN=Microsoft Corporation"
        sshdConfigSha256 = ("b" * 64)
        authorizedKeysSha256 = ("c" * 64)
        listenerAddresses = @("127.0.0.1", "192.0.2.20")
        expectedHostKeyFingerprint = $hostDigest
        actualHostKeyFingerprint = $hostDigest
        expectedDirectPublicKeyFingerprint = $clientDigest
        actualDirectPublicKeyFingerprint = $clientDigest
        directPublicKeyProvenanceRef = "approved-key:fixture-v1"
        candidateConfigValid = $true
        lanEffectivePolicyValid = $true
        relayEffectivePolicyValid = $true
        hostPrivateKeyAclValid = $true
        lanAccountNonAdministrator = $true
        relayAccountNonAdministrator = $true
        managedFirewallExact = $true
        firewallConflicts = @()
        preflightPassed = $true
        finalPolicyInstalled = $true
        finalListenerSetExact = $true
        finalAuthorizedKeyExact = $true
        finalAclExact = $true
        changed = $false
        rolledBack = $false
        accepted = $false
    }
}

function Copy-Observation {
    param($Observation)
    return (($Observation | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
}

function Write-Fixture {
    param(
        [string]$Path,
        $Observation
    )

    $fixture = [ordered]@{
        schema = "skybridge-windows-lan-ssh-lifecycle-fixture-v1"
        observation = $Observation
        sensitive = [ordered]@{
            targetAddress = "203.0.113.77"
            sourceAddress = "198.51.100.42"
            interfaceName = "en99-CANARY"
            hostName = "WIN-CANARY-HOST"
            accountName = "lan-user-CANARY"
            accountSid = "S-1-5-21-111111111-222222222-333333333-4444"
            identityPath = "/Users/canary/.ssh/direct-CANARY"
            knownHostsPath = "/Users/canary/.ssh/known-hosts-CANARY"
            hostKeyFingerprint = "SHA256:HOST-CANARY"
            identityKeyFingerprint = "SHA256:IDENTITY-CANARY"
            rawStderr = "RAW_STDERR_CANARY"
        }
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (($fixture | ConvertTo-Json -Depth 10) + "`n"),
        [System.Text.UTF8Encoding]::new($false))
}

function Invoke-FixtureCase {
    param(
        [string]$Name,
        $Observation,
        [bool]$ExpectEvaluationPassed,
        [string]$ExpectedFailedCheck = ""
    )

    $caseRoot = Join-Path $script:TempRoot $Name
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $fixturePath = Join-Path $caseRoot "fixture.json"
    $privatePath = Join-Path $caseRoot "private.json"
    $publicPath = Join-Path $caseRoot "public.json"
    Write-Fixture -Path $fixturePath -Observation $Observation

    $failed = $false
    $failureMessage = ""
    $commandOutput = @()
    try {
        $commandOutput = @(& $script:VerifierPath -FixturePath $fixturePath -PrivateEvidencePath $privatePath -PublicEvidencePath $publicPath)
    }
    catch {
        $failed = $true
        $failureMessage = $_.Exception.Message
    }
    Assert-Equal -Expected (-not $ExpectEvaluationPassed) -Actual $failed -Message "Fixture '$Name' process result mismatch. Failure='$failureMessage'."
    Assert-True -Condition (Test-Path -LiteralPath $privatePath -PathType Leaf) -Message "Fixture '$Name' did not write private evidence."
    Assert-True -Condition (Test-Path -LiteralPath $publicPath -PathType Leaf) -Message "Fixture '$Name' did not write public evidence."

    $privateText = Get-Content -Raw -LiteralPath $privatePath
    $publicText = Get-Content -Raw -LiteralPath $publicPath
    $private = $privateText | ConvertFrom-Json
    $public = $publicText | ConvertFrom-Json
    Assert-Equal -Expected $ExpectEvaluationPassed -Actual ([bool]$private.evaluationPassed) -Message "Fixture '$Name' private evaluation mismatch."
    Assert-Equal -Expected $ExpectEvaluationPassed -Actual ([bool]$public.evaluationPassed) -Message "Fixture '$Name' public evaluation mismatch."
    Assert-Equal -Expected $false -Actual ([bool]$private.accepted) -Message "Fixture '$Name' private evidence must never be accepted."
    Assert-Equal -Expected $false -Actual ([bool]$public.accepted) -Message "Fixture '$Name' public evidence must never be accepted."
    Assert-Equal -Expected $true -Actual ([bool]$private.fixtureEvidenceNotAccepted) -Message "Fixture '$Name' must declare its non-acceptance boundary."
    Assert-Equal -Expected $true -Actual ([bool]$public.fixtureEvidenceNotAccepted) -Message "Fixture '$Name' public projection must declare its non-acceptance boundary."
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFailedCheck)) {
        Assert-True -Condition (@($public.failedCheckCodes) -contains $ExpectedFailedCheck) -Message "Fixture '$Name' omitted expected failed check '$ExpectedFailedCheck'."
    }
    return [ordered]@{
        privatePath = $privatePath
        publicPath = $publicPath
        privateText = $privateText
        publicText = $publicText
        commandOutputText = ($commandOutput -join "`n")
        private = $private
        public = $public
    }
}

$verifierPath = Join-Path $RepoRoot "Scripts/verify-windows-lan-ssh-lifecycle.ps1"
$registrationPath = Join-Path $RepoRoot "Scripts/register-windows-lan-ssh-access.ps1"
Assert-True -Condition (Test-Path -LiteralPath $verifierPath -PathType Leaf) -Message "Missing Windows LAN SSH lifecycle verifier."
Assert-True -Condition (Test-Path -LiteralPath $registrationPath -PathType Leaf) -Message "Missing Windows LAN SSH registration script."
$script:VerifierPath = $verifierPath

$verifierAst = Get-ParsedScript -Path $verifierPath
$registrationAst = Get-ParsedScript -Path $registrationPath
Assert-NoEmptyCatch -Ast $verifierAst -Label "LAN SSH lifecycle verifier"
Assert-NoEmptyCatch -Ast $registrationAst -Label "LAN SSH registration"
$discoveryCommand = @("ssh", "keyscan") -join "-"
Assert-NoForbiddenCommand -Ast $verifierAst -Names @($discoveryCommand) -Label "LAN SSH lifecycle verifier"
Assert-NoForbiddenCommand -Ast $registrationAst -Names @($discoveryCommand, "Set-LocalUser", "Add-LocalGroupMember") -Label "LAN SSH registration"

$verifierSource = Get-Content -Raw -LiteralPath $verifierPath
$registrationSource = Get-Content -Raw -LiteralPath $registrationPath
Assert-True -Condition (-not $verifierSource.Contains($discoveryCommand, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Verifier must not contain host-key discovery fallback."
Assert-True -Condition (-not $registrationSource.Contains($discoveryCommand, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Registration must not discover or trust a host key."
Assert-True -Condition (-not $verifierSource.Contains("accept-new", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Verifier must not use accept-new."
Assert-True -Condition (-not $registrationSource.Contains("accept-new", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Registration must not use accept-new."

$knownHostsWriteCommands = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @("Set-Content", "Add-Content", "Clear-Content", "Out-File", "Copy-Item", "Move-Item", "Rename-Item", "Remove-Item")) {
    [void]$knownHostsWriteCommands.Add($name)
}
$knownHostsWrites = @($verifierAst.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
    $commandName = $node.GetCommandName()
    return -not [string]::IsNullOrWhiteSpace($commandName) -and
        $knownHostsWriteCommands.Contains($commandName) -and
        $node.Extent.Text -match '(?i)knownhosts|known_hosts'
}, $true))
Assert-Equal -Expected 0 -Actual $knownHostsWrites.Count -Message "Verifier must never mutate the pinned known_hosts file."
$knownHostsMemberWrites = @($verifierAst.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
    $memberName = [string]$node.Member.Value
    return $memberName -in @("WriteAllText", "WriteAllBytes", "OpenWrite", "Create", "Delete", "Move", "Replace") -and
        $node.Extent.Text -match '(?i)knownhosts|known_hosts'
}, $true))
Assert-Equal -Expected 0 -Actual $knownHostsMemberWrites.Count -Message "Verifier must never mutate the pinned known_hosts file through .NET APIs."

$remoteSessionFunctions = @($verifierAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "New-RemoteSessionAuditScript"
}, $true))
Assert-Equal -Expected 1 -Actual $remoteSessionFunctions.Count -Message "Verifier must define exactly one bounded remote session audit script."
$remoteSessionSource = $remoteSessionFunctions[0].Extent.Text
foreach ($privilegedCommand in @("Get-Acl", "Get-CimInstance", "Get-LocalUser", "Get-NetFirewallRule", "Get-NetTCPConnection", "Get-AuthenticodeSignature")) {
    Assert-True -Condition (-not $remoteSessionSource.Contains($privilegedCommand, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Remote non-administrative session audit must not invoke $privilegedCommand."
}
Assert-True -Condition $verifierSource.Contains('mode -eq "server-audit"', [System.StringComparison]::Ordinal) -Message "Verifier must provide a distinct Windows-local server-audit mode."
Assert-True -Condition $verifierSource.Contains('evidenceClass = "private-server-audit"', [System.StringComparison]::Ordinal) -Message "Server audit must be classified as private evidence."
Assert-True -Condition $verifierSource.Contains('serverAuditSha256', [System.StringComparison]::Ordinal) -Message "Live verification must bind the independently hashed server audit."
Assert-True -Condition $verifierSource.Contains('[string]$ExpectedRelayAccountSid', [System.StringComparison]::Ordinal) -Message "Production verification must bind the independently expected relay-account SID."
Assert-True -Condition $verifierSource.Contains('& $registrationScriptPath', [System.StringComparison]::Ordinal) -Message "Server audit must compose the registration VerifyOnly authority."
Assert-True -Condition $verifierSource.Contains('-VerifyOnly', [System.StringComparison]::Ordinal) -Message "Server audit must invoke registration in active VerifyOnly mode."
Assert-True -Condition (-not $verifierSource.Contains("New-WindowsServerAuditScript", [System.StringComparison]::Ordinal)) -Message "Verifier must not duplicate the registration authority in a second server audit implementation."
foreach ($unsupportedApi in @(".ArgumentList", "::HashData", ".Kill(`$true)", "UnixFileMode", "SetUnixFileMode", "RuntimeInformation", "OSPlatform")) {
    Assert-True -Condition (-not $verifierSource.Contains($unsupportedApi, [System.StringComparison]::Ordinal)) -Message "Verifier contains a Windows PowerShell 5.1-incompatible API: $unsupportedApi"
}
if ($env:OS -ne "Windows_NT") {
    foreach ($functionName in @("Resolve-NativeCommandPath", "ConvertTo-ProcessArgument", "Invoke-NativeCapture")) {
        $definitions = @($verifierAst.FindAll({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
        }, $true))
        Assert-Equal -Expected 1 -Actual $definitions.Count -Message "Verifier must define exactly one $functionName function."
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $argumentCanary = 'value with spaces "quoted" and trailing-backslash\'
    $argumentResult = Invoke-NativeCapture -FileName "/usr/bin/printf" -Arguments @("%s", $argumentCanary)
    Assert-Equal -Expected 0 -Actual $argumentResult.exitCode -Message "Native argument round-trip command failed."
    Assert-Equal -Expected $argumentCanary -Actual $argumentResult.stdout -Message "Native argument quoting changed a bounded argument."
    $stdinCanary = "standard-input-canary`nsecond-line"
    $stdinResult = Invoke-NativeCapture -FileName "/bin/cat" -Arguments @() -StandardInputText $stdinCanary
    Assert-Equal -Expected 0 -Actual $stdinResult.exitCode -Message "Native standard-input round-trip command failed."
    Assert-Equal -Expected $stdinCanary -Actual $stdinResult.stdout -Message "Native standard-input transport changed the payload."

    foreach ($functionName in @("Get-StringSha256", "Get-FileSha256", "Get-UnixFileSecurityObservation", "Get-MacDirectoryChainSnapshot", "Get-BoundFileSnapshot", "Test-BoundFileSnapshotMatch")) {
        $definitions = @($verifierAst.FindAll({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
        }, $true))
        Assert-Equal -Expected 1 -Actual $definitions.Count -Message "Verifier must define exactly one $functionName function."
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $boundTestRoot = Join-Path ([Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)) (".skybridge-bound-file-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $boundTestRoot | Out-Null
    & /bin/chmod 700 $boundTestRoot
    Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Message "chmod failed for bound-file fixture root."
    try {
        $boundFile = Join-Path $boundTestRoot "authority.bin"
        [System.IO.File]::WriteAllText($boundFile, "authority-A", [System.Text.UTF8Encoding]::new($false))
        & /bin/chmod 600 $boundFile
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Message "chmod failed for bound-file fixture."
        $snapshotA = Get-BoundFileSnapshot -Path $boundFile -RequireMode0600 $true -TrustedRoot $boundTestRoot
        $snapshotAUnchanged = Get-BoundFileSnapshot -Path $boundFile -RequireMode0600 $true -TrustedRoot $boundTestRoot
        Assert-True -Condition (Test-BoundFileSnapshotMatch -Before $snapshotA -After $snapshotAUnchanged) -Message "Unchanged bound-file snapshots must match."
        [System.IO.File]::WriteAllText($boundFile, "authority-B", [System.Text.UTF8Encoding]::new($false))
        $snapshotB = Get-BoundFileSnapshot -Path $boundFile -RequireMode0600 $true -TrustedRoot $boundTestRoot
        Assert-True -Condition (-not (Test-BoundFileSnapshotMatch -Before $snapshotA -After $snapshotB)) -Message "A real A-to-B bound-file mutation must invalidate the snapshot."
    }
    finally {
        if (Test-Path -LiteralPath $boundTestRoot -PathType Container) {
            Remove-Item -LiteralPath $boundTestRoot -Recurse -Force
        }
    }
    foreach ($functionName in @("Assert-NoReparsePathChain", "Get-AppleToolManifestSnapshot")) {
        $definitions = @($verifierAst.FindAll({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
        }, $true))
        Assert-Equal -Expected 1 -Actual $definitions.Count -Message "Verifier must define exactly one $functionName function."
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $appleManifest = Get-AppleToolManifestSnapshot
    Assert-Equal -Expected 10 -Actual $appleManifest.count -Message "Apple system-tool manifest count mismatch."
    Assert-True -Condition ([string]$appleManifest.digest -match '^[a-f0-9]{64}$') -Message "Apple system-tool manifest digest is malformed."
}

foreach ($requiredFragment in @(
    '"-F", "/dev/null"',
    '"AddressFamily=inet"',
    '"BindAddress=$canonicalMacAddress"',
    '"BindInterface=$MacLanInterface"',
    '"StrictHostKeyChecking=yes"',
    '"UserKnownHostsFile=$knownHostsFullPath"',
    '"UpdateHostKeys=no"',
    '"PreferredAuthentications=publickey"',
    '"PasswordAuthentication=no"',
    '"KbdInteractiveAuthentication=no"',
    '"HostbasedAuthentication=no"',
    '"GSSAPIAuthentication=no"',
    '"IdentityAgent=none"',
    '"VerifyHostKeyDNS=no"',
    '"CheckHostIP=yes"',
    '"CanonicalizeHostname=no"',
    '"ProxyCommand=none"',
    '"ProxyJump=none"',
    '"ControlMaster=no"',
    '"ClearAllForwardings=yes"',
    '"ForwardAgent=no"',
    '"ForwardX11=no"',
    '"Tunnel=no"',
    '"EscapeChar=none"',
    '"KexAlgorithms=$requiredKex"',
    '"HostKeyAlgorithms=$requiredHostKeyAlgorithm"'
)) {
    Assert-True -Condition $verifierSource.Contains($requiredFragment, [System.StringComparison]::Ordinal) -Message "Verifier is missing required SSH contract fragment: $requiredFragment"
}
Assert-True -Condition $verifierSource.Contains('"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "-"', [System.StringComparison]::Ordinal) -Message "Remote audit script must use the fixed Windows PowerShell path over SSH standard input."
Assert-True -Condition $verifierSource.Contains('-StandardInputText $remoteScript', [System.StringComparison]::Ordinal) -Message "SSH invocation must pass the remote audit script on standard input."
Assert-True -Condition (-not $verifierSource.Contains("EncodedCommand", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Remote audit script must not be placed on the Windows command line."
foreach ($fixedApplePath in @(
    "/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/bin/uname", "/sbin/ifconfig",
    "/usr/sbin/networksetup", "/sbin/route", "/usr/sbin/arp", "/usr/bin/stat",
    "/bin/chmod", "/usr/bin/codesign"
)) {
    Assert-True -Condition $verifierSource.Contains($fixedApplePath, [System.StringComparison]::Ordinal) -Message "Verifier is missing fixed Apple tool path: $fixedApplePath"
}
Assert-True -Condition (-not $verifierSource.Contains('private-evidence=$', [System.StringComparison]::Ordinal)) -Message "Verifier source must not print an absolute private evidence path."

$literalFunctions = @($verifierAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "ConvertTo-PowerShellSingleQuotedLiteral"
}, $true))
Assert-Equal -Expected 1 -Actual $literalFunctions.Count -Message "Verifier must define one strict remote literal encoder."
. ([scriptblock]::Create($literalFunctions[0].Extent.Text))
. ([scriptblock]::Create($remoteSessionFunctions[0].Extent.Text))
$boundedRemoteScript = New-RemoteSessionAuditScript -AccountName "lanuser" `
    -AccountSid "S-1-5-21-111111111-222222222-333333333-4444" `
    -ClientAddress "192.0.2.10" -ServerAddress "192.0.2.20" -SshPort 22 `
    -ExpectedPowerShellSha256 ("a" * 64)
Assert-True -Condition ([System.Text.Encoding]::UTF8.GetByteCount($boundedRemoteScript) -le 4096) -Message "Remote session audit script exceeds its standard-input payload bound."

$exactMergeFunctions = @($verifierAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Merge-ExactObservationFields"
}, $true))
Assert-Equal -Expected 1 -Actual $exactMergeFunctions.Count -Message "Verifier must define one exact remote observation merge boundary."
. ([scriptblock]::Create($exactMergeFunctions[0].Extent.Text))
$unexpectedRemoteRejected = $false
try {
    Merge-ExactObservationFields -Destination ([ordered]@{}) `
        -Source ([pscustomobject]@{ remoteSchema = "expected"; clientPlatform = "overwrite" }) `
        -AllowedNames @("remoteSchema") -Label "test remote"
}
catch {
    $unexpectedRemoteRejected = $true
}
Assert-True -Condition $unexpectedRemoteRejected -Message "Exact remote merge must reject an authority-overwrite field."

foreach ($functionName in @("Get-ObservationValue", "Get-RegistrationAuditAssessment")) {
    $definitions = @($verifierAst.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
    }, $true))
    Assert-Equal -Expected 1 -Actual $definitions.Count -Message "Verifier must define exactly one $functionName function."
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$registrationFixture = New-PositiveRegistrationArtifact
$registrationAssessment = Get-RegistrationAuditAssessment -Artifact $registrationFixture `
    -ExpectedLanAccount "lanuser" -ExpectedRelayAccount "relayuser" `
    -ExpectedLanSid "S-1-5-21-111111111-222222222-333333333-4444" `
    -ExpectedRelaySid "S-1-5-21-111111111-222222222-333333333-5555" `
    -ExpectedWindowsAddress "192.0.2.20" -ExpectedMacAddress "192.0.2.10" `
    -ExpectedPrefixLength 24 -ExpectedInterfaceAlias "Ethernet" -ExpectedPort 22 `
    -ExpectedFirewallRuleName "SkyBridge-Windows-LAN-SSH" `
    -ExpectedHostDigest $registrationFixture.expectedHostKeyFingerprint `
    -ExpectedClientDigest $registrationFixture.expectedDirectPublicKeyFingerprint `
    -ExpectedProvenance "approved-key:fixture-v1"
Assert-True -Condition ([bool]$registrationAssessment.passed) -Message "Positive registration authority fixture must pass."
$registrationFirewallFailure = (($registrationFixture | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
$registrationFirewallFailure.managedFirewallExact = $false
$failedRegistrationAssessment = Get-RegistrationAuditAssessment -Artifact $registrationFirewallFailure `
    -ExpectedLanAccount "lanuser" -ExpectedRelayAccount "relayuser" `
    -ExpectedLanSid "S-1-5-21-111111111-222222222-333333333-4444" `
    -ExpectedRelaySid "S-1-5-21-111111111-222222222-333333333-5555" `
    -ExpectedWindowsAddress "192.0.2.20" -ExpectedMacAddress "192.0.2.10" `
    -ExpectedPrefixLength 24 -ExpectedInterfaceAlias "Ethernet" -ExpectedPort 22 `
    -ExpectedFirewallRuleName "SkyBridge-Windows-LAN-SSH" `
    -ExpectedHostDigest $registrationFixture.expectedHostKeyFingerprint `
    -ExpectedClientDigest $registrationFixture.expectedDirectPublicKeyFingerprint `
    -ExpectedProvenance "approved-key:fixture-v1"
Assert-True -Condition (-not [bool]$failedRegistrationAssessment.passed) -Message "Registration fixture must fail when the authoritative firewall result is false."

foreach ($requiredRegistrationFragment in @(
    "evidenceClass = 'private-provisioning'",
    'accepted = $false',
    '"ListenAddress 127.0.0.1`:$SshPort"',
    '"ListenAddress $LanAddress`:$SshPort"',
    '"AllowUsers $LanUser@$MacAddress $RelayUser@127.0.0.1"',
    '[ValidateRange(22, 22)]',
    '[string]$ExpectedLanPublicKeyFingerprint',
    '[string]$LanPublicKeyProvenanceRef',
    "'AuthorizedKeysCommand none'",
    "'AuthorizedKeysCommandUser none'",
    "'TrustedUserCAKeys none'",
    "'AuthorizedPrincipalsCommand none'",
    "'AuthorizedPrincipalsCommandUser none'",
    "'AuthorizedPrincipalsFile none'",
    '$lanEffective = Get-EffectiveSshdConfig',
    '$relayEffective = Get-EffectiveSshdConfig',
    '$installedLanEffective = Get-EffectiveSshdConfig',
    '$installedRelayEffective = Get-EffectiveSshdConfig',
    "evidenceClass = 'private-provisioning'",
    "outcome = 'succeeded'",
    'expectedHostKeyFingerprint = $ExpectedWindowsHostKeyFingerprint',
    'actualHostKeyFingerprint = $actualHostFingerprint',
    'expectedDirectPublicKeyFingerprint = $ExpectedLanPublicKeyFingerprint',
    'actualDirectPublicKeyFingerprint = $directKeyFingerprint',
    'directPublicKeyProvenanceRef = $LanPublicKeyProvenanceRef',
    'Restore-SshdServiceState -OriginalState $originalServiceState -OriginalStartMode $originalServiceStartMode',
    'LAN SSH registration failed and was rolled back'
)) {
    Assert-True -Condition $registrationSource.Contains($requiredRegistrationFragment, [System.StringComparison]::Ordinal) -Message "Registration is missing lifecycle contract fragment: $requiredRegistrationFragment"
}

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-windows-lan-ssh-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
try {
    $positive = New-PositiveObservation
    $positiveResult = Invoke-FixtureCase -Name "positive" -Observation $positive -ExpectEvaluationPassed $true
    Assert-Equal -Expected "mlkem768x25519-sha256" -Actual ([string]$positiveResult.public.negotiatedKex) -Message "Positive fixture must retain only the negotiated algorithm in public evidence."
    Assert-True -Condition $positiveResult.privateText.Contains("RAW_STDERR_CANARY", [System.StringComparison]::Ordinal) -Message "Private evidence should retain the fixture canary for redaction testing."
    Assert-True -Condition (-not $positiveResult.commandOutputText.Contains($positiveResult.privatePath, [System.StringComparison]::Ordinal)) -Message "Verifier stdout leaked the private evidence path."
    Assert-True -Condition (-not $positiveResult.commandOutputText.Contains($positiveResult.publicPath, [System.StringComparison]::Ordinal)) -Message "Verifier stdout leaked the public evidence path."
    Assert-True -Condition (-not $positiveResult.commandOutputText.Contains("RAW_STDERR_CANARY", [System.StringComparison]::Ordinal)) -Message "Verifier stdout leaked a private evidence canary."
    foreach ($canary in @(
        "203.0.113.77",
        "198.51.100.42",
        "en99-CANARY",
        "WIN-CANARY-HOST",
        "lan-user-CANARY",
        "S-1-5-21-111111111-222222222-333333333-4444",
        "/Users/canary/.ssh/direct-CANARY",
        "/Users/canary/.ssh/known-hosts-CANARY",
        "SHA256:HOST-CANARY",
        "SHA256:IDENTITY-CANARY",
        "RAW_STDERR_CANARY"
    )) {
        Assert-True -Condition (-not $positiveResult.publicText.Contains($canary, [System.StringComparison]::Ordinal)) -Message "Public evidence leaked canary '$canary'."
    }
    Assert-True -Condition ($positiveResult.publicText -notmatch '(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])') -Message "Public evidence must not contain an IPv4 address."
    Assert-True -Condition ($positiveResult.publicText -notmatch '(?i)S-1-\d-') -Message "Public evidence must not contain a Windows SID."
    Assert-True -Condition ($positiveResult.publicText -notmatch '(?i)(?:/Users/|[A-Z]:\\)') -Message "Public evidence must not contain a local filesystem path."
    Assert-True -Condition ($positiveResult.publicText -notmatch '(?i)raw.?stderr') -Message "Public evidence must not contain raw stderr data or a raw-stderr field."

    $neighborFunctions = @($verifierAst.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Test-MacNeighborOutput"
    }, $true))
    Assert-Equal -Expected 1 -Actual $neighborFunctions.Count -Message "Verifier must define one exact ARP parser."
    . ([scriptblock]::Create($neighborFunctions[0].Extent.Text))
    Assert-True -Condition (Test-MacNeighborOutput -Output "? (192.0.2.20) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]" -TargetAddress "192.0.2.20" -InterfaceName "en0") -Message "ARP parser must accept macOS question-mark format."
    Assert-True -Condition (Test-MacNeighborOutput -Output "192.0.2.20 (192.0.2.20) at AA:BB:CC:DD:EE:FF on en0 ifscope [ethernet]" -TargetAddress "192.0.2.20" -InterfaceName "en0") -Message "ARP parser must accept macOS numeric-target format."
    Assert-True -Condition (-not (Test-MacNeighborOutput -Output "192.0.2.20 (192.0.2.20) at (incomplete) on en0 ifscope [ethernet]" -TargetAddress "192.0.2.20" -InterfaceName "en0")) -Message "ARP parser must reject incomplete entries."
    Assert-True -Condition (-not (Test-MacNeighborOutput -Output "192.0.2.20 (192.0.2.20) at aa:bb:cc:dd:ee:ff on utun4" -TargetAddress "192.0.2.20" -InterfaceName "en0")) -Message "ARP parser must reject a different interface."
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $modeResult = & stat -f "%Lp" $positiveResult.privatePath
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Message "stat failed for private fixture evidence."
        Assert-Equal -Expected "600" -Actual ([string]$modeResult).Trim() -Message "Private evidence must be mode 0600."
    }

    $negativeCases = @(
        [ordered]@{ name = "route-mismatch"; property = "routeInterfaceMatches"; value = $false; failed = "directRouteBound" },
        [ordered]@{ name = "extra-host-pin"; property = "pinActiveRecordCount"; value = 2; failed = "hostPinTrusted" },
        [ordered]@{ name = "rsa-host-pin"; property = "pinAlgorithm"; value = "ssh-rsa"; failed = "hostPinTrusted" },
        [ordered]@{ name = "negotiated-host-digest-mismatch"; property = "negotiatedHostKeyDigestMatches"; value = $false; failed = "ed25519HostAuthenticated" },
        [ordered]@{ name = "bound-input-mutated"; property = "boundInputSnapshotsStable"; value = $false; failed = "localAuthorityStable" },
        [ordered]@{ name = "stale-server-audit"; property = "serverAuditFresh"; value = $false; failed = "serverAuditTrusted" },
        [ordered]@{ name = "server-audit-digest-mismatch"; property = "serverAuditDigestMatches"; value = $false; failed = "serverAuditTrusted" },
        [ordered]@{ name = "administrator-account"; property = "remoteAccountIsAdministrator"; value = $true; failed = "accountLeastPrivilege" },
        [ordered]@{ name = "firewall-any-profile"; property = "serverFirewallExact"; value = $false; failed = "serverFirewallExact" },
        [ordered]@{ name = "authentication-policy-mismatch"; property = "serverAuthenticationPolicyExact"; value = $false; failed = "serverAuthenticationPolicyExact" },
        [ordered]@{ name = "ssh-connection-mismatch"; property = "remoteSshConnectionMatches"; value = $false; failed = "sessionEndpointsBound" }
    )
    foreach ($case in $negativeCases) {
        $observation = Copy-Observation -Observation $positive
        $observation.($case.property) = $case.value
        [void](Invoke-FixtureCase -Name $case.name -Observation $observation -ExpectEvaluationPassed $false -ExpectedFailedCheck $case.failed)
    }
}
finally {
    if (Test-Path -LiteralPath $script:TempRoot -PathType Container) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }
}

Write-Output "windows-lan-ssh-lifecycle-tests: ok"
