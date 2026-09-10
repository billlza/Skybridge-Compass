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

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Script under test does not exist: $Path"
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors)
    Assert-Equal -Expected 0 -Actual $errors.Count -Message "Script under test does not parse: $Path"
    return $ast
}

function Get-SingleFunctionSource {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$Name,
        [string]$ScriptLabel
    )

    $definitions = @($Ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true))
    Assert-Equal -Expected 1 -Actual $definitions.Count -Message "$ScriptLabel must define exactly one $Name function."
    return $definitions[0].Extent.Text
}

# Access rights that a single ACE can grant, paired with what the reverse-relay ACL
# checks must conclude about that ACE. The read column answers "can this principal read
# the private key bytes", the write column answers "can this principal change the file".
#
# ReadAndExecute is the regression case: Set-StrictReadableFileAcl grants exactly that to
# the task service account, and FileSystemRights.Modify / FullControl are composite masks
# that contain every read bit, so deciding "canWrite" by -band against them classified that
# read-only grant as a write and made the registration script reject the ACL it had just
# written itself.
$rightsCases = @(
    @{ Name = "ReadAndExecute"; Rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute; CanRead = $true;  CanWrite = $false },
    @{ Name = "Read";           Rights = [System.Security.AccessControl.FileSystemRights]::Read;           CanRead = $true;  CanWrite = $false },
    @{ Name = "ReadData";       Rights = [System.Security.AccessControl.FileSystemRights]::ReadData;       CanRead = $true;  CanWrite = $false },
    @{ Name = "ReadAttributes"; Rights = [System.Security.AccessControl.FileSystemRights]::ReadAttributes; CanRead = $false; CanWrite = $false },
    @{ Name = "ExecuteFile";    Rights = [System.Security.AccessControl.FileSystemRights]::ExecuteFile;    CanRead = $false; CanWrite = $false },
    @{ Name = "Write";          Rights = [System.Security.AccessControl.FileSystemRights]::Write;          CanRead = $false; CanWrite = $true },
    @{ Name = "WriteData";      Rights = [System.Security.AccessControl.FileSystemRights]::WriteData;      CanRead = $false; CanWrite = $true },
    @{ Name = "AppendData";     Rights = [System.Security.AccessControl.FileSystemRights]::AppendData;     CanRead = $false; CanWrite = $true },
    @{ Name = "WriteAttributes"; Rights = [System.Security.AccessControl.FileSystemRights]::WriteAttributes; CanRead = $false; CanWrite = $true },
    @{ Name = "Delete";         Rights = [System.Security.AccessControl.FileSystemRights]::Delete;         CanRead = $false; CanWrite = $true },
    @{ Name = "ChangePermissions"; Rights = [System.Security.AccessControl.FileSystemRights]::ChangePermissions; CanRead = $false; CanWrite = $true },
    @{ Name = "TakeOwnership";  Rights = [System.Security.AccessControl.FileSystemRights]::TakeOwnership;  CanRead = $false; CanWrite = $true },
    @{ Name = "Modify";         Rights = [System.Security.AccessControl.FileSystemRights]::Modify;         CanRead = $true;  CanWrite = $true },
    @{ Name = "FullControl";    Rights = [System.Security.AccessControl.FileSystemRights]::FullControl;    CanRead = $true;  CanWrite = $true }
)

$scriptsUnderTest = @(
    @{ Label = "register-windows-reverse-ssh-relay-task.ps1"; Path = (Join-Path $RepoRoot "Scripts/register-windows-reverse-ssh-relay-task.ps1") },
    @{ Label = "verify-windows-reverse-ssh-relay-lifecycle.ps1"; Path = (Join-Path $RepoRoot "Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1") }
)

$checked = 0
foreach ($scriptUnderTest in $scriptsUnderTest) {
    $label = [string]$scriptUnderTest.Label
    $path = [string]$scriptUnderTest.Path
    $ast = Get-ParsedScript -Path $path
    $source = Get-Content -LiteralPath $path -Raw

    # Deciding write capability by -band against a composite mask is the defect itself;
    # it must not come back in either script.
    foreach ($compositeMask in @("Modify", "FullControl")) {
        $bannedIdiom = "-band [System.Security.AccessControl.FileSystemRights]::$compositeMask"
        Assert-True -Condition ($source.IndexOf($bannedIdiom, [System.StringComparison]::Ordinal) -lt 0) -Message "$label must not decide access capability by -band against the composite mask $compositeMask."
    }

    $functionSource = Get-SingleFunctionSource -Ast $ast -Name "Get-FileSystemRightsCapability" -ScriptLabel $label
    . ([scriptblock]::Create($functionSource))

    foreach ($case in $rightsCases) {
        $capability = Get-FileSystemRightsCapability -Rights $case.Rights
        Assert-Equal -Expected $case.CanRead -Actual ([bool]$capability.canRead) -Message "$label misread canRead for $($case.Name)."
        Assert-Equal -Expected $case.CanWrite -Actual ([bool]$capability.canWrite) -Message "$label misread canWrite for $($case.Name)."
        $checked++
    }

    # Get-ScheduledTaskInfo().LastTaskResult is a UInt32 HRESULT. Real values such as
    # 0x800710E0 (2147946720) exceed Int32.MaxValue, so an [int] cast throws - and it throws
    # while building evidence, i.e. after the task has already been registered and started.
    # Match the cast applied directly to the .LastTaskResult member access. Matching on the
    # extent text instead would also select the enclosing [ordered]@{...} evidence literal,
    # whose body merely mentions the member.
    $lastTaskResultConversions = @($ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            $node.Child -is [System.Management.Automation.Language.MemberExpressionAst] -and
            ([string]$node.Child.Member.Extent.Text) -ceq "LastTaskResult"
    }, $true))
    Assert-True -Condition ($lastTaskResultConversions.Count -ge 1) -Message "$label must read LastTaskResult through an explicit widening conversion."
    foreach ($conversion in $lastTaskResultConversions) {
        $conversionType = [string]$conversion.Type.TypeName.FullName
        Assert-True -Condition ($conversionType -in @("uint32", "UInt32", "System.UInt32", "long", "Int64", "System.Int64")) -Message "$label reads LastTaskResult as [$conversionType]; it is a UInt32 HRESULT and values above Int32.MaxValue throw, aborting evidence writing after the task is already registered."
    }

    # Every ACE loop in the script must route through the shared capability decision
    # rather than re-deriving it inline.
    $capabilityCallCount = @($ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq "Get-FileSystemRightsCapability"
    }, $true)).Count
    Assert-True -Condition ($capabilityCallCount -ge 1) -Message "$label must call Get-FileSystemRightsCapability from its ACL evaluation."
}

# The scheduled task must launch powershell.exe as a bare
# "-NoProfile -NonInteractive -File <script>": the lifecycle verifier fails closed on any
# ExecutionPolicy, Bypass, EncodedCommand or interpreter indirection in that command line, so the
# registration script must not smuggle a policy override in to make a Restricted machine work.
$registerPath = Join-Path $RepoRoot "Scripts/register-windows-reverse-ssh-relay-task.ps1"
$registerAst = Get-ParsedScript -Path $registerPath
$registerSource = Get-Content -LiteralPath $registerPath -Raw

$argumentAssignments = @($registerAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq "taskArgumentsList"
}, $true))
Assert-Equal -Expected 1 -Actual $argumentAssignments.Count -Message "Registration must build exactly one scheduled-task argument list."

$literalArguments = @($argumentAssignments[0].Right.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
}, $true) | ForEach-Object { $_.Value })

Assert-True -Condition ($literalArguments.IndexOf("-NoProfile") -ge 0) -Message "Scheduled-task arguments must pass -NoProfile."
Assert-True -Condition ($literalArguments.IndexOf("-NonInteractive") -ge 0) -Message "Scheduled-task arguments must pass -NonInteractive."
Assert-True -Condition ($literalArguments.IndexOf("-File") -ge 0) -Message "Scheduled-task arguments must pass -File."
foreach ($forbidden in @("-ExecutionPolicy", "Bypass", "Unrestricted", "-EncodedCommand", "-Command")) {
    Assert-True -Condition ($literalArguments.IndexOf($forbidden) -lt 0) -Message "Scheduled-task arguments must not contain $forbidden; the lifecycle verifier fails closed on it."
}

# Because the command line may not relax policy, the machine policy is a precondition of the
# task ever starting. Registration must fail loudly on a Restricted machine instead of reporting
# success for a task that exits 1 before the start script can log anything.
$policyFunctions = @($registerAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Get-TaskAccountExecutionPolicy"
}, $true))
Assert-Equal -Expected 1 -Actual $policyFunctions.Count -Message "Registration must define exactly one Get-TaskAccountExecutionPolicy function."
. ([scriptblock]::Create($policyFunctions[0].Extent.Text))
$policyFunctionSource = $policyFunctions[0].Extent.Text
foreach ($perUserScope in @('"Process"', '"CurrentUser"')) {
    Assert-True -Condition ($policyFunctionSource.IndexOf($perUserScope, [System.StringComparison]::Ordinal) -lt 0) -Message "Task execution policy must not be read from the $perUserScope scope; that scope belongs to whoever runs the registration, not to the task service account."
}
Assert-True -Condition ($registerSource.IndexOf('$taskAccountExecutionPolicy -ne "Restricted"', [System.StringComparison]::Ordinal) -ge 0) -Message "Registration must refuse to register when the task account's execution policy resolves to Restricted."
Assert-True -Condition ($registerSource.IndexOf('$taskAccountExecutionPolicy -eq "AllSigned"', [System.StringComparison]::Ordinal) -ge 0) -Message "Registration must require a valid signature on the installed start script when the machine policy is AllSigned."
Assert-True -Condition ($registerSource.IndexOf("taskAccountExecutionPolicy = `$taskAccountExecutionPolicy", [System.StringComparison]::Ordinal) -ge 0) -Message "Registration evidence must record the execution policy the task account will run under."

# Durability contract: a boot-only trigger leaves the tunnel down until the next reboot,
# because RestartCount only replaces an instance Task Scheduler itself started and saw fail.
# The registration must also install a repeating trigger, and the verifier must refuse to
# accept a task that lacks either one.
function Get-SingleAssignmentRight {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$VariableName,
        [string]$ScriptLabel
    )

    $assignments = @($Ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq $VariableName
    }, $true))
    Assert-Equal -Expected 1 -Actual $assignments.Count -Message "$ScriptLabel must assign `$$VariableName exactly once."
    return $assignments[0].Right.Extent.Text
}

$selfHealTriggerSource = Get-SingleAssignmentRight -Ast $registerAst -VariableName "selfHealTrigger" -ScriptLabel "register-windows-reverse-ssh-relay-task.ps1"
Assert-True -Condition ($selfHealTriggerSource.IndexOf("-RepetitionInterval", [System.StringComparison]::Ordinal) -ge 0) -Message "The self-heal trigger must repeat on an interval."
Assert-True -Condition ($selfHealTriggerSource.IndexOf("SelfHealIntervalMinutes", [System.StringComparison]::Ordinal) -ge 0) -Message "The self-heal repetition interval must come from the SelfHealIntervalMinutes parameter."

# Measured on Windows 11 26200: -RepetitionDuration ([TimeSpan]::MaxValue) serialises to
# P99999999DT23H59M59S and Register-ScheduledTask rejects the whole task XML, while any finite
# duration stops the repetition when it elapses. Only an empty duration repeats forever, and it
# has to be assigned after construction because New-ScheduledTaskTrigger cannot express it.
# Look at parameter nodes, not raw text: the surrounding comment names -RepetitionDuration on
# purpose, and a text search would flag the explanation instead of the code.
$repetitionDurationArguments = @($registerAst.FindAll({
    param($node)
    return $node -is [System.Management.Automation.Language.CommandParameterAst] -and
        $node.ParameterName -ceq "RepetitionDuration"
}, $true))
Assert-Equal -Expected 0 -Actual $repetitionDurationArguments.Count -Message "Do not pass -RepetitionDuration: TimeSpan::MaxValue is rejected by Task Scheduler and a finite value silently ends self-healing."
Assert-True -Condition ($registerSource.IndexOf("`$selfHealTrigger.Repetition.Duration = ''", [System.StringComparison]::Ordinal) -ge 0) -Message "The self-heal repetition duration must be cleared to empty so the trigger repeats indefinitely."
Assert-True -Condition ($registerSource.IndexOf("`$selfHealTrigger.Repetition.StopAtDurationEnd = `$false", [System.StringComparison]::Ordinal) -ge 0) -Message "StopAtDurationEnd must be explicitly false for an indefinite self-heal repetition."

$triggerSource = Get-SingleAssignmentRight -Ast $registerAst -VariableName "trigger" -ScriptLabel "register-windows-reverse-ssh-relay-task.ps1"
foreach ($required in @('$startupTrigger', '$selfHealTrigger')) {
    Assert-True -Condition ($triggerSource.IndexOf($required, [System.StringComparison]::Ordinal) -ge 0) -Message "The registered trigger set must include $required; a boot-only task cannot recover a dead tunnel before the next reboot."
}

$verifierPath = Join-Path $RepoRoot "Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1"
$verifierAst = Get-ParsedScript -Path $verifierPath
$acceptedSource = Get-SingleAssignmentRight -Ast $verifierAst -VariableName "accepted" -ScriptLabel "verify-windows-reverse-ssh-relay-lifecycle.ps1"
foreach ($required in @('$bootTriggerPresent', '$selfHealTriggerPresent')) {
    Assert-True -Condition ($acceptedSource.IndexOf($required, [System.StringComparison]::Ordinal) -ge 0) -Message "Lifecycle acceptance must require $required; otherwise a task with no self-heal trigger still passes the gate."
}

Write-Output ("reverse-ssh-relay registration checks passed: {0} ACL assertions across {1} scripts, plus scheduled-task argument composition and execution-policy preconditions" -f ($checked * 2), $scriptsUnderTest.Count)
exit 0
