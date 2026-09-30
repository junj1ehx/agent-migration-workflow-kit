[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$ReviewerId,
    [Parameter(Mandatory)][ValidateSet('approve', 'request_changes')][string]$Decision,
    [Parameter(Mandatory)][string]$Summary,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$record = Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    if ([string]$state.status -ne 'needs_review') { throw 'Review record requires needs_review state.' }
    if ([string]::IsNullOrWhiteSpace($ReviewerId) -or $ReviewerId -eq [string]$state.owner.id) { throw 'Reviewer must be distinct from implementer owner.' }
    if ([string]::IsNullOrWhiteSpace($Summary)) { throw 'Review summary is required.' }
    $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
    [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        runId = [string]$state.runId
        reviewerId = $ReviewerId
        decision = $Decision
        summary = $Summary
        evidenceSha256 = [string]$state.evidenceSha256
        headCommit = [string]$evidence.headCommit
        reviewedAtUtc = Get-WorkflowUtcNow
    }
}

$state = Read-WorkflowRunState -RunDirectory $RunDirectory
$path = Get-WorkflowCanonicalPath -Path $OutputPath
if ((Test-WorkflowPathWithin -Candidate $path -Parent ([string]$state.worktree.path)) -or
    (Test-WorkflowPathWithin -Candidate $path -Parent ([string]$state.repository.root))) {
    throw 'Review record must be stored outside repository checkouts.'
}
if (Test-Path -LiteralPath $path) { throw 'Review record output already exists; use a new file name.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
$stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
return $record
