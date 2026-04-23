# CI failure — automated tracking issue

> Opened by `.github/workflows/self-heal.yml` after a failed CI run.
> Variables below are substituted server-side via `envsubst`.

**Workflow:** `${WORKFLOW_NAME}`
**Failed job:** `${FAILED_JOB_NAME}`
**Branch:** `${HEAD_BRANCH}`
**Commit:** `${HEAD_SHA}`
**Run:** [#${RUN_NUMBER} (attempt ${RUN_ATTEMPT})](${RUN_URL})
**Triggered by:** `${TRIGGERING_ACTOR}`

## Reproduce locally

```bash
cd src/Web
npm ci
npm test
```

## Last 50 log lines

<!-- 4-tilde fence so log content containing triple backticks cannot break it. -->
~~~~text
${LOG_TAIL}
~~~~

## Rollback (if needed)

```bash
git revert ${HEAD_SHA}
git push origin ${HEAD_BRANCH}
```

---
<sub>Dedupe key: `sh-${DEDUPE_KEY}`</sub>
