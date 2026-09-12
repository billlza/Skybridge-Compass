param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$AcceptanceEvidencePath,
    [double]$MinimumLineCoverage = 90.0,
    [switch]$RequireRustCliCoverage,
    [switch]$RequireOnlineStackFreshness,
    [switch]$RequireWinUiVisualEvidence,
    [switch]$AllowStandaloneWinUiVisualEvidence,
    [switch]$RequireNativeDnsSdAcceptance,
    [switch]$RequireMacInterop,
    [switch]$RequireCurrentPathProductControlTransport,
    [switch]$RequireCurrentPathProductControlAppControl,
    [switch]$RequireCurrentPathProductControlFileTransfer,
    [switch]$RequireCurrentPathProductControlAnswererTransport,
    [switch]$RequireCurrentPathProductControlAnswererAppControl,
    [switch]$RequireCurrentPathProductControlAnswererFileTransfer,
    [switch]$RequireCurrentPathProductControlSessionImport,
    [switch]$RequireCurrentPathProductControlAnswererAppControlSessionImport,
    [switch]$RequireWindowsReverseSshRelayLifecycle,
    [switch]$RequireLiveFileTransfer,
    [switch]$RequireLiveRemoteDesktop,
    [switch]$RequirePublicArtifactRedaction,
    [string[]]$PublicArtifactPath = @(),
    [string[]]$PublicArtifactSensitiveToken = @(),
    [string]$PublicArtifactScanEvidencePath = "",
    [string]$RustCliCoverageEvidencePath = "",
    [string]$StackFreshnessEvidencePath = "",
    [string]$WinUiEvidenceDir = "",
    [string]$MacSshEvidencePath = "",
    [string]$CurrentPathProductControlEvidencePath = "",
    [string]$CurrentPathProductControlFileTransferEvidencePath = "",
    [string]$CurrentPathProductControlAnswererEvidencePath = "",
    [string]$CurrentPathProductControlAnswererAppControlEvidencePath = "",
    [string]$CurrentPathProductControlAnswererFileTransferEvidencePath = "",
    [string]$CurrentPathProductControlAppControlSessionImportEvidencePath = "",
    [string]$CurrentPathProductControlAnswererAppControlSessionImportEvidencePath = "",
    [string]$WindowsReverseSshRelayEvidencePath = "",
    [string]$LiveFileTransferEvidencePath = "",
    [string]$LiveRemoteDesktopEvidencePath = "",
    [string]$ExpectedBranch = "",
    [string]$ExpectedHead = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:AcceptanceArtifactDigests = @()

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-JsonProperty {
    param(
        $Object,
        [string]$Name,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Object) -Message "$Context is null."
    $property = $Object.PSObject.Properties[$Name]
    Assert-True -Condition ($null -ne $property) -Message "$Context missing JSON property: $Name"
    return $property.Value
}

function ConvertTo-Boolean {
    param(
        $Value,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Value) -Message "$Context is null."
    return [System.Convert]::ToBoolean($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DoubleInvariant {
    param(
        $Value,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Value) -Message "$Context is null."
    return [System.Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-EvidencePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepoRoot $Path))
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

function Add-ExpectedArtifactPath {
    param(
        [hashtable]$ExpectedArtifactPaths,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $resolvedPath = Resolve-EvidencePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        return
    }

    $pathHash = Get-StableSha256Hex -Value ([System.IO.Path]::GetFullPath($resolvedPath))
    if ($ExpectedArtifactPaths.ContainsKey($pathHash)) {
        Assert-True -Condition ([string]::Equals([string]$ExpectedArtifactPaths[$pathHash], $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) -Message "Acceptance artifact path hash collision or inconsistent duplicate: $pathHash"
        return
    }

    $ExpectedArtifactPaths[$pathHash] = $resolvedPath
}

function Get-ExpectedArtifactPathMap {
    param(
        $EvidencePaths,
        [object[]]$GateResults
    )

    $expectedArtifactPaths = @{}
    foreach ($property in $EvidencePaths.PSObject.Properties) {
        if (Test-IsDigestibleEvidencePathProperty -Name $property.Name) {
            Add-ExpectedArtifactPath -ExpectedArtifactPaths $expectedArtifactPaths -Path ([string]$property.Value)
        }
    }

    foreach ($gate in $GateResults) {
        if ($null -ne $gate -and $null -ne $gate.PSObject.Properties["evidencePath"]) {
            Add-ExpectedArtifactPath -ExpectedArtifactPaths $expectedArtifactPaths -Path ([string]$gate.evidencePath)
        }
    }

    return $expectedArtifactPaths
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

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Context
    )

    $resolvedPath = Resolve-EvidencePath -Path $Path
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedPath)) -Message "$Context evidence path is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedPath) -Message "$Context evidence file is missing: $resolvedPath"
    Assert-ArtifactDigestForResolvedPath -ResolvedPath $resolvedPath -Context $Context
    return (Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json)
}

function Assert-ArtifactDigests {
    param(
        [object[]]$Artifacts,
        [hashtable]$ExpectedArtifactPaths
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($artifact in $Artifacts) {
        $path = [string](Assert-JsonProperty -Object $artifact -Name "path" -Context "acceptance.artifactDigests[]")
        $pathSha256 = [string](Assert-JsonProperty -Object $artifact -Name "pathSha256" -Context "acceptance.artifactDigests[$path]")
        $pathScope = [string](Assert-JsonProperty -Object $artifact -Name "pathScope" -Context "acceptance.artifactDigests[$path]")
        $pathType = [string](Assert-JsonProperty -Object $artifact -Name "pathType" -Context "acceptance.artifactDigests[$path]")
        $exists = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $artifact -Name "exists" -Context "acceptance.artifactDigests[$path]") -Context "acceptance.artifactDigests[$path].exists"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($path)) -Message "Acceptance artifact digest path is empty."
        Assert-True -Condition ($pathSha256 -match '^[0-9a-f]{64}$') -Message "Acceptance artifact digest pathSha256 must be lowercase hex: $path"
        Assert-True -Condition ($seen.Add($pathSha256)) -Message "Duplicate acceptance artifact digest path hash: $pathSha256"
        Assert-True -Condition ($ExpectedArtifactPaths.ContainsKey($pathSha256)) -Message "Acceptance artifact digest does not correspond to an expected evidence path: $path"
        $resolvedPath = [string]$ExpectedArtifactPaths[$pathSha256]
        Assert-True -Condition ($path -eq (ConvertTo-PortableArtifactPath -ResolvedPath $resolvedPath)) -Message "Acceptance artifact digest path display is not canonical for: $path"
        Assert-True -Condition ($pathScope -eq (Get-ArtifactPathScope -ResolvedPath $resolvedPath)) -Message "Acceptance artifact digest path scope is not canonical for: $path"

        if ($pathType -eq "file") {
            Assert-True -Condition ($exists -eq $true) -Message "File artifact digest must set exists=true: $path"
            Assert-True -Condition (Test-Path -LiteralPath $resolvedPath -PathType Leaf) -Message "Acceptance artifact file is missing: $path"
            $expectedLength = [System.Convert]::ToInt64((Assert-JsonProperty -Object $artifact -Name "byteLength" -Context "acceptance.artifactDigests[$path]"), [Globalization.CultureInfo]::InvariantCulture)
            $expectedSha256 = [string](Assert-JsonProperty -Object $artifact -Name "sha256" -Context "acceptance.artifactDigests[$path]")
            Assert-True -Condition ($expectedLength -ge 0) -Message "Artifact byteLength must be non-negative: $path"
            Assert-True -Condition ($expectedSha256 -match '^[0-9a-f]{64}$') -Message "Artifact sha256 must be lowercase hex: $path"
            $item = Get-Item -LiteralPath $resolvedPath
            Assert-True -Condition ([int64]$item.Length -eq $expectedLength) -Message "Artifact byteLength changed: $path"
            $actualSha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True -Condition ($actualSha256 -eq $expectedSha256) -Message "Artifact sha256 changed: $path"
            Assert-DateString -Value ([string](Assert-JsonProperty -Object $artifact -Name "lastWriteTimeUtc" -Context "acceptance.artifactDigests[$path]")) -Context "acceptance.artifactDigests[$path].lastWriteTimeUtc"
        }
        elseif ($pathType -eq "directory") {
            Assert-True -Condition ($exists -eq $true) -Message "Directory artifact digest must set exists=true: $path"
            Assert-True -Condition (Test-Path -LiteralPath $resolvedPath -PathType Container) -Message "Acceptance artifact directory is missing: $path"
            $expectedFileCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $artifact -Name "fileCount" -Context "acceptance.artifactDigests[$path]"), [Globalization.CultureInfo]::InvariantCulture)
            $expectedLength = [System.Convert]::ToInt64((Assert-JsonProperty -Object $artifact -Name "byteLength" -Context "acceptance.artifactDigests[$path]"), [Globalization.CultureInfo]::InvariantCulture)
            $expectedSha256 = [string](Assert-JsonProperty -Object $artifact -Name "sha256" -Context "acceptance.artifactDigests[$path]")
            Assert-True -Condition ($expectedFileCount -ge 0) -Message "Directory artifact fileCount must be non-negative: $path"
            Assert-True -Condition ($expectedLength -ge 0) -Message "Directory artifact byteLength must be non-negative: $path"
            Assert-True -Condition ($expectedSha256 -match '^[0-9a-f]{64}$') -Message "Directory artifact sha256 must be lowercase hex: $path"
            $actualDigest = Get-DirectoryManifestDigest -DirectoryPath $resolvedPath
            Assert-True -Condition ([int64]$actualDigest.fileCount -eq $expectedFileCount) -Message "Directory artifact fileCount changed: $path"
            Assert-True -Condition ([int64]$actualDigest.byteLength -eq $expectedLength) -Message "Directory artifact byteLength changed: $path"
            Assert-True -Condition ([string]$actualDigest.sha256 -eq $expectedSha256) -Message "Directory artifact sha256 changed: $path"
            Assert-DateString -Value ([string](Assert-JsonProperty -Object $artifact -Name "lastWriteTimeUtc" -Context "acceptance.artifactDigests[$path]")) -Context "acceptance.artifactDigests[$path].lastWriteTimeUtc"
        }
        elseif ($pathType -eq "missing") {
            Assert-True -Condition ($exists -eq $false) -Message "Missing artifact digest must set exists=false: $path"
            Assert-True -Condition (-not (Test-Path -LiteralPath $resolvedPath)) -Message "Artifact was marked missing but now exists: $path"
        }
        else {
            throw "Unknown acceptance artifact digest pathType for $path`: $pathType"
        }
    }

    Assert-True -Condition ($seen.Count -eq $ExpectedArtifactPaths.Count) -Message "Acceptance artifact digest count does not match expected evidence artifact paths."
    foreach ($expectedArtifactPathHash in $ExpectedArtifactPaths.Keys) {
        Assert-True -Condition ($seen.Contains([string]$expectedArtifactPathHash)) -Message "Missing acceptance artifact digest for expected evidence artifact path hash: $expectedArtifactPathHash"
    }
}

function Assert-ArtifactDigestForResolvedPath {
    param(
        [string]$ResolvedPath,
        [string]$Context
    )

    $matches = @($script:AcceptanceArtifactDigests | Where-Object {
        [string]::Equals(
            [string]$_.pathSha256,
            (Get-StableSha256Hex -Value ([System.IO.Path]::GetFullPath($ResolvedPath))),
            [StringComparison]::OrdinalIgnoreCase)
    })
    Assert-True -Condition ($matches.Count -eq 1) -Message "$Context evidence file must have exactly one acceptance artifact digest record: $ResolvedPath"
    $pathType = [string](Assert-JsonProperty -Object $matches[0] -Name "pathType" -Context "acceptance.artifactDigests[$ResolvedPath]")
    $exists = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $matches[0] -Name "exists" -Context "acceptance.artifactDigests[$ResolvedPath]") -Context "acceptance.artifactDigests[$ResolvedPath].exists"
    Assert-True -Condition ($pathType -eq "file") -Message "$Context evidence digest must describe a file artifact: $ResolvedPath"
    Assert-True -Condition ($exists -eq $true) -Message "$Context evidence digest must set exists=true: $ResolvedPath"
}

function Get-OverrideOrJsonPath {
    param(
        [string]$OverridePath,
        $EvidencePaths,
        [string]$PropertyName
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }

    return [string](Assert-JsonProperty -Object $EvidencePaths -Name $PropertyName -Context "acceptance.evidencePaths")
}

function Assert-DateString {
    param(
        [string]$Value,
        [string]$Context
    )

    $parsed = [DateTime]::MinValue
    Assert-True -Condition ([DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed) -and $parsed -gt [DateTime]::MinValue) -Message "$Context must be a parseable UTC date string."
}

function Assert-PassedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    Assert-True -Condition ([string]$gate.status -eq "passed") -Message "Acceptance gate must be passed: $Name status=$($gate.status) detail=$($gate.detail)"
    return $gate
}

function Assert-SkippedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    Assert-True -Condition ([string]$gate.status -eq "skipped") -Message "Acceptance gate must be skipped: $Name status=$($gate.status) detail=$($gate.detail)"
    return $gate
}

function Assert-PassedOrSkippedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    $status = [string]$gate.status
    Assert-True -Condition ($status -eq "passed" -or $status -eq "skipped") -Message "Acceptance gate must be passed or skipped: $Name status=$status detail=$($gate.detail)"
    return $gate
}

function Get-Gate {
    param([string]$Name)

    $matches = @($script:AcceptanceGateResults | Where-Object { [string]$_.name -eq $Name })
    Assert-True -Condition ($matches.Count -eq 1) -Message "Expected exactly one acceptance gate named $Name, found $($matches.Count)."
    return $matches[0]
}

function Assert-RequiredBooleanParameter {
    param(
        $Parameters,
        [string]$Name,
        [bool]$Expected
    )

    $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Parameters -Name $Name -Context "acceptance.parameters") -Context "acceptance.parameters.$Name"
    Assert-True -Condition ($value -eq $Expected) -Message "Acceptance parameter $Name must be $Expected, got $value."
}

function Get-OptionalBooleanParameter {
    param(
        $Parameters,
        [string]$Name,
        [bool]$DefaultValue
    )

    $property = $Parameters.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return ConvertTo-Boolean -Value $property.Value -Context "acceptance.parameters.$Name"
}

function Get-OptionalJsonPath {
    param(
        [string]$OverridePath,
        $EvidencePaths,
        [string]$PropertyName
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }

    $property = $EvidencePaths.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return ""
    }

    return [string]$property.Value
}

function Get-OptionalJsonStringArray {
    param(
        $Object,
        [string]$PropertyName
    )

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        return @()
    }

    if ($property.Value -is [System.Array]) {
        return @($property.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @([string]$property.Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-PublicArtifactRedactionVerifier {
    param(
        [string[]]$Paths,
        [string[]]$Tokens
    )

    Assert-True -Condition ($Paths.Count -gt 0) -Message "PublicArtifactPath or acceptance.evidencePaths.publicArtifactPaths is required when public artifact redaction is required."
    $scannerPath = Join-Path $RepoRoot "Scripts/verify-windows-public-artifact-redaction.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $scannerPath -PathType Leaf) -Message "Missing Windows public artifact redaction verifier: $scannerPath"
    $scannerArguments = @{
        RepoRoot = $RepoRoot
        ArtifactPath = $Paths
    }
    if ($Tokens.Count -gt 0) {
        $scannerArguments.SensitiveToken = $Tokens
    }

    & $scannerPath @scannerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows public artifact redaction verifier failed: $scannerPath exitCode=$LASTEXITCODE"
    }
}

function Test-GatePresent {
    param([string]$Name)

    return (@($script:AcceptanceGateResults | Where-Object { [string]$_.name -eq $Name }).Count -eq 1)
}

function Assert-CurrentPathProductControlEvidence {
    param(
        $Evidence,
        [bool]$RequireAppControl,
        [bool]$RequireFileTransfer = $false,
        [string]$ExpectedTransportProfile = "current-path-product-control-transport",
        [string]$ExpectedTransportScope = "AdmissionLookupBoundSdpIceProductControlTransportOpen",
        [string]$ExpectedAppControlProfile = "current-path-product-control-appcontrol",
        [string]$ExpectedAppControlScope = "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong",
        [string]$ExpectedFileTransferProfile = "current-path-product-control-file-transfer",
        [string]$ExpectedFileTransferScope = "AdmissionLookupBoundSdpIceProductControlHandshakeFileTransferReceipt",
        [string]$ExpectedRole = "offer",
        [string]$ExpectedSignalingExchangeRole = ""
    )

    $profile = [string](Assert-JsonProperty -Object $Evidence -Name "Profile" -Context "currentPathProductControl")
    $scope = [string](Assert-JsonProperty -Object $Evidence -Name "EvidenceScope" -Context "currentPathProductControl")
    $status = [string](Assert-JsonProperty -Object $Evidence -Name "Status" -Context "currentPathProductControl")
    $steps = Assert-JsonProperty -Object $Evidence -Name "Steps" -Context "currentPathProductControl"

    if ($RequireFileTransfer) {
        Assert-True -Condition ($profile -eq $ExpectedFileTransferProfile) -Message "Current-path FileTransfer evidence has unexpected profile: $profile"
        Assert-True -Condition ($scope -eq $ExpectedFileTransferScope) -Message "Current-path FileTransfer evidence has unexpected scope: $scope"
        Assert-True -Condition ($status -eq "fileTransferReceipt") -Message "Current-path FileTransfer evidence has unexpected status: $status"
    }
    elseif ($RequireAppControl) {
        Assert-True -Condition ($profile -eq $ExpectedAppControlProfile) -Message "Current-path AppControl evidence has unexpected profile: $profile"
        Assert-True -Condition ($scope -eq $ExpectedAppControlScope) -Message "Current-path AppControl evidence has unexpected scope: $scope"
        Assert-True -Condition ($status -eq "appControlPong") -Message "Current-path AppControl evidence has unexpected status: $status"
    }
    else {
        Assert-True -Condition ($profile -eq $ExpectedTransportProfile) -Message "Current-path transport evidence has unexpected profile: $profile"
        Assert-True -Condition ($scope -eq $ExpectedTransportScope) -Message "Current-path product-control transport evidence has unexpected scope: $scope"
        Assert-True -Condition ($status -eq "transportOpen") -Message "Current-path product-control transport evidence has unexpected status: $status"
    }

    $connectionCodeStep = if ($ExpectedRole -eq "answer") { "RegisterCode" } else { "LookupCode" }
    foreach ($requiredStep in @("AdmissionChallenge", "AdmissionLease", $connectionCodeStep, "SignalingBound", "ProductControlTransport")) {
        $stepValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $steps -Name $requiredStep -Context "currentPathProductControl.Steps") -Context "currentPathProductControl.Steps.$requiredStep"
        Assert-True -Condition ($stepValue -eq $true) -Message "Current-path product-control evidence must have Steps.$requiredStep=true."
    }

    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "Bound" -Context "currentPathProductControl") -Context "currentPathProductControl.Bound") -eq $true) -Message "Current-path product-control evidence must be bound."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "BoundSessionMatches" -Context "currentPathProductControl") -Context "currentPathProductControl.BoundSessionMatches") -eq $true) -Message "Current-path product-control evidence must prove the bound session matches."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "QueryTokenPresent" -Context "currentPathProductControl") -Context "currentPathProductControl.QueryTokenPresent") -eq $false) -Message "Current-path product-control evidence must use header credentials, not query tokens."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "HeaderValuesCaptured" -Context "currentPathProductControl") -Context "currentPathProductControl.HeaderValuesCaptured") -eq $false) -Message "Current-path product-control evidence must not capture header values."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "SecretInputsCaptured" -Context "currentPathProductControl") -Context "currentPathProductControl.SecretInputsCaptured") -eq $false) -Message "Current-path product-control evidence must not capture secret inputs."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "ConnectionCodeCaptured" -Context "currentPathProductControl") -Context "currentPathProductControl.ConnectionCodeCaptured") -eq $false) -Message "Current-path product-control evidence must not capture the connection code."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "RuntimeProfile" -Context "currentPathProductControl") -eq "mac-product-control-v1") -Message "Current-path product-control evidence must use mac-product-control-v1 runtime profile."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "DataChannelLabel" -Context "currentPathProductControl") -eq "skybridge") -Message "Current-path product-control evidence must use the skybridge DataChannel."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "Role" -Context "currentPathProductControl") -eq $ExpectedRole) -Message "Windows current-path product-control live profile has unexpected role."
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSignalingExchangeRole)) {
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SignalingExchangeRole" -Context "currentPathProductControl") -eq $ExpectedSignalingExchangeRole) -Message "Current-path product-control evidence has unexpected signaling exchange role."
    }
    $expectedRemoteSignalWaitType = if ($ExpectedRole -eq "answer") { "offer" } else { "answer" }
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "RemoteSignalWaitType" -Context "currentPathProductControl") -eq $expectedRemoteSignalWaitType) -Message "Current-path product-control evidence has unexpected remote signal wait type."
    Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "RemoteSignalTimeoutSeconds" -Context "currentPathProductControl") -gt 0) -Message "Current-path product-control evidence must record a positive remote signal timeout."
    Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "LateRemoteIceCandidateRelayCount" -Context "currentPathProductControl") -ge 0) -Message "Current-path product-control evidence must record a non-negative late remote ICE relay count."
    if ($ExpectedRole -eq "answer") {
        $expectedBoundRole = [string](Assert-JsonProperty -Object $Evidence -Name "ExpectedBoundRole" -Context "currentPathProductControl")
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($expectedBoundRole)) -Message "Current-path answerer evidence must record ExpectedBoundRole."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "BoundRole" -Context "currentPathProductControl") -eq $expectedBoundRole) -Message "Current-path answerer evidence has unexpected bound role."
        $expectedRemoteIdentitySource = if ($RequireAppControl -or $RequireFileTransfer) { "operatorExpectedPeerHandshakeVerifiedNotServerAttested" } else { "operatorExpectedPeerNotServerAttested" }
        $expectedNotRemoteIdentityProof = -not ($RequireAppControl -or $RequireFileTransfer)
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "RemoteIdentitySource" -Context "currentPathProductControl") -eq $expectedRemoteIdentitySource) -Message "Current-path answerer evidence has unexpected remote identity source."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "RemoteIdentityServerAttested" -Context "currentPathProductControl") -Context "currentPathProductControl.RemoteIdentityServerAttested") -eq $false) -Message "Current-path answerer evidence must not claim server-attested remote identity."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "NotRemoteIdentityProof" -Context "currentPathProductControl") -Context "currentPathProductControl.NotRemoteIdentityProof") -eq $expectedNotRemoteIdentityProof) -Message "Current-path answerer evidence has unexpected remote identity proof marker."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "HelperMode" -Context "currentPathProductControl") -eq "product-control-answer") -Message "Current-path answerer evidence must use product-control-answer helper mode."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "LocalSignalType" -Context "currentPathProductControl") -eq "answer") -Message "Current-path answerer evidence must write a local answer."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "RemoteSignalType" -Context "currentPathProductControl") -eq "offer") -Message "Current-path answerer evidence must consume a remote offer."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "TransportOnlyDirection" -Context "currentPathProductControl") -eq "answerer") -Message "Current-path answerer evidence must remain scoped to answerer transport."
    }
    else {
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "RemoteIdentitySource" -Context "currentPathProductControl") -eq "connectionCodeLookup") -Message "Current-path offerer evidence must use lookup-attested remote identity."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "RemoteIdentityServerAttested" -Context "currentPathProductControl") -Context "currentPathProductControl.RemoteIdentityServerAttested") -eq $true) -Message "Current-path offerer evidence must record lookup-attested remote identity."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "NotRemoteIdentityProof" -Context "currentPathProductControl") -Context "currentPathProductControl.NotRemoteIdentityProof") -eq $false) -Message "Current-path offerer evidence must not set NotRemoteIdentityProof."
    }
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "TransportBindingDigestHex" -Context "currentPathProductControl") -match '^[0-9a-f]{64}$') -Message "Current-path product-control evidence missing transport binding digest."

    if ($RequireAppControl) {
        foreach ($requiredStep in @("ProductHandshake", "AppControlPingPong")) {
            $stepValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $steps -Name $requiredStep -Context "currentPathProductControl.Steps") -Context "currentPathProductControl.Steps.$requiredStep"
            Assert-True -Condition ($stepValue -eq $true) -Message "Current-path AppControl evidence must have Steps.$requiredStep=true."
        }

        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SecureSessionState" -Context "currentPathProductControl") -eq "Established") -Message "Current-path AppControl evidence must establish the secure session."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "NegotiatedSuiteWireId" -Context "currentPathProductControl") -eq "0x0101") -Message "Current-path AppControl evidence must negotiate ML-KEM-768/ML-DSA-65."
        $requiredTrueFields = if ($ExpectedRole -eq "answer") {
            @("PolicyRequirePqc", "InitiatorIdentityFingerprintVerified", "InitiatorSignatureVerified", "ResponderFinishedSent", "InitiatorFinishedVerified", "AppControlPongIdMatches", "AuthenticatedAppControlPingPongProof", "NotMacProductAppProof", "LocalMlKem768DecapsulationKeyInputPresent", "LocalMlKem768EncapsulationKeyInputPresent", "LocalMlKem768KeyPairVerified")
        }
        else {
            @("PolicyRequirePqc", "ResponderIdentityFingerprintVerified", "ResponderSignatureVerified", "ResponderFinishedVerified", "InitiatorFinishedSent", "AppControlPongIdMatches", "AuthenticatedAppControlPingPongProof", "NotMacProductAppProof", "PeerMlKem768PublicKeyInputPresent")
        }
        foreach ($requiredTrue in $requiredTrueFields) {
            $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredTrue -Context "currentPathProductControl") -Context "currentPathProductControl.$requiredTrue"
            Assert-True -Condition ($value -eq $true) -Message "Current-path AppControl evidence must have $requiredTrue=true."
        }
        $requiredFalseFields = if ($ExpectedRole -eq "answer") {
            @("PolicyAllowClassicFallback", "NotHandshakeProof", "NotAppControlProof", "LocalMlKem768DecapsulationKeyCaptured", "LocalMlKem768EncapsulationKeyCaptured", "RemoteProductAppObserved", "PeerTrustPersistenceProof")
        }
        else {
            @("PolicyAllowClassicFallback", "NotHandshakeProof", "NotAppControlProof", "PeerMlKem768PublicKeyCaptured", "RemoteProductAppObserved", "PeerTrustPersistenceProof")
        }
        foreach ($requiredFalse in $requiredFalseFields) {
            $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredFalse -Context "currentPathProductControl") -Context "currentPathProductControl.$requiredFalse"
            Assert-True -Condition ($value -eq $false) -Message "Current-path AppControl evidence must have $requiredFalse=false."
        }
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlPacketType" -Context "currentPathProductControl") -eq "AppControl") -Message "Current-path AppControl evidence must prove AppControl packet type."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlPayloadFormat" -Context "currentPathProductControl") -eq "SkybridgeSecureEnvelopeV1") -Message "Current-path AppControl evidence must use the SBWC secure envelope wire format."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlCryptoFormat" -Context "currentPathProductControl") -eq "SkybridgeSecureEnvelopeV1") -Message "Current-path AppControl evidence must record the SBWC secure envelope crypto format."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "AppControlSbwcEnvelope" -Context "currentPathProductControl") -Context "currentPathProductControl.AppControlSbwcEnvelope") -eq $true) -Message "Current-path AppControl evidence must prove SBWC envelope usage."
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "AppControlSbwcCounterPresent" -Context "currentPathProductControl") -Context "currentPathProductControl.AppControlSbwcCounterPresent") -eq $true) -Message "Current-path AppControl evidence must prove SBWC counters."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlReplayProtection" -Context "currentPathProductControl") -eq "sbwc-replay-window") -Message "SBWC AppControl replay boundary must be explicit."
        Assert-True -Condition ($null -eq (Assert-JsonProperty -Object $Evidence -Name "AppControlLegacyNonceLength" -Context "currentPathProductControl")) -Message "SBWC AppControl evidence must not record legacy nonce length."
        Assert-True -Condition ($null -eq (Assert-JsonProperty -Object $Evidence -Name "AppControlLegacyTagLength" -Context "currentPathProductControl")) -Message "SBWC AppControl evidence must not record legacy tag length."
        Assert-True -Condition ($null -eq (Assert-JsonProperty -Object $Evidence -Name "AppControlLegacyAadLength" -Context "currentPathProductControl")) -Message "SBWC AppControl evidence must not record legacy AAD length."
        Assert-True -Condition ($null -eq (Assert-JsonProperty -Object $Evidence -Name "AppControlLegacyCombinedLayout" -Context "currentPathProductControl")) -Message "SBWC AppControl evidence must not record legacy combined layout."
        foreach ($sbwcField in @("AppControlOutboundCounter", "AppControlInboundCounter", "AppControlSessionHash", "AppControlTranscriptPrefix")) {
            Assert-True -Condition ($null -ne (Assert-JsonProperty -Object $Evidence -Name $sbwcField -Context "currentPathProductControl")) -Message "Current-path AppControl evidence must record $sbwcField."
        }
        if ($ExpectedRole -eq "answer") {
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "HandshakeRole" -Context "currentPathProductControl") -eq "responder") -Message "Current-path answerer AppControl evidence must use responder handshake role."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlReceivedMessageKind" -Context "currentPathProductControl") -eq "ping") -Message "Current-path answerer AppControl evidence must receive a ping."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlResponseMessageKind" -Context "currentPathProductControl") -eq "pong") -Message "Current-path answerer AppControl evidence must send a pong."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "LocalMlKem768EncapsulationKeySource" -Context "currentPathProductControl") -eq "operatorProvidedOutOfBand") -Message "Current-path answerer AppControl evidence must keep local KEM public key source explicit."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "LocalMlKem768EncapsulationKeyServerPublished" -Context "currentPathProductControl") -Context "currentPathProductControl.LocalMlKem768EncapsulationKeyServerPublished") -eq $false) -Message "Current-path answerer AppControl evidence must not claim server-published KEM key material."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "LocalMlKem768EncapsulationKeySha256" -Context "currentPathProductControl") -match '^[0-9a-f]{64}$') -Message "Current-path answerer AppControl evidence must record a local ML-KEM public key hash."
        }
        else {
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "HandshakeRole" -Context "currentPathProductControl") -eq "initiator") -Message "Current-path AppControl evidence must use initiator handshake role."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "AppControlReceivedMessageKind" -Context "currentPathProductControl") -eq "pong") -Message "Current-path AppControl evidence must receive a pong."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "PeerMlKem768PublicKeySource" -Context "currentPathProductControl") -eq "operatorProvidedOutOfBand") -Message "Current-path AppControl evidence must keep peer KEM public key source explicit."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "PeerMlKem768PublicKeyServerAttested" -Context "currentPathProductControl") -Context "currentPathProductControl.PeerMlKem768PublicKeyServerAttested") -eq $false) -Message "Current-path AppControl evidence must not claim server-attested peer KEM key material."
        }
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductSendCount" -Context "currentPathProductControl") -eq 1) -Message "Current-path AppControl evidence must send exactly one AppControl payload."
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductReceiveCount" -Context "currentPathProductControl") -eq 1) -Message "Current-path AppControl evidence must receive exactly one AppControl payload."
    }
    elseif ($RequireFileTransfer) {
        foreach ($requiredStep in @("ProductHandshake", "FileTransferReceipt")) {
            $stepValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $steps -Name $requiredStep -Context "currentPathProductControl.Steps") -Context "currentPathProductControl.Steps.$requiredStep"
            Assert-True -Condition ($stepValue -eq $true) -Message "Current-path FileTransfer evidence must have Steps.$requiredStep=true."
        }

        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SecureSessionState" -Context "currentPathProductControl") -eq "Established") -Message "Current-path FileTransfer evidence must establish the secure session."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "NegotiatedSuiteWireId" -Context "currentPathProductControl") -eq "0x0101") -Message "Current-path FileTransfer evidence must negotiate ML-KEM-768/ML-DSA-65."
        $requiredTrueFields = if ($ExpectedRole -eq "answer") {
            @("PolicyRequirePqc", "InitiatorIdentityFingerprintVerified", "InitiatorSignatureVerified", "ResponderFinishedSent", "InitiatorFinishedVerified", "AuthenticatedFileTransferReceiptProof", "FileTransferSbwcEnvelope", "FileChannelObserved", "ReceiptMatchesSentHash", "NotMacProductAppProof", "LocalMlKem768DecapsulationKeyInputPresent", "LocalMlKem768EncapsulationKeyInputPresent", "LocalMlKem768KeyPairVerified")
        }
        else {
            @("PolicyRequirePqc", "ResponderIdentityFingerprintVerified", "ResponderSignatureVerified", "ResponderFinishedVerified", "InitiatorFinishedSent", "AuthenticatedFileTransferReceiptProof", "FileTransferSbwcEnvelope", "FileChannelObserved", "ReceiptMatchesSentHash", "NotMacProductAppProof", "PeerMlKem768PublicKeyInputPresent")
        }
        foreach ($requiredTrue in $requiredTrueFields) {
            $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredTrue -Context "currentPathProductControl") -Context "currentPathProductControl.$requiredTrue"
            Assert-True -Condition ($value -eq $true) -Message "Current-path FileTransfer evidence must have $requiredTrue=true."
        }
        $requiredFalseFields = if ($ExpectedRole -eq "answer") {
            @("PolicyAllowClassicFallback", "NotHandshakeProof", "LocalMlKem768DecapsulationKeyCaptured", "LocalMlKem768EncapsulationKeyCaptured", "RemoteProductAppObserved", "PeerTrustPersistenceProof", "RawLocalPathCaptured", "RawRemotePathCaptured", "RawSignalingCaptured", "RawSdpCaptured", "RawIceCredentialCaptured", "RawPayloadCaptured")
        }
        else {
            @("PolicyAllowClassicFallback", "NotHandshakeProof", "PeerMlKem768PublicKeyCaptured", "RemoteProductAppObserved", "PeerTrustPersistenceProof", "RawLocalPathCaptured", "RawRemotePathCaptured", "RawSignalingCaptured", "RawSdpCaptured", "RawIceCredentialCaptured", "RawPayloadCaptured")
        }
        foreach ($requiredFalse in $requiredFalseFields) {
            $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredFalse -Context "currentPathProductControl") -Context "currentPathProductControl.$requiredFalse"
            Assert-True -Condition ($value -eq $false) -Message "Current-path FileTransfer evidence must have $requiredFalse=false."
        }
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "NotAppControlProof" -Context "currentPathProductControl") -Context "currentPathProductControl.NotAppControlProof") -eq $true) -Message "Current-path FileTransfer evidence must not claim AppControl proof."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "FileTransferPacketType" -Context "currentPathProductControl") -eq "FileTransfer") -Message "Current-path FileTransfer evidence must prove FileTransfer packet type."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SbwcPacketType" -Context "currentPathProductControl") -eq "FileTransfer") -Message "Current-path FileTransfer evidence must prove SBWC packet type."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "FileTransferReplayProtection" -Context "currentPathProductControl") -eq "sbwc-replay-window") -Message "SBWC FileTransfer replay boundary must be explicit."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "ProductPayloadCountSource" -Context "currentPathProductControl") -eq "runtime-smoke-filetransfer-exchange") -Message "Current-path FileTransfer evidence has unexpected payload count source."
        $expectedTransferRole = if ($ExpectedRole -eq "answer") { "receiver" } else { "sender" }
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "TransferRole" -Context "currentPathProductControl") -eq $expectedTransferRole) -Message "Current-path FileTransfer evidence has unexpected transfer role."
        $manifestBytes = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ManifestBytes" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)
        $transferredBytes = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "TransferredBytes" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)
        $manifestFileCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ManifestFileCount" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)
        $chunkCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ChunkCount" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)
        $chunkAckCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ChunkAckCount" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)
        Assert-True -Condition ($manifestBytes -gt 0) -Message "Current-path FileTransfer evidence must record ManifestBytes > 0."
        Assert-True -Condition ($manifestBytes -eq $transferredBytes) -Message "Current-path FileTransfer ManifestBytes must equal TransferredBytes."
        Assert-True -Condition ($manifestFileCount -eq 1) -Message "Current-path FileTransfer evidence must record ManifestFileCount=1."
        Assert-True -Condition ($chunkCount -gt 0) -Message "Current-path FileTransfer evidence must record ChunkCount > 0."
        Assert-True -Condition ($chunkAckCount -eq $chunkCount) -Message "Current-path FileTransfer ChunkAckCount must equal ChunkCount."
        if ($ExpectedRole -eq "answer") {
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "HandshakeRole" -Context "currentPathProductControl") -eq "responder") -Message "Current-path answerer FileTransfer evidence must use responder handshake role."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "CompleteAckSent" -Context "currentPathProductControl") -Context "currentPathProductControl.CompleteAckSent") -eq $true) -Message "Current-path answerer FileTransfer evidence must send complete ACK."
            Assert-True -Condition ($manifestBytes -eq [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ReceivedBytes" -Context "currentPathProductControl"), [Globalization.CultureInfo]::InvariantCulture)) -Message "Current-path answerer FileTransfer ReceivedBytes must equal ManifestBytes."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "LocalMlKem768EncapsulationKeySource" -Context "currentPathProductControl") -eq "operatorProvidedOutOfBand") -Message "Current-path answerer FileTransfer evidence must keep local KEM public key source explicit."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "LocalMlKem768EncapsulationKeyServerPublished" -Context "currentPathProductControl") -Context "currentPathProductControl.LocalMlKem768EncapsulationKeyServerPublished") -eq $false) -Message "Current-path answerer FileTransfer evidence must not claim server-published KEM key material."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "ReceivedFileSha256" -Context "currentPathProductControl") -match '^[0-9a-f]{64}$') -Message "Current-path answerer FileTransfer evidence must record ReceivedFileSha256."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "ReceiptMatchesReceivedHash" -Context "currentPathProductControl") -Context "currentPathProductControl.ReceiptMatchesReceivedHash") -eq $true) -Message "Current-path answerer FileTransfer receipt must match the received hash."
        }
        else {
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "HandshakeRole" -Context "currentPathProductControl") -eq "initiator") -Message "Current-path FileTransfer evidence must use initiator handshake role."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "CompleteAckReceived" -Context "currentPathProductControl") -Context "currentPathProductControl.CompleteAckReceived") -eq $true) -Message "Current-path FileTransfer evidence must receive complete ACK."
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "PeerMlKem768PublicKeySource" -Context "currentPathProductControl") -eq "operatorProvidedOutOfBand") -Message "Current-path FileTransfer evidence must keep peer KEM public key source explicit."
            Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "PeerMlKem768PublicKeyServerAttested" -Context "currentPathProductControl") -Context "currentPathProductControl.PeerMlKem768PublicKeyServerAttested") -eq $false) -Message "Current-path FileTransfer evidence must not claim server-attested peer KEM key material."
        }
        foreach ($digestField in @("SentFileSha256", "FileSha256Receipt", "FileTransferSessionIdSha256", "FileTransferTransferIdSha256")) {
            Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name $digestField -Context "currentPathProductControl") -match '^[0-9a-f]{64}$') -Message "Current-path FileTransfer evidence must record lowercase SHA-256 hex for $digestField."
        }
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SentFileSha256" -Context "currentPathProductControl") -eq [string](Assert-JsonProperty -Object $Evidence -Name "FileSha256Receipt" -Context "currentPathProductControl")) -Message "Current-path FileTransfer receipt hash must equal sent file hash."
        foreach ($sbwcField in @("FileTransferSessionHash", "FileTransferTranscriptPrefix")) {
            Assert-True -Condition ($null -ne (Assert-JsonProperty -Object $Evidence -Name $sbwcField -Context "currentPathProductControl")) -Message "Current-path FileTransfer evidence must record $sbwcField."
        }
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductSendCount" -Context "currentPathProductControl") -eq 3) -Message "Current-path FileTransfer evidence must send exactly three product payloads."
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductReceiveCount" -Context "currentPathProductControl") -eq 3) -Message "Current-path FileTransfer evidence must receive exactly three product payloads."
    }
    elseif ($profile -ne "current-path-product-control-appcontrol") {
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "SecureSessionState" -Context "currentPathProductControl") -eq "TransportOnly") -Message "Current-path transport evidence must not claim an established secure session."
        foreach ($requiredTrue in @("NotHandshakeProof", "NotAppControlProof", "NotMacProductAppProof")) {
            $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredTrue -Context "currentPathProductControl") -Context "currentPathProductControl.$requiredTrue"
            Assert-True -Condition ($value -eq $true) -Message "Current-path transport evidence must have $requiredTrue=true."
        }
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductSendCount" -Context "currentPathProductControl") -eq 0) -Message "Current-path transport evidence must not send AppControl payloads."
        Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ProductReceiveCount" -Context "currentPathProductControl") -eq 0) -Message "Current-path transport evidence must not receive AppControl payloads."
    }
}

function Assert-CurrentPathProductControlSessionImportEvidence {
    param(
        $Evidence,
        [string]$Context,
        [bool]$ExpectedTargetRuntimeIdProvided,
        [int]$ExpectedTtlSeconds
    )

    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "capability_id" -Context $Context) -eq "session.import_product_control") -Message "$Context capability_id must be session.import_product_control."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "accepted" -Context $Context) -Context "$Context.accepted") -eq $true) -Message "$Context must be accepted."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "status" -Context $Context) -eq "session_imported") -Message "$Context must have status=session_imported."
    foreach ($requiredTrue in @("session_registry_supported", "session_imported", "mutation_supported", "session_id_file_used")) {
        $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $requiredTrue -Context $Context) -Context "$Context.$requiredTrue"
        Assert-True -Condition ($value -eq $true) -Message "$Context must have $requiredTrue=true."
    }
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "live_runtime_started" -Context $Context) -Context "$Context.live_runtime_started") -eq $false) -Message "$Context must not claim a live runtime start."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "target_runtime_id_provided" -Context $Context) -Context "$Context.target_runtime_id_provided") -eq $ExpectedTargetRuntimeIdProvided) -Message "$Context target_runtime_id_provided mismatch."
    Assert-True -Condition ([int](Assert-JsonProperty -Object $Evidence -Name "ttl_seconds" -Context $Context) -eq $ExpectedTtlSeconds) -Message "$Context ttl_seconds mismatch."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "source" -Context $Context) -eq "windows_operator_state_session_registry") -Message "$Context source must be windows_operator_state_session_registry."

    $session = Assert-JsonProperty -Object $Evidence -Name "session" -Context $Context
    Assert-True -Condition ([string](Assert-JsonProperty -Object $session -Name "state" -Context "$Context.session") -eq "established") -Message "$Context session state must be established."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $session -Name "secure_session_state" -Context "$Context.session") -eq "Established") -Message "$Context secure session state must be Established."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $session -Name "readiness_kind" -Context "$Context.session") -eq "product_control_secure_session") -Message "$Context readiness kind must be product_control_secure_session."
    foreach ($sessionTrue in @("remote_identity_bound", "product_control_secure_session_ready", "session_id_present", "target_runtime_id_present", "remote_device_id_present")) {
        $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $session -Name $sessionTrue -Context "$Context.session") -Context "$Context.session.$sessionTrue"
        Assert-True -Condition ($value -eq $true) -Message "$Context session must have $sessionTrue=true."
    }
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $session -Name "expired" -Context "$Context.session") -Context "$Context.session.expired") -eq $false) -Message "$Context session must not be expired."

    $proofBoundary = Assert-JsonProperty -Object $Evidence -Name "proof_boundary" -Context $Context
    foreach ($proofField in @("appcontrol_evidence_required", "session_import_not_live_runtime_start", "request_registered_not_live_transfer", "request_registered_not_live_remote_apply", "raw_session_ids_redacted")) {
        $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $proofBoundary -Name $proofField -Context "$Context.proof_boundary") -Context "$Context.proof_boundary.$proofField"
        Assert-True -Condition ($value -eq $true) -Message "$Context proof boundary must have $proofField=true."
    }

    if ($null -ne $Evidence.PSObject.Properties["required_gates_before_live_transfer"]) {
        $fileTransferGates = @((Assert-JsonProperty -Object $Evidence -Name "required_gates_before_live_transfer" -Context $Context))
        foreach ($gate in @("transferred_bytes", "file_sha256_receipt")) {
            Assert-True -Condition ($fileTransferGates -contains $gate) -Message "$Context must keep live file-transfer gate boundary visible: $gate"
        }
    }
    if ($null -ne $Evidence.PSObject.Properties["required_gates_before_live_remote_apply"]) {
        $remoteApplyGates = @((Assert-JsonProperty -Object $Evidence -Name "required_gates_before_live_remote_apply" -Context $Context))
        Assert-True -Condition ($remoteApplyGates -contains "capture_input_video_data_path") -Message "$Context must keep live remote-desktop gate boundary visible."
    }
}

function Assert-LiveFileTransferEvidence {
    param(
        $Evidence,
        [string]$Context
    )

    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "Profile" -Context $Context) -eq "windows-live-file-transfer") -Message "$Context Profile must be windows-live-file-transfer."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "Status" -Context $Context) -eq "completed") -Message "$Context Status must be completed."
    $transferredBytes = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "TransferredBytes" -Context $Context), [Globalization.CultureInfo]::InvariantCulture)
    $manifestBytes = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ManifestBytes" -Context $Context), [Globalization.CultureInfo]::InvariantCulture)
    $manifestFileCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ManifestFileCount" -Context $Context), [Globalization.CultureInfo]::InvariantCulture)
    $chunkCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ChunkCount" -Context $Context), [Globalization.CultureInfo]::InvariantCulture)
    $chunkAckCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name "ChunkAckCount" -Context $Context), [Globalization.CultureInfo]::InvariantCulture)
    Assert-True -Condition ($transferredBytes -gt 0) -Message "$Context must record TransferredBytes > 0."
    Assert-True -Condition ($manifestBytes -eq $transferredBytes) -Message "$Context ManifestBytes must equal TransferredBytes."
    Assert-True -Condition ($manifestFileCount -gt 0) -Message "$Context must record ManifestFileCount > 0."
    Assert-True -Condition ($chunkCount -gt 0) -Message "$Context must record ChunkCount > 0."
    Assert-True -Condition ($chunkAckCount -eq $chunkCount) -Message "$Context ChunkAckCount must equal ChunkCount."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "CompleteAckReceived" -Context $Context) -Context "$Context.CompleteAckReceived") -eq $true) -Message "$Context must record CompleteAckReceived=true."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "FileChannelObserved" -Context $Context) -Context "$Context.FileChannelObserved") -eq $true) -Message "$Context must record FileChannelObserved=true."
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name "ReceiptMatchesSentHash" -Context $Context) -Context "$Context.ReceiptMatchesSentHash") -eq $true) -Message "$Context must record ReceiptMatchesSentHash=true."
    foreach ($digestField in @("SentFileSha256", "FileSha256Receipt", "SessionIdSha256", "PeerDeviceIdSha256", "PeerFingerprintSha256", "TransportBindingDigestHex")) {
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name $digestField -Context $Context) -match '^[0-9a-f]{64}$') -Message "$Context $digestField must be lowercase SHA-256 hex."
    }
    $sentFileSha256 = [string](Assert-JsonProperty -Object $Evidence -Name "SentFileSha256" -Context $Context)
    $fileSha256Receipt = [string](Assert-JsonProperty -Object $Evidence -Name "FileSha256Receipt" -Context $Context)
    Assert-True -Condition ([string]::Equals($sentFileSha256, $fileSha256Receipt, [StringComparison]::Ordinal)) -Message "$Context FileSha256Receipt must equal SentFileSha256."
    if ($null -ne $Evidence.PSObject.Properties["ReceivedFileSha256"]) {
        $receivedFileSha256 = [string](Assert-JsonProperty -Object $Evidence -Name "ReceivedFileSha256" -Context $Context)
        Assert-True -Condition ($receivedFileSha256 -match '^[0-9a-f]{64}$') -Message "$Context ReceivedFileSha256 must be lowercase SHA-256 hex."
        Assert-True -Condition ([string]::Equals($receivedFileSha256, $sentFileSha256, [StringComparison]::Ordinal)) -Message "$Context ReceivedFileSha256 must equal SentFileSha256."
    }
    foreach ($falseField in @(
        "SecretInputsCaptured",
        "ConnectionCodeCaptured",
        "HeaderValuesCaptured",
        "RawLocalPathCaptured",
        "RawRemotePathCaptured",
        "RawSignalingCaptured",
        "RawSdpCaptured",
        "RawIceCredentialCaptured",
        "RawPayloadCaptured"
    )) {
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $falseField -Context $Context) -Context "$Context.$falseField") -eq $false) -Message "$Context must have $falseField=false."
    }
}

function Assert-LiveRemoteDesktopEvidence {
    param(
        $Evidence,
        [string]$Context
    )

    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "Profile" -Context $Context) -eq "windows-live-remote-desktop") -Message "$Context Profile must be windows-live-remote-desktop."
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "Status" -Context $Context) -eq "completed") -Message "$Context Status must be completed."
    foreach ($trueField in @(
        "NoticeLifecycleObserved",
        "EncryptedSessionEstablished",
        "CaptureInputVideoDataPathObserved",
        "MouseInputObserved",
        "KeyboardInputObserved",
        "TextInputObserved",
        "ClipboardObserved",
        "DisconnectObserved"
    )) {
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $trueField -Context $Context) -Context "$Context.$trueField") -eq $true) -Message "$Context must have $trueField=true."
    }
    foreach ($positiveField in @("ScreenFrameWidth", "ScreenFrameHeight", "ScreenFrameBytes", "FrameCount")) {
        Assert-True -Condition ([System.Convert]::ToInt64((Assert-JsonProperty -Object $Evidence -Name $positiveField -Context $Context), [Globalization.CultureInfo]::InvariantCulture) -gt 0) -Message "$Context must record $positiveField > 0."
    }
    Assert-True -Condition ((ConvertTo-DoubleInvariant -Value (Assert-JsonProperty -Object $Evidence -Name "ObservedFps" -Context $Context) -Context "$Context.ObservedFps") -gt 0.0) -Message "$Context must record ObservedFps > 0."
    foreach ($digestField in @("SessionIdSha256", "PeerDeviceIdSha256", "PeerFingerprintSha256")) {
        Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name $digestField -Context $Context) -match '^[0-9a-f]{64}$') -Message "$Context $digestField must be lowercase SHA-256 hex."
    }
    Assert-True -Condition ([string](Assert-JsonProperty -Object $Evidence -Name "PermissionState" -Context $Context) -eq "granted") -Message "$Context PermissionState must be granted."
    foreach ($falseField in @("SecretInputsCaptured", "RawCapturePathCaptured", "RawClipboardTextCaptured")) {
        Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Evidence -Name $falseField -Context $Context) -Context "$Context.$falseField") -eq $false) -Message "$Context must have $falseField=false."
    }
}

$resolvedRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
$resolvedAcceptanceEvidencePath = Resolve-EvidencePath -Path $AcceptanceEvidencePath
Assert-True -Condition (Test-Path -LiteralPath $resolvedAcceptanceEvidencePath) -Message "Missing Windows portability acceptance evidence: $resolvedAcceptanceEvidencePath"

$acceptance = Get-Content -Raw -LiteralPath $resolvedAcceptanceEvidencePath | ConvertFrom-Json
Assert-DateString -Value ([string](Assert-JsonProperty -Object $acceptance -Name "generatedAtUtc" -Context "acceptance")) -Context "acceptance.generatedAtUtc"
$runId = [string](Assert-JsonProperty -Object $acceptance -Name "runId" -Context "acceptance")
Assert-True -Condition ($runId -match '^[0-9a-f]{32}$') -Message "Acceptance runId must be a 32-character lowercase hex GUID: $runId"

$acceptanceRepoRoot = [string](Assert-JsonProperty -Object $acceptance -Name "repoRoot" -Context "acceptance")
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($acceptanceRepoRoot)) -Message "Acceptance repoRoot is empty."
$resolvedAcceptanceRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($acceptanceRepoRoot)
Assert-True -Condition ([string]::Equals($resolvedAcceptanceRepoRoot, $resolvedRepoRoot, [StringComparison]::OrdinalIgnoreCase)) -Message "Acceptance repoRoot mismatch: expected=$resolvedRepoRoot actual=$resolvedAcceptanceRepoRoot"

$branch = [string](Assert-JsonProperty -Object $acceptance -Name "branch" -Context "acceptance")
$head = [string](Assert-JsonProperty -Object $acceptance -Name "head" -Context "acceptance")
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($branch)) -Message "Acceptance branch is empty."
Assert-True -Condition ($head -match '^[0-9a-f]{40}$') -Message "Acceptance head must be a 40-character git SHA: $head"
if (-not [string]::IsNullOrWhiteSpace($ExpectedBranch)) {
    Assert-True -Condition ($branch -eq $ExpectedBranch) -Message "Acceptance branch mismatch: expected=$ExpectedBranch actual=$branch"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedHead)) {
    Assert-True -Condition ($head -eq $ExpectedHead) -Message "Acceptance head mismatch: expected=$ExpectedHead actual=$head"
}

$parameters = Assert-JsonProperty -Object $acceptance -Name "parameters" -Context "acceptance"
$evidencePaths = Assert-JsonProperty -Object $acceptance -Name "evidencePaths" -Context "acceptance"
$script:AcceptanceGateResults = @((Assert-JsonProperty -Object $acceptance -Name "gateResults" -Context "acceptance"))
Assert-True -Condition ($script:AcceptanceGateResults.Count -gt 0) -Message "Acceptance gateResults must not be empty."
$artifactDigests = @((Assert-JsonProperty -Object $acceptance -Name "artifactDigests" -Context "acceptance"))
$expectedArtifactPaths = Get-ExpectedArtifactPathMap -EvidencePaths $evidencePaths -GateResults $script:AcceptanceGateResults
Assert-ArtifactDigests -Artifacts $artifactDigests -ExpectedArtifactPaths $expectedArtifactPaths
$script:AcceptanceArtifactDigests = $artifactDigests

$seenGates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($gate in $script:AcceptanceGateResults) {
    $name = [string](Assert-JsonProperty -Object $gate -Name "name" -Context "acceptance.gateResults[]")
    $status = [string](Assert-JsonProperty -Object $gate -Name "status" -Context "acceptance.gateResults[$name]")
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($name)) -Message "Acceptance gate name is empty."
    Assert-True -Condition ($seenGates.Add($name)) -Message "Duplicate acceptance gate result: $name"
    Assert-True -Condition ($status -eq "passed" -or $status -eq "skipped") -Message "Acceptance gate must not be failed: $name status=$status"
}

foreach ($gateName in @(
    "git-ssh-remote",
    "windows-ci-workflow",
    "windows-stack-freshness",
    "windows-research-evidence",
    "windows-portability-acceptance-map",
    "windows-powershell-ast",
    "windows-ffi-client",
    "windows-ui-parity",
    "windows-ui-action-order",
    "windows-ui-parity-matrix",
    "windows-startup-state",
    "windows-command-gates",
    "windows-file-transfer-qr",
    "windows-native-runtime-profile",
    "windows-connection-launch",
    "windows-webrtc-proof-smoke",
    "apple-native-preservation",
    "mac-rust-cli-codbg-wrapper"
)) {
    Assert-PassedGate -Name $gateName | Out-Null
}

$includeWinUiAutomationSmoke = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeWinUiAutomationSmoke" -Context "acceptance.parameters") -Context "acceptance.parameters.includeWinUiAutomationSmoke"
$winUiEvidencePath = Get-OverrideOrJsonPath -OverridePath $WinUiEvidenceDir -EvidencePaths $evidencePaths -PropertyName "winUiEvidenceDir"
if ($includeWinUiAutomationSmoke) {
    Assert-PassedGate -Name "windows-ui-automation-smoke" | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($winUiEvidencePath)) {
        Assert-PassedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    else {
        Assert-SkippedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
}
else {
    Assert-PassedOrSkippedGate -Name "windows-ui-automation-smoke" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-ui-visual-evidence" | Out-Null
}

if ($RequireWinUiVisualEvidence) {
    if ($includeWinUiAutomationSmoke) {
        Assert-PassedGate -Name "windows-ui-automation-smoke" | Out-Null
        Assert-PassedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    else {
        Assert-True `
            -Condition ([bool]$AllowStandaloneWinUiVisualEvidence) `
            -Message "WinUI visual evidence was required, but acceptance evidence did not run windows-ui-automation-smoke. Pass -AllowStandaloneWinUiVisualEvidence with -WinUiEvidenceDir only when an interactive desktop task generated the evidence for this same branch/head."
        Assert-SkippedGate -Name "windows-ui-automation-smoke" | Out-Null
        Assert-SkippedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    $resolvedWinUiEvidenceDir = Resolve-EvidencePath -Path $winUiEvidencePath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedWinUiEvidenceDir)) -Message "WinUI visual evidence directory is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedWinUiEvidenceDir) -Message "WinUI visual evidence directory is missing: $resolvedWinUiEvidenceDir"
    $visualEvidenceVerifier = Join-Path $resolvedRepoRoot "Scripts/verify-windows-ui-visual-evidence.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $visualEvidenceVerifier) -Message "Missing WinUI visual evidence verifier: $visualEvidenceVerifier"
    & $visualEvidenceVerifier -RepoRoot $resolvedRepoRoot -EvidenceDir $resolvedWinUiEvidenceDir -ExpectedBranch $branch -ExpectedHead $head | Write-Output
}

$includeNativeDnsSdAcceptance = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeNativeDnsSdAcceptance" -Context "acceptance.parameters") -Context "acceptance.parameters.includeNativeDnsSdAcceptance"
$requireNativeDnsSdPeer = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireNativeDnsSdPeer" -Context "acceptance.parameters") -Context "acceptance.parameters.requireNativeDnsSdPeer"
if ($RequireNativeDnsSdAcceptance) {
    Assert-True -Condition ($includeNativeDnsSdAcceptance -or $requireNativeDnsSdPeer) -Message "Acceptance must include native DNS-SD acceptance when -RequireNativeDnsSdAcceptance is passed."
    Assert-PassedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}
elseif ($includeNativeDnsSdAcceptance -or $requireNativeDnsSdPeer) {
    Assert-PassedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}

$checkOnlineStackFreshness = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "checkOnlineStackFreshness" -Context "acceptance.parameters") -Context "acceptance.parameters.checkOnlineStackFreshness"
$stackFreshnessPath = Get-OverrideOrJsonPath -OverridePath $StackFreshnessEvidencePath -EvidencePaths $evidencePaths -PropertyName "stackFreshnessEvidencePath"
if ($RequireOnlineStackFreshness) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "checkOnlineStackFreshness" -Expected $true
}
if ($RequireOnlineStackFreshness -or $checkOnlineStackFreshness) {
    $stackEvidence = Read-JsonFile -Path $stackFreshnessPath -Context "Windows stack freshness"
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $stackEvidence -Name "checkOnline" -Context "stackFreshness") -Context "stackFreshness.checkOnline") -eq $true) -Message "Stack freshness evidence must be online evidence."
    $sourceUris = Assert-JsonProperty -Object $stackEvidence -Name "sourceUris" -Context "stackFreshness"
    Assert-True -Condition (@($sourceUris.PSObject.Properties).Count -ge 7) -Message "Stack freshness evidence must include primary source URIs."
    $online = Assert-JsonProperty -Object $stackEvidence -Name "online" -Context "stackFreshness"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "dotnet10" -Context "stackFreshness.online") -Name "latestRuntime" -Context "stackFreshness.online.dotnet10"))) -Message "Stack freshness online evidence missing dotnet latest runtime."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "nugetLatestStable" -Context "stackFreshness.online") -Name "MicrosoftWindowsAppSdk" -Context "stackFreshness.online.nugetLatestStable"))) -Message "Stack freshness online evidence missing Windows App SDK latest version."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "githubLatestStable" -Context "stackFreshness.online") -Name "MsQuic" -Context "stackFreshness.online.githubLatestStable") -Name "tagName" -Context "stackFreshness.online.githubLatestStable.MsQuic"))) -Message "Stack freshness online evidence missing MsQuic latest tag."
}

$includeRustCliCoverage = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeRustCliCoverage" -Context "acceptance.parameters") -Context "acceptance.parameters.includeRustCliCoverage"
$rustCoveragePath = Get-OverrideOrJsonPath -OverridePath $RustCliCoverageEvidencePath -EvidencePaths $evidencePaths -PropertyName "rustCliCoverageEvidencePath"
if ($RequireRustCliCoverage) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "includeRustCliCoverage" -Expected $true
}
if ($RequireRustCliCoverage -or $includeRustCliCoverage) {
    Assert-PassedGate -Name "rust-cli-coverage" | Out-Null
    $coverageEvidence = Read-JsonFile -Path $rustCoveragePath -Context "Rust CLI coverage"
    Assert-True -Condition ([string](Assert-JsonProperty -Object $coverageEvidence -Name "status" -Context "rustCoverage") -eq "passed") -Message "Rust CLI coverage evidence must be passed."
    $totalLineCoverage = ConvertTo-DoubleInvariant -Value (Assert-JsonProperty -Object $coverageEvidence -Name "totalLineCoverage" -Context "rustCoverage") -Context "rustCoverage.totalLineCoverage"
    $cliLineCoverage = ConvertTo-DoubleInvariant -Value (Assert-JsonProperty -Object $coverageEvidence -Name "cliLineCoverage" -Context "rustCoverage") -Context "rustCoverage.cliLineCoverage"
    Assert-True -Condition ($totalLineCoverage -ge $MinimumLineCoverage) -Message "Rust total line coverage $totalLineCoverage% is below $MinimumLineCoverage%."
    Assert-True -Condition ($cliLineCoverage -ge $MinimumLineCoverage) -Message "Rust cli.rs line coverage $cliLineCoverage% is below $MinimumLineCoverage%."
    $commandResults = @((Assert-JsonProperty -Object $coverageEvidence -Name "commandResults" -Context "rustCoverage"))
    Assert-True -Condition ($commandResults.Count -ge 5) -Message "Rust CLI coverage evidence must include command results."
    $commandNames = @($commandResults | ForEach-Object { [string](Assert-JsonProperty -Object $_ -Name "name" -Context "rustCoverage.commandResults[]") })
    foreach ($requiredCommandName in @(
        "cargo fmt --all -- --check",
        "cargo clippy --all-targets --all-features -- -D warnings",
        "cargo build --lib",
        "cargo test"
    )) {
        Assert-True -Condition ($commandNames -contains $requiredCommandName) -Message "Rust CLI coverage evidence missing command result: $requiredCommandName"
    }
    Assert-True -Condition (@($commandNames | Where-Object { $_.StartsWith("cargo llvm-cov --fail-under-lines ", [StringComparison]::Ordinal) -and $_.EndsWith(" --summary-only", [StringComparison]::Ordinal) }).Count -eq 1) -Message "Rust CLI coverage evidence must include one cargo llvm-cov --fail-under-lines <threshold> --summary-only command result."
    foreach ($commandResult in $commandResults) {
        $commandName = [string](Assert-JsonProperty -Object $commandResult -Name "name" -Context "rustCoverage.commandResults[]")
        $exitCode = [int](Assert-JsonProperty -Object $commandResult -Name "exitCode" -Context "rustCoverage.commandResults[$commandName]")
        Assert-True -Condition ($exitCode -eq 0) -Message "Rust CLI coverage command failed in evidence: $commandName exitCode=$exitCode"
    }
}
else {
    Assert-PassedOrSkippedGate -Name "rust-cli-coverage" | Out-Null
}

$includeWindowsReverseSshRelayLifecycle = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeWindowsReverseSshRelayLifecycle" -Context "acceptance.parameters") -Context "acceptance.parameters.includeWindowsReverseSshRelayLifecycle"
$requireWindowsReverseSshRelayLifecycle = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireWindowsReverseSshRelayLifecycle" -Context "acceptance.parameters") -Context "acceptance.parameters.requireWindowsReverseSshRelayLifecycle"
$reverseSshRelayEvidencePath = Get-OverrideOrJsonPath -OverridePath $WindowsReverseSshRelayEvidencePath -EvidencePaths $evidencePaths -PropertyName "windowsReverseSshRelayEvidencePath"
if ($RequireWindowsReverseSshRelayLifecycle) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireWindowsReverseSshRelayLifecycle" -Expected $true
}
if ($RequireWindowsReverseSshRelayLifecycle -or $requireWindowsReverseSshRelayLifecycle) {
    Assert-PassedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
    $reverseSshRelayEvidence = Read-JsonFile -Path $reverseSshRelayEvidencePath -Context "Windows reverse SSH relay lifecycle"
    foreach ($requiredRelayBooleanField in @(
        "accepted",
        "taskActionExpected",
        "taskActionFailClosed",
        "taskPrincipalExpected",
        "relayHostKeyPinned",
        "identityFileAclOk",
        "knownHostsAclOk",
        "installedStartScriptAclOk",
        "startScriptInstalledAndCurrent",
        "runtimeAclOk",
        "localSshEndpointReachable"
    )) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name $requiredRelayBooleanField -Context "reverseSshRelay") -Context "reverseSshRelay.$requiredRelayBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Windows reverse SSH relay evidence must have $requiredRelayBooleanField=true."
    }
    $relayProcessCount = [System.Convert]::ToInt32((Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "sshProcessCount" -Context "reverseSshRelay"), [Globalization.CultureInfo]::InvariantCulture)
    Assert-True -Condition ($relayProcessCount -eq 1) -Message "Required Windows reverse SSH relay evidence must include exactly one matching ssh.exe process."
    $relayProcessOwnerExpected = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "sshProcessOwnerExpected" -Context "reverseSshRelay") -Context "reverseSshRelay.sshProcessOwnerExpected"
    Assert-True -Condition ($relayProcessOwnerExpected -eq $true) -Message "Required Windows reverse SSH relay evidence must prove matching ssh.exe belongs to the task service account."
    $relayRequireRunning = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "requireRunning" -Context "reverseSshRelay") -Context "reverseSshRelay.requireRunning"
    Assert-True -Condition ($relayRequireRunning -eq $true) -Message "Required Windows reverse SSH relay evidence must be generated with RequireRunning=true."
}
elseif ($includeWindowsReverseSshRelayLifecycle) {
    Assert-PassedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
    $reverseSshRelayEvidence = Read-JsonFile -Path $reverseSshRelayEvidencePath -Context "Windows reverse SSH relay lifecycle"
    foreach ($optionalRelayBooleanField in @("accepted", "taskActionExpected", "taskActionFailClosed", "taskPrincipalExpected", "relayHostKeyPinned", "identityFileAclOk", "knownHostsAclOk", "installedStartScriptAclOk", "startScriptInstalledAndCurrent", "runtimeAclOk", "localSshEndpointReachable")) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name $optionalRelayBooleanField -Context "reverseSshRelay") -Context "reverseSshRelay.$optionalRelayBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Included Windows reverse SSH relay evidence must have $optionalRelayBooleanField=true."
    }
}
else {
    Assert-PassedOrSkippedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
}

$probeMacSsh = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "probeMacSsh" -Context "acceptance.parameters") -Context "acceptance.parameters.probeMacSsh"
$requireMacSshReady = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacSshReady" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacSshReady"
$requireMacDirectLan = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacDirectLan" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacDirectLan"
$requireMacRustCliSmoke = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacRustCliSmoke" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacRustCliSmoke"
$requireMacWebRtcInterop = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacWebRtcInterop" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacWebRtcInterop"

if ($probeMacSsh -or $requireMacSshReady -or $requireMacDirectLan -or $requireMacRustCliSmoke) {
    Assert-PassedGate -Name "mac-ssh-readiness" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "mac-ssh-readiness" | Out-Null
}

if ($requireMacWebRtcInterop) {
    Assert-PassedGate -Name "windows-mac-webrtc-interop" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "windows-mac-webrtc-interop" | Out-Null
}

if ($RequireMacInterop) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacSshReady" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacDirectLan" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacRustCliSmoke" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacWebRtcInterop" -Expected $true
    Assert-PassedGate -Name "mac-ssh-readiness" | Out-Null
    Assert-PassedGate -Name "windows-mac-webrtc-interop" | Out-Null

    $macEvidencePath = Get-OverrideOrJsonPath -OverridePath $MacSshEvidencePath -EvidencePaths $evidencePaths -PropertyName "macSshEvidencePath"
    $macEvidence = Read-JsonFile -Path $macEvidencePath -Context "Mac SSH readiness"
    foreach ($macBooleanField in @("ready", "directLanLikely", "hostKeyPinned")) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $macEvidence -Name $macBooleanField -Context "macSsh") -Context "macSsh.$macBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Mac SSH evidence must have $macBooleanField=true."
    }

    $macRustCliSmoke = Assert-JsonProperty -Object $macEvidence -Name "rustCliSmoke" -Context "macSsh"
    Assert-True -Condition ([string](Assert-JsonProperty -Object $macRustCliSmoke -Name "status" -Context "macSsh.rustCliSmoke") -eq "passed") -Message "Mac SSH evidence must include passed rustCliSmoke status."
    $macRustExitCode = [System.Convert]::ToInt32((Assert-JsonProperty -Object $macRustCliSmoke -Name "exitCode" -Context "macSsh.rustCliSmoke"), [Globalization.CultureInfo]::InvariantCulture)
    Assert-True -Condition ($macRustExitCode -eq 0) -Message "Mac SSH evidence must include rustCliSmoke exitCode=0."
    $macRustCliCommand = [string](Assert-JsonProperty -Object $macRustCliSmoke -Name "command" -Context "macSsh.rustCliSmoke")
    Assert-True -Condition ($macRustCliCommand -match "transport select --local macos --remote ios --path same-lan") -Message "Mac Rust CLI smoke evidence must prove the transport-select command."
    $macRustExpectedSignals = @((Assert-JsonProperty -Object $macRustCliSmoke -Name "expectedSignals" -Context "macSsh.rustCliSmoke"))
    $macRustActualSignals = @((Assert-JsonProperty -Object $macRustCliSmoke -Name "actualSignals" -Context "macSsh.rustCliSmoke"))
    foreach ($expectedSignal in @("kind=AppleNative", "audit=AppleNativeDefault", "relay_allowed=false")) {
        Assert-True -Condition ($macRustExpectedSignals -contains $expectedSignal) -Message "Mac Rust CLI smoke evidence missing expected signal: $expectedSignal"
        Assert-True -Condition ($macRustActualSignals -contains $expectedSignal) -Message "Mac Rust CLI smoke evidence missing actual signal: $expectedSignal"
    }
    Assert-True -Condition ([string](Assert-JsonProperty -Object $macRustCliSmoke -Name "actualOutputSha256" -Context "macSsh.rustCliSmoke") -match '^[0-9a-f]{64}$') -Message "Mac Rust CLI smoke evidence must include actualOutputSha256."

    $macWebRtcProofPath = [string](Assert-JsonProperty -Object $evidencePaths -Name "macWebRtcProofPath" -Context "acceptance.evidencePaths")
    $resolvedMacWebRtcProofPath = Resolve-EvidencePath -Path $macWebRtcProofPath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedMacWebRtcProofPath)) -Message "Mac WebRTC proof evidence path is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedMacWebRtcProofPath) -Message "Mac WebRTC proof file is missing: $resolvedMacWebRtcProofPath"
}

$requireCurrentPathProductControlTransport = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireCurrentPathProductControlTransport" -Context "acceptance.parameters") -Context "acceptance.parameters.requireCurrentPathProductControlTransport"
$requireCurrentPathProductControlAppControl = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireCurrentPathProductControlAppControl" -Context "acceptance.parameters") -Context "acceptance.parameters.requireCurrentPathProductControlAppControl"
$requireCurrentPathProductControlFileTransfer = Get-OptionalBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlFileTransfer" -DefaultValue $false
$requireCurrentPathProductControlAnswererTransport = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireCurrentPathProductControlAnswererTransport" -Context "acceptance.parameters") -Context "acceptance.parameters.requireCurrentPathProductControlAnswererTransport"
$requireCurrentPathProductControlAnswererAppControl = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireCurrentPathProductControlAnswererAppControl" -Context "acceptance.parameters") -Context "acceptance.parameters.requireCurrentPathProductControlAnswererAppControl"
$requireCurrentPathProductControlAnswererFileTransfer = Get-OptionalBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlAnswererFileTransfer" -DefaultValue $false
$importCurrentPathProductControlAppControlSession = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "importCurrentPathProductControlAppControlSession" -Context "acceptance.parameters") -Context "acceptance.parameters.importCurrentPathProductControlAppControlSession"
$importCurrentPathProductControlAnswererAppControlSession = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "importCurrentPathProductControlAnswererAppControlSession" -Context "acceptance.parameters") -Context "acceptance.parameters.importCurrentPathProductControlAnswererAppControlSession"
$currentPathProductControlAppControlSessionImportTargetRuntimeIdProvided = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "currentPathProductControlAppControlSessionImportTargetRuntimeIdProvided" -Context "acceptance.parameters") -Context "acceptance.parameters.currentPathProductControlAppControlSessionImportTargetRuntimeIdProvided"
$currentPathProductControlAnswererAppControlSessionImportTargetRuntimeIdProvided = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "currentPathProductControlAnswererAppControlSessionImportTargetRuntimeIdProvided" -Context "acceptance.parameters") -Context "acceptance.parameters.currentPathProductControlAnswererAppControlSessionImportTargetRuntimeIdProvided"
$currentPathProductControlAppControlSessionImportTtlSeconds = [System.Convert]::ToInt32((Assert-JsonProperty -Object $parameters -Name "currentPathProductControlAppControlSessionImportTtlSeconds" -Context "acceptance.parameters"), [Globalization.CultureInfo]::InvariantCulture)
$currentPathProductControlAnswererAppControlSessionImportTtlSeconds = [System.Convert]::ToInt32((Assert-JsonProperty -Object $parameters -Name "currentPathProductControlAnswererAppControlSessionImportTtlSeconds" -Context "acceptance.parameters"), [Globalization.CultureInfo]::InvariantCulture)
$currentPathProductControlEvidencePath = Get-OverrideOrJsonPath -OverridePath $CurrentPathProductControlEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlEvidencePath"
$currentPathProductControlFileTransferEvidencePath = Get-OptionalJsonPath -OverridePath $CurrentPathProductControlFileTransferEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlFileTransferEvidencePath"
$currentPathProductControlAnswererEvidencePath = Get-OverrideOrJsonPath -OverridePath $CurrentPathProductControlAnswererEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlAnswererEvidencePath"
$currentPathProductControlAnswererAppControlEvidencePath = Get-OverrideOrJsonPath -OverridePath $CurrentPathProductControlAnswererAppControlEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlAnswererAppControlEvidencePath"
$currentPathProductControlAnswererFileTransferEvidencePath = Get-OptionalJsonPath -OverridePath $CurrentPathProductControlAnswererFileTransferEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlAnswererFileTransferEvidencePath"
$currentPathProductControlAppControlSessionImportEvidencePath = Get-OverrideOrJsonPath -OverridePath $CurrentPathProductControlAppControlSessionImportEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlAppControlSessionImportEvidencePath"
$currentPathProductControlAnswererAppControlSessionImportEvidencePath = Get-OverrideOrJsonPath -OverridePath $CurrentPathProductControlAnswererAppControlSessionImportEvidencePath -EvidencePaths $evidencePaths -PropertyName "currentPathProductControlAnswererAppControlSessionImportEvidencePath"
if ($RequireCurrentPathProductControlTransport) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlTransport" -Expected $true
}
if ($RequireCurrentPathProductControlAppControl) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlAppControl" -Expected $true
}
if ($RequireCurrentPathProductControlFileTransfer) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlFileTransfer" -Expected $true
}
if ($RequireCurrentPathProductControlAnswererTransport) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlAnswererTransport" -Expected $true
}
if ($RequireCurrentPathProductControlAnswererAppControl) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlAnswererAppControl" -Expected $true
}
if ($RequireCurrentPathProductControlAnswererFileTransfer) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireCurrentPathProductControlAnswererFileTransfer" -Expected $true
}
if ($RequireCurrentPathProductControlSessionImport) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "importCurrentPathProductControlAppControlSession" -Expected $true
}
if ($RequireCurrentPathProductControlAnswererAppControlSessionImport) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "importCurrentPathProductControlAnswererAppControlSession" -Expected $true
}

$currentPathProductControlTransportRequired = $RequireCurrentPathProductControlTransport -or $requireCurrentPathProductControlTransport
$currentPathProductControlAppControlRequired = $RequireCurrentPathProductControlAppControl -or $requireCurrentPathProductControlAppControl
$currentPathProductControlFileTransferRequired = $RequireCurrentPathProductControlFileTransfer -or $requireCurrentPathProductControlFileTransfer
$currentPathProductControlAnswererTransportRequired = $RequireCurrentPathProductControlAnswererTransport -or $requireCurrentPathProductControlAnswererTransport
$currentPathProductControlAnswererAppControlRequired = $RequireCurrentPathProductControlAnswererAppControl -or $requireCurrentPathProductControlAnswererAppControl
$currentPathProductControlAnswererFileTransferRequired = $RequireCurrentPathProductControlAnswererFileTransfer -or $requireCurrentPathProductControlAnswererFileTransfer
$currentPathProductControlAppControlSessionImportRequired = $RequireCurrentPathProductControlSessionImport -or $importCurrentPathProductControlAppControlSession
$currentPathProductControlAnswererAppControlSessionImportRequired = $RequireCurrentPathProductControlAnswererAppControlSessionImport -or $importCurrentPathProductControlAnswererAppControlSession

Assert-True -Condition (-not ($currentPathProductControlTransportRequired -and $currentPathProductControlAppControlRequired)) -Message "Current-path offerer transport and AppControl evidence must be verified in separate acceptance evidence files."
Assert-True -Condition (-not ($currentPathProductControlTransportRequired -and $currentPathProductControlFileTransferRequired)) -Message "Current-path offerer transport and FileTransfer evidence must be verified in separate acceptance evidence files."
Assert-True -Condition (-not ($currentPathProductControlAppControlRequired -and $currentPathProductControlFileTransferRequired)) -Message "Current-path offerer AppControl and FileTransfer evidence must be verified in separate acceptance evidence files."
Assert-True -Condition (-not ($currentPathProductControlAppControlSessionImportRequired -and -not $currentPathProductControlAppControlRequired)) -Message "Current-path product-control session import acceptance requires current-path AppControl evidence in the same package."
Assert-True -Condition (-not ($currentPathProductControlAnswererAppControlSessionImportRequired -and -not $currentPathProductControlAnswererAppControlRequired)) -Message "Current-path answerer AppControl session import acceptance requires answerer AppControl evidence in the same package."

if ($currentPathProductControlFileTransferRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-file-transfer" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-transport" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-session-import" | Out-Null
    $currentPathFileTransferEvidence = Read-JsonFile -Path $currentPathProductControlFileTransferEvidencePath -Context "Current-path product-control FileTransfer"
    Assert-CurrentPathProductControlEvidence -Evidence $currentPathFileTransferEvidence -RequireAppControl $false -RequireFileTransfer $true
}
elseif ($currentPathProductControlAppControlRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-transport" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-file-transfer" | Out-Null
    $currentPathEvidence = Read-JsonFile -Path $currentPathProductControlEvidencePath -Context "Current-path product-control AppControl"
    Assert-CurrentPathProductControlEvidence -Evidence $currentPathEvidence -RequireAppControl $true
    if ($currentPathProductControlAppControlSessionImportRequired) {
        Assert-PassedGate -Name "windows-current-path-product-control-session-import" | Out-Null
        $sessionImportEvidence = Read-JsonFile -Path $currentPathProductControlAppControlSessionImportEvidencePath -Context "Current-path product-control session import"
        Assert-CurrentPathProductControlSessionImportEvidence `
            -Evidence $sessionImportEvidence `
            -Context "Current-path product-control session import" `
            -ExpectedTargetRuntimeIdProvided $currentPathProductControlAppControlSessionImportTargetRuntimeIdProvided `
            -ExpectedTtlSeconds $currentPathProductControlAppControlSessionImportTtlSeconds
    }
    else {
        Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-session-import" | Out-Null
    }
}
elseif ($currentPathProductControlTransportRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-transport" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-file-transfer" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-session-import" | Out-Null
    $currentPathEvidence = Read-JsonFile -Path $currentPathProductControlEvidencePath -Context "Current-path product-control transport"
    Assert-CurrentPathProductControlEvidence -Evidence $currentPathEvidence -RequireAppControl $false
}
else {
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-transport" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-file-transfer" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-session-import" | Out-Null
}

if ($currentPathProductControlAnswererTransportRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-answerer-transport" | Out-Null
    $currentPathAnswererEvidence = Read-JsonFile -Path $currentPathProductControlAnswererEvidencePath -Context "Current-path product-control answerer transport"
    Assert-CurrentPathProductControlEvidence `
        -Evidence $currentPathAnswererEvidence `
        -RequireAppControl $false `
        -ExpectedTransportProfile "current-path-product-control-answerer-transport" `
        -ExpectedTransportScope "AdmissionRegisterBoundSdpIceProductControlAnswererTransportOpen" `
        -ExpectedRole "answer" `
        -ExpectedSignalingExchangeRole "answerer"
}
elseif (-not $currentPathProductControlAnswererAppControlRequired) {
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-transport" | Out-Null
}

if ($currentPathProductControlAnswererAppControlRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-answerer-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-transport" | Out-Null
    $currentPathAnswererAppControlEvidence = Read-JsonFile -Path $currentPathProductControlAnswererAppControlEvidencePath -Context "Current-path product-control answerer AppControl"
    Assert-CurrentPathProductControlEvidence `
        -Evidence $currentPathAnswererAppControlEvidence `
        -RequireAppControl $true `
        -ExpectedAppControlProfile "current-path-product-control-answerer-appcontrol" `
        -ExpectedAppControlScope "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeAppControlPong" `
        -ExpectedRole "answer" `
        -ExpectedSignalingExchangeRole "answerer"
    if ($currentPathProductControlAnswererAppControlSessionImportRequired) {
        Assert-PassedGate -Name "windows-current-path-product-control-answerer-appcontrol-session-import" | Out-Null
        $answererSessionImportEvidence = Read-JsonFile -Path $currentPathProductControlAnswererAppControlSessionImportEvidencePath -Context "Current-path product-control answerer AppControl session import"
        Assert-CurrentPathProductControlSessionImportEvidence `
            -Evidence $answererSessionImportEvidence `
            -Context "Current-path product-control answerer AppControl session import" `
            -ExpectedTargetRuntimeIdProvided $currentPathProductControlAnswererAppControlSessionImportTargetRuntimeIdProvided `
            -ExpectedTtlSeconds $currentPathProductControlAnswererAppControlSessionImportTtlSeconds
    }
    else {
        Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-appcontrol-session-import" | Out-Null
    }
}
elseif (-not $currentPathProductControlAnswererTransportRequired) {
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-appcontrol" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-appcontrol-session-import" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-appcontrol-session-import" | Out-Null
}

if ($currentPathProductControlAnswererFileTransferRequired) {
    Assert-PassedGate -Name "windows-current-path-product-control-answerer-file-transfer" | Out-Null
    $currentPathAnswererFileTransferEvidence = Read-JsonFile -Path $currentPathProductControlAnswererFileTransferEvidencePath -Context "Current-path product-control answerer FileTransfer"
    Assert-CurrentPathProductControlEvidence `
        -Evidence $currentPathAnswererFileTransferEvidence `
        -RequireAppControl $false `
        -RequireFileTransfer $true `
        -ExpectedFileTransferProfile "current-path-product-control-answerer-file-transfer" `
        -ExpectedFileTransferScope "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeFileTransferReceipt" `
        -ExpectedRole "answer" `
        -ExpectedSignalingExchangeRole "answerer"
}
else {
    Assert-PassedOrSkippedGate -Name "windows-current-path-product-control-answerer-file-transfer" | Out-Null
}

$requireLiveFileTransfer = Get-OptionalBooleanParameter -Parameters $parameters -Name "requireLiveFileTransfer" -DefaultValue $false
$requireLiveRemoteDesktop = Get-OptionalBooleanParameter -Parameters $parameters -Name "requireLiveRemoteDesktop" -DefaultValue $false
$requirePublicArtifactRedaction = Get-OptionalBooleanParameter -Parameters $parameters -Name "requirePublicArtifactRedaction" -DefaultValue $false
$liveFileTransferEvidencePath = Get-OptionalJsonPath -OverridePath $LiveFileTransferEvidencePath -EvidencePaths $evidencePaths -PropertyName "liveFileTransferEvidencePath"
$liveRemoteDesktopEvidencePath = Get-OptionalJsonPath -OverridePath $LiveRemoteDesktopEvidencePath -EvidencePaths $evidencePaths -PropertyName "liveRemoteDesktopEvidencePath"
$publicArtifactScanEvidencePath = Get-OptionalJsonPath -OverridePath $PublicArtifactScanEvidencePath -EvidencePaths $evidencePaths -PropertyName "publicArtifactScanEvidencePath"

if ($RequireLiveFileTransfer) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireLiveFileTransfer" -Expected $true
}
if ($RequireLiveRemoteDesktop) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireLiveRemoteDesktop" -Expected $true
}
if ($RequirePublicArtifactRedaction) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requirePublicArtifactRedaction" -Expected $true
}

if ($RequireLiveFileTransfer -or $requireLiveFileTransfer) {
    Assert-PassedGate -Name "windows-live-file-transfer" | Out-Null
    $liveFileTransferEvidence = Read-JsonFile -Path $liveFileTransferEvidencePath -Context "Windows live file-transfer"
    Assert-LiveFileTransferEvidence -Evidence $liveFileTransferEvidence -Context "Windows live file-transfer"
}
elseif (Test-GatePresent -Name "windows-live-file-transfer") {
    Assert-PassedOrSkippedGate -Name "windows-live-file-transfer" | Out-Null
}

if ($RequireLiveRemoteDesktop -or $requireLiveRemoteDesktop) {
    Assert-PassedGate -Name "windows-live-remote-desktop" | Out-Null
    $liveRemoteDesktopEvidence = Read-JsonFile -Path $liveRemoteDesktopEvidencePath -Context "Windows live remote-desktop"
    Assert-LiveRemoteDesktopEvidence -Evidence $liveRemoteDesktopEvidence -Context "Windows live remote-desktop"
}
elseif (Test-GatePresent -Name "windows-live-remote-desktop") {
    Assert-PassedOrSkippedGate -Name "windows-live-remote-desktop" | Out-Null
}

if ($RequirePublicArtifactRedaction -or $requirePublicArtifactRedaction) {
    $publicArtifactPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($PublicArtifactPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $publicArtifactPaths.Add([string]$path)
        }
    }
    if ($publicArtifactPaths.Count -eq 0) {
        foreach ($path in (Get-OptionalJsonStringArray -Object $evidencePaths -PropertyName "publicArtifactPaths")) {
            $publicArtifactPaths.Add([string]$path)
        }
    }

    Invoke-PublicArtifactRedactionVerifier -Paths $publicArtifactPaths.ToArray() -Tokens $PublicArtifactSensitiveToken
    if (-not [string]::IsNullOrWhiteSpace($publicArtifactScanEvidencePath)) {
        $publicArtifactScanEvidence = Read-JsonFile -Path $publicArtifactScanEvidencePath -Context "Windows public artifact redaction"
        Assert-True -Condition ([string](Assert-JsonProperty -Object $publicArtifactScanEvidence -Name "profile" -Context "publicArtifactScan") -eq "windows-public-artifact-redaction") -Message "Public artifact scan evidence has unexpected profile."
        Assert-True -Condition ([string](Assert-JsonProperty -Object $publicArtifactScanEvidence -Name "status" -Context "publicArtifactScan") -eq "passed") -Message "Public artifact scan evidence must have status=passed."
        $scanFileCount = [System.Convert]::ToInt64((Assert-JsonProperty -Object $publicArtifactScanEvidence -Name "fileCount" -Context "publicArtifactScan"), [Globalization.CultureInfo]::InvariantCulture)
        Assert-True -Condition ($scanFileCount -gt 0) -Message "Public artifact scan evidence must report at least one scanned file."
    }
    if (Test-GatePresent -Name "windows-public-artifact-redaction") {
        Assert-PassedGate -Name "windows-public-artifact-redaction" | Out-Null
    }
}
elseif (Test-GatePresent -Name "windows-public-artifact-redaction") {
    Assert-PassedOrSkippedGate -Name "windows-public-artifact-redaction" | Out-Null
}

Write-Output "windows-portability-acceptance-evidence: ok path=$resolvedAcceptanceEvidencePath branch=$branch head=$head gates=$($script:AcceptanceGateResults.Count)"
