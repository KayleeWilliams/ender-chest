---
name: review-changes
description: Review a local Git diff for actionable bugs, regressions, and missing tests when asked to review code changes. Report findings without editing files or posting a remote review.
---

# Review changes

Establish the review scope from the request. For working-tree changes, inspect `git status --short`, `git diff`, and `git diff --cached`. For a branch review, use the requested base and its merge base. If the base is ambiguous, ask before treating unrelated commits as part of the review.

Read untracked files that belong to the requested change; `git diff` does not show their contents. Leave unrelated files outside the review.

Read the project's instructions and the callers or consumers of changed code. Trace a concrete input through the changed behavior; a suspicious line alone is not a finding.

For each potential bug, identify the trigger and observable failure. Use an existing test or a small reproduction when it can run without changing live data. Record what actually ran. If you cannot reproduce the issue, label the uncertainty and explain what would confirm it.

Prioritize broken behavior, lost data, exposed credentials, and compatibility regressions. Report style differences only when they violate a project rule or cause a concrete maintenance problem. Do not invent findings to fill a quota.

Return findings in order of impact. Include the file and line, the failing scenario, and a concise explanation of the needed correction. End with relevant validation gaps. If no actionable problems remain, say that directly.

A review request does not authorize fixes, commits, or comments on a remote PR. Keep the review local unless the user also requested those actions.
