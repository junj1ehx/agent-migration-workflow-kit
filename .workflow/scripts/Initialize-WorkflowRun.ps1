[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskContractPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$OwnerId,
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$validated = Assert-WorkflowTaskContract -Path $TaskContractPath -SchemaPath (Join-Path $PSScriptRoot '../schemas/task-contract.schema.json')
if (Test-Path -LiteralPath $validated.WorktreePath) {
    throw "Worktree path already exists: $($validated.WorktreePath)"
}

[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($StateRoot)) | Out-Null
$stateRootPath = Get-WorkflowCanonicalPath -Path $StateRoot -MustExist
if ($stateRootPath -eq $validated.RepositoryRoot -or (Test-WorkflowPathWithin -Candidate $stateRootPath -Parent $validated.RepositoryRoot)) {
    throw 'StateRoot must be outside the source repository.'
}
if (
    $stateRootPath -eq $validated.WorktreePath -or
    (Test-WorkflowPathWithin -Candidate $stateRootPath -Parent $validated.WorktreePath) -or
    (Test-WorkflowPathWithin -Candidate $validated.WorktreePath -Parent $stateRootPath)
) {
    throw 'StateRoot and worktree must not contain one another.'
}

$branchProbe = Invoke-WorkflowGit -Repository $validated.RepositoryRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$($validated.Branch)") -AllowFailure
if ($branchProbe.ExitCode -eq 0) {
    throw "Branch already exists: $($validated.Branch)"
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ').ToLowerInvariant()
    $RunId = "$($validated.Contract.taskId)-r$($validated.Contract.revision)-$stamp-$suffix"
}
if ($RunId -cnotmatch '^[a-z0-9][a-z0-9._-]{2,95}$') { throw 'Invalid run ID.' }

$runDirectory = Join-Path $stateRootPath $RunId
if (Test-Path -LiteralPath $runDirectory) { throw "Run directory already exists: $runDirectory" }
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null

$ownerToken = New-WorkflowOwnerToken
$now = Get-WorkflowUtcNow
$state = [pscustomobject][ordered]@{
    schemaVersion = '1.0'
    runId = $RunId
    taskId = [string]$validated.Contract.taskId
    taskRevision = [int]$validated.Contract.revision
    taskContractPath = $validated.ContractPath
    taskContractSha256 = $validated.ContractSha256
    status = 'initializing'
    attempt = 1
    reviewCyclesUsed = 0
    eventSequence = 0
    owner = [pscustomobject][ordered]@{
        id = $OwnerId
        tokenSha256 = Get-WorkflowStringSha256 -Value $ownerToken
        acquiredAtUtc = $now
    }
    repository = [pscustomobject][ordered]@{
        root = $validated.RepositoryRoot
        baseCommit = $validated.BaseCommit
    }
    worktree = [pscustomobject][ordered]@{
        path = $validated.WorktreePath
        branch = $validated.Branch
    }
    evidencePath = $null
    evidenceSha256 = $null
    reviewPath = $null
    reviewSha256 = $null
    integrationCommit = $null
    lastError = $null
    timestamps = [pscustomobject][ordered]@{
        createdAtUtc = $now
        updatedAtUtc = $now
        completedAtUtc = $null
    }
}

Use-WorkflowRunLock -RunDirectory $runDirectory -ScriptBlock {
    Add-WorkflowEvent -RunDirectory $runDirectory -State $state -Type 'run_initialized' -Data @{
        taskContractSha256 = $validated.ContractSha256
        baseCommit = $validated.BaseCommit
        worktreePath = $validated.WorktreePath
        branch = $validated.Branch
    }
    Write-WorkflowJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
}

try {
    Invoke-WorkflowGit -Repository $validated.RepositoryRoot -Arguments @(
        'worktree', 'add', '-b', $validated.Branch, $validated.WorktreePath, $validated.BaseCommit
    ) -TimeoutSeconds 120 | Out-Null

    Use-WorkflowRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Read-WorkflowRunState -RunDirectory $runDirectory
        $current.status = 'ready'
        $current.timestamps.updatedAtUtc = Get-WorkflowUtcNow
        Add-WorkflowEvent -RunDirectory $runDirectory -State $current -Type 'state_transition' -Data @{
            from = 'initializing'
            to = 'ready'
            reason = 'worktree-created'
        }
        Write-WorkflowJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $current
    }
}
catch {
    $failure = $_.Exception.Message
    Use-WorkflowRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Read-WorkflowRunState -RunDirectory $runDirectory
        $current.status = 'needs_attention'
        $current.lastError = $failure
        $current.timestamps.updatedAtUtc = Get-WorkflowUtcNow
        Add-WorkflowEvent -RunDirectory $runDirectory -State $current -Type 'state_transition' -Data @{
            from = 'initializing'
            to = 'needs_attention'
            reason = 'worktree-create-failed'
            error = $failure
        }
        Write-WorkflowJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $current
    }
    throw
}

[pscustomobject]@{
    RunId = $RunId
    RunDirectory = $runDirectory
    OwnerToken = $ownerToken
    WorktreePath = $validated.WorktreePath
    Branch = $validated.Branch
    BaseCommit = $validated.BaseCommit
    Status = 'ready'
}
