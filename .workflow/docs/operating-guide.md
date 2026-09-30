# Operating guide

Use the operator variables from the quick start: `$scripts`, `$run`, `$runDirectory`, and `$ownerToken`. The scripts are local controls. Execute them from the trusted configuration checkout, while the agent edits only its assigned worktree.

## Commands and records

| Command | Purpose |
| --- | --- |
| `Initialize-WorkflowRun.ps1` | Validate a task and allocate an external worktree with an owner token |
| `Set-WorkflowState.ps1` | Apply transitions, execution budgets, evidence gates, review gates, and integration checks |
| `Capture-WorkflowEvidence.ps1` | Check committed scope and run approved verification commands |
| `Export-WorkflowReviewPacket.ps1` | Export the task, exact diff, and verification evidence for review |
| `New-WorkflowReviewRecord.ps1` | Record the operator's attestation of a review decision |
| `Get-WorkflowStatus.ps1` | Inspect the current state and candidate without changing it |
| `Test-WorkflowCleanup.ps1` | Explain cleanup eligibility |
| `Remove-WorkflowWorktree.ps1` | Preview removal or remove an eligible worktree while retaining its branch |
| `Test-WorkflowSetup.ps1` | Inspect prerequisites and repository profile/model configuration |

Each run stores `state.json`, `events.jsonl`, and a lock file outside the checkouts. Verification adds `evidence.json`; approved review adds `review.json`. State contains the hashes of the task, evidence, review, and owner token. A review packet contains source code and should remain in approved local storage.

The usual path is:

```text
ready -> running -> verifying -> needs_review -> accepted
      -> landing -> completed -> cleanup eligibility
```

`accepted` means local checks and the required local attestation have passed for that candidate. `completed` means the supplied integration commit contains the candidate. Neither status independently authenticates a PR or a human identity.

## Request a fresh review

After successful verification:

```powershell
& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To needs_review -Reason 'verification passed; request review'

$packetPath = Join-Path $runDirectory 'review-packet-1.json'
$packet = & (Join-Path $scripts 'Export-WorkflowReviewPacket.ps1') `
  -RunDirectory $runDirectory -OutputPath $packetPath
```

The packet binds the review input to the task, base, head, tree, and evidence digest. Output files must be outside the checkouts and use new names. Start a fresh Copilot session in the assigned worktree with `workflow-reviewer` and an explicit approved model. The implementer must remain stopped while the reviewer reads the worktree. Supply the review brief and packet content using the approved interface. The reviewer has read/search tools and reads the recorded results; the operator runs any additional checks.

Confirm that the reviewer actually lacks edit, shell, network, and delegation tools in the installed client. Verify its reported commit and evidence digest against the packet. Ask for concrete findings and missing checks. A different role name or model does not by itself prove independent or authenticated review.

After assessing the review, the operator records its decision:

```powershell
$reviewInput = Join-Path $runDirectory 'review-input-1.json'
& (Join-Path $scripts 'New-WorkflowReviewRecord.ps1') `
  -RunDirectory $runDirectory -ReviewerId 'review-session-1' `
  -Decision approve -Summary 'Describe the checks reviewed and remaining concerns.' `
  -OutputPath $reviewInput

& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To accepted -Reason 'operator attested independent review' `
  -ReviewRecordPath $reviewInput
```

Acceptance checks the review schema, distinct reviewer label, approval decision, head, and evidence hash. The label is an operator assertion; it is not an authenticated identity. A local record cannot replace code-owner or human PR approval required by the repository.

For `request_changes`, write that decision using the same record command, preserve the findings, and return to `running` with a concrete rework reason. Rework consumes the retry budget. Commit the revision, enter `verifying`, capture new evidence, and request another review. Prior evidence and review are cleared when implementation resumes. New candidates require new review even when the change is small.

Review-optional tasks can move from `verifying` directly to `accepted` after passing checks. Keep review required for the initial team pilot.

## Failure and bounded rework

| Condition | Operator action |
| --- | --- |
| Verification command fails or times out | Preserve evidence; inspect the failure; return `verifying -> running` if budget permits |
| Missing executable or working directory | Preserve work; classify setup failure; correct the environment or create a revised contract/run |
| Dirty candidate or changed HEAD | Stop editing; inspect and commit intentionally; capture new evidence |
| Out-of-scope commit, even if later undone | Preserve the rejected branch; start a new approved run and carry only permitted changes with operator review |
| Required check or objective must change | Create a new contract revision and run; keep the old run for inspection |
| Candidate changes after acceptance | Move `accepted -> needs_attention`; rework only within remaining budgets, then recapture and re-review |
| Retry, review, or elapsed budget exhausted | Stop model execution; preserve the run and decide whether a new authorized revision/run is justified |

Budget gates run when implementation/verification/review is entered and when checks run. Verification commands receive the smaller of their timeout and remaining elapsed time. No background watchdog kills the model session, detects waiting for input, or meters tokens. The operator stops the live session at its deadline and records an interruption or attention state.

Retries count transitions from `verifying`, `needs_review`, or `needs_attention` back to `running`. Resume through `interrupted -> ready -> running` keeps the same attempt and elapsed deadline. A review cycle is consumed on entry to `needs_review`. Do not use resume to disguise rework or bypass an exhausted retry count.

## Interrupt and recover

Stop the active session first. From `running`, `verifying`, `needs_review`, `accepted`, or `landing`, enter `interrupted` with a concrete reason:

```powershell
& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To interrupted -Reason 'operator stopped the session'

& (Join-Path $scripts 'Get-WorkflowStatus.ps1') -RunDirectory $runDirectory
```

Preserve the branch, worktree, task, state, events, and evidence. Inspect Git status and the last event before deciding to resume. A supported resume uses the same token and `interrupted -> ready -> running`, then fresh verification and review. The elapsed deadline remains the original one.

If an event was appended but state replacement failed, stop writes and compare event sequence with state. The file pair is not a transactional database. There is no automatic event replay or token takeover. A lost token, unexplained mismatch, or partial initialization requires manual inspection and a new controlled run where appropriate; do not hand-edit state to claim completion.

Cancellation is terminal and preserves the checkout. Normal cleanup deliberately requires completion, so abandoned runs are retained until the operator applies an approved separate retention procedure.

## Enterprise PR and integration

From an accepted candidate, enter `landing`. Use the existing enterprise workflow to push only to its approved remote, create the PR, run CI, receive required reviews, and merge. The scripts perform no remote operation. Record the PR and CI evidence in the enterprise system; do not put private source or workflow packets on public GitHub.

Before landing, resolve the candidate commit and compare it with the PR head. If PR content changes, repeat verification and review for the actual new candidate. Branch protection, authenticated approvals, and merge permission remain enforced by the enterprise repository.

After approved integration, bring the integration commit into the local object database through the normal authorized fetch process and record its full commit ID:

```powershell
& (Join-Path $scripts 'Set-WorkflowState.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken `
  -To completed -Reason 'enterprise integration confirmed' `
  -IntegrationCommit 'REPLACE_WITH_INTEGRATION_COMMIT'
```

The integration commit must contain the verified candidate by Git ancestry. Fast-forward or ordinary merge can satisfy this. Squash merge and rebase merge commonly create different commits and will not satisfy the gate. If the repository requires either strategy, retain the worktree and record the integration in the enterprise process; this version has no squash/rebase equivalence gate. Do not change repository merge policy or supply the candidate itself merely to get cleanup approved.

Git ancestry alone cannot prove which branch was merged, that CI passed, or that a PR was authorized. The operator must confirm those in the enterprise system before supplying the commit.

## Cleanup and retention

Stop all sessions and processes using the worktree before cleanup. The scripts cannot prove they are inactive.

```powershell
& (Join-Path $scripts 'Test-WorkflowCleanup.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken

& (Join-Path $scripts 'Remove-WorkflowWorktree.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken

# After the preview is reviewed:
& (Join-Path $scripts 'Remove-WorkflowWorktree.ps1') `
  -RunDirectory $runDirectory -OwnerToken $ownerToken -Execute
```

Cleanup requires completed state, token match, unchanged task/evidence/review, clean candidate, and integrated ancestry. Removal uses native Git without force and retains the branch and run records. Untracked files make the worktree dirty. Ignored files are not evidence: save any valuable ignored files separately before removal. Branch and record deletion follow the repository's retention process.

## Environment acceptance

Before routine use, run one low-risk real task and record:

- installed Git, PowerShell, and Copilot client versions;
- loaded agent profile, actual model, and approved account;
- reviewer tool restriction observed in the real client;
- candidate, verification, review, PR/CI, and integration identities;
- one failure and one interruption/recovery exercise;
- cleanup preview and retained records.

The local fixture covers script behavior. These acceptance steps establish whether the deployed client and enterprise configuration support the same workflow.
