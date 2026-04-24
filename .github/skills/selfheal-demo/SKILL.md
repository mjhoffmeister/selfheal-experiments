---
name: selfheal-demo
description: 'Run or reset the self-heal walkthrough demo in this repo. USE FOR: showing the @-mention-PR-author handoff pattern end-to-end (inject a CI failure, watch the demo workflow open a tracking issue and PR comment, then assign Copilot manually). Trigger phrases: "run the self-heal demo", "demo the self-healing pattern", "show the selfheal-experiments demo", "reset the self-heal demo", "clean up the self-heal demo". Wraps run-demo.ps1 and reset-demo.ps1 (next to this SKILL.md). DO NOT USE FOR: experiment trials (use scripts/inject.ps1 + experiments/trials.jsonl); fixture changes; workflow changes.'
---

# selfheal-demo

Drives the customer-facing walkthrough packaged with this skill. The skill
lives at `.github/skills/selfheal-demo/` and VS Code auto-discovers it from
that location — no manual install step.

## Operations

### `run` — start a demo run

Run when the user asks to start, run, kick off, or trigger the demo.

1. **Pre-flight** — verify all of:
   - Current working directory is the `selfheal-experiments` repo root
     (check for `.github/skills/selfheal-demo/run-demo.ps1`).
   - `gh auth status` reports an authenticated **user** (not just an App).
     If not, stop and tell the user — App tokens cannot assign Copilot,
     which is the entire point of the demo.
   - No open `[demo]` PR already exists. (`gh pr list --state open
     --search '"[demo]" in:title' --json number --jq 'length'` returns 0.)
     If one exists, ask whether to reset first; do not silently `-Force`.
2. **Invoke** — run `pwsh .github/skills/selfheal-demo/run-demo.ps1` from
   the repo root. (On non-Windows: `bash
   .github/skills/selfheal-demo/run-demo.sh`.) The user's working tree is
   never modified — the script uses a sibling worktree.
3. **Report** — surface the script's printed output to the user, in
   particular:
   - The demo PR URL.
   - The expected wait (~30 s for CI to fail; ~8 min median for the
     agent's fix PR after manual assignment).
   - The exact `gh issue edit <NUMBER> --add-assignee copilot-swe-agent`
     snippet, with `<NUMBER>` left as a placeholder until the tracking
     issue actually appears.
4. **Do NOT** attempt to assign Copilot programmatically. The manual
   click is the demo's payload.

### `reset` — clean up after a run

Run when the user asks to reset, clean up, tear down, or repeat the demo.

1. Invoke `pwsh .github/skills/selfheal-demo/reset-demo.ps1 -Force` (skill
   always passes `-Force` — the user already asked for the reset by
   invoking the skill).
2. Surface the printed output. The script is idempotent; "nothing to
   clean" is a success path.

## Pre-flight checklist (both operations)

- `git` and `gh` on PATH.
- Repo has the App installed and `Demo Self-heal` workflow present at
  `.github/workflows/demo-self-heal.yml`.
- Authenticated `gh` user has access to the repo.

## Files this skill touches

- Reads / executes (next to this SKILL.md):
  [run-demo.ps1](run-demo.ps1), [run-demo.sh](run-demo.sh),
  [reset-demo.ps1](reset-demo.ps1), [reset-demo.sh](reset-demo.sh).
- Reads only (for context if the user asks why something happened):
  [README.md](README.md),
  [../../workflows/demo-self-heal.yml](../../workflows/demo-self-heal.yml),
  [../../DEMO_CI_FAILURE_TEMPLATE.md](../../DEMO_CI_FAILURE_TEMPLATE.md).

## Anti-patterns

- **Do not** edit the workflow or the inject scripts to make the demo
  "more reliable." The current fixture has 5/5 success in Batch 1; the
  variability sits with the agent, not the harness.
- **Do not** attempt to bypass the manual assignment step by introducing
  a PAT or OAuth user-to-server token. That defeats the point of the
  walkthrough — see [README.md](README.md).
- **Do not** run `reset` while a Copilot fix-PR session is in progress;
  the agent will lose context. Wait for the fix PR to be opened (or
  abandoned) first.
