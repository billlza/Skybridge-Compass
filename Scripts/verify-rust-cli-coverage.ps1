param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [double]$MinimumLineCoverage = 90.0
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

function Get-LineCoverage {
    param(
        [string]$CoverageText,
        [string]$RowName
    )

    $line = ($CoverageText -split "\r?\n") |
        Where-Object { $_ -match "^\s*$([regex]::Escape($RowName))\s+" } |
        Select-Object -First 1
    Assert-True -Condition ($null -ne $line) -Message "Coverage row missing: $RowName"

    $matches = [regex]::Matches($line, "([0-9]+(?:\.[0-9]+)?)%")
    Assert-True -Condition ($matches.Count -ge 3) -Message "Coverage row does not include line coverage: $line"
    return [double]::Parse($matches[2].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

$coreRoot = Join-Path $RepoRoot "core/skybridge-core"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "Cargo.toml")) -Message "Missing Rust core Cargo.toml: $coreRoot"

Push-Location $coreRoot
try {
    & cargo test
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "cargo test failed."

    $coverageOutput = & cargo llvm-cov --fail-under-lines $MinimumLineCoverage --summary-only 2>&1
    $coverageExitCode = $LASTEXITCODE
    $coverageText = $coverageOutput -join "`n"
    Write-Output $coverageText
    Assert-True -Condition ($coverageExitCode -eq 0) -Message "cargo llvm-cov failed or total line coverage is below $MinimumLineCoverage%."

    $totalLineCoverage = Get-LineCoverage -CoverageText $coverageText -RowName "TOTAL"
    $cliLineCoverage = Get-LineCoverage -CoverageText $coverageText -RowName "cli.rs"
    Assert-True -Condition ($totalLineCoverage -ge $MinimumLineCoverage) -Message "Total line coverage $totalLineCoverage% is below $MinimumLineCoverage%."
    Assert-True -Condition ($cliLineCoverage -ge $MinimumLineCoverage) -Message "cli.rs line coverage $cliLineCoverage% is below $MinimumLineCoverage%."
}
finally {
    Pop-Location
}

Write-Output "rust-cli-coverage: ok"
