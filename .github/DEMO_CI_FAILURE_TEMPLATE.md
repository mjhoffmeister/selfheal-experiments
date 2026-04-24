# CI failure — automated tracking issue (demo)

> Opened by `.github/workflows/demo-self-heal.yml` after a failed CI run on
> a `demo/*` branch. Variables below are substituted server-side via
> `envsubst`.

@${PR_AUTHOR} — CI failed on your PR. **Please assign Copilot to start the
fix** (one click; see "Assign Copilot" below). This is a deliberate
human-in-the-loop step; the workflow cannot do it for you.

**Source PR:** [#${PR_NUMBER}](${PR_URL})
**Workflow:** `${WORKFLOW_NAME}`
**Failed job:** `${FAILED_JOB_NAME}`
**Branch:** `${HEAD_BRANCH}`
**Commit:** `${HEAD_SHA}`
**Run:** [#${RUN_NUMBER} (attempt ${RUN_ATTEMPT})](${RUN_URL})
**Triggered by:** `${TRIGGERING_ACTOR}`

## Assign Copilot to start the fix

Use either:

- **GitHub UI** — open this issue and pick **Copilot** from the Assignees
  sidebar.
- **Command line** — from a shell authenticated as your GitHub user:

  ```bash
  gh issue edit <THIS_ISSUE_NUMBER> --add-assignee copilot-swe-agent
  ```

  (Replace `<THIS_ISSUE_NUMBER>` with the number shown in this issue's URL;
  the workflow can't substitute its own future number into its own body.)

### Why a human click?

GitHub App installation tokens **cannot** assign the Copilot cloud agent
(`copilot-swe-agent`). Per
[GitHub's docs](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-a-pr#assigning-an-issue-to-copilot-via-the-github-api),
assignment requires a personal access token or a GitHub App user-to-server
token — both of which are stored user credentials with the same business
continuity problem (what happens when the user leaves?).

This demo accepts the one-click handoff so the responder does not have to
hold a long-lived user credential. See
[`.github/skills/selfheal-demo/README.md`](./skills/selfheal-demo/README.md) for the full design tradeoff.

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
<sub>Dedupe key: `sh-${DEDUPE_KEY}` · demo</sub>
