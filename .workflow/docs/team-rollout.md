# Team rollout and measurement

## Pilot tasks

Begin with a small, well-specified change in one repository: a regression test and fix, a small refactor with existing tests, or a bounded documentation change. Select work that already has a human-review baseline and clear acceptance criteria.

Use one implementer, one fresh read-only reviewer, and the existing enterprise PR process. Keep configuration changes separate from development tasks. Add concurrency only after task dependencies and worktree ownership can be demonstrated; this package does not implement a dispatcher or concurrent landing queue.

## Compare outcomes

Record the same measures for a conventional assisted task and for a workflow task:

| Measure | Definition |
| --- | --- |
| Lead time | Task confirmation to accepted PR/integration, including review and waiting |
| Human effort | Minutes of planning, supervising, reviewing, fixing, and operating the workflow |
| Quality | Accepted behavior, test coverage relevant to the change, defects found before/after merge |
| Rework | Implementation attempts, review rounds, failed checks, and reasons |
| Reliability | Scope failures, interrupted runs recovered, evidence mismatches, cleanup failures |
| Cost | Actual provider/billing usage for implementation and review, plus operator time |
| Reuse | Time needed to apply the package to another repository and configure its checks |

Compare tasks of similar size and risk. Record uncertainty and task difficulty instead of attributing all changes in performance to the workflow. A passing local fixture establishes script behavior, not productivity improvement.

## Token and spending controls

Use a capable approved model for difficult implementation or review, and a lower-cost approved model only where evaluations show it retains quality. Keep role instructions focused, pass the relevant task and diff rather than unrelated history, and stop repeated unproductive attempts.

Measure implementation, review, and recovery separately. Provider token counts, Copilot billing units or requests, and monetary cost are different measures. Use the work environment's actual billing reports and current plan terms; do not infer one from another. The scripts track elapsed time and attempt/review counts, not tokens or money.

Set a pilot usage cap through the approved account controls. Define when a task needs human escalation and when another attempt merits its additional cost. Higher spend should buy a measurable reduction in human effort or defects, or completion of work that a cheaper configuration could not reliably perform. Avoid stating an improvement percentage before measurement.

## Adoption gates

Promote the package to routine use after the local fixture and real environment acceptance pass, the team can recover an interrupted task, reviewers can reproduce the evidence, and the matched-task pilot shows acceptable quality and total cost.

Retain the task ID, commit identities, verification/review summaries, PR/CI links in the enterprise system, usage totals, and failure classifications according to the work environment's retention rules. Keep credentials, owner tokens, unrelated source, and unnecessary personal data out of shared reports.

For updates, review the script/profile/schema diff, rerun the local fixture, and complete a representative environment task. Start new runs with the updated version. To stop adoption, stop sessions and return to the repository's established development process while retaining unfinished branches and run records until reviewed.
