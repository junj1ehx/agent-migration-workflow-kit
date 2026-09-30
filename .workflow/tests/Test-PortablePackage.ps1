[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('workflow-portability-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository'

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = & git -C $repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git command failed: $output" }
}

try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    Copy-Item -LiteralPath $packageRoot -Destination $repository -Recurse
    Invoke-FixtureGit -Arguments @('init', '--initial-branch=main')
    Invoke-FixtureGit -Arguments @('config', 'user.name', 'Workflow Fixture')
    Invoke-FixtureGit -Arguments @('config', 'user.email', 'workflow-fixture@example.invalid')
    Invoke-FixtureGit -Arguments @('config', 'core.hooksPath', (Join-Path $fixtureRoot 'disabled-hooks'))
    Invoke-FixtureGit -Arguments @('config', 'commit.gpgsign', 'false')
    $fixtureModel = 'gpt-fixture-not-a-real-model'
    foreach ($role in @('implementer', 'reviewer')) {
        $path = Join-Path $repository ".github/agents/workflow-$role.agent.md"
        $content = [IO.File]::ReadAllText($path).Replace('REPLACE_WITH_APPROVED_MODEL_ID', $fixtureModel)
        [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    }
    Invoke-FixtureGit -Arguments @('add', '--', '.')
    Invoke-FixtureGit -Arguments @('commit', '-m', 'fixture package setup')
    $scripts = Join-Path $repository '.workflow/scripts'
    $setup = & (Join-Path $scripts 'Test-WorkflowSetup.ps1') -RepositoryRoot $repository -ApprovedModelIds @($fixtureModel)
    if (-not $setup.LocalEngineReady) { throw 'Copied local engine prerequisites failed.' }
    if (@($setup.Checks | Where-Object { $_.name -like 'profile-*' -and $_.passed }).Count -ne 2) { throw 'Copied profile checks failed.' }
    $smoke = & (Join-Path $repository '.workflow/tests/Run-SmokeTest.ps1')
    if (-not $smoke.Passed) { throw 'Standalone copy smoke test failed.' }
    [pscustomobject]@{
        Passed = $true
        StandaloneCopyVerified = $true
        ProfileConfigurationChecked = $true
        CopilotInvoked = $false
        LocalWorkflow = $smoke
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $tempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd('\', '/')
        if ([IO.Path]::GetDirectoryName($resolved) -ne $tempRoot -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('workflow-portability-', [StringComparison]::Ordinal)) {
            throw 'Refusing cleanup of an unexpected portability fixture path.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
