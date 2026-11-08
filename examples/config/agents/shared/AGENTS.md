# Shared agent instructions

## Working on a task

Read the project's `AGENTS.md` and relevant package instructions before editing. Use its package manager, formatting rules, and test runner. Put project-specific exceptions in the project, so they do not affect every repository.

Check `git status` before making changes. Preserve work outside the task, including uncommitted edits. Ask a focused question when missing information would change the implementation; otherwise proceed with a stated assumption.

## Implementation

Follow an existing implementation of the same behavior before adding another pattern or dependency. Keep the change scoped to the request. If a related issue needs separate work, describe it without folding it into the patch.

Handle input at the boundary where it enters the program. Make invalid input produce an actionable error. Do not turn unexpected failures into successful empty results just to keep a command running.

## Tests and checks

Treat tests as part of implementation. For a bug fix, reproduce the failure and add a regression test when practical. Use the smallest test that can fail for the right reason; avoid tests that only repeat the implementation. Use the repository's existing test runner.

Run the checks relevant to the changed behavior before claiming it works. State which checks passed, which failed, and which could not run. Do not report a test as passing because its code looks correct.

## Writing

Lead with the outcome. Use plain words and concrete details in conversation, documentation, and UI copy. Explain decisions that affect the user, and omit filler, praise, and repeated summaries.

For a review, list reproducible problems with file references and their impact. Distinguish confirmed failures from questions. If you find no actionable issues, say so and name any gaps in verification.

## Git and pull requests

Before committing, review the staged diff and include only the task's work. A request for a review alone does not authorize editing files or posting comments remotely.

Describe the problem, resulting behavior, and validation in the PR. Keep unrelated cleanup in a separate change.

## Machines

`DEVICES.md` in the user's config checkout lists their machines and how to reach each one. The checkout's path is in `~/.config/ender-chest/repo`. Read it before working on another machine, and act on another machine only when the user asked for that machine.

## Credentials

Keep credentials, account sessions, private keys, generated tokens, and machine-specific settings out of Git. Show variable names and redacted examples when discussing configuration; do not print live tokens in logs or diffs.
