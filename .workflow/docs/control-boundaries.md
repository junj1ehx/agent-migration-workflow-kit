# Control boundaries

## Implemented local gates

The task is validated against JSON Schema before worktree allocation. Additional checks resolve the repository and base, validate external paths, restrict declared model-family labels, reject automatic-fallback intent, and require each verification executable to appear in the contract.

State transitions use a per-run file lock and owner-token match. Execution transitions check elapsed time, rework count, and review cycles. Evidence requires a clean committed candidate descended from the base. Both final changed paths and all paths touched in candidate commit history are inspected. Protected paths win over writable paths; Windows path matching ignores case.

Verification starts processes with separate executable/argument values and no shell-string construction. Per-command timeouts are capped by remaining task time. Candidate identity is checked again after verification. Task/evidence hashes and head/tree identity must remain fresh during acceptance, landing, completion, and cleanup.

Review-required acceptance checks a versioned record containing a distinct reviewer label, approval decision, candidate commit, and exact evidence digest. The copied review record is hashed and checked again before landing, completion, and cleanup. Completion requires candidate ancestry in the supplied integration commit. Cleanup previews by default, uses native Git without force, and retains the branch and run records.

## Controls supplied by the work environment

| Area | What the package provides | What the environment/operator supplies |
| --- | --- | --- |
| Models | Family/intent fields and profiles requiring a pinned model | Approved exact IDs, accessible account, actual model verification, enterprise restrictions |
| Tools | Explicit role tools and task executable labels | Review of command arguments/project scripts, client tool permissions, protected machine policy |
| Files | Candidate scope rejection and external state placement | Filesystem permissions/isolation, protection of state/task/configuration, stopping competing writers |
| Network | Task declares local verification; profiles omit web/MCP tools | Egress controls and permission decisions for shell processes, Git, dependencies, telemetry, and provider access |
| Review | Fresh packet, record format, digest binding, different label | Fresh session, actual reviewer identity, assessment of findings, authenticated enterprise approval |
| Integration | Git ancestry check | PR identity, target branch, CI status, authorized merge, supported merge strategy |
| Budgets | Transition limits and verification timeouts | Live-session supervision, token/billing measurement, account spending limits |

`allowNetwork=false` expresses verification intent; it cannot prevent a permitted executable from accessing a network. Likewise, `execute` can write outside the worktree or launch other programs unless external permissions prevent it. A shell allowlist based only on executable names is insufficient for security enforcement.

Repository instructions and custom-agent profiles are configuration, not an immutable enterprise boundary. More specific or user-level configurations may change the loaded profile. Validate the actual client behavior and protect configuration changes through the repository process.

The owner token and reviewer label coordinate trusted operators; they do not authenticate users or defend against an actor who can edit the external state files. Apply approved filesystem permissions to those locations. Git worktrees separate checkouts while sharing Git objects and repository configuration; they are not process sandboxes. Path canonicalization does not establish a security boundary across symlinks, junctions, or other filesystem aliases.

## Operational limits

- Only clean, committed candidates are supported. Uncommitted patch recovery and automated token takeover are unavailable.
- State/event writes are serialized but not transactional. Inspect partial writes manually.
- Budgets do not stop a live model session automatically. There is no scheduled watchdog or token meter in this package.
- Verification output is hashed, not retained as raw logs. Capture necessary diagnostic output separately using the approved retention process. Process output is buffered in memory, so avoid unbounded-output commands.
- A check that exits successfully can still be inadequate or modify ignored/external files. Use trusted verification definitions and review their coverage.
- Squash/rebase merge equivalence, authenticated PR lookup, automatic push/merge, and multi-writer orchestration are unavailable.
- Cleanup does not establish that processes have stopped and does not archive ignored files. The operator handles both before removal.
- Existing run records from another script/schema version must not be reused blindly. Start fresh runs with a matched script/schema set and retain older records for inspection.

## Environment setup check

From the target repository, after replacing the profile placeholders:

```powershell
& ./.workflow/scripts/Test-WorkflowSetup.ps1 `
  -RepositoryRoot (Get-Location).Path `
  -ApprovedModelIds @('REPLACE_WITH_EXACT_APPROVED_ID') |
  ConvertTo-Json -Depth 10
```

Replace the sample ID with the approved list. The check inspects prerequisites, local schema files, and profile fields. It does not authenticate to Copilot, verify billing/model availability, inspect user-level overrides, or prove the client's actual tool restrictions. Complete the real environment acceptance exercise in the operating guide.
