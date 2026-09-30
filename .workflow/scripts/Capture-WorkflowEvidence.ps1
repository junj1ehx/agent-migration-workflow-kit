[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$OwnerToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$snapshot = Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    Assert-WorkflowOwner -State $state -OwnerToken $OwnerToken
    if ([string]$state.status -ne 'verifying') { throw 'Evidence may be captured only in verifying state.' }
    $taskHash = Get-WorkflowFileSha256 -Path ([string]$state.taskContractPath)
    if ($taskHash -ne [string]$state.taskContractSha256) { throw 'Task contract changed after initialization.' }
    $candidate = Get-WorkflowCandidateIdentity -WorktreePath ([string]$state.worktree.path)
    if (-not $candidate.Clean) { throw 'Commit all candidate changes before evidence capture.' }
    if ($candidate.HeadCommit -eq [string]$state.repository.baseCommit) { throw 'Candidate HEAD is unchanged from the task base commit.' }
    $contract = Read-WorkflowJson -Path ([string]$state.taskContractPath)
    Assert-WorkflowExecutionBudget -State $state -Contract $contract | Out-Null
    $scope = Test-WorkflowCandidateScope -WorktreePath ([string]$state.worktree.path) -BaseCommit ([string]$state.repository.baseCommit) -Scope $contract.scope
    if (-not $scope.Passed) { throw "Candidate changes files outside the permitted scope: $($scope.Violations -join ', ')" }
    return [pscustomobject]@{
        State = $state
        Candidate = $candidate
        Contract = $contract
        Scope = $scope
    }
}

$checkResults = [Collections.Generic.List[object]]::new()
foreach ($criterion in @($snapshot.Contract.acceptanceCriteria)) {
    $relativeWorking = if ($null -eq $criterion.command.PSObject.Properties['workingDirectory']) { '.' } else { [string]$criterion.command.workingDirectory }
    $workingDirectory = Get-WorkflowCanonicalPath -Path (Join-Path ([string]$snapshot.State.worktree.path) $relativeWorking) -MustExist
    $worktreePath = Get-WorkflowCanonicalPath -Path ([string]$snapshot.State.worktree.path) -MustExist
    if ($workingDirectory -ne $worktreePath -and -not (Test-WorkflowPathWithin -Candidate $workingDirectory -Parent $worktreePath)) {
        throw "Acceptance criterion $($criterion.id) escapes the worktree."
    }
    $remainingSeconds = Assert-WorkflowExecutionBudget -State $snapshot.State -Contract $snapshot.Contract
    $checkTimeout = [Math]::Min([int]$criterion.command.timeoutSeconds, $remainingSeconds)
    $resolvedArguments = @($criterion.command.arguments | ForEach-Object {
        if ([string]$_ -eq '{baseCommit}') { [string]$snapshot.State.repository.baseCommit }
        elseif ([string]$_ -eq '{headCommit}') { [string]$snapshot.Candidate.HeadCommit }
        else { [string]$_ }
    })
    $result = Invoke-WorkflowProcess `
        -Executable ([string]$criterion.command.executable) `
        -Arguments $resolvedArguments `
        -WorkingDirectory $workingDirectory `
        -TimeoutSeconds $checkTimeout
    $passed = -not $result.TimedOut -and $result.ExitCode -eq 0
    $checkResults.Add([pscustomobject][ordered]@{
        id = [string]$criterion.id
        executable = [string]$criterion.command.executable
        arguments = $resolvedArguments
        workingDirectory = $workingDirectory
        exitCode = $result.ExitCode
        timedOut = [bool]$result.TimedOut
        durationMs = [int64]$result.DurationMs
        stdoutSha256 = Get-WorkflowStringSha256 -Value ([string]$result.StdOut)
        stderrSha256 = Get-WorkflowStringSha256 -Value ([string]$result.StdErr)
        passed = [bool]$passed
    })
}

$allPassed = @($checkResults | Where-Object { -not $_.passed }).Count -eq 0
$evidencePath = Join-Path (Get-WorkflowCanonicalPath -Path $RunDirectory -MustExist) 'evidence.json'
$evidence = [pscustomobject][ordered]@{
    schemaVersion = '1.0'
    runId = [string]$snapshot.State.runId
    taskId = [string]$snapshot.State.taskId
    taskRevision = [int]$snapshot.State.taskRevision
    taskContractSha256 = [string]$snapshot.State.taskContractSha256
    capturedAtUtc = Get-WorkflowUtcNow
    baseCommit = [string]$snapshot.State.repository.baseCommit
    headCommit = [string]$snapshot.Candidate.HeadCommit
    headTree = [string]$snapshot.Candidate.HeadTree
    worktreeClean = $true
    changedPaths = @($snapshot.Scope.ChangedPaths)
    historyPaths = @($snapshot.Scope.HistoryPaths)
    scopePassed = $true
    checks = @($checkResults)
    allChecksPassed = [bool]$allPassed
}

Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $current = Read-WorkflowRunState -RunDirectory $RunDirectory
    Assert-WorkflowOwner -State $current -OwnerToken $OwnerToken
    if ([string]$current.status -ne 'verifying') { throw 'Run state changed while checks were executing.' }
    if ([string]$current.taskContractSha256 -ne [string]$snapshot.State.taskContractSha256) { throw 'Task identity changed while checks were executing.' }
    $after = Get-WorkflowCandidateIdentity -WorktreePath ([string]$current.worktree.path)
    if (-not $after.Clean -or $after.HeadCommit -ne $snapshot.Candidate.HeadCommit -or $after.HeadTree -ne $snapshot.Candidate.HeadTree) {
        throw 'Candidate changed while checks were executing; evidence was not recorded.'
    }
    $afterScope = Test-WorkflowCandidateScope -WorktreePath ([string]$current.worktree.path) -BaseCommit ([string]$current.repository.baseCommit) -Scope $snapshot.Contract.scope
    if (-not $afterScope.Passed) { throw 'Candidate file scope changed while checks were executing.' }
    if (@(Compare-Object -ReferenceObject @($snapshot.Scope.HistoryPaths) -DifferenceObject @($afterScope.HistoryPaths)).Count -gt 0) {
        throw 'Candidate commit history changed while checks were executing.'
    }
    Write-WorkflowJsonAtomic -Path $evidencePath -Value $evidence
    $current.evidencePath = $evidencePath
    $current.evidenceSha256 = Get-WorkflowFileSha256 -Path $evidencePath
    $current.timestamps.updatedAtUtc = Get-WorkflowUtcNow
    Add-WorkflowEvent -RunDirectory $RunDirectory -State $current -Type 'evidence_captured' -Data @{
        evidencePath = $evidencePath
        headCommit = $evidence.headCommit
        headTree = $evidence.headTree
        allChecksPassed = $evidence.allChecksPassed
    }
    Write-WorkflowJsonAtomic -Path (Join-Path $RunDirectory 'state.json') -Value $current
}

return $evidence
