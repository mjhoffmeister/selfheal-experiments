# selfheal-experiments

A test harness for honestly measuring whether the GitHub Copilot cloud agent can
resolve realistic CI failures unaided. **This is an experiment, not a demo.**

The fixture is small and deliberately uninteresting; the interesting bits live in
[experiments/README.md](experiments/README.md) (rubric, trial procedure, scenario
rationale) and [experiments/trials.jsonl](experiments/trials.jsonl) (append-only
trial log).

See also [.github/skills/selfheal-demo/](.github/skills/selfheal-demo/) for
a customer-facing walkthrough of the @-mention-PR-author handoff pattern
(built on the same fixture; isolated from the experiment harness so trial
data stays byte-stable). Packaged as a VS Code skill so it's chat-invokable.

## Predecessor

Architectural patterns (issue-assignment dispatch, App-token minting, SHA-pinned
actions, per-job `permissions:` blocks, dedupe key) are carried from
`mjhoffmeister/self-healing-pipeline`, preserved at tag
`v0-governance-reference`. Application code is not carried over by design.

## Conventions

- **Pin every third-party action by full commit SHA** with a trailing `# vX.Y.Z`
  comment.
- **No PATs.** Cross-identity work uses a runtime-minted GitHub App installation
  token (`actions/create-github-app-token` with `vars.APP_ID` +
  `secrets.APP_PRIVATE_KEY`).
- **Per-job `permissions:`** blocks, minimum viable.
- **Loop guard.** Any responder logic guards `github.actor != 'copilot-swe-agent[bot]'`.

## Layout

```
.github/
  CI_FAILURE_TEMPLATE.md       Issue body template (envsubst-rendered)
  DEMO_CI_FAILURE_TEMPLATE.md  Issue body template for the demo flow
  copilot-instructions.md      Per-repo agent guardrails (filled in X6)
  workflows/
    ci.yml                     Builds + tests src/Web/
    self-heal.yml              Experiment responder (skips demo/* branches)
    demo-self-heal.yml         Demo responder (scoped to demo/* branches)
src/Web/                       Node fixture (Express + jest)
scripts/                       Experiment inject scripts (PowerShell + bash)
experiments/                   Trial procedure + log
.github/skills/selfheal-demo/  Customer-facing walkthrough (run/reset + SKILL.md)
```

## External setup (one-time, not scripted)

1. Repo variable `APP_ID` (App ID of `selfheal-orchestrator-mjh`).
2. Repo secret `APP_PRIVATE_KEY` (the App's RSA private key, PEM).
3. Install the App on this repository.
4. Settings → Actions → General: workflow permissions = read+write, allow PR approval.
5. Confirm the agent is assignable:
   ```pwsh
   gh api graphql -f query='query { repository(owner:"<owner>", name:"selfheal-experiments") { suggestedActors(capabilities:[CAN_BE_ASSIGNED], first:25) { nodes { login __typename } } } }'
   ```
   Expect a `Bot` node with `login: "copilot-swe-agent"`.
