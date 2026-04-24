# Self-heal demo: the @-mention-PR-author handoff

A repeatable, customer-facing walkthrough of one specific pattern for
self-healing CI: when CI fails, open a tracking issue that **@-mentions
the PR author with a one-click `gh` snippet**, and let the human assign
the GitHub Copilot cloud agent. No PAT. No long-lived OAuth refresh
token. One human click.

## What you'll see

1. `pwsh .github/skills/selfheal-demo/run-demo.ps1` opens a
   deliberately-broken PR (`[demo] Self-heal walkthrough: Node 22 +
   crypto.createCipher`).
2. CI fails on that PR within ~30 s.
3. The `Demo Self-heal` workflow opens a tracking issue that mentions
   the PR author and includes a copy-paste `gh issue edit … --add-assignee
   copilot-swe-agent` snippet, **and** posts a comment on the source PR
   linking to the tracking issue.
4. You (or the PR author) assign Copilot to the tracking issue. The
   agent opens a fix PR off `main` within ~10 min (Batch 1 median: 8 min).

## Why this design

The Copilot cloud agent only starts when assigned to an issue, and
[GitHub explicitly requires a user identity for that
assignment](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-a-pr#assigning-an-issue-to-copilot-via-the-github-api).
Confirmed empirically in this repo: GitHub App installation tokens
silently fail (REST returns 201 but drops the bot; GraphQL hard-errors).
A PAT or App user-to-server token works — but both are stored user
credentials with the same business-continuity problem (what happens when
the user leaves?).

This pattern accepts the loss of unattended dispatch in exchange for
**no stored user credentials**. The PR author is the natural party to
click "assign" — they were going to look at the failure anyway.

### What this demo deliberately is *not*

- Not a circuit breaker, not a retry strategy, not a transient-failure
  filter. (See the predecessor at tag `v0-governance-reference` if you
  want those.)
- Not a multi-scenario classifier. One scenario, picked because it has
  validated 5/5 success in unguided trials (see
  [`../experiments/README.md`](../experiments/README.md), Batch 1).
- Not auto-merging the agent's fix. Human still reviews.

## Architecture

```
┌──────────────┐  push   ┌──────────┐  failure   ┌──────────────────┐
│ PR author    │────────►│   CI     │───────────►│ Demo Self-heal   │
│ (you)        │         │ workflow │            │    workflow      │
└──────┬───────┘         └──────────┘            └────────┬─────────┘
       │                                                  │
       │             ┌────────────────────────────────────┤
       │             │ open issue (@-mention author)      │
       │             │ comment on source PR with link     │
       │             ▼                                    │
       │      ┌──────────────┐                            │
       │      │ tracking     │                            │
       │      │ issue        │                            │
       │      └──────┬───────┘                            │
       │ (1 click)   │                                    │
       └────────────►│ assign copilot-swe-agent           │
                     ▼                                    │
              ┌──────────────┐                            │
              │ Copilot      │  opens fix PR off main     │
              │ cloud agent  │───────────────────────────►│
              └──────────────┘                            │
                                                          ▼
                                                   ┌──────────┐
                                                   │ fix PR   │
                                                   │ (review) │
                                                   └──────────┘
```

Demo scope is the path between **CI failure** and **agent assignment**.
The agent's fix PR and your review of it are outside the responder's
scope.

## Run it yourself

### Prerequisites

- The repo-level setup in [`../../../README.md`](../../../README.md) is complete:
  - `selfheal-orchestrator-mjh` GitHub App installed.
  - Repo variable `APP_ID` and secret `APP_PRIVATE_KEY` set.
  - Actions permissions: read+write, allow PR approval.
  - Copilot is in `suggestedActors(CAN_BE_ASSIGNED)` for this repo.
- Local: `git`, `gh` (authenticated as a **user**, not just an App), and
  `pwsh` (Windows/macOS/Linux) **or** `bash`.
- A clean clone, but you do **not** need a clean working tree on `main`
  — the runner uses a sibling worktree and never touches your checkout.

### One command

```pwsh
pwsh .github/skills/selfheal-demo/run-demo.ps1
```

or

```bash
.github/skills/selfheal-demo/run-demo.sh
```

The script prints the demo PR URL and the `gh issue edit` snippet to
copy once the tracking issue appears.

### Expected timeline

| Step | Wallclock |
|---|---|
| `run-demo` opens demo PR | < 5 s |
| CI fails on the demo PR | ~30 s after push |
| `Demo Self-heal` workflow runs (issue + PR comment) | ~30 s after CI fails |
| You click "assign Copilot" | (manual; the demo's payload) |
| Agent opens fix PR | ~3–10 min after assignment (Batch 1 median: 8 min) |
| Agent CI runs (may need rerun, see below) | ~1 min once unblocked |

**Heads-up on bot CI runs.** GitHub gates first-party-bot-authored CI
runs (`action_required`) by default; you may need to click "Approve and
run workflows" on the agent's fix PR. This is repo-wide GitHub
behaviour, not a defect of the demo.

## Reset

```pwsh
pwsh .github/skills/selfheal-demo/reset-demo.ps1
```

or

```bash
.github/skills/selfheal-demo/reset-demo.sh
```

Closes the demo PR (and its branch), closes the tracking issue,
removes the worktree, deletes any lingering `demo/*` remote branches,
and prunes worktree metadata. Idempotent.

> **Tip.** If you abandon a fix PR halfway through (agent still
> running), close it manually first; otherwise `reset-demo` will leave
> it open (the filter is `[demo]` titles only, and Copilot's PRs don't
> use that prefix).

## Use from VS Code chat

This directory **is** the skill — VS Code auto-discovers skills under
`.github/skills/<name>/`, so [`SKILL.md`](SKILL.md) is live as soon as
you open the workspace. After that:

> "Run the self-heal demo."
> "Reset the self-heal demo."

The skill wraps the same scripts and surfaces their output back into
chat.

## Files

| Path | Role |
|---|---|
| [run-demo.ps1](run-demo.ps1) / [run-demo.sh](run-demo.sh) | Inject + push + open PR; records state under `.state/` (gitignored). |
| [reset-demo.ps1](reset-demo.ps1) / [reset-demo.sh](reset-demo.sh) | Idempotent cleanup. |
| [SKILL.md](SKILL.md) | Chat-invokable wrapper (auto-discovered from `.github/skills/`). |
| [`../../workflows/demo-self-heal.yml`](../../workflows/demo-self-heal.yml) | Demo responder workflow (scoped to `demo/*` branches). |
| [`../../DEMO_CI_FAILURE_TEMPLATE.md`](../../DEMO_CI_FAILURE_TEMPLATE.md) | Tracking-issue template (with `@author` mention + `gh` snippet). |

## Relationship to the experiment harness

The repo's experiment workflow (`.github/workflows/self-heal.yml`)
**ignores `demo/*` branches** so trial data stays comparable across
batches. The demo lives entirely in `.github/skills/selfheal-demo/` and
`.github/workflows/demo-self-heal.yml`. The fixture (`src/Web/`) and
inject mutations are shared; the runner deliberately duplicates the
mutation block from `scripts/inject.ps1` rather than refactor a shared
helper, again to keep the experiment scripts byte-stable.
