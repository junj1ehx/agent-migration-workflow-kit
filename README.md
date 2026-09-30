# Repository agent workflow kit

This folder is a self-contained configuration and operations package for one coding session, one read-only review session, and a human-governed pull request. Copy its contents into a Git repository after merging any existing configuration files.

The local workflow records a task contract, creates an owned Git worktree, checks candidate file scope, runs declared verification, binds review to a specific commit and evidence digest, and checks integration before cleanup. Copilot supplies the coding and review sessions; the scripts supply the local workflow gates.

## Start here

1. Follow [quick start](.workflow/docs/quick-start.md) to install and run the first task.
2. Use [operating guide](.workflow/docs/operating-guide.md) for review, recovery, integration, and cleanup.
3. Read [control boundaries](.workflow/docs/control-boundaries.md) before enabling agent execution.
4. Use [team rollout](.workflow/docs/team-rollout.md) to measure usefulness and cost.

## Package layout

```text
.github/
  agents/                       implementer and read-only reviewer profiles
  copilot-instructions.md       repository instruction fragment to merge
.workflow/
  docs/                         setup, operation, boundaries, rollout
  scripts/                      local workflow commands
  schemas/                      task, state, evidence, review contracts
  templates/                    task and session-brief templates
  tests/Run-SmokeTest.ps1        disposable local Git experiment
```

Requirements: Windows, PowerShell 7.4 or newer, Git, and a repository with at least one commit. Copilot CLI access and an approved model are required for the Copilot session steps. Use your approved IDE interface for equivalent manual session steps when CLI access is unavailable; the local scripts still work.

The agent profiles contain a model placeholder. Replace it with an exact approved model ID before use. This package does not select a provider, install tools, alter enterprise policy, push commits, create pull requests, or merge changes automatically.

## Verification and current capability

Run the disposable fixture from the repository root:

```powershell
& ./.workflow/tests/Run-SmokeTest.ps1 | ConvertTo-Json -Depth 10
```

The fixture exercises the local workflow and negative gates. It does not call a model or an enterprise service. Copilot profile loading, actual model selection, reviewer tool restrictions, and enterprise PR integration require the environment acceptance steps in the operating guide.

For a package check that copies the kit into an independent temporary repository and runs the same gates there:

```powershell
& ./.workflow/tests/Test-PortablePackage.ps1 | ConvertTo-Json -Depth 15
```

The package check uses a synthetic model label only to inspect local profile configuration. It does not establish model availability or invoke Copilot.

Start with one implementation task at a time. State and review records are operator-controlled local attestations. Filesystem isolation, network controls, authenticated review, billing limits, and protected merge remain responsibilities of the work environment.
