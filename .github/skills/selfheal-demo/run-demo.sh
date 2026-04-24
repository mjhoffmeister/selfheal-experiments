#!/usr/bin/env bash
# Customer-facing self-heal demo runner. Bash counterpart to
# .github/skills/selfheal-demo/run-demo.ps1.
# See that file for the full rationale; behaviour is identical.
#
# Usage:
#   .github/skills/selfheal-demo/run-demo.sh [--no-push] [--force]
#
# Requires: git, gh (authenticated as a user — App tokens cannot assign
# Copilot, which is the whole point of this demo).
set -euo pipefail

NO_PUSH=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-push) NO_PUSH=1; shift ;;
        --force)   FORCE=1;   shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

for cmd in git gh; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not in PATH: $cmd" >&2; exit 1; }
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PKG='src/Web/package.json'
CI='.github/workflows/ci.yml'
HELPER='src/Web/crypto-helper.js'
HELPER_TEST='src/Web/crypto-helper.test.js'

[ -f "$PKG" ] || { echo "Missing $PKG" >&2; exit 1; }
[ -f "$CI"  ] || { echo "Missing $CI"  >&2; exit 1; }

# Pre-flight: refuse if a demo run is already in flight (unless --force).
if [ "$FORCE" = 0 ]; then
    open_demo="$(gh pr list --state open --search '"[demo]" in:title' --json number --jq 'length' 2>/dev/null || echo 0)"
    if [ -n "$open_demo" ] && [ "$open_demo" -gt 0 ]; then
        echo "An open demo PR already exists. Run '.github/skills/selfheal-demo/reset-demo.sh' first, or pass --force." >&2
        exit 1
    fi
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BRANCH="demo/$TS"
WORKTREE="$(dirname "$REPO_ROOT")/selfheal-demo-$TS"

if [ -e "$WORKTREE" ]; then
    echo "Worktree path already exists: $WORKTREE" >&2
    exit 1
fi

git fetch origin main --quiet
git worktree add -b "$BRANCH" "$WORKTREE" origin/main >/dev/null
echo "Worktree: $WORKTREE (branch: $BRANCH)"

(
    cd "$WORKTREE"

    # package.json: "node": "18.x" -> "22.x"
    if ! grep -qE '"node":\s*"18\.x"' "$PKG"; then
        echo "engines.node \"18.x\" not found in $PKG (fixture drift?)" >&2
        exit 1
    fi
    perl -0777 -i -pe 's|"node":\s*"18\.x"|"node": "22.x"|' "$PKG"

    # ci.yml: node-version: '18.20.4' -> '22.11.0'
    if ! grep -qE "node-version:\s*'18\.20\.4'" "$CI"; then
        echo "node-version '18.20.4' not found in $CI (fixture drift?)" >&2
        exit 1
    fi
    perl -0777 -i -pe "s|node-version:\s*'18\.20\.4'|node-version: '22.11.0'|" "$CI"

    # SYNCED with scripts/inject.sh; update both if the fixture changes.
    cat > "$HELPER" <<'EOF'
'use strict';

// Sign an opaque session token. Implementation predates Node 22.
//
// Note: crypto.createCipher is a legacy API. It derives a key from the
// passphrase via OpenSSL's EVP_BytesToKey, which is not considered secure
// for new code. Kept here for backward-compatibility with tokens issued by
// the previous version of this service.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';

function signToken(payload, passphrase) {
  const cipher = crypto.createCipher(ALGO, passphrase);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };
EOF

    cat > "$HELPER_TEST" <<'EOF'
'use strict';

const { signToken, verifyToken } = require('./crypto-helper');

describe('crypto-helper', () => {
  test('signToken is deterministic for the same passphrase', () => {
    const a = signToken('user-42', 'shared-secret');
    const b = signToken('user-42', 'shared-secret');
    expect(a).toBe(b);
  });

  test('verifyToken accepts a freshly signed token', () => {
    const token = signToken('user-42', 'shared-secret');
    expect(verifyToken(token, 'user-42', 'shared-secret')).toBe(true);
  });
});
EOF

    git add "$PKG" "$CI" "$HELPER" "$HELPER_TEST"
    git commit -m '[demo] Bump Node 18 -> 22 + add legacy crypto helper' >/dev/null
)

STATE_DIR="$REPO_ROOT/.github/skills/selfheal-demo/.state"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$TS.json"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$NO_PUSH" = 1 ]; then
    cat > "$STATE_FILE" <<EOF
{
  "branch": "$BRANCH",
  "worktree": "$WORKTREE",
  "created_utc": "$CREATED",
  "pr_url": null
}
EOF
    echo
    echo "[dry-run] Skipped push/PR."
    echo "[dry-run] Inspect: cd $WORKTREE; git diff origin/main..HEAD"
    echo "[dry-run] Clean up with: .github/skills/selfheal-demo/reset-demo.sh"
    exit 0
fi

(
    cd "$WORKTREE"
    git push -u origin "$BRANCH" >/dev/null
)

PR_BODY=$(cat <<'EOF'
> Opened by `.github/skills/selfheal-demo/run-demo.sh` for the self-heal walkthrough demo.

This PR deliberately breaks CI (Node bump removes an API the app uses).
The `Demo Self-heal` workflow will:

1. Open a tracking issue that @-mentions you with a one-click `gh` snippet.
2. Comment on this PR linking to that issue.

Then **you** assign Copilot to the tracking issue. The agent opens a fix PR
off `main` (not off this branch).

When done, run `.github/skills/selfheal-demo/reset-demo.sh` to clean up everything this run created.
EOF
)

gh pr create --base main --head "$BRANCH" \
    --title '[demo] Self-heal walkthrough: Node 22 + crypto.createCipher' \
    --body "$PR_BODY" >/dev/null
PR_URL="$(gh pr view "$BRANCH" --json url --jq .url)"

cat > "$STATE_FILE" <<EOF
{
  "branch": "$BRANCH",
  "worktree": "$WORKTREE",
  "created_utc": "$CREATED",
  "pr_url": "$PR_URL"
}
EOF

echo
echo "Demo PR opened: $PR_URL"
echo "Worktree:        $WORKTREE"
echo "State recorded:  $STATE_FILE"
echo
echo 'Next steps:'
echo '  1. Wait ~30s for CI to fail on the demo PR.'
echo '  2. The Demo Self-heal workflow will open a tracking issue and comment on the PR.'
echo '  3. From the tracking issue, click Assignees -> Copilot, OR run:'
echo '       gh issue edit <ISSUE_NUMBER> --add-assignee copilot-swe-agent'
echo '  4. The agent will open a fix PR off main within ~10 min (Batch 1 median: 8 min).'
echo
echo 'When finished:'
echo '  .github/skills/selfheal-demo/reset-demo.sh'
