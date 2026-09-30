[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$state = Read-WorkflowRunState -RunDirectory $RunDirectory
$candidate = $null
try { $candidate = Get-WorkflowCandidateIdentity -WorktreePath ([string]$state.worktree.path) } catch {}

[pscustomobject]@{
    RunId = [string]$state.runId
    TaskId = [string]$state.taskId
    Status = [string]$state.status
    OwnerId = [string]$state.owner.id
    BaseCommit = [string]$state.repository.baseCommit
    HeadCommit = if ($null -eq $candidate) { $null } else { $candidate.HeadCommit }
    WorktreeClean = if ($null -eq $candidate) { $null } else { $candidate.Clean }
    EvidencePath = $state.evidencePath
    ReviewPath = $state.reviewPath
    IntegrationCommit = $state.integrationCommit
    UpdatedAtUtc = [string]$state.timestamps.updatedAtUtc
}
