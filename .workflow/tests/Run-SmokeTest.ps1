[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workflowScripts = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-workflow-smoke-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $testRoot 'source'
$worktree = Join-Path $testRoot 'worktree'
$stateRoot = Join-Path $testRoot 'state'
$contractPath = Join-Path $testRoot 'task.json'
$ownerId = 'smoke-test-owner'

function Invoke-TestGit {
    param([Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][string[]]$Arguments)
    $result = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $result" }
    return ($result -join "`n").Trim()
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message, [string]$ExpectedPattern = '.')
    $threw = $false
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $ExpectedPattern) { throw "Assertion failed: unexpected error for ${Message}: $($_.Exception.Message)" }
        $threw = $true
    }
    if (-not $threw) { throw "Assertion failed: expected failure: $Message" }
}

$result = [ordered]@{
    happyPath = $false
    wrongOwnerRejected = $false
    invalidTransitionRejected = $false
    dirtyEvidenceRejected = $false
    staleEvidenceRejected = $false
    prematureCleanupRejected = $false
    integratedAncestryRequired = $false
    nestedWorktreeRejected = $false
    unapprovedModelRejected = $false
    unapprovedExecutableRejected = $false
    unknownFieldRejected = $false
    safeCleanup = $false
    scopeHistoryRejected = $false
    reviewRecordBound = $false
    evidenceTamperRejected = $false
    selfReviewRejected = $false
    retryBudgetEnforced = $false
    elapsedBudgetEnforced = $false
    reviewPacketExported = $false
    artifactsMatchSchemas = $false
}

try {
    [IO.Directory]::CreateDirectory($repository) | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('init', '--initial-branch=main') | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('config', 'user.name', 'Workflow Smoke Test') | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('config', 'user.email', 'workflow-smoke@example.invalid') | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('config', 'core.hooksPath', (Join-Path $testRoot 'disabled-hooks')) | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('config', 'commit.gpgsign', 'false') | Out-Null
    [IO.File]::WriteAllText((Join-Path $repository 'README.md'), "# Fixture`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('add', 'README.md') | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('commit', '-m', 'fixture baseline') | Out-Null

    $contract = [ordered]@{
        schemaVersion = '1.0'
        taskId = 'smoke-safe-loop'
        revision = 1
        objective = 'Exercise the minimum safe workflow loop.'
        nonGoals = @('No network', 'No remote push')
        repository = [ordered]@{ root = $repository; baseRef = 'HEAD' }
        worktree = [ordered]@{ path = $worktree; branch = 'agent/smoke-safe-loop' }
        scope = [ordered]@{ writablePaths = @('README.md'); protectedPaths = @('.github/', '.agents/') }
        modelPolicy = [ordered]@{ allowedFamilies = @('openai', 'gemini'); allowedModelIds = @(); allowAutomaticFallback = $false }
        toolPolicy = [ordered]@{ allowedExecutables = @('git'); allowNetwork = $false }
        acceptanceCriteria = @(
            [ordered]@{
                id = 'diff-check'
                description = 'Git diff has no whitespace errors.'
                command = [ordered]@{ executable = 'git'; arguments = @('diff', '--check', 'HEAD^', 'HEAD'); workingDirectory = '.'; timeoutSeconds = 30 }
            }
        )
        budgets = [ordered]@{ elapsedMinutes = 10; retryLimit = 1; reviewCycles = 0 }
        review = [ordered]@{ required = $false }
    }
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    [IO.File]::WriteAllText($contractPath, (($contract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))

    $nestedContractPath = Join-Path $testRoot 'nested-task.json'
    $nestedContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $nestedContract.taskId = 'smoke-nested-reject'
    $nestedContract.worktree.path = Join-Path $repository 'nested-worktree'
    $nestedContract.worktree.branch = 'agent/smoke-nested-reject'
    [IO.File]::WriteAllText($nestedContractPath, (($nestedContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-Throws -Message 'nested worktree path rejected' -Action {
        & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $nestedContractPath -StateRoot $stateRoot -OwnerId $ownerId
    }
    $result.nestedWorktreeRejected = $true

    $modelContractPath = Join-Path $testRoot 'model-task.json'
    $modelContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $modelContract.taskId = 'smoke-model-reject'
    $modelContract.worktree.path = Join-Path $testRoot 'model-worktree'
    $modelContract.worktree.branch = 'agent/smoke-model-reject'
    $modelContract.modelPolicy.allowedFamilies = @('unapproved-provider')
    [IO.File]::WriteAllText($modelContractPath, (($modelContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-Throws -Message 'unapproved model family rejected' -Action {
        & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $modelContractPath -StateRoot $stateRoot -OwnerId $ownerId
    }
    $result.unapprovedModelRejected = $true

    $toolContractPath = Join-Path $testRoot 'tool-task.json'
    $toolContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $toolContract.taskId = 'smoke-tool-reject'
    $toolContract.worktree.path = Join-Path $testRoot 'tool-worktree'
    $toolContract.worktree.branch = 'agent/smoke-tool-reject'
    $toolContract.acceptanceCriteria[0].command.executable = 'pwsh'
    [IO.File]::WriteAllText($toolContractPath, (($toolContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-Throws -Message 'verification executable outside tool allowlist rejected' -Action {
        & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $toolContractPath -StateRoot $stateRoot -OwnerId $ownerId
    }
    $result.unapprovedExecutableRejected = $true

    $unknownContractPath = Join-Path $testRoot 'unknown-task.json'
    $unknownContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $unknownContract.taskId = 'smoke-unknown-reject'
    $unknownContract.worktree.path = Join-Path $testRoot 'unknown-worktree'
    $unknownContract.worktree.branch = 'agent/smoke-unknown-reject'
    $unknownContract | Add-Member -NotePropertyName 'unexpectedAuthority' -NotePropertyValue 'allow'
    [IO.File]::WriteAllText($unknownContractPath, (($unknownContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-Throws -Message 'unknown top-level policy field rejected' -Action {
        & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $unknownContractPath -StateRoot $stateRoot -OwnerId $ownerId
    }
    $result.unknownFieldRejected = $true

    $run = & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $contractPath -StateRoot $stateRoot -OwnerId $ownerId
    Assert-True -Condition ($run.Status -eq 'ready') -Message 'run initializes to ready'

    Assert-Throws -Message 'ready cannot skip directly to accepted' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To accepted -Reason 'invalid skip'
    }
    $result.invalidTransitionRejected = $true

    $earlyCleanup = & (Join-Path $workflowScripts 'Test-WorkflowCleanup.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken
    Assert-True -Condition (-not $earlyCleanup.Eligible) -Message 'cleanup rejected before completion'
    $result.prematureCleanupRejected = $true

    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To running -Reason 'start implementation' | Out-Null
    [IO.File]::AppendAllText((Join-Path $worktree 'README.md'), "safe change`n", [Text.UTF8Encoding]::new($false))

    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To verifying -Reason 'attempt dirty verification' | Out-Null
    Assert-Throws -Message 'dirty worktree cannot produce evidence' -Action {
        & (Join-Path $workflowScripts 'Capture-WorkflowEvidence.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken
    }
    $result.dirtyEvidenceRejected = $true

    Invoke-TestGit -WorkingDirectory $worktree -Arguments @('add', 'README.md') | Out-Null
    Invoke-TestGit -WorkingDirectory $worktree -Arguments @('commit', '-m', 'candidate change') | Out-Null
    $evidence = & (Join-Path $workflowScripts 'Capture-WorkflowEvidence.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken
    Assert-True -Condition ([bool]$evidence.allChecksPassed) -Message 'declared verification passes'
    $storedEvidencePath = Join-Path $run.RunDirectory 'evidence.json'
    $originalEvidenceBytes = [IO.File]::ReadAllBytes($storedEvidencePath)
    [IO.File]::AppendAllText($storedEvidencePath, ' ')
    Assert-Throws -Message 'modified evidence rejected' -ExpectedPattern 'Evidence bundle changed after capture' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To accepted -Reason 'tampered evidence'
    }
    [IO.File]::WriteAllBytes($storedEvidencePath, $originalEvidenceBytes)
    $result.evidenceTamperRejected = $true

    Assert-Throws -Message 'wrong owner token rejected' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken 'wrong-token' -To accepted -Reason 'unauthorized'
    }
    $result.wrongOwnerRejected = $true

    [IO.File]::AppendAllText((Join-Path $worktree 'README.md'), "stale evidence probe`n", [Text.UTF8Encoding]::new($false))
    Assert-Throws -Message 'dirty change invalidates evidence' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To accepted -Reason 'stale evidence'
    }
    Invoke-TestGit -WorkingDirectory $worktree -Arguments @('restore', 'README.md') | Out-Null
    $result.staleEvidenceRejected = $true

    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To accepted -Reason 'checks passed' | Out-Null
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To landing -Reason 'begin local integration simulation' | Out-Null

    Assert-Throws -Message 'completion requires integrated ancestry' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To completed -Reason 'bad integration' -IntegrationCommit 'HEAD'
    }
    $result.integratedAncestryRequired = $true

    Invoke-TestGit -WorkingDirectory $repository -Arguments @('merge', '--ff-only', 'agent/smoke-safe-loop') | Out-Null
    $integrationCommit = Invoke-TestGit -WorkingDirectory $repository -Arguments @('rev-parse', 'HEAD')
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -To completed -Reason 'candidate integrated' -IntegrationCommit $integrationCommit | Out-Null

    $cleanup = & (Join-Path $workflowScripts 'Test-WorkflowCleanup.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken
    Assert-True -Condition ([bool]$cleanup.Eligible) -Message 'completed integrated clean run is cleanup eligible'
    $dryRun = & (Join-Path $workflowScripts 'Remove-WorkflowWorktree.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken
    Assert-True -Condition ([bool]$dryRun.DryRun -and -not [bool]$dryRun.Removed) -Message 'cleanup defaults to dry-run'
    $removed = & (Join-Path $workflowScripts 'Remove-WorkflowWorktree.ps1') -RunDirectory $run.RunDirectory -OwnerToken $run.OwnerToken -Execute -Confirm:$false
    Assert-True -Condition ([bool]$removed.Removed) -Message 'verified worktree removed'
    Assert-True -Condition (-not (Test-Path -LiteralPath $worktree)) -Message 'worktree path no longer exists'
    $result.safeCleanup = $true
    $result.happyPath = $true

    $scopeContractPath = Join-Path $testRoot 'scope-task.json'
    $scopeContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $scopeContract.taskId = 'smoke-scope-history'
    $scopeContract.worktree.path = Join-Path $testRoot 'scope-worktree'
    $scopeContract.worktree.branch = 'agent/smoke-scope-history'
    [IO.File]::WriteAllText($scopeContractPath, (($scopeContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    $scopeRun = & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $scopeContractPath -StateRoot $stateRoot -OwnerId $ownerId
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken -To running -Reason 'scope test' | Out-Null
    [IO.File]::WriteAllText((Join-Path $scopeRun.WorktreePath 'FORBIDDEN.md'), "temporary forbidden content`n")
    Invoke-TestGit -WorkingDirectory $scopeRun.WorktreePath -Arguments @('add', 'FORBIDDEN.md') | Out-Null
    Invoke-TestGit -WorkingDirectory $scopeRun.WorktreePath -Arguments @('commit', '-m', 'temporary forbidden edit') | Out-Null
    [IO.File]::Delete((Join-Path $scopeRun.WorktreePath 'FORBIDDEN.md'))
    [IO.File]::AppendAllText((Join-Path $scopeRun.WorktreePath 'README.md'), "allowed final edit`n")
    Invoke-TestGit -WorkingDirectory $scopeRun.WorktreePath -Arguments @('add', '-A') | Out-Null
    Invoke-TestGit -WorkingDirectory $scopeRun.WorktreePath -Arguments @('commit', '-m', 'remove forbidden edit and keep allowed edit') | Out-Null
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken -To verifying -Reason 'scope history candidate' | Out-Null
    Assert-Throws -Message 'historical out-of-scope edit rejected despite final diff' -ExpectedPattern 'outside the permitted scope' -Action {
        & (Join-Path $workflowScripts 'Capture-WorkflowEvidence.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken
    }
    $result.scopeHistoryRejected = $true
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken -To running -Reason 'first retry' | Out-Null
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken -To verifying -Reason 'retry candidate' | Out-Null
    Assert-Throws -Message 'second retry blocked' -ExpectedPattern 'retry budget is exhausted' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken -To running -Reason 'excess retry'
    }
    $result.retryBudgetEnforced = $true
    $expiredStatePath = Join-Path $scopeRun.RunDirectory 'state.json'
    $expiredState = Get-Content -LiteralPath $expiredStatePath -Raw | ConvertFrom-Json
    $expiredState.timestamps.createdAtUtc = [DateTime]::UtcNow.AddHours(-2).ToString('o')
    [IO.File]::WriteAllText($expiredStatePath, ($expiredState | ConvertTo-Json -Depth 30))
    Assert-Throws -Message 'elapsed budget blocked' -ExpectedPattern 'elapsed-time budget is exhausted' -Action {
        & (Join-Path $workflowScripts 'Capture-WorkflowEvidence.ps1') -RunDirectory $scopeRun.RunDirectory -OwnerToken $scopeRun.OwnerToken
    }
    $result.elapsedBudgetEnforced = $true

    $reviewContractPath = Join-Path $testRoot 'review-task.json'
    $reviewContract = ($contract | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
    $reviewContract.taskId = 'smoke-review-bound'
    $reviewContract.worktree.path = Join-Path $testRoot 'review-worktree'
    $reviewContract.worktree.branch = 'agent/smoke-review-bound'
    $reviewContract.review.required = $true
    $reviewContract.budgets.reviewCycles = 1
    [IO.File]::WriteAllText($reviewContractPath, (($reviewContract | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    $reviewRun = & (Join-Path $workflowScripts 'Initialize-WorkflowRun.ps1') -TaskContractPath $reviewContractPath -StateRoot $stateRoot -OwnerId $ownerId
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To running -Reason 'review test' | Out-Null
    [IO.File]::AppendAllText((Join-Path $reviewRun.WorktreePath 'README.md'), "reviewed edit`n")
    Invoke-TestGit -WorkingDirectory $reviewRun.WorktreePath -Arguments @('add', 'README.md') | Out-Null
    Invoke-TestGit -WorkingDirectory $reviewRun.WorktreePath -Arguments @('commit', '-m', 'review candidate') | Out-Null
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To verifying -Reason 'review candidate committed' | Out-Null
    $reviewEvidence = & (Join-Path $workflowScripts 'Capture-WorkflowEvidence.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken
    Assert-Throws -Message 'review-required candidate cannot skip review' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To accepted -Reason 'skip review'
    }
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To needs_review -Reason 'checks passed' | Out-Null
    $reviewPacketPath = Join-Path $testRoot 'review-packet.json'
    $reviewPacket = & (Join-Path $workflowScripts 'Export-WorkflowReviewPacket.ps1') -RunDirectory $reviewRun.RunDirectory -OutputPath $reviewPacketPath
    Assert-True -Condition ($reviewPacket.evidence.headCommit -eq $reviewEvidence.headCommit -and $reviewPacket.diff.Contains('reviewed edit')) -Message 'review packet contains exact candidate and diff'
    $result.reviewPacketExported = $true
    $reviewRecordPath = Join-Path $testRoot 'review-record.json'
    $reviewRecord = & (Join-Path $workflowScripts 'New-WorkflowReviewRecord.ps1') -RunDirectory $reviewRun.RunDirectory -ReviewerId 'independent-reviewer' -Decision approve -Summary 'Diff and declared checks reviewed in disposable fixture.' -OutputPath $reviewRecordPath
    $selfReviewRecordPath = Join-Path $testRoot 'self-review.json'
    $selfReviewRecord = ($reviewRecord | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $selfReviewRecord.reviewerId = $ownerId
    [IO.File]::WriteAllText($selfReviewRecordPath, ($selfReviewRecord | ConvertTo-Json -Depth 30))
    Assert-Throws -Message 'self-review rejected' -ExpectedPattern 'Reviewer must be distinct' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To accepted -Reason 'self review' -ReviewRecordPath $selfReviewRecordPath
    }
    $result.selfReviewRejected = $true
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To accepted -Reason 'review attested' -ReviewRecordPath $reviewRecordPath | Out-Null
    $storedReviewPath = Join-Path $reviewRun.RunDirectory 'review.json'
    $originalReviewBytes = [IO.File]::ReadAllBytes($storedReviewPath)
    [IO.File]::AppendAllText($storedReviewPath, " ")
    Assert-Throws -Message 'modified review record blocks landing' -ExpectedPattern 'Review record changed after acceptance' -Action {
        & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To landing -Reason 'tampered review'
    }
    [IO.File]::WriteAllBytes($storedReviewPath, $originalReviewBytes)
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To landing -Reason 'review restored' | Out-Null
    Invoke-TestGit -WorkingDirectory $repository -Arguments @('merge', '--ff-only', 'agent/smoke-review-bound') | Out-Null
    $reviewIntegration = Invoke-TestGit -WorkingDirectory $repository -Arguments @('rev-parse', 'HEAD')
    & (Join-Path $workflowScripts 'Set-WorkflowState.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken -To completed -Reason 'reviewed candidate integrated' -IntegrationCommit $reviewIntegration | Out-Null
    $reviewCleanup = & (Join-Path $workflowScripts 'Test-WorkflowCleanup.ps1') -RunDirectory $reviewRun.RunDirectory -OwnerToken $reviewRun.OwnerToken
    Assert-True -Condition ([bool]$reviewCleanup.Eligible) -Message 'reviewed run is cleanup eligible after integration'
    $result.reviewRecordBound = $true

    $schemaDirectory = Join-Path $workflowScripts '../schemas'
    foreach ($artifact in @(
        @{ Path = (Join-Path $reviewRun.RunDirectory 'state.json'); Schema = 'run-state.schema.json' },
        @{ Path = (Join-Path $reviewRun.RunDirectory 'evidence.json'); Schema = 'evidence-bundle.schema.json' },
        @{ Path = (Join-Path $reviewRun.RunDirectory 'review.json'); Schema = 'review-record.schema.json' }
    )) {
        $matchesSchema = Test-Json -Json (Get-Content -LiteralPath $artifact.Path -Raw) -SchemaFile (Join-Path $schemaDirectory $artifact.Schema) -ErrorAction Stop
        Assert-True -Condition $matchesSchema -Message 'recorded artifact matches its versioned schema'
    }
    $result.artifactsMatchSchemas = $true

    [pscustomobject]@{
        Passed = (@($result.Values | Where-Object { -not $_ }).Count -eq 0)
        Checks = [pscustomobject]$result
        EventCount = (Get-Content -LiteralPath (Join-Path $run.RunDirectory 'events.jsonl')).Count
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $tempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd('\', '/')
        $parent = [IO.Path]::GetDirectoryName($resolved)
        if ($parent -ne $tempRoot -or -not [IO.Path]::GetFileName($resolved).StartsWith('agent-workflow-smoke-', [StringComparison]::Ordinal)) {
            throw "Refusing fixture cleanup for unexpected path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
