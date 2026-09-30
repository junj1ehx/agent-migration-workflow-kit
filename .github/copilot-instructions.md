# Repository workflow instructions

Merge these instructions with any existing repository instructions before use.

Every implementation task has an operator-approved task brief, one worktree, explicit writable and protected paths, acceptance criteria, an approved model, and a time budget. Protected paths take precedence. The operator retains workflow state and the owner token outside the checkouts.

Implementers edit only within their assigned scope and report observed verification results. Reviewers use a fresh read-only session and review the exact committed candidate. Changing the candidate requires new verification and new review.

Do not modify `.workflow/`, `.github/agents/`, policy files, or instructions during an ordinary implementation task. Workflow configuration changes require a separate task reviewed by its maintainer.

Ask the operator when scope, requirements, required tools, or policy are unclear. Stop repeated attempts when a budget is exhausted. Preserve partial work and explain the blocker.

Remote Git operations, pull requests, authenticated approvals, and merging follow the repository's existing process. Consult `.workflow/docs/operating-guide.md` for the local handoff procedure.
