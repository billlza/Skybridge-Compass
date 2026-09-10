param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [double]$MinimumLineCoverage = 90.0,
    [switch]$IncludeRustCliCoverage,
    [switch]$IncludeNativeDnsSdAcceptance,
    [switch]$CheckOnlineStackFreshness,
    [string]$StackFreshnessEvidencePath = "",
    [string]$RustCliCoverageEvidencePath = "",
    [string]$AcceptanceEvidencePath = "",
    [switch]$CiMode,
    [switch]$ProbeMacSsh,
    [switch]$IncludeWinUiAutomationSmoke,
    [string]$WinUiEvidenceDir = "",
    [switch]$RequireMacSshReady,
    [switch]$RequireMacDirectLan,
    [switch]$RequireMacRustCliSmoke,
    [switch]$RequireMacWebRtcInterop,
    [switch]$RequireNativeDnsSdPeer,
    [string]$ExpectedDeviceId = "",
    [string]$ExpectedFingerprint = "",
    [string]$SearchText = "",
    [string]$MacHostName = "192.168.0.102",
    [string[]]$MacAlternateHostNames = @("LzadeMacBook-Pro.local", "bill.local"),
    [int]$MacPort = 22,
    [string[]]$MacUserNames = @("bill", "Lza"),
    [string]$MacSshKeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$MacKnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [string]$MacExpectedHostKeyFingerprint = "",
    [string]$MacExpectedHostAddress = "192.168.0.102",
    [string]$MacDirectSourceAddress = "",
    [string]$MacSshEvidencePath = "",
    [string]$MacRemoteRepoRoot = "",
    [string]$MacWebRtcProofPath = "",
    [ValidateRange(1, 600000)]
    [UInt64]$MacWebRtcProofMaxAgeMs = 60000,
    [switch]$IncludeWindowsReverseSshRelayLifecycle,
    [switch]$RequireWindowsReverseSshRelayLifecycle,
    [string]$WindowsReverseSshRelayEvidencePath = "",
    [string]$WindowsReverseSshRelayTaskName = "SkyBridgeReverseSshTunnel",
    [string]$WindowsReverseSshRelayHostName = "54.92.79.99",
    [string]$WindowsReverseSshRelayUserName = "ubuntu",
    [ValidateRange(1, 65535)]
    [int]$WindowsReverseSshRelayPort = 22,
    [string]$WindowsReverseSshRelayExpectedHostKeyFingerprint = "",
    [string]$WindowsReverseSshRelayIdentityFile = "C:\ProgramData\ssh\skybridge-relay-ed25519",
    [string]$WindowsReverseSshRelayKnownHostsPath = "C:\ProgramData\ssh\skybridge-relay-known_hosts",
    [string]$WindowsReverseSshRelayInstalledStartScriptPath = "C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1",
    [string]$WindowsReverseSshRelayTaskUserId = "NT AUTHORITY\LOCAL SERVICE",
    [switch]$RequireCurrentPathProductControlTransport,
    [switch]$RequireCurrentPathProductControlAppControl,
    [switch]$RequireCurrentPathProductControlFileTransfer,
    [switch]$RequireCurrentPathProductControlAnswererTransport,
    [switch]$RequireCurrentPathProductControlAnswererAppControl,
    [switch]$RequireCurrentPathProductControlAnswererFileTransfer,
    [switch]$ImportCurrentPathProductControlAppControlSession,
    [switch]$ImportCurrentPathProductControlAnswererAppControlSession,
    [string]$CurrentPathProductControlEvidencePath = "",
    [string]$CurrentPathProductControlFileTransferEvidencePath = "",
    [string]$CurrentPathProductControlAnswererEvidencePath = "",
    [string]$CurrentPathProductControlAnswererAppControlEvidencePath = "",
    [string]$CurrentPathProductControlAnswererFileTransferEvidencePath = "",
    [string]$CurrentPathProductControlAppControlSessionImportEvidencePath = "",
    [string]$CurrentPathProductControlAnswererAppControlSessionImportEvidencePath = "",
    [string]$CurrentPathProductControlAppControlSessionImportStateDir = "",
    [string]$CurrentPathProductControlAnswererAppControlSessionImportStateDir = "",
    [string]$CurrentPathProductControlAppControlSessionImportTargetRuntimeId = "",
    [string]$CurrentPathProductControlAnswererAppControlSessionImportTargetRuntimeId = "",
    [string]$CurrentPathProductControlSignalingDir = "",
    [string]$CurrentPathSignalServerBaseUrl = "https://api.nebula-technologies.net",
    [string]$CurrentPathLocalDeviceId = "",
    [string]$CurrentPathPeerDeviceId = "",
    [string]$CurrentPathPeerFingerprint = "",
    [string]$CurrentPathDeviceName = "Windows RuntimeSmoke",
    [string]$CurrentPathConnectionCodeEnvVar = "SKYBRIDGE_CURRENT_PATH_CONNECTION_CODE",
    [string]$CurrentPathBearerTokenEnvVar = "SKYBRIDGE_CURRENT_PATH_BEARER_TOKEN",
    [string]$CurrentPathTenantIdEnvVar = "SKYBRIDGE_CURRENT_PATH_TENANT_ID",
    [string]$CurrentPathMldsa65PrivateKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_MLDSA65_PRIVATE_KEY_BASE64",
    [string]$CurrentPathPeerMlKem768PublicKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    [string]$CurrentPathLocalMlKem768DecapsulationKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_DECAPSULATION_KEY_BASE64",
    [string]$CurrentPathLocalMlKem768EncapsulationKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_PUBLIC_KEY_BASE64",
    [string]$CurrentPathBindAddress = "",
    [string]$CurrentPathClientVersion = "1.0.0",
    [string]$CurrentPathProtocolVersion = "1",
    [ValidateSet("initiator", "responder")]
    [string]$CurrentPathExpectedBoundRole = "responder",
    [string]$CurrentPathProductControlAnswererConnectionCodePath = "",
    [string]$CurrentPathProductControlAnswererTransportConnectionCodePath = "",
    [string]$CurrentPathProductControlAnswererAppControlConnectionCodePath = "",
    [string]$CurrentPathProductControlAnswererFileTransferConnectionCodePath = "",
    [switch]$RequireLiveFileTransfer,
    [string]$LiveFileTransferEvidencePath = "",
    [switch]$RequireLiveRemoteDesktop,
    [string]$LiveRemoteDesktopEvidencePath = "",
    [switch]$RequirePublicArtifactRedaction,
    [string[]]$PublicArtifactPath = @(),
    [string[]]$PublicArtifactSensitiveToken = @(),
    [string]$PublicArtifactScanEvidencePath = "",
    [int]$CurrentPathConnectionCodeTtlSeconds = 300,
    [int]$CurrentPathTimeoutSeconds = 180,
    [int]$CurrentPathSignalFileTimeoutSeconds = 30,
    [int]$CurrentPathRemoteOfferTimeoutSeconds = 120,
    [int]$CurrentPathRemoteAnswerTimeoutSeconds = 120,
    [ValidateRange(1, 2048)]
    [int]$CurrentPathFileTransferPayloadBytes = 1024,
    [ValidateRange(1, 86400)]
    [int]$CurrentPathProductControlAppControlSessionImportTtlSeconds = 3600,
    [ValidateRange(1, 86400)]
    [int]$CurrentPathProductControlAnswererAppControlSessionImportTtlSeconds = 3600,
    [string]$CurrentPathConfiguration = "Debug",
    [ValidateRange(1, 30)]
    [int]$ExtendedSearchSeconds = 2,
    [switch]$RequireGitRemoteAccess
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$script:PortabilitySmokeGateResults = [System.Collections.Generic.List[object]]::new()

function Add-SmokeGateResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = "",
        [string]$EvidencePath = ""
    )

    $script:PortabilitySmokeGateResults.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
        evidencePath = $EvidencePath
    })
}

function Get-GitText {
    param([string[]]$Arguments)

    $output = & git -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed while writing portability smoke evidence: $($output -join [Environment]::NewLine)"
    }

    $firstLine = (($output | Select-Object -First 1) -as [string])
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        throw "git $($Arguments -join ' ') returned empty output while writing portability smoke evidence."
    }

    return $firstLine
}

function Resolve-OptionalEvidencePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepoRoot $Path))
}

function Test-PathIsSameOrUnderDirectory {
    param(
        [string]$Path,
        [string]$DirectoryPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($DirectoryPath)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath((Resolve-OptionalEvidencePath -Path $Path))
    $fullDirectory = [System.IO.Path]::GetFullPath((Resolve-OptionalEvidencePath -Path $DirectoryPath)).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    if ([string]::Equals($fullPath, $fullDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $directoryPrefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-StableSha256Hex {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
}

function ConvertTo-PortableArtifactPath {
    param([string]$ResolvedPath)

    $fullPath = [System.IO.Path]::GetFullPath($ResolvedPath)
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    if ([string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }

    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $fullPath.Substring($rootPrefix.Length).Replace([string][System.IO.Path]::DirectorySeparatorChar, "/")
        if ([System.IO.Path]::AltDirectorySeparatorChar -ne [System.IO.Path]::DirectorySeparatorChar) {
            $relativePath = $relativePath.Replace([string][System.IO.Path]::AltDirectorySeparatorChar, "/")
        }

        return $relativePath
    }

    return "<external:" + (Get-StableSha256Hex -Value $fullPath).Substring(0, 16) + ">"
}

function Get-ArtifactPathScope {
    param([string]$ResolvedPath)

    $fullPath = [System.IO.Path]::GetFullPath($ResolvedPath)
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    if ([string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return "repo"
    }

    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return "repo"
    }

    return "external-redacted"
}

function Test-IsDigestibleEvidencePathProperty {
    param([string]$Name)

    return $Name -match '(EvidencePath|EvidenceDir|ProofPath)$'
}

function Get-DirectoryManifestDigest {
    param([string]$DirectoryPath)

    $root = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    $rootItem = Get-Item -LiteralPath $root
    Assert-True -Condition (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "Directory artifact digest refuses reparse-point root: $root"

    $reparseDirectories = @(Get-ChildItem -LiteralPath $root -Force -Recurse -Directory | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    Assert-True -Condition ($reparseDirectories.Count -eq 0) -Message "Directory artifact digest refuses reparse-point descendants: $root"

    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    [int64]$totalBytes = 0
    $files = @(Get-ChildItem -LiteralPath $root -Force -Recurse -File | Sort-Object -Property FullName)
    foreach ($file in $files) {
        $fullName = [System.IO.Path]::GetFullPath($file.FullName)
        Assert-True -Condition ($fullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message "Directory artifact file escapes root: $fullName"
        $relativePath = $fullName.Substring($rootPrefix.Length).Replace([string][System.IO.Path]::DirectorySeparatorChar, "/")
        if ([System.IO.Path]::AltDirectorySeparatorChar -ne [System.IO.Path]::DirectorySeparatorChar) {
            $relativePath = $relativePath.Replace([string][System.IO.Path]::AltDirectorySeparatorChar, "/")
        }

        [int64]$length = $file.Length
        $hash = Get-FileHash -LiteralPath $fullName -Algorithm SHA256
        $manifestLines.Add("$relativePath`t$length`t$($hash.Hash.ToLowerInvariant())")
        $totalBytes += $length
    }

    $manifest = $manifestLines.ToArray() -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $manifestHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($manifest))
    }
    finally {
        $sha.Dispose()
    }

    return [ordered]@{
        fileCount = [int64]$files.Count
        byteLength = $totalBytes
        sha256 = [System.BitConverter]::ToString($manifestHash).Replace("-", "").ToLowerInvariant()
    }
}

function Get-EvidenceArtifactDigests {
    param(
        [System.Collections.IDictionary]$EvidencePaths,
        [object[]]$GateResults
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $records = [System.Collections.Generic.List[object]]::new()
    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $EvidencePaths.GetEnumerator()) {
        if ((Test-IsDigestibleEvidencePathProperty -Name ([string]$entry.Key)) -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $candidatePaths.Add([string]$entry.Value)
        }
    }

    foreach ($gate in $GateResults) {
        if ($null -ne $gate -and $null -ne $gate.evidencePath -and -not [string]::IsNullOrWhiteSpace([string]$gate.evidencePath)) {
            $candidatePaths.Add([string]$gate.evidencePath)
        }
    }

    foreach ($candidatePath in $candidatePaths) {
        $resolvedPath = Resolve-OptionalEvidencePath -Path $candidatePath
        if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not $seen.Add($resolvedPath)) {
            continue
        }

        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
            $item = Get-Item -LiteralPath $resolvedPath
            $hash = Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256
            $records.Add([ordered]@{
                path = ConvertTo-PortableArtifactPath -ResolvedPath $resolvedPath
                pathSha256 = Get-StableSha256Hex -Value ([System.IO.Path]::GetFullPath($resolvedPath))
                pathScope = Get-ArtifactPathScope -ResolvedPath $resolvedPath
                pathType = "file"
                exists = $true
                byteLength = [int64]$item.Length
                sha256 = $hash.Hash.ToLowerInvariant()
                lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
            })
        }
        elseif (Test-Path -LiteralPath $resolvedPath -PathType Container) {
            $item = Get-Item -LiteralPath $resolvedPath
            $manifestDigest = Get-DirectoryManifestDigest -DirectoryPath $resolvedPath
            $records.Add([ordered]@{
                path = ConvertTo-PortableArtifactPath -ResolvedPath $resolvedPath
                pathSha256 = Get-StableSha256Hex -Value ([System.IO.Path]::GetFullPath($resolvedPath))
                pathScope = Get-ArtifactPathScope -ResolvedPath $resolvedPath
                pathType = "directory"
                exists = $true
                fileCount = $manifestDigest.fileCount
                byteLength = $manifestDigest.byteLength
                sha256 = $manifestDigest.sha256
                lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
            })
        }
        else {
            $records.Add([ordered]@{
                path = ConvertTo-PortableArtifactPath -ResolvedPath $resolvedPath
                pathSha256 = Get-StableSha256Hex -Value ([System.IO.Path]::GetFullPath($resolvedPath))
                pathScope = Get-ArtifactPathScope -ResolvedPath $resolvedPath
                pathType = "missing"
                exists = $false
                byteLength = $null
                sha256 = $null
                lastWriteTimeUtc = $null
            })
        }
    }

    return $records.ToArray()
}

function Write-AcceptanceEvidence {
    if ([string]::IsNullOrWhiteSpace($AcceptanceEvidencePath)) {
        return
    }

    $resolvedEvidencePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AcceptanceEvidencePath)
    $evidenceDirectory = Split-Path -Parent $resolvedEvidencePath
    if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
        New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    }

    $branch = Get-GitText -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
    $head = Get-GitText -Arguments @("rev-parse", "HEAD")
    $runId = [guid]::NewGuid().ToString("N")
    $evidencePathsObject = [ordered]@{
        stackFreshnessEvidencePath = $StackFreshnessEvidencePath
        rustCliCoverageEvidencePath = $RustCliCoverageEvidencePath
        winUiEvidenceDir = $WinUiEvidenceDir
        macSshEvidencePath = $MacSshEvidencePath
        macWebRtcProofPath = $MacWebRtcProofPath
        macExpectedHostKeyFingerprint = $MacExpectedHostKeyFingerprint
        windowsReverseSshRelayEvidencePath = $WindowsReverseSshRelayEvidencePath
        windowsReverseSshRelayExpectedHostKeyFingerprint = $WindowsReverseSshRelayExpectedHostKeyFingerprint
        windowsReverseSshRelayInstalledStartScriptPath = $WindowsReverseSshRelayInstalledStartScriptPath
        currentPathProductControlEvidencePath = $CurrentPathProductControlEvidencePath
        currentPathProductControlFileTransferEvidencePath = $CurrentPathProductControlFileTransferEvidencePath
        currentPathProductControlAnswererEvidencePath = $CurrentPathProductControlAnswererEvidencePath
        currentPathProductControlAnswererAppControlEvidencePath = $CurrentPathProductControlAnswererAppControlEvidencePath
        currentPathProductControlAnswererFileTransferEvidencePath = $CurrentPathProductControlAnswererFileTransferEvidencePath
        currentPathProductControlAppControlSessionImportEvidencePath = $CurrentPathProductControlAppControlSessionImportEvidencePath
        currentPathProductControlAnswererAppControlSessionImportEvidencePath = $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
        currentPathProductControlAnswererConnectionCodePath = $CurrentPathProductControlAnswererConnectionCodePath
        currentPathProductControlAnswererTransportConnectionCodePath = $CurrentPathProductControlAnswererTransportConnectionCodePath
        currentPathProductControlAnswererAppControlConnectionCodePath = $CurrentPathProductControlAnswererAppControlConnectionCodePath
        currentPathProductControlAnswererFileTransferConnectionCodePath = $CurrentPathProductControlAnswererFileTransferConnectionCodePath
        liveFileTransferEvidencePath = $LiveFileTransferEvidencePath
        liveRemoteDesktopEvidencePath = $LiveRemoteDesktopEvidencePath
        publicArtifactPaths = @($PublicArtifactPath)
        publicArtifactScanEvidencePath = $PublicArtifactScanEvidencePath
    }

    [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        runId = $runId
        repoRoot = $RepoRoot
        branch = $branch
        head = $head
        parameters = [ordered]@{
            ciMode = [bool]$CiMode
            checkOnlineStackFreshness = [bool]$CheckOnlineStackFreshness
            includeWinUiAutomationSmoke = [bool]$IncludeWinUiAutomationSmoke
            includeRustCliCoverage = [bool]$IncludeRustCliCoverage
            includeNativeDnsSdAcceptance = [bool]$IncludeNativeDnsSdAcceptance
            probeMacSsh = [bool]$ProbeMacSsh
            requireMacSshReady = [bool]$RequireMacSshReady
            requireMacDirectLan = [bool]$RequireMacDirectLan
            requireMacRustCliSmoke = [bool]$RequireMacRustCliSmoke
            requireMacWebRtcInterop = [bool]$RequireMacWebRtcInterop
            requireNativeDnsSdPeer = [bool]$RequireNativeDnsSdPeer
            includeWindowsReverseSshRelayLifecycle = [bool]$IncludeWindowsReverseSshRelayLifecycle
            requireWindowsReverseSshRelayLifecycle = [bool]$RequireWindowsReverseSshRelayLifecycle
            requireCurrentPathProductControlTransport = [bool]$RequireCurrentPathProductControlTransport
            requireCurrentPathProductControlAppControl = [bool]$RequireCurrentPathProductControlAppControl
            requireCurrentPathProductControlFileTransfer = [bool]$RequireCurrentPathProductControlFileTransfer
            requireCurrentPathProductControlAnswererTransport = [bool]$RequireCurrentPathProductControlAnswererTransport
            requireCurrentPathProductControlAnswererAppControl = [bool]$RequireCurrentPathProductControlAnswererAppControl
            requireCurrentPathProductControlAnswererFileTransfer = [bool]$RequireCurrentPathProductControlAnswererFileTransfer
            importCurrentPathProductControlAppControlSession = [bool]$ImportCurrentPathProductControlAppControlSession
            importCurrentPathProductControlAnswererAppControlSession = [bool]$ImportCurrentPathProductControlAnswererAppControlSession
            currentPathProductControlAppControlSessionImportTargetRuntimeIdProvided = -not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportTargetRuntimeId)
            currentPathProductControlAnswererAppControlSessionImportTargetRuntimeIdProvided = -not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportTargetRuntimeId)
            currentPathProductControlAppControlSessionImportTtlSeconds = $CurrentPathProductControlAppControlSessionImportTtlSeconds
            currentPathProductControlAnswererAppControlSessionImportTtlSeconds = $CurrentPathProductControlAnswererAppControlSessionImportTtlSeconds
            currentPathFileTransferPayloadBytes = $CurrentPathFileTransferPayloadBytes
            requireLiveFileTransfer = [bool]$RequireLiveFileTransfer
            requireLiveRemoteDesktop = [bool]$RequireLiveRemoteDesktop
            requirePublicArtifactRedaction = [bool]$RequirePublicArtifactRedaction
            requireGitRemoteAccess = [bool]$RequireGitRemoteAccess
        }
        evidencePaths = $evidencePathsObject
        artifactDigests = @(Get-EvidenceArtifactDigests -EvidencePaths $evidencePathsObject -GateResults @($script:PortabilitySmokeGateResults))
        gateResults = @($script:PortabilitySmokeGateResults)
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8
    Write-Output "windows-portability-smoke: acceptance-evidence=$resolvedEvidencePath"
}

function Invoke-LiveAcceptanceVerifier {
    if (-not ($RequireLiveFileTransfer -or $RequireLiveRemoteDesktop)) {
        return
    }

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($AcceptanceEvidencePath)) -Message "AcceptanceEvidencePath is required before invoking the live acceptance verifier."
    $verifierPath = Join-Path $RepoRoot "Scripts/verify-windows-portability-acceptance-evidence.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $verifierPath -PathType Leaf) -Message "Missing Windows portability acceptance verifier: $verifierPath"

    $verifierArguments = @(
        "-AcceptanceEvidencePath",
        $AcceptanceEvidencePath
    )
    if ($RequireLiveFileTransfer) {
        $verifierArguments += "-RequireLiveFileTransfer"
    }
    if ($RequireLiveRemoteDesktop) {
        $verifierArguments += "-RequireLiveRemoteDesktop"
    }

    & $verifierPath @verifierArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Live acceptance verifier failed: $verifierPath $($verifierArguments -join ' ') exitCode=$LASTEXITCODE"
    }
}

function Invoke-SmokeGate {
    param(
        [string]$Name,
        [string]$RelativeScriptPath,
        [hashtable]$Parameters = @{},
        [string]$EvidencePath = ""
    )

    $scriptPath = Join-Path $RepoRoot $RelativeScriptPath
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath) -Message "Missing smoke gate script: $scriptPath"

    try {
        Write-Output "windows-portability-smoke: running $Name"
        $LASTEXITCODE = 0
        & $scriptPath @Parameters
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Smoke gate failed: $Name exitCode=$LASTEXITCODE"
        Write-Output "windows-portability-smoke: passed $Name"
        Add-SmokeGateResult -Name $Name -Status "passed" -EvidencePath $EvidencePath
    }
    catch {
        Add-SmokeGateResult -Name $Name -Status "failed" -Detail $_.Exception.Message -EvidencePath $EvidencePath
        Write-AcceptanceEvidence
        throw
    }
}

$gitRemoteParameters = @{
    RepoRoot = $RepoRoot
}
if (-not $CiMode) {
    $gitRemoteParameters.RequireConfiguredSshCommand = $true
    $gitRemoteParameters.RequireKnownHosts = $true
    $gitRemoteParameters.RequireCredentialHelperReset = $true
}
else {
    Write-Output "windows-portability-smoke: CI mode keeps the SSH-only remote check but skips workstation-specific SSH key, known_hosts, and credential-helper requirements."
}
if ($RequireGitRemoteAccess) {
    $gitRemoteParameters.RequireRemoteAccess = $true
}

Invoke-SmokeGate `
    -Name "git-ssh-remote" `
    -RelativeScriptPath "Scripts/verify-git-ssh-remote.ps1" `
    -Parameters $gitRemoteParameters

Invoke-SmokeGate `
    -Name "windows-ci-workflow" `
    -RelativeScriptPath "Scripts/verify-windows-ci-workflow.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-powershell-ast" `
    -RelativeScriptPath "Scripts/verify-windows-powershell-ast.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

$stackFreshnessParameters = @{
    RepoRoot = $RepoRoot
}
if ($CheckOnlineStackFreshness) {
    $stackFreshnessParameters.CheckOnline = $true
}
if (-not [string]::IsNullOrWhiteSpace($StackFreshnessEvidencePath)) {
    $stackFreshnessParameters.EvidencePath = $StackFreshnessEvidencePath
}

Invoke-SmokeGate `
    -Name "windows-stack-freshness" `
    -RelativeScriptPath "Scripts/verify-windows-stack-freshness.ps1" `
    -Parameters $stackFreshnessParameters `
    -EvidencePath $StackFreshnessEvidencePath

Invoke-SmokeGate `
    -Name "windows-research-evidence" `
    -RelativeScriptPath "Scripts/verify-windows-research-evidence.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-portability-acceptance-map" `
    -RelativeScriptPath "Scripts/verify-windows-portability-acceptance-map.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ffi-client" `
    -RelativeScriptPath "Scripts/verify-windows-ffi-client.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ui-parity" `
    -RelativeScriptPath "Scripts/verify-windows-ui-parity.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ui-action-order" `
    -RelativeScriptPath "Scripts/verify-windows-ui-action-order.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ui-parity-matrix" `
    -RelativeScriptPath "Scripts/verify-windows-ui-parity-matrix.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

if ($IncludeWinUiAutomationSmoke) {
    $winUiAutomationParameters = @{
        RepoRoot = $RepoRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($WinUiEvidenceDir)) {
        $winUiAutomationParameters.EvidenceDir = $WinUiEvidenceDir
    }

    Invoke-SmokeGate `
        -Name "windows-ui-automation-smoke" `
        -RelativeScriptPath "Scripts/verify-windows-ui-automation-smoke.ps1" `
        -Parameters $winUiAutomationParameters `
        -EvidencePath $WinUiEvidenceDir

    if (-not [string]::IsNullOrWhiteSpace($WinUiEvidenceDir)) {
        Invoke-SmokeGate `
            -Name "windows-ui-visual-evidence" `
            -RelativeScriptPath "Scripts/verify-windows-ui-visual-evidence.ps1" `
            -Parameters @{
                RepoRoot = $RepoRoot
                EvidenceDir = $WinUiEvidenceDir
            } `
            -EvidencePath $WinUiEvidenceDir
    }
    else {
        Write-Output "windows-portability-smoke: skipped windows-ui-visual-evidence; pass -WinUiEvidenceDir <dir> with -IncludeWinUiAutomationSmoke to validate screenshot evidence artifacts."
        Add-SmokeGateResult -Name "windows-ui-visual-evidence" -Status "skipped" -Detail "Pass -WinUiEvidenceDir <dir> with -IncludeWinUiAutomationSmoke to validate screenshot evidence artifacts."
    }
}
else {
    Write-Output "windows-portability-smoke: skipped windows-ui-automation-smoke; pass -IncludeWinUiAutomationSmoke on an interactive Windows desktop to verify live WinUI navigation, anchors, layout, and File Transfer QR preview. Add -WinUiEvidenceDir <dir> to capture visual evidence screenshots and a manifest."
    Add-SmokeGateResult -Name "windows-ui-automation-smoke" -Status "skipped" -Detail "Pass -IncludeWinUiAutomationSmoke on an interactive Windows desktop."
    Add-SmokeGateResult -Name "windows-ui-visual-evidence" -Status "skipped" -Detail "Pass -IncludeWinUiAutomationSmoke -WinUiEvidenceDir <dir> to validate screenshot evidence artifacts." -EvidencePath $WinUiEvidenceDir
}

Invoke-SmokeGate `
    -Name "windows-startup-state" `
    -RelativeScriptPath "Scripts/verify-windows-startup-state.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-command-gates" `
    -RelativeScriptPath "Scripts/verify-windows-command-gates.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-file-transfer-qr" `
    -RelativeScriptPath "Scripts/verify-windows-file-transfer-qr.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-native-runtime-profile" `
    -RelativeScriptPath "Scripts/verify-windows-native-runtime-profile.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-current-path-bridge-contract" `
    -RelativeScriptPath "Scripts/verify-windows-current-path-bridge-contract.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-connection-launch" `
    -RelativeScriptPath "Scripts/verify-windows-connection-launch.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-webrtc-proof-smoke" `
    -RelativeScriptPath "Scripts/verify-windows-webrtc-proof-smoke.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "apple-native-preservation" `
    -RelativeScriptPath "Scripts/verify-apple-native-preservation.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "mac-rust-cli-codbg-wrapper" `
    -RelativeScriptPath "Scripts/verify-mac-rust-cli-codbg-wrapper.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

if ($IncludeWindowsReverseSshRelayLifecycle -or $RequireWindowsReverseSshRelayLifecycle) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($WindowsReverseSshRelayExpectedHostKeyFingerprint)) -Message "WindowsReverseSshRelayExpectedHostKeyFingerprint is required when the Windows reverse SSH relay lifecycle gate is included."
    $reverseSshRelayParameters = @{
        RepoRoot = $RepoRoot
        TaskName = $WindowsReverseSshRelayTaskName
        RelayHostName = $WindowsReverseSshRelayHostName
        RelayUserName = $WindowsReverseSshRelayUserName
        RelayPort = $WindowsReverseSshRelayPort
        ExpectedRelayHostKeyFingerprint = $WindowsReverseSshRelayExpectedHostKeyFingerprint
        IdentityFile = $WindowsReverseSshRelayIdentityFile
        KnownHostsPath = $WindowsReverseSshRelayKnownHostsPath
        InstalledStartScriptPath = $WindowsReverseSshRelayInstalledStartScriptPath
        TaskUserId = $WindowsReverseSshRelayTaskUserId
    }
    if (-not [string]::IsNullOrWhiteSpace($WindowsReverseSshRelayEvidencePath)) {
        $reverseSshRelayParameters.EvidencePath = $WindowsReverseSshRelayEvidencePath
    }
    if ($RequireWindowsReverseSshRelayLifecycle) {
        $reverseSshRelayParameters.RequireRunning = $true
    }

    Invoke-SmokeGate `
        -Name "windows-reverse-ssh-relay-lifecycle" `
        -RelativeScriptPath "Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1" `
        -Parameters $reverseSshRelayParameters `
        -EvidencePath $WindowsReverseSshRelayEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped windows-reverse-ssh-relay-lifecycle; pass -IncludeWindowsReverseSshRelayLifecycle for local diagnostics or -RequireWindowsReverseSshRelayLifecycle with a pinned relay host key when the Windows scheduled task must be accepted."
    Add-SmokeGateResult -Name "windows-reverse-ssh-relay-lifecycle" -Status "skipped" -Detail "Pass -IncludeWindowsReverseSshRelayLifecycle or -RequireWindowsReverseSshRelayLifecycle with WindowsReverseSshRelayExpectedHostKeyFingerprint." -EvidencePath $WindowsReverseSshRelayEvidencePath
}

if ($ProbeMacSsh -or $RequireMacSshReady -or $RequireMacDirectLan -or $RequireMacRustCliSmoke) {
    $macSshParameters = @{
        HostName = $MacHostName
        AlternateHostNames = $MacAlternateHostNames
        Port = $MacPort
        UserNames = $MacUserNames
        KeyPath = $MacSshKeyPath
        KnownHostsPath = $MacKnownHostsPath
        ExpectedHostKeyFingerprint = $MacExpectedHostKeyFingerprint
        ExpectedHostAddress = $MacExpectedHostAddress
    }

    if (-not [string]::IsNullOrWhiteSpace($MacDirectSourceAddress)) {
        $macSshParameters.DirectSourceAddress = $MacDirectSourceAddress
    }

    if (-not [string]::IsNullOrWhiteSpace($MacSshEvidencePath)) {
        $macSshParameters.EvidencePath = $MacSshEvidencePath
    }

    if ($RequireMacSshReady) {
        $macSshParameters.RequireReady = $true
        $macSshParameters.RequireKnownHost = $true
    }

    if ($RequireMacDirectLan) {
        $macSshParameters.RequireDirectLan = $true
        $macSshParameters.RequireKnownHost = $true
    }

    if ($RequireMacRustCliSmoke) {
        $macSshParameters.RequireReady = $true
        $macSshParameters.RequireKnownHost = $true
        $macSshParameters.RequireRustCliSmoke = $true
        $macSshParameters.RemoteRepoRoot = $MacRemoteRepoRoot
    }

    Invoke-SmokeGate `
        -Name "mac-ssh-readiness" `
        -RelativeScriptPath "Scripts/probe-mac-ssh.ps1" `
        -Parameters $macSshParameters `
        -EvidencePath $MacSshEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped mac-ssh-readiness; pass -ProbeMacSsh for diagnostics, -RequireMacSshReady before Rust CLI co-debugging, -RequireMacDirectLan to reject proxy/TUN routes, or -RequireMacRustCliSmoke -MacRemoteRepoRoot <path> for a Mac-side CLI smoke."
    Add-SmokeGateResult -Name "mac-ssh-readiness" -Status "skipped" -Detail "Pass -ProbeMacSsh for diagnostics or required Mac SSH gates for co-debugging."
}

if ($RequireMacWebRtcInterop) {
    Invoke-SmokeGate `
        -Name "windows-mac-webrtc-interop" `
        -RelativeScriptPath "Scripts/verify-windows-mac-webrtc-interop.ps1" `
        -Parameters @{
            RepoRoot = $RepoRoot
            MacHostName = $MacHostName
            MacAlternateHostNames = $MacAlternateHostNames
            MacPort = $MacPort
            MacUserNames = $MacUserNames
            MacSshKeyPath = $MacSshKeyPath
            MacKnownHostsPath = $MacKnownHostsPath
            MacExpectedHostKeyFingerprint = $MacExpectedHostKeyFingerprint
            MacExpectedHostAddress = $MacExpectedHostAddress
            MacDirectSourceAddress = $MacDirectSourceAddress
            MacSshEvidencePath = $MacSshEvidencePath
            MacRemoteRepoRoot = $MacRemoteRepoRoot
            WebRtcProofPath = $MacWebRtcProofPath
            ExpectedDeviceId = $ExpectedDeviceId
            ExpectedFingerprint = $ExpectedFingerprint
            SearchText = $SearchText
            ExtendedSearchSeconds = $ExtendedSearchSeconds
            WebRtcProofMaxAgeMs = $MacWebRtcProofMaxAgeMs
        } `
        -EvidencePath $MacWebRtcProofPath
}
else {
    Write-Output "windows-portability-smoke: skipped windows-mac-webrtc-interop; pass -RequireMacWebRtcInterop -MacRemoteRepoRoot <path> -MacWebRtcProofPath <path> -ExpectedDeviceId <id> -ExpectedFingerprint <hex> after direct LAN and helper proof are ready. That local gate composes probe-mac-ssh.ps1, verify-windows-native-dns-sd-acceptance.ps1, verify-windows-webrtc-proof.ps1, and verify-windows-connection-launch.ps1."
    Add-SmokeGateResult -Name "windows-mac-webrtc-interop" -Status "skipped" -Detail "Requires direct LAN, Mac Rust CLI smoke, native DNS-SD peer, and helper proof."
}

$offererSessionImportInputsProvided = (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportStateDir)) -or
    (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportEvidencePath)) -or
    (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportTargetRuntimeId))
$answererSessionImportInputsProvided = (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportStateDir)) -or
    (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportEvidencePath)) -or
    (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportTargetRuntimeId))
if ($ImportCurrentPathProductControlAppControlSession) {
    Assert-True -Condition $RequireCurrentPathProductControlAppControl -Message "ImportCurrentPathProductControlAppControlSession requires RequireCurrentPathProductControlAppControl because only established AppControl evidence can become a product-control session authority."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportStateDir)) -Message "CurrentPathProductControlAppControlSessionImportStateDir is required when ImportCurrentPathProductControlAppControlSession is enabled."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportEvidencePath)) -Message "CurrentPathProductControlAppControlSessionImportEvidencePath is required when ImportCurrentPathProductControlAppControlSession is enabled."
    Assert-True -Condition (-not [string]::Equals((Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAppControlSessionImportEvidencePath), (Resolve-OptionalEvidencePath -Path $CurrentPathProductControlEvidencePath), [StringComparison]::OrdinalIgnoreCase)) -Message "CurrentPathProductControlAppControlSessionImportEvidencePath must be distinct from CurrentPathProductControlEvidencePath so the AppControl evidence and session import report cannot overwrite each other."
    Assert-True -Condition (-not (Test-PathIsSameOrUnderDirectory -Path $CurrentPathProductControlAppControlSessionImportEvidencePath -DirectoryPath $CurrentPathProductControlAppControlSessionImportStateDir)) -Message "CurrentPathProductControlAppControlSessionImportEvidencePath must not be inside CurrentPathProductControlAppControlSessionImportStateDir because the state directory contains raw session registry material."
}
elseif ($offererSessionImportInputsProvided) {
    throw "Current-path offerer session-import state/report/target parameters require ImportCurrentPathProductControlAppControlSession."
}

if ($ImportCurrentPathProductControlAnswererAppControlSession) {
    Assert-True -Condition $RequireCurrentPathProductControlAnswererAppControl -Message "ImportCurrentPathProductControlAnswererAppControlSession requires RequireCurrentPathProductControlAnswererAppControl because only established answerer AppControl evidence can become a product-control session authority."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportStateDir)) -Message "CurrentPathProductControlAnswererAppControlSessionImportStateDir is required when ImportCurrentPathProductControlAnswererAppControlSession is enabled."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportEvidencePath)) -Message "CurrentPathProductControlAnswererAppControlSessionImportEvidencePath is required when ImportCurrentPathProductControlAnswererAppControlSession is enabled."
    Assert-True -Condition (-not [string]::Equals((Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath), (Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAnswererAppControlEvidencePath), [StringComparison]::OrdinalIgnoreCase)) -Message "CurrentPathProductControlAnswererAppControlSessionImportEvidencePath must be distinct from CurrentPathProductControlAnswererAppControlEvidencePath so the AppControl evidence and session import report cannot overwrite each other."
    Assert-True -Condition (-not (Test-PathIsSameOrUnderDirectory -Path $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath -DirectoryPath $CurrentPathProductControlAnswererAppControlSessionImportStateDir)) -Message "CurrentPathProductControlAnswererAppControlSessionImportEvidencePath must not be inside CurrentPathProductControlAnswererAppControlSessionImportStateDir because the state directory contains raw session registry material."
}
elseif ($answererSessionImportInputsProvided) {
    throw "Current-path answerer session-import state/report/target parameters require ImportCurrentPathProductControlAnswererAppControlSession."
}

if ($ImportCurrentPathProductControlAppControlSession -and $ImportCurrentPathProductControlAnswererAppControlSession) {
    Assert-True -Condition (-not [string]::Equals((Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAppControlSessionImportStateDir), (Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAnswererAppControlSessionImportStateDir), [StringComparison]::OrdinalIgnoreCase)) -Message "Offerer and answerer session imports must use different state directories so imported runtime session registries remain independently reviewable."
    Assert-True -Condition (-not [string]::Equals((Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAppControlSessionImportEvidencePath), (Resolve-OptionalEvidencePath -Path $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath), [StringComparison]::OrdinalIgnoreCase)) -Message "Offerer and answerer session import reports must use different evidence paths."
}

if ($RequireCurrentPathProductControlTransport -or $RequireCurrentPathProductControlAppControl -or $RequireCurrentPathProductControlFileTransfer -or $RequireCurrentPathProductControlAnswererTransport -or $RequireCurrentPathProductControlAnswererAppControl -or $RequireCurrentPathProductControlAnswererFileTransfer) {
    $offererCurrentPathGates = @($RequireCurrentPathProductControlTransport, $RequireCurrentPathProductControlAppControl, $RequireCurrentPathProductControlFileTransfer)
    $offererCurrentPathGateCount = @($offererCurrentPathGates | Where-Object { $_ }).Count
    Assert-True -Condition ($offererCurrentPathGateCount -le 1) -Message "Current-path product-control offerer transport, AppControl, and FileTransfer gates require separate smoke invocations because each consumes a remote one-time connection code."
    $currentPathAnswererTransportCodePath = if ([string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererTransportConnectionCodePath)) { $CurrentPathProductControlAnswererConnectionCodePath } else { $CurrentPathProductControlAnswererTransportConnectionCodePath }
    $currentPathAnswererAppControlCodePath = if ([string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlConnectionCodePath)) { $CurrentPathProductControlAnswererConnectionCodePath } else { $CurrentPathProductControlAnswererAppControlConnectionCodePath }
    $currentPathAnswererFileTransferCodePath = if ([string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererFileTransferConnectionCodePath)) { $CurrentPathProductControlAnswererConnectionCodePath } else { $CurrentPathProductControlAnswererFileTransferConnectionCodePath }
    $answererCurrentPathGates = @($RequireCurrentPathProductControlAnswererTransport, $RequireCurrentPathProductControlAnswererAppControl, $RequireCurrentPathProductControlAnswererFileTransfer)
    $answererCurrentPathGateCount = @($answererCurrentPathGates | Where-Object { $_ }).Count
    $answererCodePaths = @()
    if ($RequireCurrentPathProductControlAnswererTransport) {
        if ($answererCurrentPathGateCount -gt 1) {
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($currentPathAnswererTransportCodePath)) -Message "CurrentPathProductControlAnswererTransportConnectionCodePath is required when answerer transport runs with another answerer current-path gate."
            $answererCodePaths += $currentPathAnswererTransportCodePath
        }
    }
    if ($RequireCurrentPathProductControlAnswererAppControl) {
        if ($answererCurrentPathGateCount -gt 1) {
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($currentPathAnswererAppControlCodePath)) -Message "CurrentPathProductControlAnswererAppControlConnectionCodePath is required when answerer AppControl runs with another answerer current-path gate."
            $answererCodePaths += $currentPathAnswererAppControlCodePath
        }
    }
    if ($RequireCurrentPathProductControlAnswererFileTransfer) {
        if ($answererCurrentPathGateCount -gt 1) {
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($currentPathAnswererFileTransferCodePath)) -Message "CurrentPathProductControlAnswererFileTransferConnectionCodePath is required when answerer FileTransfer runs with another answerer current-path gate."
            $answererCodePaths += $currentPathAnswererFileTransferCodePath
        }
    }
    if ($answererCodePaths.Count -gt 1) {
        $distinctAnswererCodePaths = @($answererCodePaths | Select-Object -Unique)
        Assert-True -Condition ($distinctAnswererCodePaths.Count -eq $answererCodePaths.Count) -Message "Current-path product-control answerer gates must use different registered-code output paths because each gate registers a one-time current-path code."
    }
    if ($RequireCurrentPathProductControlTransport -or $RequireCurrentPathProductControlAppControl) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlEvidencePath)) -Message "CurrentPathProductControlEvidencePath is required for current-path product-control offerer live gates so acceptance evidence can validate the durable artifact."
    }
    if ($RequireCurrentPathProductControlFileTransfer) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlFileTransferEvidencePath)) -Message "CurrentPathProductControlFileTransferEvidencePath is required for current-path product-control offerer FileTransfer live gates so acceptance evidence can validate the durable artifact."
    }
    if ($RequireCurrentPathProductControlAnswererTransport) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererEvidencePath)) -Message "CurrentPathProductControlAnswererEvidencePath is required for current-path product-control answerer live gates so acceptance evidence can validate the durable artifact."
    }
    if ($RequireCurrentPathProductControlAnswererAppControl) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlEvidencePath)) -Message "CurrentPathProductControlAnswererAppControlEvidencePath is required for current-path product-control answerer AppControl live gates so acceptance evidence can validate the durable artifact."
    }
    if ($RequireCurrentPathProductControlAnswererFileTransfer) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererFileTransferEvidencePath)) -Message "CurrentPathProductControlAnswererFileTransferEvidencePath is required for current-path product-control answerer FileTransfer live gates so acceptance evidence can validate the durable artifact."
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($CurrentPathLocalDeviceId)) -Message "CurrentPathLocalDeviceId is required for current-path product-control live gates."
    $effectiveCurrentPathPeerDeviceId = if ([string]::IsNullOrWhiteSpace($CurrentPathPeerDeviceId)) { $ExpectedDeviceId } else { $CurrentPathPeerDeviceId }
    $effectiveCurrentPathPeerFingerprint = if ([string]::IsNullOrWhiteSpace($CurrentPathPeerFingerprint)) { $ExpectedFingerprint } else { $CurrentPathPeerFingerprint }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($effectiveCurrentPathPeerDeviceId)) -Message "CurrentPathPeerDeviceId or ExpectedDeviceId is required for current-path product-control live gates."
    Assert-True -Condition ($effectiveCurrentPathPeerFingerprint -match '^[0-9a-f]{64}$') -Message "CurrentPathPeerFingerprint or ExpectedFingerprint must be 64 lowercase hex characters for current-path product-control live gates."

    $currentPathBaseParameters = @{
        RepoRoot = $RepoRoot
        SignalServerBaseUrl = $CurrentPathSignalServerBaseUrl
        LocalDeviceId = $CurrentPathLocalDeviceId
        PeerDeviceId = $effectiveCurrentPathPeerDeviceId
        PeerFingerprint = $effectiveCurrentPathPeerFingerprint
        DeviceName = $CurrentPathDeviceName
        ConnectionCodeEnvVar = $CurrentPathConnectionCodeEnvVar
        BearerTokenEnvVar = $CurrentPathBearerTokenEnvVar
        TenantIdEnvVar = $CurrentPathTenantIdEnvVar
        Mldsa65PrivateKeyBase64EnvVar = $CurrentPathMldsa65PrivateKeyBase64EnvVar
        ClientVersion = $CurrentPathClientVersion
        ProtocolVersion = $CurrentPathProtocolVersion
        TimeoutSeconds = $CurrentPathTimeoutSeconds
        SignalFileTimeoutSeconds = $CurrentPathSignalFileTimeoutSeconds
        RemoteAnswerTimeoutSeconds = $CurrentPathRemoteAnswerTimeoutSeconds
        RemoteOfferTimeoutSeconds = $CurrentPathRemoteOfferTimeoutSeconds
        TtlSeconds = $CurrentPathConnectionCodeTtlSeconds
        Configuration = $CurrentPathConfiguration
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlSignalingDir)) {
        $currentPathBaseParameters.SignalingDir = $CurrentPathProductControlSignalingDir
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentPathBindAddress)) {
        $currentPathBaseParameters.BindAddress = $CurrentPathBindAddress
    }

    if ($RequireCurrentPathProductControlFileTransfer) {
        $currentPathFileTransferParameters = $currentPathBaseParameters.Clone()
        $currentPathFileTransferParameters.Remove("RemoteOfferTimeoutSeconds")
        $currentPathFileTransferParameters.Remove("TtlSeconds")
        $currentPathFileTransferParameters.EvidencePath = $CurrentPathProductControlFileTransferEvidencePath
        $currentPathFileTransferParameters.PeerMlKem768PublicKeyBase64EnvVar = $CurrentPathPeerMlKem768PublicKeyBase64EnvVar
        $currentPathFileTransferParameters.FileTransferPayloadBytes = $CurrentPathFileTransferPayloadBytes
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-file-transfer" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-file-transfer-live.ps1" `
            -Parameters $currentPathFileTransferParameters `
            -EvidencePath $CurrentPathProductControlFileTransferEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-transport" -Status "skipped" -Detail "The FileTransfer evidence includes ProductControlTransport, but this independent transport-only gate requires running -RequireCurrentPathProductControlTransport in a separate smoke invocation." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl in a separate smoke invocation when AppControl ping/pong proof is required." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "skipped" -Detail "Session import requires established AppControl evidence; rerun with -RequireCurrentPathProductControlAppControl and -ImportCurrentPathProductControlAppControlSession." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
    }
    elseif ($RequireCurrentPathProductControlAppControl) {
        $currentPathParameters = $currentPathBaseParameters.Clone()
        $currentPathParameters.Remove("RemoteOfferTimeoutSeconds")
        $currentPathParameters.Remove("TtlSeconds")
        $currentPathParameters.EvidencePath = $CurrentPathProductControlEvidencePath
        $currentPathParameters.PeerMlKem768PublicKeyBase64EnvVar = $CurrentPathPeerMlKem768PublicKeyBase64EnvVar
        if ($ImportCurrentPathProductControlAppControlSession) {
            $currentPathParameters.ImportProductControlSession = $true
            $currentPathParameters.SessionImportStateDir = $CurrentPathProductControlAppControlSessionImportStateDir
            $currentPathParameters.SessionImportReportPath = $CurrentPathProductControlAppControlSessionImportEvidencePath
            $currentPathParameters.SessionImportTtlSeconds = $CurrentPathProductControlAppControlSessionImportTtlSeconds
            if (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAppControlSessionImportTargetRuntimeId)) {
                $currentPathParameters.SessionImportTargetRuntimeId = $CurrentPathProductControlAppControlSessionImportTargetRuntimeId
            }
        }
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-appcontrol" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1" `
            -Parameters $currentPathParameters `
            -EvidencePath $CurrentPathProductControlEvidencePath
        if ($ImportCurrentPathProductControlAppControlSession) {
            Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "passed" -Detail "AppControl evidence was imported into the Rust product-control session registry; the report is redacted and digest-checked as an acceptance artifact." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
        }
        else {
            Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "skipped" -Detail "Pass -ImportCurrentPathProductControlAppControlSession with a dedicated state directory and report path to import the established AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
        }
        Add-SmokeGateResult -Name "windows-current-path-product-control-transport" -Status "skipped" -Detail "The AppControl evidence includes a ProductControlTransport step, but this independent transport-only gate requires running -RequireCurrentPathProductControlTransport in a separate smoke invocation." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlFileTransfer in a separate smoke invocation when FileTransfer receipt proof is required." -EvidencePath $CurrentPathProductControlFileTransferEvidencePath
    }
    elseif ($RequireCurrentPathProductControlTransport) {
        $currentPathParameters = $currentPathBaseParameters.Clone()
        $currentPathParameters.EvidencePath = $CurrentPathProductControlEvidencePath
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-transport" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-transport-live.ps1" `
            -Parameters $currentPathParameters `
            -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl with peer ML-KEM-768 public key evidence for authenticated AppControl proof." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlFileTransfer with peer ML-KEM-768 public key evidence for authenticated FileTransfer receipt proof." -EvidencePath $CurrentPathProductControlFileTransferEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "skipped" -Detail "Session import requires established AppControl evidence; rerun with -RequireCurrentPathProductControlAppControl and -ImportCurrentPathProductControlAppControlSession." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
    }
    else {
        Add-SmokeGateResult -Name "windows-current-path-product-control-transport" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlTransport or -RequireCurrentPathProductControlAppControl for live current-path product-control offerer evidence." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl with peer ML-KEM-768 public key evidence for authenticated AppControl proof." -EvidencePath $CurrentPathProductControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlFileTransfer with peer ML-KEM-768 public key evidence for authenticated FileTransfer receipt proof." -EvidencePath $CurrentPathProductControlFileTransferEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl and -ImportCurrentPathProductControlAppControlSession to import established AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
    }

    if ($RequireCurrentPathProductControlAnswererTransport) {
        $currentPathAnswererParameters = $currentPathBaseParameters.Clone()
        $currentPathAnswererParameters.EvidencePath = $CurrentPathProductControlAnswererEvidencePath
        $currentPathAnswererParameters.ExpectedBoundRole = $CurrentPathExpectedBoundRole
        if (-not [string]::IsNullOrWhiteSpace($currentPathAnswererTransportCodePath)) {
            $currentPathAnswererParameters.RegisteredCodeOutPath = $currentPathAnswererTransportCodePath
        }
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-answerer-transport" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-answerer-transport-live.ps1" `
            -Parameters $currentPathAnswererParameters `
            -EvidencePath $CurrentPathProductControlAnswererEvidencePath
    }
    elseif ($RequireCurrentPathProductControlAnswererAppControl) {
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-transport" -Status "skipped" -Detail "The answerer AppControl evidence includes a ProductControlTransport step, but this independent transport-only gate requires running -RequireCurrentPathProductControlAnswererTransport." -EvidencePath $CurrentPathProductControlAnswererEvidencePath
    }
    else {
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-transport" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererTransport after the remote mac/iOS peer is ready to send a current-path product-control offer to Windows." -EvidencePath $CurrentPathProductControlAnswererEvidencePath
    }

    if ($RequireCurrentPathProductControlAnswererAppControl) {
        $currentPathAnswererAppControlParameters = $currentPathBaseParameters.Clone()
        $currentPathAnswererAppControlParameters.EvidencePath = $CurrentPathProductControlAnswererAppControlEvidencePath
        $currentPathAnswererAppControlParameters.ExpectedBoundRole = $CurrentPathExpectedBoundRole
        $currentPathAnswererAppControlParameters.LocalMlKem768DecapsulationKeyBase64EnvVar = $CurrentPathLocalMlKem768DecapsulationKeyBase64EnvVar
        $currentPathAnswererAppControlParameters.LocalMlKem768EncapsulationKeyBase64EnvVar = $CurrentPathLocalMlKem768EncapsulationKeyBase64EnvVar
        if ($ImportCurrentPathProductControlAnswererAppControlSession) {
            $currentPathAnswererAppControlParameters.ImportProductControlSession = $true
            $currentPathAnswererAppControlParameters.SessionImportStateDir = $CurrentPathProductControlAnswererAppControlSessionImportStateDir
            $currentPathAnswererAppControlParameters.SessionImportReportPath = $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
            $currentPathAnswererAppControlParameters.SessionImportTtlSeconds = $CurrentPathProductControlAnswererAppControlSessionImportTtlSeconds
            if (-not [string]::IsNullOrWhiteSpace($CurrentPathProductControlAnswererAppControlSessionImportTargetRuntimeId)) {
                $currentPathAnswererAppControlParameters.SessionImportTargetRuntimeId = $CurrentPathProductControlAnswererAppControlSessionImportTargetRuntimeId
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($currentPathAnswererAppControlCodePath)) {
            $currentPathAnswererAppControlParameters.RegisteredCodeOutPath = $currentPathAnswererAppControlCodePath
        }
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-answerer-appcontrol" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-answerer-appcontrol-live.ps1" `
            -Parameters $currentPathAnswererAppControlParameters `
            -EvidencePath $CurrentPathProductControlAnswererAppControlEvidencePath
        if ($ImportCurrentPathProductControlAnswererAppControlSession) {
            Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol-session-import" -Status "passed" -Detail "Answerer AppControl evidence was imported into the Rust product-control session registry; the report is redacted and digest-checked as an acceptance artifact." -EvidencePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
        }
        else {
            Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol-session-import" -Status "skipped" -Detail "Pass -ImportCurrentPathProductControlAnswererAppControlSession with a dedicated state directory and report path to import answerer AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
        }
    }
    elseif ($RequireCurrentPathProductControlAnswererTransport) {
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererAppControl after the remote mac/iOS peer is ready to send a signed current-path product-control MessageA and encrypted AppControl ping to Windows." -EvidencePath $CurrentPathProductControlAnswererAppControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol-session-import" -Status "skipped" -Detail "Answerer session import requires established answerer AppControl evidence; rerun with -RequireCurrentPathProductControlAnswererAppControl and -ImportCurrentPathProductControlAnswererAppControlSession." -EvidencePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
    }
    else {
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererAppControl after the remote mac/iOS peer is ready to send a signed current-path product-control MessageA and encrypted AppControl ping to Windows." -EvidencePath $CurrentPathProductControlAnswererAppControlEvidencePath
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol-session-import" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererAppControl and -ImportCurrentPathProductControlAnswererAppControlSession to import established answerer AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
    }

    if ($RequireCurrentPathProductControlAnswererFileTransfer) {
        $currentPathAnswererFileTransferParameters = $currentPathBaseParameters.Clone()
        $currentPathAnswererFileTransferParameters.EvidencePath = $CurrentPathProductControlAnswererFileTransferEvidencePath
        $currentPathAnswererFileTransferParameters.ExpectedBoundRole = $CurrentPathExpectedBoundRole
        $currentPathAnswererFileTransferParameters.LocalMlKem768DecapsulationKeyBase64EnvVar = $CurrentPathLocalMlKem768DecapsulationKeyBase64EnvVar
        $currentPathAnswererFileTransferParameters.LocalMlKem768EncapsulationKeyBase64EnvVar = $CurrentPathLocalMlKem768EncapsulationKeyBase64EnvVar
        $currentPathAnswererFileTransferParameters.FileTransferPayloadBytes = $CurrentPathFileTransferPayloadBytes
        if (-not [string]::IsNullOrWhiteSpace($currentPathAnswererFileTransferCodePath)) {
            $currentPathAnswererFileTransferParameters.RegisteredCodeOutPath = $currentPathAnswererFileTransferCodePath
        }
        Invoke-SmokeGate `
            -Name "windows-current-path-product-control-answerer-file-transfer" `
            -RelativeScriptPath "Scripts/verify-windows-current-path-product-control-answerer-file-transfer-live.ps1" `
            -Parameters $currentPathAnswererFileTransferParameters `
            -EvidencePath $CurrentPathProductControlAnswererFileTransferEvidencePath
    }
    else {
        Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererFileTransfer after the remote mac/iOS peer is ready to send a signed current-path product-control MessageA and encrypted FileTransfer payloads to Windows." -EvidencePath $CurrentPathProductControlAnswererFileTransferEvidencePath
    }
}
else {
    Write-Output "windows-portability-smoke: skipped windows-current-path-product-control transport/appcontrol/file-transfer and answerer transport/appcontrol/file-transfer; pass the corresponding RequireCurrentPathProductControl* switch when a live peer is ready."
    Add-SmokeGateResult -Name "windows-current-path-product-control-transport" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlTransport or -RequireCurrentPathProductControlAppControl for live current-path product-control evidence." -EvidencePath $CurrentPathProductControlEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl with peer ML-KEM-768 public key evidence for authenticated AppControl proof." -EvidencePath $CurrentPathProductControlEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlFileTransfer with peer ML-KEM-768 public key evidence for authenticated FileTransfer receipt proof." -EvidencePath $CurrentPathProductControlFileTransferEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-session-import" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAppControl and -ImportCurrentPathProductControlAppControlSession to import established AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAppControlSessionImportEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-transport" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererTransport after the remote mac/iOS peer is ready to send a current-path product-control offer to Windows." -EvidencePath $CurrentPathProductControlAnswererEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererAppControl after the remote mac/iOS peer is ready to send a signed current-path product-control MessageA and encrypted AppControl ping to Windows." -EvidencePath $CurrentPathProductControlAnswererAppControlEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-file-transfer" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererFileTransfer after the remote mac/iOS peer is ready to send signed current-path product-control FileTransfer payloads to Windows." -EvidencePath $CurrentPathProductControlAnswererFileTransferEvidencePath
    Add-SmokeGateResult -Name "windows-current-path-product-control-answerer-appcontrol-session-import" -Status "skipped" -Detail "Pass -RequireCurrentPathProductControlAnswererAppControl and -ImportCurrentPathProductControlAnswererAppControlSession to import established answerer AppControl evidence into the Rust session registry." -EvidencePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath
}

if ($IncludeNativeDnsSdAcceptance -or $RequireNativeDnsSdPeer) {
    $dnsSdParameters = @{
        RepoRoot = $RepoRoot
        ExtendedSearchSeconds = $ExtendedSearchSeconds
    }

    if ($RequireNativeDnsSdPeer) {
        $dnsSdParameters.RequirePeer = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) {
        $dnsSdParameters.ExpectedDeviceId = $ExpectedDeviceId
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
        $dnsSdParameters.ExpectedFingerprint = $ExpectedFingerprint
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchText)) {
        $dnsSdParameters.SearchText = $SearchText
    }

    Invoke-SmokeGate `
        -Name "windows-native-dns-sd-acceptance" `
        -RelativeScriptPath "Scripts/verify-windows-native-dns-sd-acceptance.ps1" `
        -Parameters $dnsSdParameters
}
else {
    Write-Output "windows-portability-smoke: skipped windows-native-dns-sd-acceptance; pass -IncludeNativeDnsSdAcceptance or -RequireNativeDnsSdPeer for local-network acceptance."
    Add-SmokeGateResult -Name "windows-native-dns-sd-acceptance" -Status "skipped" -Detail "Pass -IncludeNativeDnsSdAcceptance or -RequireNativeDnsSdPeer for local-network acceptance."
}

$requiresLiveEvidenceAcceptanceManifest = $RequireLiveFileTransfer -or $RequireLiveRemoteDesktop
if ($requiresLiveEvidenceAcceptanceManifest) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($AcceptanceEvidencePath)) -Message "AcceptanceEvidencePath is required when live file-transfer or remote-desktop gates are required; run Scripts/verify-windows-portability-acceptance-evidence.ps1 against that manifest with matching -RequireLive* switches before treating live evidence as accepted."
}

if ($RequireLiveFileTransfer) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($LiveFileTransferEvidencePath)) -Message "LiveFileTransferEvidencePath is required when RequireLiveFileTransfer is passed."
    $resolvedLiveFileTransferEvidencePath = Resolve-OptionalEvidencePath -Path $LiveFileTransferEvidencePath
    Assert-True -Condition (Test-Path -LiteralPath $resolvedLiveFileTransferEvidencePath -PathType Leaf) -Message "Live file-transfer evidence is missing: $resolvedLiveFileTransferEvidencePath"
    Add-SmokeGateResult -Name "windows-live-file-transfer" -Status "passed" -Detail "Live file-transfer evidence file is present; this smoke invocation runs the acceptance verifier before reporting ok, enforcing bytes, ACK, and SHA-256 receipt schema." -EvidencePath $LiveFileTransferEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped windows-live-file-transfer; pass -RequireLiveFileTransfer -LiveFileTransferEvidencePath <path> after real device file transfer completes."
    Add-SmokeGateResult -Name "windows-live-file-transfer" -Status "skipped" -Detail "Pass -RequireLiveFileTransfer with live bytes/ACK/SHA-256 receipt evidence." -EvidencePath $LiveFileTransferEvidencePath
}

if ($RequireLiveRemoteDesktop) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($LiveRemoteDesktopEvidencePath)) -Message "LiveRemoteDesktopEvidencePath is required when RequireLiveRemoteDesktop is passed."
    $resolvedLiveRemoteDesktopEvidencePath = Resolve-OptionalEvidencePath -Path $LiveRemoteDesktopEvidencePath
    Assert-True -Condition (Test-Path -LiteralPath $resolvedLiveRemoteDesktopEvidencePath -PathType Leaf) -Message "Live remote-desktop evidence is missing: $resolvedLiveRemoteDesktopEvidencePath"
    Add-SmokeGateResult -Name "windows-live-remote-desktop" -Status "passed" -Detail "Live remote-desktop evidence file is present; this smoke invocation runs the acceptance verifier before reporting ok, enforcing notice, frame, input, and disconnect schema." -EvidencePath $LiveRemoteDesktopEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped windows-live-remote-desktop; pass -RequireLiveRemoteDesktop -LiveRemoteDesktopEvidencePath <path> after real remote desktop capture/input completes."
    Add-SmokeGateResult -Name "windows-live-remote-desktop" -Status "skipped" -Detail "Pass -RequireLiveRemoteDesktop with notice/frame/input/disconnect evidence." -EvidencePath $LiveRemoteDesktopEvidencePath
}

if ($IncludeRustCliCoverage) {
    $rustCliCoverageParameters = @{
        RepoRoot = $RepoRoot
        MinimumLineCoverage = $MinimumLineCoverage
    }
    if (-not [string]::IsNullOrWhiteSpace($RustCliCoverageEvidencePath)) {
        $rustCliCoverageParameters.EvidencePath = $RustCliCoverageEvidencePath
    }

    Invoke-SmokeGate `
        -Name "rust-cli-coverage" `
        -RelativeScriptPath "Scripts/verify-rust-cli-coverage.ps1" `
        -Parameters $rustCliCoverageParameters `
        -EvidencePath $RustCliCoverageEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped rust-cli-coverage; pass -IncludeRustCliCoverage for the 90% Rust CLI coverage gate."
    Add-SmokeGateResult -Name "rust-cli-coverage" -Status "skipped" -Detail "Pass -IncludeRustCliCoverage for the 90% Rust CLI coverage gate." -EvidencePath $RustCliCoverageEvidencePath
}

if ($RequirePublicArtifactRedaction) {
    Assert-True -Condition ($PublicArtifactPath.Count -gt 0) -Message "PublicArtifactPath is required when RequirePublicArtifactRedaction is passed."
    $publicArtifactRedactionParameters = @{
        RepoRoot = $RepoRoot
        ArtifactPath = $PublicArtifactPath
    }
    if ($PublicArtifactSensitiveToken.Count -gt 0) {
        $publicArtifactRedactionParameters.SensitiveToken = $PublicArtifactSensitiveToken
    }
    if (-not [string]::IsNullOrWhiteSpace($PublicArtifactScanEvidencePath)) {
        $publicArtifactRedactionParameters.EvidencePath = $PublicArtifactScanEvidencePath
    }

    Invoke-SmokeGate `
        -Name "windows-public-artifact-redaction" `
        -RelativeScriptPath "Scripts/verify-windows-public-artifact-redaction.ps1" `
        -Parameters $publicArtifactRedactionParameters `
        -EvidencePath $PublicArtifactScanEvidencePath
}
else {
    Write-Output "windows-portability-smoke: skipped windows-public-artifact-redaction; pass -RequirePublicArtifactRedaction -PublicArtifactPath <public-artifact-dir> before publishing acceptance artifacts."
    Add-SmokeGateResult -Name "windows-public-artifact-redaction" -Status "skipped" -Detail "Pass -RequirePublicArtifactRedaction with redacted public artifact paths before publishing evidence." -EvidencePath $PublicArtifactScanEvidencePath
}

Write-AcceptanceEvidence
Invoke-LiveAcceptanceVerifier
Write-Output "windows-portability-smoke: ok"
