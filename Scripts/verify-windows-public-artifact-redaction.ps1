param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string[]]$ArtifactPath,
    [string[]]$SensitiveToken = @(),
    [string]$EvidencePath = "",
    [ValidateRange(1, 1073741824)]
    [int64]$MaxFileBytes = 16777216,
    [ValidateRange(1, 1099511627776)]
    [int64]$MaxTotalBytes = 268435456,
    [ValidateRange(1, 1000000)]
    [int]$MaxFileCount = 5000
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

function Resolve-ArtifactPath {
    param([string]$Path)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Path)) -Message "Public artifact path is empty."
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepoRoot $Path))
}

function Test-IsScanEligibleArtifactName {
    param([string]$Name)

    return $Name.EndsWith(".log", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.EndsWith(".jsonl", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.EndsWith(".txt", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.EndsWith(".csv", [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsDeniedArtifactRelativePath {
    param([string]$RelativePath)

    $normalized = $RelativePath.Replace("\", "/")
    return $normalized -match '(^|/)\.git(/|$)' -or
        $normalized -match '(^|/)\.ssh(/|$)' -or
        $normalized -match '(^|/)webrtc-signaling(/|$)' -or
        $normalized -match '(^|/)skybridge-current-path-product-control-answerer-code-[^/]+(/|$)' -or
        $normalized -match '(^|/)skybridge-current-path-product-control-session-id-[^/]+(/|$)' -or
        $normalized -match '(^|/)skybridge-current-path-product-control-session-state-[^/]+(/|$)' -or
        $normalized -match '(^|/)skybridge-current-path-product-control-signaling-[^/]+(/|$)' -or
        $normalized -match '(^|/)(offer|answer)\.json$' -or
        $normalized -match '\.(offer|answer)\.json$' -or
        $normalized -match '(^|/)turn-credentials\.json$' -or
        $normalized -match '(^|/)\.env[^/]*$' -or
        $normalized -match '\.(pfx|p12|pem|key|dmp|dump|pcap|har|zip)$' -or
        $normalized -match '(^|/)id_[^/]+$'
}

function Assert-NoReparsePoint {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string]$Context
    )

    Assert-True -Condition (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "Public artifact scan refuses reparse-point $Context`: $($Item.FullName)"
}

function Get-PublicArtifactFiles {
    param([string]$Path)

    $resolvedPath = Resolve-ArtifactPath -Path $Path
    Assert-True -Condition (Test-Path -LiteralPath $resolvedPath) -Message "Public artifact path does not exist: $resolvedPath"
    $item = Get-Item -LiteralPath $resolvedPath -Force
    Assert-NoReparsePoint -Item $item -Context "root"

    if ($item.PSIsContainer) {
        $root = [System.IO.Path]::GetFullPath($resolvedPath).TrimEnd([char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar))
        $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar))
        Assert-True -Condition (-not [string]::Equals($root, $repo, [StringComparison]::OrdinalIgnoreCase)) -Message "Public artifact scan refuses repo root as artifact root: $root"
        $blockedDirectories = @(Get-ChildItem -LiteralPath $resolvedPath -Force -Recurse -Directory | Where-Object {
            ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        })
        Assert-True -Condition ($blockedDirectories.Count -eq 0) -Message "Public artifact scan refuses reparse-point descendants under: $resolvedPath"

        $allFiles = @(Get-ChildItem -LiteralPath $resolvedPath -Force -Recurse -File | Sort-Object -Property FullName)
        foreach ($candidate in $allFiles) {
            Assert-NoReparsePoint -Item $candidate -Context "file"
            $fullName = [System.IO.Path]::GetFullPath($candidate.FullName)
            $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
            Assert-True -Condition ($fullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message "Public artifact file escapes root: $fullName"
            $relativePath = $fullName.Substring($rootPrefix.Length).Replace([string][System.IO.Path]::DirectorySeparatorChar, "/")
            if ([System.IO.Path]::AltDirectorySeparatorChar -ne [System.IO.Path]::DirectorySeparatorChar) {
                $relativePath = $relativePath.Replace([string][System.IO.Path]::AltDirectorySeparatorChar, "/")
            }
            Assert-True -Condition (-not (Test-IsDeniedArtifactRelativePath -RelativePath $relativePath)) -Message "Public artifact package contains denied sensitive artifact path: $relativePath"
            Assert-True -Condition (Test-IsScanEligibleArtifactName -Name $candidate.Name) -Message "Public artifact file is not scan-eligible: $relativePath"
        }

        return @($allFiles)
    }

    Assert-True -Condition (-not (Test-IsDeniedArtifactRelativePath -RelativePath $item.Name)) -Message "Public artifact package contains denied sensitive artifact path: $($item.Name)"
    Assert-True -Condition (Test-IsScanEligibleArtifactName -Name $item.Name) -Message "Public artifact file is not scan-eligible: $resolvedPath"
    return @($item)
}

function Get-DefaultSensitiveTokens {
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            $RepoRoot,
            (Get-Location).Path,
            $env:USERPROFILE,
            $env:HOME,
            $env:TEMP,
            $env:TMP,
            $env:LOCALAPPDATA,
            $env:APPDATA,
            $env:PROGRAMDATA
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $tokens.Add([string]$candidate)
        }
    }

    foreach ($name in @(
            "SKYBRIDGE_CURRENT_PATH_CONNECTION_CODE",
            "SKYBRIDGE_CURRENT_PATH_BEARER_TOKEN",
            "SKYBRIDGE_CURRENT_PATH_TENANT_ID",
            "SKYBRIDGE_CURRENT_PATH_MLDSA65_PRIVATE_KEY_BASE64",
            "SKYBRIDGE_CURRENT_PATH_PEER_MLKEM768_PUBLIC_KEY_BASE64",
            "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_DECAPSULATION_KEY_BASE64",
            "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_PUBLIC_KEY_BASE64"
        )) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $tokens.Add([string]$value)
        }
    }

    return $tokens.ToArray()
}

$SensitiveStructuredFieldNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($fieldName in @(
        "accesstoken",
        "accountdisplayname",
        "address",
        "apikey",
        "authsession",
        "authorization",
        "bearertoken",
        "bonjourservicename",
        "bundlepath",
        "candidate",
        "clientsecret",
        "clouddeviceid",
        "code",
        "connectioncode",
        "controlendpoint",
        "currentpathproductcontrolanswererappcontrolconnectioncodepath",
        "currentpathproductcontrolanswererconnectioncodepath",
        "currentpathproductcontrolanswererfiletransferconnectioncodepath",
        "currentpathproductcontrolanswerertransportconnectioncodepath",
        "deviceid",
        "displayname",
        "email",
        "endpoint",
        "endpointhost",
        "evidencedir",
        "evidencepath",
        "file",
        "fingerprint",
        "host",
        "identitykey",
        "ice",
        "icecandidate",
        "icepwd",
        "iceufrag",
        "ip",
        "localdeviceid",
        "localendpoint",
        "localpath",
        "mlkempublickey",
        "mlkempublickeybase64",
        "nebulaid",
        "p2pdeviceid",
        "path",
        "peerdeviceid",
        "peerid",
        "peerpublickey",
        "privatekey",
        "privatekeybase64",
        "proofpath",
        "publickeybase64",
        "pubkeyfp",
        "rawsessionid",
        "reason",
        "refreshtoken",
        "remoteendpoint",
        "remotepath",
        "reporoot",
        "routeidentifier",
        "selectedcandidate",
        "selectedcandidatepair",
        "session",
        "sessionid",
        "sdp",
        "stablepeerid",
        "statusfile",
        "sub",
        "targetdeviceid",
        "tenantid",
        "token",
        "trackid",
        "url",
        "userid",
        "useridentifier",
        "xwingpublickey",
        "xwingpublickeybase64"
    )) {
    [void]$SensitiveStructuredFieldNames.Add($fieldName)
}

function ConvertTo-CanonicalPublicArtifactKey {
    param([string]$Key)

    return ([regex]::Replace($Key.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Test-IsRedactedPublicArtifactValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $true
    }
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            return $true
        }
        $lower = $trimmed.ToLowerInvariant()
        return $lower.StartsWith("<redacted") -or
            $lower.StartsWith("<external:") -or
            $lower.StartsWith("ref:") -or
            $lower.StartsWith("sha256:") -or
            $lower.StartsWith("present:length=") -or
            $lower -eq "missing"
    }

    return $false
}

function Test-ContainsUnredactedSensitiveValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [string]) {
        return -not (Test-IsRedactedPublicArtifactValue -Value $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($item in $Value.Values) {
            if (Test-ContainsUnredactedSensitiveValue -Value $item) {
                return $true
            }
        }
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            if (Test-ContainsUnredactedSensitiveValue -Value $item) {
                return $true
            }
        }
        return $false
    }

    $properties = @($Value.PSObject.Properties | Where-Object {
            $_.MemberType -eq [System.Management.Automation.PSMemberTypes]::NoteProperty -or
            $_.MemberType -eq [System.Management.Automation.PSMemberTypes]::Property
        })
    if ($properties.Count -gt 0) {
        foreach ($property in $properties) {
            if (Test-ContainsUnredactedSensitiveValue -Value $property.Value) {
                return $true
            }
        }
        return $false
    }

    return $true
}

function Add-StructuredJsonFindings {
    param(
        [AllowNull()]$Value,
        [string]$RelativePath,
        [System.Collections.Generic.List[string]]$Findings
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string] -or $Value.GetType().IsPrimitive -or $Value -is [decimal]) {
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $canonicalName = ConvertTo-CanonicalPublicArtifactKey -Key ([string]$key)
            if ($SensitiveStructuredFieldNames.Contains($canonicalName) -and
                (Test-ContainsUnredactedSensitiveValue -Value $Value[$key])) {
                $Findings.Add("$RelativePath`: raw sensitive JSON field $key")
            }
            Add-StructuredJsonFindings -Value $Value[$key] -RelativePath $RelativePath -Findings $Findings
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and
        $Value -isnot [System.Collections.IDictionary]) {
        foreach ($item in $Value) {
            Add-StructuredJsonFindings -Value $item -RelativePath $RelativePath -Findings $Findings
        }
        return
    }

    foreach ($property in @($Value.PSObject.Properties | Where-Object {
                $_.MemberType -eq [System.Management.Automation.PSMemberTypes]::NoteProperty -or
                $_.MemberType -eq [System.Management.Automation.PSMemberTypes]::Property
            })) {
        $canonicalName = ConvertTo-CanonicalPublicArtifactKey -Key ([string]$property.Name)
        if ($SensitiveStructuredFieldNames.Contains($canonicalName) -and
            (Test-ContainsUnredactedSensitiveValue -Value $property.Value)) {
            $Findings.Add("$RelativePath`: raw sensitive JSON field $($property.Name)")
        }
        Add-StructuredJsonFindings -Value $property.Value -RelativePath $RelativePath -Findings $Findings
    }
}

function Add-StructuredTextFindings {
    param(
        [string]$Text,
        [string]$RelativePath,
        [System.Collections.Generic.List[string]]$Findings
    )

    $candidates = @()
    if ($RelativePath.EndsWith(".jsonl", [StringComparison]::OrdinalIgnoreCase)) {
        $candidates = @($Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    elseif ($RelativePath.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase) -or
        $Text.TrimStart().StartsWith("{") -or
        $Text.TrimStart().StartsWith("[")) {
        $candidates = @($Text)
    }

    foreach ($candidate in $candidates) {
        try {
            $parsed = $candidate | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        }
        catch {
            continue
        }
        Add-StructuredJsonFindings -Value $parsed -RelativePath $RelativePath -Findings $Findings
    }
}

function Get-PublicArtifactFindings {
    param(
        [string]$Text,
        [string]$RelativePath,
        [string[]]$Tokens
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($token in ($Tokens | Sort-Object -Unique | Sort-Object Length -Descending)) {
        if (-not [string]::IsNullOrWhiteSpace($token) -and $Text.Contains($token)) {
            $findings.Add("$RelativePath`: raw configured token")
            break
        }
    }

    $patterns = [ordered]@{
        "raw connect link" = 'skybridge://'
        "raw http URL" = '\bhttps?://[^\s"'']+'
        "raw JWT" = '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*)?\b'
        "raw OpenAI key" = '\bsk-[A-Za-z0-9._-]{8,}\b'
        "raw private key block" = '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
        "raw SDP" = '(^|\n)v=0(\r?\n|$)'
        "raw ICE password" = 'a=ice-pwd:[^\s]+'
        "raw ICE ufrag" = 'a=ice-ufrag:[^\s]+'
        "raw ICE candidate" = 'a=candidate:[^\r\n]+'
        "raw bearer authorization" = '\bAuthorization:\s*Bearer\s+(?!<redacted\b|<redacted>)[^\s]+'
        "raw secret assignment" = '\b(?:access[-_]?token|auth[-_]?token|bearer[-_]?token|refresh[-_]?token|id[-_]?token|api[-_]?key|client[-_]?secret|private[-_]?key(?:[-_]?base64)?|token|authorization|connection[-_]?code|registered[-_]?code|ice[-_]?candidate|ice[-_]?pwd|ice[-_]?ufrag|sdp)=(?!<redacted\b|<redacted>)[^\s&]+'
        "raw identity assignment" = '\b(?:raw[-_]?session[-_]?id|session|session[-_]?id|peer|peer[-_]?id|peer[-_]?device[-_]?id|target[-_]?device[-_]?id|local[-_]?device[-_]?id|p2p[-_]?device[-_]?id|cloud[-_]?device[-_]?id|stable[-_]?peer[-_]?id|device[-_]?id|identity[-_]?key|fingerprint|pub[-_]?key[-_]?fp|peer[-_]?public[-_]?key|public[-_]?key[-_]?base64|xwing[-_]?public[-_]?key(?:[-_]?base64)?|mlkem[-_]?public[-_]?key(?:[-_]?base64)?|track[-_]?id|connection[-_]?code|status[-_]?file|tenant[-_]?id|user[-_]?identifier|user[-_]?id|sub|nebula[-_]?id|display[-_]?name|account[-_]?display[-_]?name|email|reason|route[-_]?identifier|bonjour[-_]?service[-_]?name|endpoint|endpoint[-_]?host|control[-_]?endpoint|host|ip|address|url|repo[-_]?root|path|file|evidence[-_]?path|evidence[-_]?dir|proof[-_]?path|local[-_]?path|remote[-_]?path|capture[-_]?path|clipboard[-_]?text|local[-_]?endpoint|remote[-_]?endpoint|selected[-_]?candidate(?:[-_]?pair)?)=(?!<redacted\b|<redacted>|ref:|sha256:|present:length=|missing\b|<external:)[^\s&]+'
        "raw sensitive JSON field" = '"(?:accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|privateKey|privateKeyBase64|token|connectionCode|registeredCode|rawSessionId|icePwd|iceUfrag|sdp|peerPublicKey|publicKeyBase64|xwingPublicKey|xwingPublicKeyBase64|mlkemPublicKey|mlkemPublicKeyBase64|session|sessionId|trackId|peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|deviceId|identityKey|fingerprint|pubKeyFP|tenantId|userIdentifier|userId|sub|nebulaId|displayName|accountDisplayName|email|reason|routeIdentifier|bonjourServiceName|endpoint|endpointHost|controlEndpoint|host|ip|address|url|repoRoot|path|file|localPath|remotePath|capturePath|clipboardText|evidencePath|evidenceDir|proofPath|currentPathProductControlAnswererConnectionCodePath|currentPathProductControlAnswererTransportConnectionCodePath|currentPathProductControlAnswererAppControlConnectionCodePath|currentPathProductControlAnswererFileTransferConnectionCodePath)"\s*:\s*"(?!<redacted\b|<redacted>|<external:|ref:|sha256:|present:length=|missing\b)[^"]+"'
        "raw Windows path" = '(?i)(^|[\s"=:])(?:[A-Z]:\\|\\\\)[^\s"'']+'
        "raw macOS or Android path" = '(^|[\s"=:])/(?:Users|private/var|var/folders|data/(?:user|data)|tmp)/[^\s"'']+'
        "raw connect code" = '\bconnect\s+(?!<redacted\b|<redacted>)[A-Za-z0-9._:-]{4,}\b'
        "raw plain SAS code" = '\bcode\s+(?!<redacted\b|<redacted>)[0-9]{6}\b'
        "raw long base64" = '\b[A-Za-z0-9+/_-]{80,}={0,2}\b'
    }

    foreach ($entry in $patterns.GetEnumerator()) {
        if ([regex]::IsMatch($Text, [string]$entry.Value, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $findings.Add("$RelativePath`: $($entry.Key)")
        }
    }
    Add-StructuredTextFindings -Text $Text -RelativePath $RelativePath -Findings $findings

    return $findings.ToArray()
}

$allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($path in $ArtifactPath) {
    foreach ($file in Get-PublicArtifactFiles -Path $path) {
        $allFiles.Add($file)
    }
}
Assert-True -Condition ($allFiles.Count -gt 0) -Message "Public artifact scan found no scan-eligible files."
Assert-True -Condition ($allFiles.Count -le $MaxFileCount) -Message "Public artifact scan file count exceeds MaxFileCount: count=$($allFiles.Count) max=$MaxFileCount"

$tokens = @((Get-DefaultSensitiveTokens) + $SensitiveToken)
$findings = [System.Collections.Generic.List[string]]::new()
$scannedBytes = [int64]0
foreach ($file in ($allFiles | Sort-Object -Property FullName -Unique)) {
    Assert-NoReparsePoint -Item $file -Context "file"
    Assert-True -Condition ([int64]$file.Length -le $MaxFileBytes) -Message "Public artifact scan refuses oversized file: $($file.FullName)"
    $scannedBytes += [int64]$file.Length
    Assert-True -Condition ($scannedBytes -le $MaxTotalBytes) -Message "Public artifact scan total bytes exceed MaxTotalBytes: total=$scannedBytes max=$MaxTotalBytes"
    $text = Get-Content -Raw -LiteralPath $file.FullName
    $relativePath = $file.FullName
    foreach ($artifactRoot in $ArtifactPath) {
        $resolvedRoot = Resolve-ArtifactPath -Path $artifactRoot
        if (Test-Path -LiteralPath $resolvedRoot -PathType Container) {
            $root = [System.IO.Path]::GetFullPath($resolvedRoot).TrimEnd([char[]]@(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar))
            $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
            if ($file.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $relativePath = $file.FullName.Substring($prefix.Length).Replace([string][System.IO.Path]::DirectorySeparatorChar, "/")
                if ([System.IO.Path]::AltDirectorySeparatorChar -ne [System.IO.Path]::DirectorySeparatorChar) {
                    $relativePath = $relativePath.Replace([string][System.IO.Path]::AltDirectorySeparatorChar, "/")
                }
                break
            }
        }
    }

    foreach ($finding in Get-PublicArtifactFindings -Text $text -RelativePath $relativePath -Tokens $tokens) {
        $findings.Add($finding)
    }
}

if ($findings.Count -gt 0) {
    throw "Windows public artifacts contain unredacted sensitive content:$([Environment]::NewLine)$((($findings | Select-Object -First 20) -join [Environment]::NewLine))"
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $resolvedEvidencePath = Resolve-ArtifactPath -Path $EvidencePath
    $evidenceDirectory = Split-Path -Parent $resolvedEvidencePath
    if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
        New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    }

    [ordered]@{
        profile = "windows-public-artifact-redaction"
        status = "passed"
        denylistVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        artifactPathCount = [int64]$ArtifactPath.Count
        fileCount = [int64]$allFiles.Count
        byteLength = [int64]$scannedBytes
        maxFileBytes = [int64]$MaxFileBytes
        maxTotalBytes = [int64]$MaxTotalBytes
        maxFileCount = [int]$MaxFileCount
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8
    Write-Output "windows-public-artifact-redaction: evidence=$resolvedEvidencePath"
}

Write-Output "windows-public-artifact-redaction: ok files=$($allFiles.Count)"
