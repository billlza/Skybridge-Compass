Set-StrictMode -Version Latest

function Assert-WindowsCurrentPathCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Save-WindowsCurrentPathProcessEnvironment {
    param([string[]]$Names)

    $environment = [Environment]::GetEnvironmentVariables("Process")
    $snapshot = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $Names) {
        Assert-WindowsCurrentPathCondition -Condition (-not [string]::IsNullOrWhiteSpace($name)) -Message "Environment variable names must not be empty."
        $snapshot.Add([pscustomobject]@{
            Name = $name
            Exists = $environment.Contains($name)
            Value = [Environment]::GetEnvironmentVariable($name, "Process")
        })
    }

    return $snapshot.ToArray()
}

function Restore-WindowsCurrentPathProcessEnvironment {
    param([object[]]$Snapshot)

    foreach ($entry in $Snapshot) {
        $name = [string]$entry.Name
        if ([bool]$entry.Exists) {
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
}

function Test-WindowsCurrentPathIsWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Assert-WindowsCurrentPathNotReparsePath {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    Assert-WindowsCurrentPathCondition -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "$Label must not be a reparse point: $Path"
}

function Assert-WindowsCurrentPathNotReparsePathAncestors {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $current = [System.IO.Path]::GetFullPath($Path)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            Assert-WindowsCurrentPathNotReparsePath -Path $current -Label $Label
        }

        $trimmed = $current.TrimEnd($separators)
        $parent = [System.IO.Path]::GetDirectoryName($trimmed)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { return }
        $current = $parent
    }
}

function Get-WindowsCurrentPathLeafName {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return [System.IO.Path]::GetFileName($fullPath.TrimEnd($separators))
}

function New-WindowsCurrentPathRestrictedDirectory {
    param(
        [string]$Directory,
        [string]$RequiredLeafPrefix,
        [string]$Label
    )

    Assert-WindowsCurrentPathCondition -Condition (-not [string]::IsNullOrWhiteSpace($Directory)) -Message "$Label must not be empty."
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
    $leafName = Get-WindowsCurrentPathLeafName -Path $fullDirectory
    Assert-WindowsCurrentPathCondition -Condition ((-not [string]::IsNullOrWhiteSpace($leafName)) -and $leafName.StartsWith($RequiredLeafPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message "$Label must be a dedicated directory whose leaf name starts with '$RequiredLeafPrefix': $fullDirectory"
    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $fullDirectory -Label $Label

    if (Test-Path -LiteralPath $fullDirectory) {
        Assert-WindowsCurrentPathNotReparsePath -Path $fullDirectory -Label $Label
        $existingItem = Get-ChildItem -LiteralPath $fullDirectory -Force | Select-Object -First 1
        Assert-WindowsCurrentPathCondition -Condition ($null -eq $existingItem) -Message "$Label must be a newly-created or empty dedicated directory: $fullDirectory"
    }
    else {
        New-Item -ItemType Directory -Path $fullDirectory | Out-Null
    }

    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $fullDirectory -Label $Label
    if (Test-WindowsCurrentPathIsWindows) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($account in @($identity, "BUILTIN\Administrators", "NT AUTHORITY\SYSTEM")) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $account,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule) | Out-Null
        }
        Set-Acl -LiteralPath $fullDirectory -AclObject $acl
    }

    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $fullDirectory -Label $Label
    return $fullDirectory
}

function New-WindowsCurrentPathSignalingDirectory {
    param([string]$Directory)

    return New-WindowsCurrentPathRestrictedDirectory `
        -Directory $Directory `
        -RequiredLeafPrefix "skybridge-current-path-product-control-signaling-" `
        -Label "SignalingDir"
}

function New-WindowsCurrentPathOperatorSecretDirectory {
    param([string]$Directory)

    return New-WindowsCurrentPathRestrictedDirectory `
        -Directory $Directory `
        -RequiredLeafPrefix "skybridge-current-path-product-control-answerer-code-" `
        -Label "Registered code directory"
}

function New-WindowsCurrentPathSessionIdSecretDirectory {
    param([string]$Directory)

    return New-WindowsCurrentPathRestrictedDirectory `
        -Directory $Directory `
        -RequiredLeafPrefix "skybridge-current-path-product-control-session-id-" `
        -Label "Session id directory"
}

function New-WindowsCurrentPathSessionImportStateDirectory {
    param([string]$Directory)

    $stateRoot = New-WindowsCurrentPathRestrictedDirectory `
        -Directory $Directory `
        -RequiredLeafPrefix "skybridge-current-path-product-control-session-state-" `
        -Label "SessionImportStateDir"
    $runtimeDir = Join-Path $stateRoot "runtime"
    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $runtimeDir -Label "SessionImportStateDir runtime"
    if (Test-Path -LiteralPath $runtimeDir) {
        Assert-WindowsCurrentPathNotReparsePath -Path $runtimeDir -Label "SessionImportStateDir runtime"
    }
    else {
        New-Item -ItemType Directory -Path $runtimeDir | Out-Null
    }

    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $runtimeDir -Label "SessionImportStateDir runtime"
    if (Test-WindowsCurrentPathIsWindows) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($account in @($identity, "BUILTIN\Administrators", "NT AUTHORITY\SYSTEM")) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $account,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule) | Out-Null
        }
        Set-Acl -LiteralPath $runtimeDir -AclObject $acl
    }

    return $stateRoot
}

function Assert-WindowsCurrentPathOperatorSecretFileProtected {
    param(
        [string]$Path,
        [string]$Label = "operator secret file"
    )

    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $Path -Label $Label
    Assert-WindowsCurrentPathNotReparsePath -Path $Path -Label $Label
    if (-not (Test-WindowsCurrentPathIsWindows)) { return }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $allowed.Add([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) | Out-Null
    $allowed.Add("BUILTIN\Administrators") | Out-Null
    $allowed.Add("NT AUTHORITY\SYSTEM") | Out-Null
    $acl = Get-Acl -LiteralPath $Path
    Assert-WindowsCurrentPathCondition -Condition ($acl.AreAccessRulesProtected) -Message "$Label ACL must disable inherited access rules."
    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $name = $entry.IdentityReference.Value
        Assert-WindowsCurrentPathCondition -Condition ($allowed.Contains($name)) -Message "$Label has broad ACL entry: $name"
    }
}

function Assert-WindowsCurrentPathOperatorBindingText {
    param(
        [string]$Value,
        [string]$Label
    )

    Assert-WindowsCurrentPathCondition -Condition (-not [string]::IsNullOrWhiteSpace($Value)) -Message "$Label must not be empty."
    Assert-WindowsCurrentPathCondition -Condition ($Value -eq $Value.Trim()) -Message "$Label must not contain leading or trailing whitespace."
    Assert-WindowsCurrentPathCondition -Condition ($Value.Length -le 512) -Message "$Label must not exceed 512 characters."
    Assert-WindowsCurrentPathCondition -Condition ($Value -notmatch '[\x00-\x1f\x7f]') -Message "$Label must not contain control characters."
}

function Get-WindowsCurrentPathSha256Hex {
    param([string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Read-WindowsCurrentPathSecretLineFile {
    param(
        [string]$Path,
        [string]$Label
    )

    Assert-WindowsCurrentPathOperatorSecretFileProtected -Path $Path -Label $Label
    $raw = Get-Content -LiteralPath $Path -Raw
    $value = $raw -replace "(\r\n|\n|\r)$", ""
    Assert-WindowsCurrentPathOperatorBindingText -Value $value -Label $Label
    return $value
}

function Assert-WindowsCurrentPathTextDoesNotContain {
    param(
        [string]$Text,
        [string[]]$Needles,
        [string]$Label
    )

    foreach ($needle in $Needles) {
        if ([string]::IsNullOrWhiteSpace($needle)) { continue }
        Assert-WindowsCurrentPathCondition -Condition (-not $Text.Contains($needle)) -Message "$Label leaked a sensitive value."
    }
}

function ConvertTo-WindowsCurrentPathProcessArgument {
    param([string]$Value)

    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $result = '"'
    $backslashCount = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashCount += 1
        }
        elseif ($char -eq '"') {
            $result += ('\' * (($backslashCount * 2) + 1))
            $result += '"'
            $backslashCount = 0
        }
        else {
            if ($backslashCount -gt 0) {
                $result += ('\' * $backslashCount)
                $backslashCount = 0
            }
            $result += $char
        }
    }
    if ($backslashCount -gt 0) {
        $result += ('\' * ($backslashCount * 2))
    }
    $result += '"'
    return $result
}

function Invoke-WindowsCurrentPathRustCli {
    param(
        [string]$RepoRoot,
        [string[]]$CliArguments,
        [int]$TimeoutSeconds = 120
    )

    Assert-WindowsCurrentPathCondition -Condition ($TimeoutSeconds -gt 0) -Message "Rust CLI timeout must be positive."
    $manifestPath = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
    Assert-WindowsCurrentPathCondition -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "Missing Rust Core Cargo manifest: $manifestPath"
    $cargoCommand = (Get-Command cargo -ErrorAction Stop).Source
    $arguments = @(
        "run",
        "--quiet",
        "--manifest-path",
        $manifestPath,
        "--bin",
        "skybridge",
        "--"
    ) + $CliArguments

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $cargoCommand
    $processStartInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsCurrentPathProcessArgument -Value $_ }) -join " ")
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill($true) } catch { $process.Kill() }
        throw "Rust CLI command timed out."
    }

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = [string]$stdoutTask.Result
        Stderr = [string]$stderrTask.Result
    }
}

function Remove-WindowsCurrentPathGeneratedDirectory {
    param(
        [string]$Directory,
        [string]$RequiredLeafPrefix,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $fullDirectory)) { return }

    $leafName = Get-WindowsCurrentPathLeafName -Path $fullDirectory
    Assert-WindowsCurrentPathCondition -Condition ((-not [string]::IsNullOrWhiteSpace($leafName)) -and $leafName.StartsWith($RequiredLeafPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message "$Label cleanup requires a generated directory whose leaf name starts with '$RequiredLeafPrefix': $fullDirectory"
    Assert-WindowsCurrentPathNotReparsePathAncestors -Path $fullDirectory -Label "$Label cleanup"
    Assert-WindowsCurrentPathNotReparsePath -Path $fullDirectory -Label "$Label cleanup"

    foreach ($child in Get-ChildItem -LiteralPath $fullDirectory -Force -Recurse) {
        Assert-WindowsCurrentPathCondition -Condition (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "$Label cleanup refuses to remove a directory containing a reparse point: $($child.FullName)"
    }

    Remove-Item -LiteralPath $fullDirectory -Recurse -Force
}
