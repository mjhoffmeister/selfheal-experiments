#!/usr/bin/env bash
# Inject the "engines.node bump -> transitive dep conflict" scenario.
# Bash counterpart to scripts/inject-dep-conflict.ps1. See that file for full
# rationale; behaviour is identical.
#
# Usage:
#   scripts/inject-dep-conflict.sh [--from-node 18.x] [--to-node 22.x] \
#                                  [--from-node-full 18.20.4] [--to-node-full 22.11.0] \
#                                  [--no-push]
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
NPMRC='src/Web/.npmrc'

[ -f "$PKG" ] || { echo "Missing $PKG" >&2; exit 1; }
[ -f "$CI"  ] || { echo "Missing $CI"  >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
    echo 'Working tree not clean.' >&2
    exit 1
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BRANCH="inject/dep-conflict-$TS"

git fetch origin main --quiet
git switch -c "$BRANCH" origin/main >/dev/null

# package.json: "node": "<from>" -> "node": "<to>"
if ! grep -qE "\"node\":\s*\"$(printf '%s' "$FROM_NODE" | sed 's/[.[\*^$()+?{}|]/\\&/g')\"" "$PKG"; then
    echo "engines.node \"$FROM_NODE\" not found in $PKG" >&2
    exit 1
fi
# Use perl for safe in-place edit (BSD/GNU sed differ on -i).
perl -0777 -i -pe "s|\"node\":\s*\"\Q$FROM_NODE\E\"|\"node\": \"$TO_NODE\"|" "$PKG"

# ci.yml: node-version: '<from>' -> '<to>'
if ! grep -qE "node-version:\s*'$(printf '%s' "$FROM_NODE_FULL" | sed 's/[.[\*^$()+?{}|]/\\&/g')'" "$CI"; then
    echo "node-version '$FROM_NODE_FULL' not found in $CI" >&2
    exit 1
fi
perl -0777 -i -pe "s|node-version:\s*'\Q$FROM_NODE_FULL\E'|node-version: '$TO_NODE_FULL'|" "$CI"

cat > "$NPMRC" <<'EOF'
# Injected by scripts/inject-dep-conflict.sh.
# engine-strict turns engines mismatches into hard errors at install time.
engine-strict=true
EOF

git add "$PKG" "$CI" "$NPMRC"
git commit -m "Bump Node engines $FROM_NODE -> $TO_NODE (inject)" >/dev/null

if [ "$NO_PUSH" = 1 ]; then
    echo "[dry-run] branch '$BRANCH' built locally; skipped push/PR."
    echo '[dry-run] inspect with: git diff origin/main..HEAD'
    exit 0
fi

git push -u origin "$BRANCH" >/dev/null

PR_BODY=$(cat <<EOF
Automated injection from \`scripts/inject-dep-conflict.sh\`.

- Bumped \`src/Web/package.json\` engines.node: \`$FROM_NODE\` -> \`$TO_NODE\`
- Bumped CI \`node-version\`: \`$FROM_NODE_FULL\` -> \`$TO_NODE_FULL\`
- Added \`src/Web/.npmrc\` with \`engine-strict=true\`

Expectation: CI fails. Self-heal responder will open a tracking issue and assign
the cloud agent. Do **not** auto-merge.
EOF
)

gh pr create --base main --head "$BRANCH" \
    --title "[inject] bump engines.node $FROM_NODE -> $TO_NODE" \
    --body "$PR_BODY" >/dev/null
gh pr view "$BRANCH" --json url --jq .url
