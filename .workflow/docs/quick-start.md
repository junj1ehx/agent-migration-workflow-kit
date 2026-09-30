# Quick start

## 1. Install into the target repository

Use an approved local Git checkout with at least one commit. Work on a configuration branch using the repository's normal change process.

Copy `.workflow/` from this package into the repository root. Copy the two files in `.github/agents/` into the target's `.github/agents/`. Merge `.github/copilot-instructions.md` with any existing instruction file. Preserve existing instructions, hooks, agents, and CI configuration. If a destination file already exists, compare it and merge deliberately; do not overwrite it automatically.

Replace `REPLACE_WITH_APPROVED_MODEL_ID` in both agent profiles with exact model IDs approved and available in the work environment. The implementer and reviewer may use different approved IDs. Verify each ID belongs to an approved OpenAI or Gemini model and is accessible under the correct enterprise account. Keep `modelPolicy: required`; do not use Auto or a fallback list. The enterprise model policy remains the authority.

The profiles are intended for Copilot CLI. Confirm that the installed version supports their fields. Inspect the agent selected by the CLI because user-level configuration can override a repository agent with the same ID. For an IDE, configure its supported role/tool settings and test them separately; do not assume CLI settings carry over.

Run the local fixture:

```powershell
& ./.workflow/tests/Run-SmokeTest.ps1 | ConvertTo-Json -Depth 10
```

The fixture creates and removes its own temporary Git repositories. `Passed` must be `true`. It does not modify the target repository's branches or contact a model. Commit the merged configuration through the normal review process before allocating a task worktree: uncommitted setup files will not appear in the new worktree.

## 2. Prepare one task

Open `.workflow/templates/task-contract.template.json` in an editor and save a completed copy outside all repository checkouts, for example under `C:/workflow-tasks/`. Replace the placeholder paths and model ID. Set a unique task ID, branch, and unused worktree path.

`repository.root` must be the exact Git top level. `baseRef` resolves once at initialization to a specific commit. The source checkout's uncommitted changes are not copied. Worktree, state root, and task contract should be separate locations under an approved local storage area. The state root and worktree must be outside the source checkout and must not contain each other.

Use plain repository-relative paths such as `src/`, `tests/`, and `README.md`. A path covers itself and its descendants; `.` allows the whole worktree subject to protected paths. Protected paths override writable paths. Protect the workflow configuration and repository policy files for ordinary development tasks. The candidate gate examines paths in every commit since the recorded base, including edits later undone.

The template's whitespace check is only a setup demonstration. For a real code task, add the repository's relevant test/build commands and expected behavior. Add each executable to `allowedExecutables` after the operator has reviewed the executable, arguments, and invoked project scripts. A named executable can run arbitrary code; an allowlist name is not a sandbox.

Commands use an executable and argument array. Only an argument exactly equal to `{baseCommit}` or `{headCommit}` is replaced with the recorded Git identity. There is no environment-variable or shell expansion. Leave `workingDirectory` as `.` or select a relative directory inside the worktree.

For review-required tasks, set `review.required=true` and at least one review cycle. `retryLimit` counts rework attempts after the initial implementation; `reviewCycles` counts entries to review; elapsed time starts when the run is created. Human waiting time consumes that elapsed budget. See the operating guide before choosing limits.

Review the completed task contract, data scope, and verification commands before initialization. Once initialized, the contract is immutable. A changed objective, scope, or budget requires a new revision and a new run.

## 3. Initialize and start implementation

The following paths are illustrative placeholders:

```powershell
$repository = 'C:/repos/project'
$scripts = Join-Path $repository '.workflow/scripts'
$taskPath = 'C:/workflow-tasks/first-task.json'
$approvedModelId = 'REPLACE_WITH_APPROVED_MODEL_ID'

$run = & (Join-Path $scripts 'Initialize-WorkflowRun.ps1') `
  -TaskContractPath $taskPath -StateRoot 'C:/workflow-state' `
  -OwnerId 'implementation-session-1'

$runDirectory = $run.RunDirectory
$ownerToken = $run.OwnerToken

& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To running -Reason 'approved implementation started'
```

Keep the token in the operator session or approved secure local storage. Only its hash is stored in state. Do not send the token to the coding agent or include the initialization object in shared logs. Losing it preserves the worktree but prevents normal workflow mutation and cleanup.

Populate the implementation brief from the approved contract and the initialization result. Give the agent its assigned worktree, base, scope, checks, and remaining time, but no token or credentials.

Start the approved session inside the worktree:

```powershell
Set-Location -LiteralPath $run.WorktreePath
copilot --agent workflow-implementer --model $approvedModelId
```

Confirm the actual selected model and loaded role before providing repository content. Keep normal tool permissions active. Submit the implementation brief. The operator supervises time and tool requests: this package does not terminate a live Copilot session automatically when a budget expires.

## 4. Capture a candidate

When the implementer hands back the result, stop further editing. Inspect all tracked and untracked changes and stage only the approved files. For the template's README-only demonstration:

```powershell
git -C $run.WorktreePath status --short
git -C $run.WorktreePath diff -- README.md
git -C $run.WorktreePath add -- README.md
git -C $run.WorktreePath commit -m 'Implement approved task'

& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To verifying -Reason 'operator committed candidate'

& (Join-Path $scripts 'Capture-WorkflowEvidence.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken
```

Evidence capture requires a clean committed change, ancestry from the recorded base, permitted paths throughout candidate history, and an unchanged candidate after verification. A failed command produces failing evidence; a dirty or out-of-scope candidate produces no new evidence. Use the operating guide for rework.

Continue with [review and integration](operating-guide.md). A captured candidate has not yet satisfied the review or enterprise PR process.
