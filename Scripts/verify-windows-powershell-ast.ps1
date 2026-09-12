param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string[]]$RelativePaths = @()
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

function Get-RelativePathForReport {
    param(
        [string]$Root,
        [string]$Path
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ([string]::Equals($normalizedPath, $normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }

    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedPath.Substring($rootPrefix.Length)
    }

    return $normalizedPath
}

function Test-IsPathUnderRoot {
    param(
        [string]$Root,
        [string]$Path
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ([string]::Equals($normalizedPath, $normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RepoRelativePath {
    param([string]$RelativePath)

    Assert-True -Condition (-not [System.IO.Path]::IsPathRooted($RelativePath)) -Message "RelativePaths entries must be repo-relative: $RelativePath"
    $segments = @($RelativePath -split '[\\/]')
    Assert-True -Condition (-not ($segments | Where-Object { $_ -eq ".." })) -Message "RelativePaths entries must not traverse parent directories: $RelativePath"
}

$resolvedRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
$scriptRoot = Join-Path $resolvedRepoRoot "Scripts"
Assert-True -Condition (Test-Path -LiteralPath $scriptRoot -PathType Container) -Message "Missing Scripts directory: $scriptRoot"

$scriptPaths = [System.Collections.Generic.List[string]]::new()
if ($RelativePaths.Count -gt 0) {
    foreach ($relativePath in $RelativePaths) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($relativePath)) -Message "RelativePaths must not contain empty entries."
        Assert-RepoRelativePath -RelativePath $relativePath
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $resolvedRepoRoot $relativePath))
        Assert-True -Condition (Test-IsPathUnderRoot -Root $resolvedRepoRoot -Path $resolvedPath) -Message "PowerShell script path escapes the repo root: $relativePath"
        Assert-True -Condition (Test-Path -LiteralPath $resolvedPath -PathType Leaf) -Message "Missing PowerShell script: $resolvedPath"
        Assert-True -Condition ([System.IO.Path]::GetExtension($resolvedPath) -eq ".ps1") -Message "PowerShell AST gate only accepts .ps1 files: $resolvedPath"
        $scriptPaths.Add($resolvedPath)
    }
}
else {
    Get-ChildItem -LiteralPath $scriptRoot -Filter "*.ps1" -File |
        Sort-Object -Property FullName |
        ForEach-Object { $scriptPaths.Add($_.FullName) }
}

Assert-True -Condition ($scriptPaths.Count -gt 0) -Message "No PowerShell scripts selected for AST validation."

$forbiddenCommandNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$forbiddenCommandNames.Add("Invoke-Expression")
[void]$forbiddenCommandNames.Add("iex")

$parsedCount = 0
foreach ($scriptPath in $scriptPaths) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors)
    $relativePath = Get-RelativePathForReport -Root $resolvedRepoRoot -Path $scriptPath

    if ($errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" })
        throw "$relativePath parse failed: $($messages -join '; ')"
    }

    $forbiddenCommands = @($ast.FindAll({
        param($node)

        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }

        $commandName = $node.GetCommandName()
        return -not [string]::IsNullOrWhiteSpace($commandName) -and $forbiddenCommandNames.Contains($commandName)
    }, $true))

    if ($forbiddenCommands.Count -gt 0) {
        $locations = @($forbiddenCommands | ForEach-Object {
            "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.GetCommandName())"
        })
        throw "$relativePath uses forbidden dynamic PowerShell execution: $($locations -join '; ')"
    }

    $parsedCount += 1
    Write-Output "windows-powershell-ast: parse-ok $relativePath"
}

Write-Output "windows-powershell-ast: parsed=$parsedCount"
Write-Output "windows-powershell-ast: ok"
