[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$OwnerToken,
    [Parameter(Mandatory)][ValidateSet('ready', 'running', 'verifying', 'needs_review', 'accepted', 'landing', 'completed', 'needs_attention', 'interrupted', 'cancelled')][string]$To,
    [Parameter(Mandatory)][string]$Reason,
    [string]$IntegrationCommit,
    [string]$ReviewRecordPath,
    [string]$ReviewSchemaPath = (Join-Path $PSScriptRoot '../schemas/review-record.schema.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    Assert-WorkflowOwner -State $state -OwnerToken $OwnerToken
    $from = [string]$state.status
    $allowed = Get-WorkflowAllowedTransitions
    if ($To -notin @($allowed[$from])) {
        throw "Invalid state transition: $from -> $To"
    }
    if ($To -in @('running', 'verifying', 'needs_review')) {
        $contract = Read-WorkflowJson -Path ([string]$state.taskContractPath)
        if ((Get-WorkflowFileSha256 -Path ([string]$state.taskContractPath)) -ne [string]$state.taskContractSha256) { throw 'Task contract changed after initialization.' }
        Assert-WorkflowExecutionBudget -State $state -Contract $contract | Out-Null
        if ($To -eq 'running' -and $from -in @('verifying', 'needs_review', 'needs_attention')) {
            if ([int]$state.attempt -ge (1 + [int]$contract.budgets.retryLimit)) { throw 'Task retry budget is exhausted.' }
            $state.attempt = [int]$state.attempt + 1
        }
        if ($To -eq 'needs_review') {
            if ([int]$state.reviewCyclesUsed -ge [int]$contract.budgets.reviewCycles) { throw 'Task review-cycle budget is exhausted.' }
            $state.reviewCyclesUsed = [int]$state.reviewCyclesUsed + 1
        }
    }

    if ($To -in @('accepted', 'needs_review')) {
        $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
        if (-not [bool]$evidence.allChecksPassed) { throw 'All verification checks must pass.' }
        $contract = Read-WorkflowJson -Path ([string]$state.taskContractPath)
        if ($To -eq 'accepted' -and [bool]$contract.review.required -and $from -ne 'needs_review') {
            throw 'Task requires review; transition to needs_review first.'
        }
        if ($To -eq 'needs_review' -and -not [bool]$contract.review.required) {
            throw 'Task does not require review; transition to accepted instead.'
        }
        if ($from -eq 'needs_review' -and $To -eq 'accepted') {
            if ([string]::IsNullOrWhiteSpace($ReviewRecordPath)) { throw 'ReviewRecordPath is required for review-required acceptance.' }
            $reviewPath = Get-WorkflowCanonicalPath -Path $ReviewRecordPath -MustExist
            if ($reviewPath -eq (Get-WorkflowCanonicalPath -Path ([string]$state.worktree.path)) -or
                (Test-WorkflowPathWithin -Candidate $reviewPath -Parent ([string]$state.worktree.path))) {
                throw 'Review record must be outside the implementer worktree.'
            }
            $review = Read-WorkflowJson -Path $reviewPath
            if (-not (Test-Json -Json (Get-Content -LiteralPath $reviewPath -Raw -Encoding utf8) -SchemaFile $ReviewSchemaPath -ErrorAction Stop)) {
                throw 'Review record does not match the JSON schema.'
            }
            Assert-WorkflowObjectShape -Object $review -Allowed @('schemaVersion', 'runId', 'reviewerId', 'decision', 'summary', 'evidenceSha256', 'headCommit', 'reviewedAtUtc') -Required @('schemaVersion', 'runId', 'reviewerId', 'decision', 'summary', 'evidenceSha256', 'headCommit', 'reviewedAtUtc') -Context 'review record'
            if ([string]$review.schemaVersion -ne '1.0' -or [string]$review.runId -ne [string]$state.runId) { throw 'Review record identity mismatch.' }
            if ([string]::IsNullOrWhiteSpace([string]$review.reviewerId) -or [string]$review.reviewerId -eq [string]$state.owner.id) { throw 'Reviewer must be distinct from implementer owner.' }
            if ([string]$review.decision -ne 'approve') { throw 'Review decision is not approve.' }
            if ([string]::IsNullOrWhiteSpace([string]$review.summary)) { throw 'Review summary is required.' }
            if ([string]$review.headCommit -ne [string]$evidence.headCommit) { throw 'Review head commit does not match verified candidate.' }
            $evidenceDigest = Get-WorkflowFileSha256 -Path ([string]$state.evidencePath)
            if ([string]$review.evidenceSha256 -ne $evidenceDigest) { throw 'Review evidence digest mismatch.' }
            $reviewCopy = Join-Path (Get-WorkflowCanonicalPath -Path $RunDirectory -MustExist) 'review.json'
            Write-WorkflowJsonAtomic -Path $reviewCopy -Value $review
            $state.reviewPath = $reviewCopy
            $state.reviewSha256 = Get-WorkflowFileSha256 -Path $reviewCopy
        }
    }

    if ($To -eq 'completed') {
        if ([string]::IsNullOrWhiteSpace($IntegrationCommit)) { throw 'IntegrationCommit is required for completion.' }
        $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
        Assert-WorkflowReviewFresh -State $state -Evidence $evidence | Out-Null
        if (-not (Test-WorkflowGitAncestor -Repository ([string]$state.repository.root) -Ancestor ([string]$evidence.headCommit) -Descendant $IntegrationCommit)) {
            throw 'Integration commit does not contain the verified candidate commit.'
        }
        $resolvedIntegration = (Invoke-WorkflowGit -Repository ([string]$state.repository.root) -Arguments @('rev-parse', '--verify', "$IntegrationCommit^{commit}")).StdOut.Trim().ToLowerInvariant()
        $state.integrationCommit = $resolvedIntegration
        $state.timestamps.completedAtUtc = Get-WorkflowUtcNow
    }

    if ($To -eq 'landing') {
        $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
        Assert-WorkflowReviewFresh -State $state -Evidence $evidence | Out-Null
    }
    if ($To -eq 'running') {
        $state.evidencePath = $null
        $state.evidenceSha256 = $null
        $state.reviewPath = $null
        $state.reviewSha256 = $null
    }

    $state.status = $To
    $state.timestamps.updatedAtUtc = Get-WorkflowUtcNow
    $state.lastError = $null
    Add-WorkflowEvent -RunDirectory $RunDirectory -State $state -Type 'state_transition' -Data @{
        from = $from
        to = $To
        reason = $Reason
        integrationCommit = $state.integrationCommit
    }
    Write-WorkflowJsonAtomic -Path (Join-Path $RunDirectory 'state.json') -Value $state
    return $state
}
