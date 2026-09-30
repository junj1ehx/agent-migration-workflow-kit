Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkflowUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-WorkflowStringSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-WorkflowFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $stream = [IO.File]::OpenRead($resolved)
    try {
        $hash = [Security.Cryptography.SHA256]::HashData($stream)
        return [Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-WorkflowCanonicalPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MustExist
    )

    $fullPath = if ($MustExist) {
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } else {
        [IO.Path]::GetFullPath($Path)
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -eq $root) { return $root }
    return $fullPath.TrimEnd('\', '/')
}

function Test-WorkflowPathWithin {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Parent
    )

    $candidatePath = (Get-WorkflowCanonicalPath -Path $Candidate).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $parentPath = (Get-WorkflowCanonicalPath -Path $Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Read-WorkflowJson {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Content -LiteralPath $resolved -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
}

function Write-WorkflowJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $fullPath -Force
}

function Invoke-WorkflowProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter()][int]$TimeoutSeconds = 60
    )

    $workingPath = Get-WorkflowCanonicalPath -Path $WorkingDirectory -MustExist
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $workingPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw "Failed to start executable: $Executable"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        $timedOut = -not $finished
        if ($timedOut) {
            try { $process.Kill($true) } catch {}
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = if ($timedOut) { $null } else { $process.ExitCode }
        return [pscustomobject]@{
            Executable = $Executable
            Arguments = @($Arguments)
            WorkingDirectory = $workingPath
            ExitCode = $exitCode
            TimedOut = $timedOut
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
            StdOut = $stdout
            StdErr = $stderr
        }
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

function Invoke-WorkflowGit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [switch]$AllowFailure
    )

    $result = Invoke-WorkflowProcess -Executable 'git' -Arguments $Arguments -WorkingDirectory $Repository -TimeoutSeconds $TimeoutSeconds
    if (-not $AllowFailure -and ($result.TimedOut -or $result.ExitCode -ne 0)) {
        $detail = ($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim()
        throw "Git command failed: git $($Arguments -join ' ')`n$detail"
    }
    return $result
}

function Assert-WorkflowObjectShape {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Object) { throw "$Context is required." }
    $actual = @($Object.PSObject.Properties.Name)
    $unknown = @($actual | Where-Object { $_ -notin $Allowed })
    if ($unknown.Count -gt 0) { throw "$Context contains unknown fields: $($unknown -join ', ')" }
    $missing = @($Required | Where-Object { $_ -notin $actual })
    if ($missing.Count -gt 0) { throw "$Context is missing required fields: $($missing -join ', ')" }
}

function Assert-WorkflowRelativePath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Context,
        [switch]$AllowCurrentDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Context must not be empty." }
    if ([IO.Path]::IsPathRooted($Path)) { throw "$Context must be relative." }
    $probeRoot = Join-Path ([IO.Path]::GetTempPath()) 'workflow-path-probe'
    $probeRootPath = Get-WorkflowCanonicalPath -Path $probeRoot
    $probePath = Get-WorkflowCanonicalPath -Path (Join-Path $probeRoot $Path)
    if ($probePath -eq $probeRootPath) {
        if (-not $AllowCurrentDirectory) { throw "$Context must identify a path below the worktree root." }
        return
    }
    if (-not (Test-WorkflowPathWithin -Candidate $probePath -Parent $probeRootPath)) {
        throw "$Context escapes the worktree."
    }
}

function Assert-WorkflowTaskContract {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SchemaPath = (Join-Path $PSScriptRoot '../schemas/task-contract.schema.json')
    )

    $contractPath = Get-WorkflowCanonicalPath -Path $Path -MustExist
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { throw 'Task contract schema is missing.' }
    $validJson = Test-Json -Json (Get-Content -LiteralPath $contractPath -Raw -Encoding utf8) -SchemaFile $SchemaPath -ErrorAction Stop
    if (-not $validJson) { throw 'Task contract does not match the JSON schema.' }
    $contract = Read-WorkflowJson -Path $contractPath

    Assert-WorkflowObjectShape -Object $contract `
        -Allowed @('schemaVersion', 'taskId', 'revision', 'objective', 'nonGoals', 'repository', 'worktree', 'scope', 'modelPolicy', 'toolPolicy', 'acceptanceCriteria', 'budgets', 'review') `
        -Required @('schemaVersion', 'taskId', 'revision', 'objective', 'repository', 'worktree', 'scope', 'modelPolicy', 'toolPolicy', 'acceptanceCriteria', 'budgets', 'review') `
        -Context 'task contract'
    Assert-WorkflowObjectShape -Object $contract.repository -Allowed @('root', 'baseRef') -Required @('root', 'baseRef') -Context 'repository'
    Assert-WorkflowObjectShape -Object $contract.worktree -Allowed @('path', 'branch') -Required @('path', 'branch') -Context 'worktree'
    Assert-WorkflowObjectShape -Object $contract.scope -Allowed @('writablePaths', 'protectedPaths') -Required @('writablePaths', 'protectedPaths') -Context 'scope'
    Assert-WorkflowObjectShape -Object $contract.modelPolicy -Allowed @('allowedFamilies', 'allowedModelIds', 'allowAutomaticFallback') -Required @('allowedFamilies', 'allowAutomaticFallback') -Context 'modelPolicy'
    Assert-WorkflowObjectShape -Object $contract.toolPolicy -Allowed @('allowedExecutables', 'allowNetwork') -Required @('allowedExecutables', 'allowNetwork') -Context 'toolPolicy'
    Assert-WorkflowObjectShape -Object $contract.budgets -Allowed @('elapsedMinutes', 'retryLimit', 'reviewCycles') -Required @('elapsedMinutes', 'retryLimit', 'reviewCycles') -Context 'budgets'
    Assert-WorkflowObjectShape -Object $contract.review -Allowed @('required') -Required @('required') -Context 'review'

    if ($contract.schemaVersion -ne '1.0') { throw "Unsupported task contract schemaVersion: $($contract.schemaVersion)" }
    if ([string]$contract.taskId -notmatch '^[a-z0-9][a-z0-9._-]{2,63}$') { throw 'Invalid taskId.' }
    if ([int]$contract.revision -lt 1) { throw 'Task revision must be at least 1.' }
    if ([string]::IsNullOrWhiteSpace([string]$contract.objective)) { throw 'Task objective is required.' }

    $repositoryRoot = Get-WorkflowCanonicalPath -Path ([string]$contract.repository.root) -MustExist
    $topResult = Invoke-WorkflowGit -Repository $repositoryRoot -Arguments @('rev-parse', '--show-toplevel')
    $actualRoot = Get-WorkflowCanonicalPath -Path $topResult.StdOut.Trim() -MustExist
    if ($actualRoot -ne $repositoryRoot) { throw "repository.root must be the Git top level: $actualRoot" }

    $baseResult = Invoke-WorkflowGit -Repository $repositoryRoot -Arguments @('rev-parse', '--verify', "$($contract.repository.baseRef)^{commit}")
    $baseCommit = $baseResult.StdOut.Trim().ToLowerInvariant()
    if ($baseCommit -notmatch '^[a-f0-9]{40,64}$') { throw 'Unable to resolve a valid base commit.' }

    $worktreePath = Get-WorkflowCanonicalPath -Path ([string]$contract.worktree.path)
    if ($worktreePath -eq $repositoryRoot -or (Test-WorkflowPathWithin -Candidate $worktreePath -Parent $repositoryRoot)) {
        throw 'The workflow requires the worktree to be outside the source checkout.'
    }
    if ([string]$contract.worktree.branch -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid worktree branch name.' }

    if (@($contract.scope.writablePaths).Count -lt 1) { throw 'At least one writable path is required.' }
    foreach ($scopePath in @($contract.scope.writablePaths)) {
        Assert-WorkflowRelativePath -Path ([string]$scopePath) -Context 'scope.writablePaths entry' -AllowCurrentDirectory
    }
    foreach ($scopePath in @($contract.scope.protectedPaths)) {
        Assert-WorkflowRelativePath -Path ([string]$scopePath) -Context 'scope.protectedPaths entry' -AllowCurrentDirectory
    }
    if (@($contract.acceptanceCriteria.id | Select-Object -Unique).Count -ne @($contract.acceptanceCriteria).Count) {
        throw 'Acceptance criterion IDs must be unique.'
    }
    if ([bool]$contract.review.required -and [int]$contract.budgets.reviewCycles -lt 1) { throw 'Review-required tasks need at least one review cycle.' }
    if (@($contract.acceptanceCriteria).Count -lt 1) { throw 'At least one acceptance criterion is required.' }
    foreach ($criterion in @($contract.acceptanceCriteria)) {
        Assert-WorkflowObjectShape -Object $criterion -Allowed @('id', 'description', 'command') -Required @('id', 'description', 'command') -Context 'acceptance criterion'
        Assert-WorkflowObjectShape -Object $criterion.command -Allowed @('executable', 'arguments', 'workingDirectory', 'timeoutSeconds') -Required @('executable', 'arguments', 'timeoutSeconds') -Context "acceptance criterion $($criterion.id) command"
        if ([string]::IsNullOrWhiteSpace([string]$criterion.id)) { throw 'Acceptance criterion id is required.' }
        if ([string]::IsNullOrWhiteSpace([string]$criterion.command.executable)) { throw "Acceptance criterion $($criterion.id) requires an executable." }
        if ([string]$criterion.command.executable -notin @($contract.toolPolicy.allowedExecutables | ForEach-Object { [string]$_ })) {
            throw "Acceptance criterion $($criterion.id) uses an executable outside toolPolicy.allowedExecutables."
        }
        if ([int]$criterion.command.timeoutSeconds -lt 1 -or [int]$criterion.command.timeoutSeconds -gt 1800) {
            throw "Acceptance criterion $($criterion.id) timeout is outside 1..1800 seconds."
        }
        $relativeWorking = if ($null -eq $criterion.command.PSObject.Properties['workingDirectory']) { '.' } else { [string]$criterion.command.workingDirectory }
        Assert-WorkflowRelativePath -Path $relativeWorking -Context "acceptance criterion $($criterion.id) workingDirectory" -AllowCurrentDirectory
    }

    $families = @($contract.modelPolicy.allowedFamilies)
    if ($families.Count -lt 1) { throw 'At least one model family is required.' }
    foreach ($family in $families) {
        if ([string]$family -notin @('openai', 'gemini')) { throw "Unapproved model family: $family" }
    }
    if ([bool]$contract.modelPolicy.allowAutomaticFallback) { throw 'Automatic model fallback must be false.' }
    if (@($contract.toolPolicy.allowedExecutables).Count -lt 1) { throw 'At least one allowed executable is required.' }
    foreach ($executable in @($contract.toolPolicy.allowedExecutables)) {
        if ([string]::IsNullOrWhiteSpace([string]$executable)) { throw 'toolPolicy.allowedExecutables contains an empty value.' }
    }
    if ([bool]$contract.toolPolicy.allowNetwork) { throw 'Local verification requires toolPolicy.allowNetwork=false.' }
    if ([int]$contract.budgets.elapsedMinutes -lt 1) { throw 'elapsedMinutes must be positive.' }
    if ([int]$contract.budgets.retryLimit -lt 0 -or [int]$contract.budgets.retryLimit -gt 10) { throw 'retryLimit must be within 0..10.' }
    if ([int]$contract.budgets.reviewCycles -lt 0 -or [int]$contract.budgets.reviewCycles -gt 10) { throw 'reviewCycles must be within 0..10.' }

    return [pscustomobject]@{
        Contract = $contract
        ContractPath = $contractPath
        ContractSha256 = Get-WorkflowFileSha256 -Path $contractPath
        RepositoryRoot = $repositoryRoot
        BaseCommit = $baseCommit
        WorktreePath = $worktreePath
        Branch = [string]$contract.worktree.branch
    }
}

function Use-WorkflowRunLock {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 10
    )

    $runPath = Get-WorkflowCanonicalPath -Path $RunDirectory -MustExist
    $lockPath = Join-Path $runPath 'run.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out acquiring run lock: $lockPath" }
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        return & $ScriptBlock
    }
    finally {
        $stream.Dispose()
    }
}

function Read-WorkflowRunState {
    param([Parameter(Mandatory)][string]$RunDirectory)

    return Read-WorkflowJson -Path (Join-Path $RunDirectory 'state.json')
}

function Assert-WorkflowOwner {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$OwnerToken
    )

    $actual = Get-WorkflowStringSha256 -Value $OwnerToken
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Convert]::FromHexString($actual),
        [Convert]::FromHexString([string]$State.owner.tokenSha256))) {
        throw 'Owner token does not match this run.'
    }
}

function Add-WorkflowEvent {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Data
    )

    $State.eventSequence = [int]$State.eventSequence + 1
    $event = [ordered]@{
        schemaVersion = '1.0'
        sequence = [int]$State.eventSequence
        timestampUtc = Get-WorkflowUtcNow
        type = $Type
        runId = [string]$State.runId
        taskId = [string]$State.taskId
        ownerId = [string]$State.owner.id
        data = $Data
    }
    $line = $event | ConvertTo-Json -Depth 30 -Compress
    [IO.File]::AppendAllText((Join-Path $RunDirectory 'events.jsonl'), $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Get-WorkflowAllowedTransitions {
    return @{
        initializing = @('ready', 'needs_attention', 'cancelled')
        ready = @('running', 'cancelled')
        running = @('verifying', 'needs_attention', 'interrupted', 'cancelled')
        verifying = @('running', 'needs_review', 'accepted', 'needs_attention', 'interrupted')
        needs_review = @('running', 'accepted', 'needs_attention', 'interrupted')
        accepted = @('landing', 'needs_attention', 'interrupted')
        landing = @('completed', 'needs_attention', 'interrupted')
        needs_attention = @('running', 'cancelled')
        interrupted = @('ready', 'cancelled')
        completed = @()
        cancelled = @()
    }
}

function Assert-WorkflowExecutionBudget {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Contract)

    $started = [DateTimeOffset]$State.timestamps.createdAtUtc
    $deadline = $started.AddMinutes([int]$Contract.budgets.elapsedMinutes)
    $remaining = [int][Math]::Floor(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) { throw 'Task elapsed-time budget is exhausted; preserve the run for operator review.' }
    return $remaining
}

function Get-WorkflowCandidateIdentity {
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [switch]$RequireChange
    )

    $worktree = Get-WorkflowCanonicalPath -Path $WorktreePath -MustExist
    $status = Invoke-WorkflowGit -Repository $worktree -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    $clean = [string]::IsNullOrWhiteSpace($status.StdOut)
    $head = (Invoke-WorkflowGit -Repository $worktree -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim().ToLowerInvariant()
    $tree = (Invoke-WorkflowGit -Repository $worktree -Arguments @('rev-parse', '--verify', 'HEAD^{tree}')).StdOut.Trim().ToLowerInvariant()
    return [pscustomobject]@{ Clean = $clean; HeadCommit = $head; HeadTree = $tree; Status = $status.StdOut }
}

function Test-WorkflowCandidateScope {
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseCommit,
        [Parameter(Mandatory)]$Scope
    )

    $worktree = Get-WorkflowCanonicalPath -Path $WorktreePath -MustExist
    if (-not (Test-WorkflowGitAncestor -Repository $worktree -Ancestor $BaseCommit -Descendant 'HEAD')) {
        throw 'Candidate HEAD is not descended from the recorded base commit.'
    }
    $diff = Invoke-WorkflowGit -Repository $worktree -Arguments @('diff', '--name-only', '--no-renames', '-z', $BaseCommit, 'HEAD', '--')
    $changedPaths = @($diff.StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    if ($changedPaths.Count -eq 0) { throw 'Candidate has no changed paths relative to the recorded base.' }
    $historyPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $revisions = Invoke-WorkflowGit -Repository $worktree -Arguments @('rev-list', "$BaseCommit..HEAD")
    foreach ($revision in @($revisions.StdOut -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $commitDiff = Invoke-WorkflowGit -Repository $worktree -Arguments @('diff-tree', '-m', '--no-commit-id', '--name-only', '--no-renames', '-r', '-z', $revision.Trim(), '--')
        foreach ($path in @($commitDiff.StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))) {
            [void]$historyPaths.Add($path)
        }
    }
    $violations = [Collections.Generic.List[string]]::new()
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($path in $historyPaths) {
        $normalized = $path.Replace('\', '/')
        $protected = $false
        foreach ($rule in @($Scope.protectedPaths)) {
            $prefix = ([string]$rule).Replace('\', '/')
            if ($prefix -eq '.' -or [string]::Equals($normalized, $prefix.TrimEnd('/'), $comparison) -or $normalized.StartsWith($prefix.TrimEnd('/') + '/', $comparison)) {
                $protected = $true
                break
            }
        }
        $writable = $false
        foreach ($rule in @($Scope.writablePaths)) {
            $prefix = ([string]$rule).Replace('\', '/')
            if ($prefix -eq '.' -or [string]::Equals($normalized, $prefix.TrimEnd('/'), $comparison) -or $normalized.StartsWith($prefix.TrimEnd('/') + '/', $comparison)) {
                $writable = $true
                break
            }
        }
        if ($protected -or -not $writable) { $violations.Add($normalized) }
    }
    return [pscustomobject]@{
        ChangedPaths = $changedPaths
        HistoryPaths = @($historyPaths | Sort-Object)
        Violations = @($violations)
        Passed = $violations.Count -eq 0
    }
}

function Assert-WorkflowEvidenceFresh {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    if ([string]::IsNullOrWhiteSpace([string]$State.evidencePath)) { throw 'No evidence bundle is recorded.' }
    if ([string]::IsNullOrWhiteSpace([string]$State.evidenceSha256) -or
        (Get-WorkflowFileSha256 -Path ([string]$State.evidencePath)) -ne [string]$State.evidenceSha256) {
        throw 'Evidence bundle changed after capture.'
    }
    $evidence = Read-WorkflowJson -Path ([string]$State.evidencePath)
    if ([string]$evidence.runId -ne [string]$State.runId) { throw 'Evidence runId mismatch.' }
    if ([string]$evidence.taskContractSha256 -ne [string]$State.taskContractSha256) { throw 'Evidence task-contract digest mismatch.' }
    $currentTaskHash = Get-WorkflowFileSha256 -Path ([string]$State.taskContractPath)
    if ($currentTaskHash -ne [string]$State.taskContractSha256) { throw 'Task contract changed after run initialization.' }
    $candidate = Get-WorkflowCandidateIdentity -WorktreePath ([string]$State.worktree.path)
    if (-not $candidate.Clean) { throw 'Worktree is not clean; evidence is stale.' }
    if ([string]$evidence.headCommit -ne $candidate.HeadCommit -or [string]$evidence.headTree -ne $candidate.HeadTree) {
        throw 'Candidate revision/tree changed after evidence capture.'
    }
    $contract = Read-WorkflowJson -Path ([string]$State.taskContractPath)
    $scope = Test-WorkflowCandidateScope -WorktreePath ([string]$State.worktree.path) -BaseCommit ([string]$State.repository.baseCommit) -Scope $contract.scope
    if (-not $scope.Passed -or -not [bool]$evidence.scopePassed) { throw 'Candidate violates the declared file scope.' }
    if (@($evidence.changedPaths).Count -ne @($scope.ChangedPaths).Count -or
        (@(Compare-Object -ReferenceObject @($evidence.changedPaths) -DifferenceObject @($scope.ChangedPaths)).Count -gt 0)) {
        throw 'Evidence changed-path list does not match the candidate.'
    }
    if (@($evidence.historyPaths).Count -ne @($scope.HistoryPaths).Count -or
        (@(Compare-Object -ReferenceObject @($evidence.historyPaths) -DifferenceObject @($scope.HistoryPaths)).Count -gt 0)) {
        throw 'Evidence history-path list does not match the candidate.'
    }
    return $evidence
}

function Assert-WorkflowReviewFresh {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Evidence
    )

    $contract = Read-WorkflowJson -Path ([string]$State.taskContractPath)
    if (-not [bool]$contract.review.required) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$State.reviewPath) -or [string]::IsNullOrWhiteSpace([string]$State.reviewSha256)) {
        throw 'Required review record is missing.'
    }
    $currentDigest = Get-WorkflowFileSha256 -Path ([string]$State.reviewPath)
    if ($currentDigest -ne [string]$State.reviewSha256) { throw 'Review record changed after acceptance.' }
    $review = Read-WorkflowJson -Path ([string]$State.reviewPath)
    if ([string]$review.runId -ne [string]$State.runId -or [string]$review.headCommit -ne [string]$Evidence.headCommit -or
        [string]$review.evidenceSha256 -ne (Get-WorkflowFileSha256 -Path ([string]$State.evidencePath)) -or
        [string]$review.decision -ne 'approve') {
        throw 'Review record no longer matches the verified candidate.'
    }
    return $review
}

function Test-WorkflowGitAncestor {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ancestor,
        [Parameter(Mandatory)][string]$Descendant
    )

    $verify = Invoke-WorkflowGit -Repository $Repository -Arguments @('rev-parse', '--verify', "$Descendant^{commit}") -AllowFailure
    if ($verify.ExitCode -ne 0) { return $false }
    $result = Invoke-WorkflowGit -Repository $Repository -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure
    return (-not $result.TimedOut -and $result.ExitCode -eq 0)
}

function New-WorkflowOwnerToken {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

Export-ModuleMember -Function @(
    'Get-WorkflowUtcNow',
    'Get-WorkflowStringSha256',
    'Get-WorkflowFileSha256',
    'Get-WorkflowCanonicalPath',
    'Test-WorkflowPathWithin',
    'Read-WorkflowJson',
    'Write-WorkflowJsonAtomic',
    'Invoke-WorkflowProcess',
    'Invoke-WorkflowGit',
    'Assert-WorkflowObjectShape',
    'Assert-WorkflowRelativePath',
    'Assert-WorkflowTaskContract',
    'Use-WorkflowRunLock',
    'Read-WorkflowRunState',
    'Assert-WorkflowOwner',
    'Add-WorkflowEvent',
    'Get-WorkflowAllowedTransitions',
    'Assert-WorkflowExecutionBudget',
    'Get-WorkflowCandidateIdentity',
    'Test-WorkflowCandidateScope',
    'Assert-WorkflowEvidenceFresh',
    'Assert-WorkflowReviewFresh',
    'Test-WorkflowGitAncestor',
    'New-WorkflowOwnerToken'
)
