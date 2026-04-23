# Experiments

This directory holds the experimental protocol, the rubric, and the trial log.
Read it end-to-end before running anything.

## Question under test

Can the GitHub Copilot cloud agent, given only an issue assignment and a
failing CI run, resolve a transitive Node dependency conflict caused by an
`engines.node` bump — without per-repo guidance?

Pass and fail are equally valid outcomes. If the answer is "no," that's data.
If the answer is "yes," that's data. If the answer is "sometimes," we want N
big enough to characterise the spread.

## Anti-bias rules

Re-read before each trial. From `/memories/selfheal-experiments-handoff.md`:

1. Do **not** tune the fixture between trials. If trial 1 fails because the
   package is weird, that's a finding. Document and move on.
2. Do **not** add `copilot-instructions.md` content pre-emptively. Run with
   no guidance first. If results are bad, *then* add guidance — that
   comparison is the useful data.
3. Do **not** write the results section before running trials.
4. Do **not** skip the trial log even for "just a quick check." Five
   untracked runs are still anecdote.
5. Do **not** cherry-pick the inject pair for likely agent success. Pick
   something plausible / real-app-like / honestly typical.
6. N=5 is small. If results are bimodal or surprising, plan for N=10+.
   State the N in any writeup.

## Fixture rationale

`src/Web/` is a deliberately small Express app:

- **express 4.19.2** — most common Node web framework; in real apps everywhere.
- **dotenv 16.4.5** — typical config loader.
- **pino 8.21.0** — common production logger; non-trivial transitive tree
  (sonic-boom, pino-abstract-transport, etc.).
- **jest 29.7.0** + **supertest 6.3.4** — standard test stack.

These were chosen because they look like dependencies a real Node service
would ship with. **They were not chosen because they are known to fail under
any specific Node bump.** That's deliberate — we want the inject to surface a
plausible real-world problem, not a contrived one.

## Inject scenario

`scripts/inject-dep-conflict.{ps1,sh}` performs four coupled mutations on a
fresh branch off `main`:

1. `src/Web/package.json` — bumps `engines.node` from `18.x` to `22.x`.
2. `src/Web/package.json` — adds `bcrypt@5.0.1` as a direct dependency.
   bcrypt 5.0.1 has no prebuilt binaries for Node 22, so `npm ci` falls
   through to a node-gyp source build that fails.
3. `.github/workflows/ci.yml` — bumps `setup-node` `node-version` from
   `18.20.4` to `22.11.0`.
4. `src/Web/.npmrc` — written with `engine-strict=true` (defence-in-depth;
   not the primary failure trigger now).

The script also regenerates `package-lock.json` via `npm install
--package-lock-only --ignore-scripts` so the lock matches the new
`package.json` without invoking native postinstall on the local box (which
would defeat the purpose).

### Iteration history

**v1 (deleted):** bare `engines.node` bump + `engine-strict=true`. Tested
empirically on 2026-04-23 against PR #1 — CI passed in 13s. Modern packages
declare permissive `engines.node`, so nothing fired. Documented and
iterated ONCE per the anti-bias rule (rule #1 forbids per-trial tuning;
this was a pre-trial infra fix, not tuning between trials).

**v2 (current):** above. Honest about the scenario class drift: this is
now "native-module install fails after Node major bump" rather than
"transitive engines conflict". Both are realistic real-world failure
modes a Node service hits when bumping Node majors; the test of agent
capability is comparable.

### Alternatives still on the table (not chosen)

If v2 also fails to produce a CI failure, or if results are uninteresting,
these remain available:

| Variant | Why considered | Why not (yet) chosen |
|---|---|---|
| Pin `eslint@7.x` as a direct dep | Older ESLint has narrower Node support | ESLint isn't a runtime dep of the fixture; would feel transparently bolted-on. |
| Use npm `overrides` to pin a transitive to an old version | Cleanest "transitive surfaces" story | Hard to pick a transitive whose old version actually breaks on Node 22 without local trial-and-error. |
| Add a test that uses `crypto.createCipher` (removed in Node 22) | Reliable runtime failure | That's a fixture bug, not a dependency conflict — wrong scenario class. |
| Pin `node-sass@4.x` | Famously Node-version-coupled real-world legacy dep | Same class as bcrypt (native module); pick one. |

### Expected agent strategies

The trial log records `agent_proposed_strategy` as one of:

- **bump-bcrypt** — bumps bcrypt to a version with Node-22 prebuilds (the
  obviously-correct fix; bcrypt 5.1.1+).
- **swap-bcrypt** — replaces bcrypt with `bcryptjs` (pure-JS, no native
  build). Reasonable but a wider change.
- **overrides** — adds `overrides` in `package.json` to pin a transitive
  forward (less applicable now that the failure is a direct dep, but
  possible if the agent misreads the failure).
- **rollback** — reverts the Node bump or removes bcrypt entirely (counts
  as `wrong-but-passing` per the rubric below — makes CI green by
  abandoning the intended change).
- **none** — no strategy proposed; PR is empty or doesn't address the issue.

## Outcome rubric

| Outcome | Meaning |
|---|---|
| `fixed` | Agent's PR makes CI green AND keeps the Node bump AND the fix is reasonable. |
| `wrong-but-passing` | CI green BUT rolled back the Node bump, OR the fix is sketchy (disabled the failing test, removed the dep entirely, etc.). |
| `no-op` | PR opened with no meaningful changes, or no PR opened. |
| `escalated` | Circuit breaker fired. (Not applicable in current responder; reserved for future.) |
| `error` | Setup broke; agent never started; infra failure. **Does not count toward N.** |

## Trial procedure

For each trial:

1. Confirm `main` is green (CI passes the baseline).
2. Confirm working tree is clean.
3. Run `pwsh scripts/inject-dep-conflict.ps1` (or the bash equivalent).
   Capture the resulting PR URL.
4. Wait for CI to fail on the inject PR. Confirm `self-heal.yml` opens a
   tracking issue and assigns `copilot-swe-agent`.
5. Watch for the agent's fix PR (it will open off `main`, **not** off the
   inject branch — see `/memories/selfheal-strategic-learnings.md`).
6. When the agent's PR settles (CI green or the agent stops responding for
   ~30 min), record outcome.
7. Append one JSON object to `trials.jsonl`. Schema below.
8. Close both PRs without merging. Close the tracking issue. Delete both
   branches. Reset `main` to baseline-green state.

## Trial log schema (`trials.jsonl`)

One JSON object per line; append-only.

```json
{
  "trial_id": "T001",
  "timestamp_utc": "2026-04-24T14:00:00Z",
  "fixture_sha": "abc1234",
  "node_from": "18",
  "node_to": "22",
  "injected_constraint": "engines.node 18.x -> 22.x + .npmrc engine-strict=true",
  "context": "pull_request",
  "instructions_present": false,
  "agent_session_started": true,
  "agent_pr_url": "https://github.com/.../pull/N",
  "agent_proposed_strategy": "overrides | parent-bump | patch-package | rollback | none",
  "agent_kept_node_bump": true,
  "agent_diff_files": ["src/Web/package.json", "src/Web/package-lock.json"],
  "agent_diff_in_scope": true,
  "ci_on_agent_pr": "green | red | not-run",
  "outcome": "fixed | wrong-but-passing | no-op | escalated | error",
  "wallclock_minutes": 12,
  "runner_os": "ubuntu-24.04",
  "node_version": "22.11.0",
  "npm_version": "10.9.0",
  "wallclock_minutes_note": "from inject PR push to agent PR settled",
  "notes": "free text"
}
```

## Reproducibility notes

- `package-lock.json` is committed; CI uses `npm ci`, never `npm install`.
- `actions/setup-node` pins both Node and (transitively) npm.
- Run trials back-to-back same day if possible to minimise registry drift.
- Each trial entry records `runner_os`, `node_version`, `npm_version`.

## Results

> Empty until at least N=5 trials have been recorded.
> Per anti-bias rule #3: do not write this section pre-emptively.
