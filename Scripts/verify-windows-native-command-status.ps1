param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$EvidenceRoot = (Join-Path ([IO.Path]::GetTempPath()) ("skybridge-command-status-" + [guid]::NewGuid().ToString("N")))
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Read-Function([string]$ScriptName, [string]$FunctionName) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot "Scripts/$ScriptName"), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Cannot parse $ScriptName"
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
    }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $FunctionName definition"
    return $definitions[0].Body.GetScriptBlock()
}

# Load the actual command wrappers without executing the surrounding release workflow.
Set-Item Function:Invoke-SkybridgeCli (Read-Function "verify-apple-native-preservation.ps1" "Invoke-SkybridgeCli")
Set-Item Function:Invoke-SmokeGate (Read-Function "verify-windows-portability-smoke.ps1" "Invoke-SmokeGate")
Set-Item Function:Invoke-InteropGate (Read-Function "verify-windows-mac-webrtc-interop.ps1" "Invoke-InteropGate")

$script:gateRecords = [Collections.Generic.List[object]]::new()
$script:evidenceWrites = 0
function Add-SmokeGateResult([string]$Name, [string]$Status, [string]$Detail, [string]$EvidencePath) {
    $script:gateRecords.Add(@{name=$Name;status=$Status;detail=$Detail})
}
function Write-AcceptanceEvidence { $script:evidenceWrites += 1 }

Assert-True (-not (Test-Path -LiteralPath $EvidenceRoot)) "Evidence root already exists"
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
$probeShell = (Get-Process -Id $PID).Path
$shellLiteral = $probeShell.Replace("'", "''")
$fixtures = @{
    "exit23.ps1" = "Write-Output 'looks successful'; exit 23"
    "throws.ps1" = "throw 'intentional gate failure'"
    "passes.ps1" = "Write-Output 'validated success'"
    "handles-native-failure.ps1" = "& '$shellLiteral' -NoProfile -NonInteractive -Command 'exit 23'; if (`$LASTEXITCODE -ne 23) { throw 'native fixture did not fail as expected' }; Write-Output 'expected failure verified'"
}
foreach ($name in $fixtures.Keys) {
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot $name), $fixtures[$name], [Text.UTF8Encoding]::new($false))
}

$sourceRepoRoot = $RepoRoot
$RepoRoot = $EvidenceRoot
$results = [Collections.Generic.List[object]]::new()
foreach ($wrapper in @("Invoke-SmokeGate", "Invoke-InteropGate")) {
    foreach ($fixture in @("exit23.ps1", "throws.ps1", "passes.ps1", "handles-native-failure.ps1")) {
        $rejected = $false
        try { & $wrapper -Name $fixture -RelativeScriptPath $fixture -Parameters @{} | Out-Null }
        catch { $rejected = $true }
        $expectedRejection = $fixture -in @("exit23.ps1", "throws.ps1")
        Assert-True ($rejected -eq $expectedRejection) "$wrapper returned the wrong outcome for $fixture"
        $results.Add(@{wrapper=$wrapper;fixture=$fixture;rejected=$rejected})
    }
}
Assert-True (@($script:gateRecords | Where-Object { $_.name -eq "exit23.ps1" -and $_.status -eq "passed" }).Count -eq 0) "Failed script was recorded as passed"
Assert-True ($script:evidenceWrites -eq 2) "Both failed smoke gates must record their failure evidence"

# A real child process emits plausible success text and fails. The CLI wrapper
# must report the native status before any caller inspects that text.
$coreManifest = Join-Path $EvidenceRoot "unused-manifest.toml"
function cargo {
    & $probeShell -NoProfile -NonInteractive -Command "Write-Output 'kind=AppleNative'; exit 23"
}
$nativeRejected = $false
try { Invoke-SkybridgeCli -Arguments @("transport", "select") | Out-Null }
catch { $nativeRejected = $_.Exception.Message.Contains("CLI command failed exitCode=23") }
Assert-True $nativeRejected "CLI wrapper failed to propagate the real native exit code"
$results.Add(@{wrapper="Invoke-SkybridgeCli";fixture="native process exit 23";rejected=$nativeRejected})

[ordered]@{status="PASS";sourceRoot=$sourceRepoRoot;cases=$results;gateRecords=$script:gateRecords} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot "result.json") -Encoding UTF8
Write-Output "windows-native-command-status: cases=$($results.Count) ok"
