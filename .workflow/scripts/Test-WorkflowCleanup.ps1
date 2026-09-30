[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$OwnerToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

return Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    $reasons = [Collections.Generic.List[string]]::new()
    try { Assert-WorkflowOwner -State $state -OwnerToken $OwnerToken } catch { $reasons.Add($_.Exception.Message) }
    if ([string]$state.status -ne 'completed') { $reasons.Add("Run state must be completed, not $($state.status).") }
    if ([string]::IsNullOrWhiteSpace([string]$state.integrationCommit)) { $reasons.Add('Integration commit is not recorded.') }

    $evidence = $null
    try {
        $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
        Assert-WorkflowReviewFresh -State $state -Evidence $evidence | Out-Null
    } catch { $reasons.Add($_.Exception.Message) }
    if ($null -ne $evidence -and -not [string]::IsNullOrWhiteSpace([string]$state.integrationCommit)) {
        if (-not (Test-WorkflowGitAncestor -Repository ([string]$state.repository.root) -Ancestor ([string]$evidence.headCommit) -Descendant ([string]$state.integrationCommit))) {
            $reasons.Add('Recorded integration commit does not contain the candidate.')
        }
    }
    $candidate = $null
    try { $candidate = Get-WorkflowCandidateIdentity -WorktreePath ([string]$state.worktree.path) } catch { $reasons.Add($_.Exception.Message) }
    if ($null -ne $candidate -and -not $candidate.Clean) { $reasons.Add('Worktree is dirty.') }

    [pscustomobject]@{
        RunId = [string]$state.runId
        WorktreePath = [string]$state.worktree.path
        Eligible = $reasons.Count -eq 0
        Reasons = @($reasons)
    }
}
