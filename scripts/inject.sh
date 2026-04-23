#!/usr/bin/env bash
# Inject the "Node major bump removes an API our code was using" scenario.
# Bash counterpart to scripts/inject.ps1. See that file for full rationale;
# behaviour is identical.
#
# Usage:
#   scripts/inject.sh [--from-node 18.x] [--to-node 22.x] \
#                     [--from-node-full 18.20.4] [--to-node-full 22.11.0] \
#                     [--no-push]
#
# Requires: git, gh (authenticated).
set -euo pipefail

FROM_NODE='18.x'
TO_NODE='22.x'
FROM_NODE_FULL='18.20.4'
TO_NODE_FULL='22.11.0'
NO_PUSH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --from-node)      FROM_NODE="$2"; shift 2 ;;
        --to-node)        TO_NODE="$2"; shift 2 ;;
        --from-node-full) FROM_NODE_FULL="$2"; shift 2 ;;
        --to-node-full)   TO_NODE_FULL="$2"; shift 2 ;;
        --no-push)        NO_PUSH=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PKG='src/Web/package.json'
CI='.github/workflows/ci.yml'
HELPER='src/Web/crypto-helper.js'
HELPER_TEST='src/Web/crypto-helper.test.js'

[ -f "$PKG" ] || { echo "Missing $PKG" >&2; exit 1; }
[ -f "$CI"  ] || { echo "Missing $CI"  >&2; exit 1; }

for cmd in git gh; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not in PATH: $cmd" >&2; exit 1; }
done

if [ -n "$(git status --porcelain)" ]; then
    echo 'Working tree not clean.' >&2
    exit 1
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BRANCH="inject/node-api-removal-$TS"

git fetch origin main --quiet
git switch -c "$BRANCH" origin/main >/dev/null

# package.json: "node": "<from>" -> "node": "<to>"
if ! grep -qE "\"node\":\s*\"$(printf '%s' "$FROM_NODE" | sed 's/[.[\*^$()+?{}|]/\\&/g')\"" "$PKG"; then
    echo "engines.node \"$FROM_NODE\" not found in $PKG" >&2
    exit 1
fi
perl -0777 -i -pe "s|\"node\":\s*\"\Q$FROM_NODE\E\"|\"node\": \"$TO_NODE\"|" "$PKG"

# ci.yml: node-version: '<from>' -> '<to>'
if ! grep -qE "node-version:\s*'$(printf '%s' "$FROM_NODE_FULL" | sed 's/[.[\*^$()+?{}|]/\\&/g')'" "$CI"; then
    echo "node-version '$FROM_NODE_FULL' not found in $CI" >&2
    exit 1
fi
perl -0777 -i -pe "s|node-version:\s*'\Q$FROM_NODE_FULL\E'|node-version: '$TO_NODE_FULL'|" "$CI"

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
git commit -m "Bump Node $FROM_NODE -> $TO_NODE + add legacy crypto helper (inject)" >/dev/null

if [ "$NO_PUSH" = 1 ]; then
    echo "[dry-run] branch '$BRANCH' built locally; skipped push/PR."
    echo '[dry-run] inspect with: git diff origin/main..HEAD'
    exit 0
fi

git push -u origin "$BRANCH" >/dev/null

PR_BODY=$(cat <<EOF
Automated injection from \`scripts/inject.sh\`.

- Bumped \`src/Web/package.json\` engines.node: \`$FROM_NODE\` -> \`$TO_NODE\`
- Bumped CI \`node-version\`: \`$FROM_NODE_FULL\` -> \`$TO_NODE_FULL\`
- Added \`src/Web/crypto-helper.js\` (uses \`crypto.createCipher\`)
- Added \`src/Web/crypto-helper.test.js\`

Expectation: CI fails. \`crypto.createCipher\` was hard-removed in Node 22, so
\`require('./crypto-helper')\` throws TypeError when jest loads the test file.
Self-heal responder will open a tracking issue and assign the cloud agent.
Do **not** auto-merge.
EOF
)

gh pr create --base main --head "$BRANCH" \
    --title "[inject] bump Node $FROM_NODE -> $TO_NODE + add legacy crypto helper" \
    --body "$PR_BODY" >/dev/null
gh pr view "$BRANCH" --json url --jq .url
