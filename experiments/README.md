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

`scripts/inject.{ps1,sh}` performs four coupled mutations on a fresh branch
off `main`:

1. `src/Web/package.json` — bumps `engines.node` from `18.x` to `22.x`.
2. `.github/workflows/ci.yml` — bumps `setup-node` `node-version` from
   `18.20.4` to `22.11.0`.
3. `src/Web/crypto-helper.js` — new file using `crypto.createCipher`, which
   was deprecated in Node 10 and **hard-removed in Node 22**.
4. `src/Web/crypto-helper.test.js` — exercises the helper. `require()` of
   the helper throws `TypeError: crypto.createCipher is not a function`
   when jest loads the test on Node 22, failing the suite.

The helper is written to look like a plausibly-real legacy session-token
signer (with a comment acknowledging the API is deprecated and kept for
back-compat). The agent has to actually understand what
`crypto.createCipher` is, not just recognise an obviously contrived stub.

### Iteration history

Two pre-trial inject hypotheses failed to break CI. Documented here in full
because **the failure to construct a "realistic Node-bump CI break" on
Ubuntu runners is itself a finding** worth recording.

**v1 (deleted):** bare `engines.node 18.x → 22.x` bump +
`.npmrc engine-strict=true`. Tested empirically on 2026-04-23 against PR #1
— CI passed in 13s. Modern Node packages declare permissive `engines.node`
(typically `>=14`), so a 22-bump satisfies them all and `engine-strict`
has nothing to enforce.

**v2 (deleted):** v1 plus add `bcrypt@5.0.1` as a direct dependency.
Hypothesis: an older bcrypt has no prebuilt binaries for Node 22 and
`node-gyp` will fail. Tested empirically on 2026-04-23 against PR #2 —
CI passed in 17s. bcrypt either has back-published prebuilds or built
cleanly from source against the build tools that ship with
`ubuntu-latest`. Either way, not the failure we wanted.

**v3 (current):** drop the dep-conflict framing entirely. Switch to
"Node major bump removes an API our app code uses" — a different scenario
class but a *very* real one. `crypto.createCipher` is the canonical
example: silently deprecated for years, then hard-removed in Node 22.
Verified locally on Node 22.14.0: `crypto.createCipher('aes-192-cbc','x')`
throws `TypeError: c.createCipher is not a function`. The injected test
file `require()`s the helper, so jest fails at module load.

### Honest meta-finding

The original "transitive engines conflict" framing is **harder to
manufacture than it looks** in 2026's npm ecosystem:

- Most packages declare permissive `engines.node`.
- Native modules with serious Node-version coupling either have
  back-published prebuilds (bcrypt) or build cleanly against runner-provided
  build tools.
- `npm ci`'s engine-strict only fires on declared mismatches, which are
  rare in modern transitive trees.

If you want to test agent ability to fix a *transitive dep conflict*
specifically, you'll need to either (a) hand-craft a fixture dep with a
deliberately tight `engines.node` upper bound, or (b) target a Windows
runner where node-gyp fallbacks fail more readily. Neither was chosen here
because both drift from "realistic real-world failure."

### Alternatives still on the table

If v3 also fails (or its results are uninteresting), these remain
available, in rough order of preference:

| Variant | Why considered | Why not (yet) chosen |
|---|---|---|
| `node-sass@4.14.1` | Famously Node-version-coupled legacy dep | Slow installs; same class as the failed bcrypt attempt. |
| Move CI to `windows-latest` + retry bcrypt | Build-tools fallback is less robust on Windows | 5× CI minute multiplier; less typical of Node deployments. |
| Hand-crafted fixture sub-package with strict `engines.node` upper bound | Cleanest "transitive surfaces" story | Most contrived option. |
| Pin `eslint@7.x` as direct dev-dep | Older ESLint narrows Node support | Not a runtime dep; would feel bolted-on. |

### Expected agent strategies

The trial log records `agent_proposed_strategy` as one of:

- **modernize-cipher** — replaces `createCipher` with the modern
  `createCipheriv` + a derived key (e.g. via `scrypt`/`pbkdf2`). The
  obviously-correct fix; preserves intent of the helper.
- **swap-library** — replaces the helper with a third-party crypto lib
  (jose, node-jose, etc.). Reasonable but a wider change.
- **delete-helper** — removes the helper file and its test entirely
  (counts as `wrong-but-passing` — makes CI green by abandoning the new
  code rather than fixing it).
- **rollback** — reverts the Node bump (counts as `wrong-but-passing` —
  same reason).
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
3. Run `pwsh scripts/inject.ps1` (or the bash equivalent).
   Capture the resulting PR URL.
4. Wait for CI to fail on the inject PR. Confirm `self-heal.yml` opens a
   tracking issue (look for the `self-heal` label).
5. **Manually assign `copilot-swe-agent` to the tracking issue.** This is
   a deliberate human-in-the-loop step — the workflow cannot do it (see
   "Discovered limitation" below). Use either the issue UI sidebar or
   `gh issue edit <N> --add-assignee copilot-swe-agent` from a shell
   authenticated with a user token.
6. Watch for the agent's fix PR (it will open off `main`, **not** off the
   inject branch — see `/memories/selfheal-strategic-learnings.md`).
7. When the agent's PR settles (CI green or the agent stops responding for
   ~30 min), record outcome.
8. Append one JSON object to `trials.jsonl`. Schema below.
9. Close both PRs without merging. Close the tracking issue. Delete both
   branches. Reset `main` to baseline-green state.

## Discovered limitation: agent assignment requires user identity

Confirmed empirically 2026-04-23 across multiple attempts:

- A GitHub App installation token (even with `issues: write`) **cannot**
  assign `copilot-swe-agent` to an issue.
  - GraphQL `replaceActorsForAssignable` (used by `gh issue edit
    --add-assignee`) fails hard with `"target repository is not
    writable"`.
  - REST `POST /repos/{o}/{r}/issues/{n}/assignees` returns 201 success
    but **silently drops** the bot from the assignees list.
- A user identity (browser click, or `gh issue edit` with a user GH_TOKEN)
  works fine. Inference: assigning the cloud agent requires a user tied
  to a Copilot subscription, not just `issues:write`.

This means full end-to-end autonomy (failure → issue → agent dispatch)
is **not achievable from a workflow** without using a fine-grained PAT,
which the harness rules forbid.

**Decision:** keep the no-PATs rule. Leave assignment as a manual step
between workflow and agent. This actually cleanly separates the two
things being measured:

- **Mechanism (the responder):** does it reliably extract the failure,
  open a useful tracking issue, and produce a clean dedupe key?
  Workflow's job. Tested by simply running CI and watching issues.
- **Capability (the agent):** given a useful tracking issue, can it
  produce a working fix? Agent's job. Tested per trial after the human
  triggers it.

If a future iteration cares about the autonomy gap, the relevant
decision is whether to introduce a PAT (and document it as a deliberate
deviation), not how to coax the App token into doing what GitHub
explicitly prevents.

### Known alternative path: GitHub App user-to-server token

Per [GitHub's docs on assigning issues to Copilot via the API](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-a-pr#assigning-an-issue-to-copilot-via-the-github-api),
"a personal access token **or a GitHub App user-to-server token**" is
acceptable. A user-to-server (U2S) token authenticates as a user
*acting through* the App, and so satisfies the user-identity requirement
that an installation token does not.

To use one from a workflow you would need to:

1. Configure the App for OAuth user authorization (callback URL, or
   device flow).
2. Walk the OAuth/device flow once as a Copilot-subscribed user → store
   the resulting refresh token as a repo secret.
3. In the workflow, exchange the refresh token for a fresh ~8h access
   token at job start, then assign the bot with that token.
4. Handle refresh-token rotation / re-consent if it ever expires.

**Not adopted for this experiment.** A long-lived refresh token in a
repo secret has effectively the same blast radius as a PAT (account-
scoped credential, persistent, one secret away from full impersonation),
so it doesn't materially honour the no-PATs rule it would be sidestepping.
The harness cost (OAuth bootstrap + refresh handling) is non-trivial; the
benefit is automating one `gh issue edit` line per trial. Recorded here
so a future iteration that genuinely needs unattended issue dispatch
(e.g. scheduled trial batches) doesn't have to re-derive the option.

## Trial log schema (`trials.jsonl`)

One JSON object per line; append-only.

```json
{
  "trial_id": "T001",
  "timestamp_utc": "2026-04-24T14:00:00Z",
  "fixture_sha": "abc1234",
  "node_from": "18",
  "node_to": "22",
  "injected_constraint": "engines.node 18.x -> 22.x + crypto.createCipher in src/Web/crypto-helper.js",
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

### Batch 1 — N=5, no per-repo guidance, Node 22 + `crypto.createCipher` fixture

Trials T001–T005 were run consecutively on 2026-04-23. All five completed
without per-repo `copilot-instructions.md` guidance.

#### Outcomes

| trial | strategy | outcome | wallclock | kept Node bump |
|---|---|---|---:|:---:|
| T001 | modernize-cipher | fixed | 7 min | ✓ |
| T002 | modernize-cipher | fixed | 9 min | ✓ |
| T003 | swap-primitive (HMAC) | fixed | 8 min | ✓ |
| T004 | swap-primitive (HMAC) | fixed | 9 min | ✓ |
| T005 | modernize-cipher | fixed | 6 min | ✓ |

**5/5 fixed. 0/5 wrong-but-passing. 0/5 no-op. 0/5 error.**

Median wallclock: ~8 min (inject PR opened → agent PR ready_for_review).

#### Strategy distribution

- **modernize-cipher** (3/5): replace `createCipher` with `createCipheriv`
  using `scryptSync` to derive a deterministic key + IV. Variations across
  trials in scrypt-call shape (one call vs two), salt representation
  (string vs `Buffer.alloc`), and `verifyToken` defence (`===` vs
  `timingSafeEqual`, with or without try/catch). All three preserved the
  helper's stated determinism contract.

- **swap-primitive** (2/5): abandon encryption entirely; replace with
  `crypto.createHmac('sha256', ...)`. This was **not** in the rubric
  defined before the trials. It is a real semantic shift (MAC, not
  encryption) but is arguably more appropriate for opaque session-token
  signing. Both T003 and T004 used `crypto.timingSafeEqual` with a
  length check; both produced near-identical diffs.

#### Quality observations

- Every trial **kept the Node bump in both `package.json` engines and
  `ci.yml` setup-node version**. The agent never tried to make CI pass by
  reverting the Node bump (the rubric's `wrong-but-passing` failure mode).
- Every trial used `crypto.timingSafeEqual` for `verifyToken` except T001
  (which used plain `===`).
- 3/5 dropped the third "rejects wrong passphrase / tampered" test that
  T001 added (T002 kept it; T003, T004, T005 shipped only 2 tests).
- The agent never modified files outside the four touched by the inject
  + ci.yml setup-node line. No scope creep.

#### Honest interpretation

For this single, well-known scenario (Node 22 hard-removed an API the app
uses), the unguided agent is **highly capable**: 5/5 fixes, no
wrong-but-passing, no scope creep, all preserved the Node bump. The
strategy varied (modernize-cipher vs swap-primitive) but never
unreasonably.

**This is one scenario, N=5.** The result does not generalize to:
- transitive dependency conflicts (the original framing the predecessor
  was aiming at; see "Honest meta-finding" in the fixture section for
  why we couldn't construct one)
- multi-file failures
- failures whose root cause is not in the latest commit
- failures requiring runtime / production context the agent doesn't have

The rubric category `swap-primitive` was added retroactively after
observing it in T003. Original rubric should be revised before any
future batch. See `agent_proposed_strategy` in `trials.jsonl` for the
canonical strategy strings used.

#### Discovered constraints (not findings about the agent)

1. **App tokens cannot assign `copilot-swe-agent`** — the workflow's
   assignment step had to be removed; assignment is now a manual step.
   See "Discovered limitation" section above.
2. **Bot-authored CI runs are gated `action_required` by default**, even
   with the repo Actions approval policy set to its most permissive
   "first-time contributors who are new to GitHub" option. Every trial
   required a `gh run rerun` from the repo owner to actually run CI on
   the agent's PR. Wallclock figures above include only agent
   work-time, not the CI-rerun delay.
3. **Stray dedupe-on-deletion**: when an inject branch is deleted while
   a CI run is queued (or after policy change releases a queued run),
   the resulting failure can produce a tracking issue against the
   deleted branch. Harmless but needs cleanup in the trial procedure.

#### What to do next

- **Add `copilot-instructions.md` guidance** and rerun N=5 in batch 2.
  Compare outcome and strategy distribution. (Anti-bias rule #2 was
  followed: batch 1 ran with no guidance.)
- **Pick a different scenario class** (multi-file root cause; failure
  in a transitively-imported module; dep with breaking semver bump)
  and run a fresh N=5. The current scenario is single-file and the
  agent solved it trivially; harder cases are needed to characterize
  the agent's edge.
- **Revise the rubric** to include `swap-primitive` and any other
  strategies seen in batch 2.
