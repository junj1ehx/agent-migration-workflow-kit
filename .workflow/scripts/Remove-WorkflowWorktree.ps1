[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$OwnerToken,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$cleanupCheck = & (Join-Path $PSScriptRoot 'Test-WorkflowCleanup.ps1') -RunDirectory $RunDirectory -OwnerToken $OwnerToken
if (-not $cleanupCheck.Eligible) {
    throw "Cleanup is not eligible:`n- $($cleanupCheck.Reasons -join "`n- ")"
}

$state = Read-WorkflowRunState -RunDirectory $RunDirectory
$repositoryRoot = Get-WorkflowCanonicalPath -Path ([string]$state.repository.root) -MustExist
$worktreePath = Get-WorkflowCanonicalPath -Path ([string]$state.worktree.path) -MustExist
if ($worktreePath -eq $repositoryRoot -or (Test-WorkflowPathWithin -Candidate $worktreePath -Parent $repositoryRoot)) {
    throw 'Refusing cleanup because recorded worktree is not an external sibling path.'
}

if (-not $Execute) {
    return [pscustomobject]@{
        RunId = [string]$state.runId
        WorktreePath = $worktreePath
        Eligible = $true
        Removed = $false
        DryRun = $true
        BranchRetained = [string]$state.worktree.branch
    }
}

if ($PSCmdlet.ShouldProcess($worktreePath, 'Remove verified Git worktree')) {
    Invoke-WorkflowGit -Repository $repositoryRoot -Arguments @('worktree', 'remove', $worktreePath) -TimeoutSeconds 120 | Out-Null
    Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
        $current = Read-WorkflowRunState -RunDirectory $RunDirectory
        Assert-WorkflowOwner -State $current -OwnerToken $OwnerToken
        Add-WorkflowEvent -RunDirectory $RunDirectory -State $current -Type 'worktree_removed' -Data @{
            worktreePath = $worktreePath
            branchRetained = [string]$current.worktree.branch
        }
        $current.timestamps.updatedAtUtc = Get-WorkflowUtcNow
        Write-WorkflowJsonAtomic -Path (Join-Path $RunDirectory 'state.json') -Value $current
    }
}

[pscustomobject]@{
    RunId = [string]$state.runId
    WorktreePath = $worktreePath
    Removed = -not (Test-Path -LiteralPath $worktreePath)
    DryRun = $false
    BranchRetained = [string]$state.worktree.branch
}
