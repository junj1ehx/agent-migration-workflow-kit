[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$packet = Use-WorkflowRunLock -RunDirectory $RunDirectory -ScriptBlock {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    if ([string]$state.status -ne 'needs_review') { throw 'Review packet requires needs_review state.' }
    $evidence = Assert-WorkflowEvidenceFresh -State $state -RunDirectory $RunDirectory
    if (-not [bool]$evidence.allChecksPassed) { throw 'Review packet requires passing verification.' }
    $contract = Read-WorkflowJson -Path ([string]$state.taskContractPath)
    $diff = Invoke-WorkflowGit -Repository ([string]$state.worktree.path) -Arguments @('diff', '--no-ext-diff', '--no-textconv', '--binary', ([string]$evidence.baseCommit), ([string]$evidence.headCommit), '--')
    [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        runId = [string]$state.runId
        taskId = [string]$state.taskId
        objective = [string]$contract.objective
        scope = $contract.scope
        acceptanceCriteria = @($contract.acceptanceCriteria)
        evidenceSha256 = [string]$state.evidenceSha256
        evidence = $evidence
        diff = [string]$diff.StdOut
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $state = Read-WorkflowRunState -RunDirectory $RunDirectory
    $path = Get-WorkflowCanonicalPath -Path $OutputPath
    if ((Test-WorkflowPathWithin -Candidate $path -Parent ([string]$state.worktree.path)) -or
        (Test-WorkflowPathWithin -Candidate $path -Parent ([string]$state.repository.root))) {
        throw 'Review packet must be stored outside repository checkouts.'
    }
    if (Test-Path -LiteralPath $path) { throw 'Review packet output already exists; use a new file name.' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($packet | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}
return $packet
