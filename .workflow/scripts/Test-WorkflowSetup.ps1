[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ApprovedModelIds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -Force

$repository = Get-WorkflowCanonicalPath -Path $RepositoryRoot -MustExist
$top = (Invoke-WorkflowGit -Repository $repository -Arguments @('rev-parse', '--show-toplevel')).StdOut.Trim()
if ((Get-WorkflowCanonicalPath -Path $top -MustExist) -ne $repository) { throw 'RepositoryRoot must be the exact Git top level.' }
$checks = [Collections.Generic.List[object]]::new()
$checks.Add([pscustomobject]@{ name = 'powershell'; passed = $PSVersionTable.PSVersion -ge [Version]'7.4'; detail = [string]$PSVersionTable.PSVersion })
$gitVersion = (Invoke-WorkflowGit -Repository $repository -Arguments @('--version')).StdOut.Trim()
$checks.Add([pscustomobject]@{ name = 'git'; passed = $true; detail = $gitVersion })
foreach ($name in @('task-contract', 'run-state', 'evidence-bundle', 'review-record')) {
    $exists = Test-Path -LiteralPath (Join-Path $repository ".workflow/schemas/$name.schema.json") -PathType Leaf
    $checks.Add([pscustomobject]@{ name = "schema-$name"; passed = [bool]$exists; detail = 'Required local schema file' })
}
$localEngineReady = @($checks | Where-Object { -not $_.passed }).Count -eq 0

foreach ($role in @('implementer', 'reviewer')) {
    $profilePath = Join-Path $repository ".github/agents/workflow-$role.agent.md"
    $valid = $false
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding utf8
        $modelMatch = [regex]::Match($profile, '(?m)^model:\s*([a-zA-Z0-9._-]+)\s*$')
        $model = if ($modelMatch.Success) { $modelMatch.Groups[1].Value } else { '' }
        $toolsMatch = [regex]::Match($profile, '(?m)^tools:\s*(\[[^\r\n]+\])\s*$')
        $tools = @()
        if ($toolsMatch.Success) { $tools = @($toolsMatch.Groups[1].Value | ConvertFrom-Json) }
        $expectedTools = if ($role -eq 'reviewer') { @('read', 'search') } else { @('read', 'search', 'edit', 'execute') }
        $toolSetMatches = $tools.Count -eq $expectedTools.Count -and @($expectedTools | Where-Object { $_ -notin $tools }).Count -eq 0
        $valid = $model -in $ApprovedModelIds -and $model -notmatch '^(REPLACE|auto)' -and
            $profile -match '(?m)^modelPolicy:\s*required\s*$' -and
            $profile -match '(?m)^include-custom-instructions:\s*true\s*$' -and $toolSetMatches
    }
    $checks.Add([pscustomobject]@{ name = "profile-$role"; passed = [bool]$valid; detail = 'Exact approved model and expected role tool list; actual client loading must be checked separately' })
}

$copilot = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$copilotAvailable = $null -ne $copilot
$checks.Add([pscustomobject]@{ name = 'copilot-cli'; passed = $copilotAvailable; detail = 'Local executable presence only; account, model availability, and role loading are not tested' })

[pscustomobject]@{
    LocalEngineReady = $localEngineReady
    SetupChecksPassed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    CopilotCliAvailable = $copilotAvailable
    Checks = @($checks)
}
