#!/usr/bin/env bash
# Inject the "Node bump + native-module conflict" scenario.
# Bash counterpart to scripts/inject-dep-conflict.ps1. See that file for full
# rationale; behaviour is identical.
#
# Usage:
#   scripts/inject-dep-conflict.sh [--from-node 18.x] [--to-node 22.x] \
#                                  [--from-node-full 18.20.4] [--to-node-full 22.11.0] \
#                                  [--bcrypt 5.0.1] [--no-push]
#
# Requires: git, gh (authenticated), node + npm in PATH.
set -euo pipefail

FROM_NODE='18.x'
TO_NODE='22.x'
FROM_NODE_FULL='18.20.4'
TO_NODE_FULL='22.11.0'
BCRYPT_VERSION='5.0.1'
NO_PUSH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --from-node)      FROM_NODE="$2"; shift 2 ;;
        --to-node)        TO_NODE="$2"; shift 2 ;;
        --from-node-full) FROM_NODE_FULL="$2"; shift 2 ;;
        --to-node-full)   TO_NODE_FULL="$2"; shift 2 ;;
        --bcrypt)         BCRYPT_VERSION="$2"; shift 2 ;;
        --no-push)        NO_PUSH=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PKG='src/Web/package.json'
LOCK='src/Web/package-lock.json'
CI='.github/workflows/ci.yml'
NPMRC='src/Web/.npmrc'

[ -f "$PKG"  ] || { echo "Missing $PKG"  >&2; exit 1; }
[ -f "$LOCK" ] || { echo "Missing $LOCK" >&2; exit 1; }
[ -f "$CI"   ] || { echo "Missing $CI"   >&2; exit 1; }

for cmd in git gh npm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not in PATH: $cmd" >&2; exit 1; }
done

if [ -n "$(git status --porcelain)" ]; then
    echo 'Working tree not clean.' >&2
    exit 1
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BRANCH="inject/dep-conflict-$TS"

git fetch origin main --quiet
git switch -c "$BRANCH" origin/main >/dev/null

# package.json: bump engines.node and add bcrypt as a direct dep.
# Use node -e for safe JSON round-trip (avoids regex fragility).
node -e "
const fs = require('fs');
const path = '$PKG';
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
if (pkg.engines.node !== '$FROM_NODE') {
  console.error('engines.node mismatch: expected \\'$FROM_NODE\\', found ' + pkg.engines.node);
  process.exit(1);
}
pkg.engines.node = '$TO_NODE';
pkg.dependencies = pkg.dependencies || {};
pkg.dependencies.bcrypt = '$BCRYPT_VERSION';
fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + '\\n');
"

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

# Regenerate lockfile without running native postinstall locally — those
# scripts are exactly what should fail on the CI runner.
(
    cd src/Web
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund --silent
)

git add "$PKG" "$LOCK" "$CI" "$NPMRC"
git commit -m "Bump Node $FROM_NODE -> $TO_NODE + add bcrypt $BCRYPT_VERSION (inject)" >/dev/null

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
- Added direct dep \`bcrypt@$BCRYPT_VERSION\` (no Node-22 prebuilt binaries)
- Added \`src/Web/.npmrc\` with \`engine-strict=true\`
- Regenerated \`package-lock.json\`

Expectation: CI fails at \`npm ci\` (bcrypt's node-gyp build can't produce a
Node-22-compatible binary). Self-heal responder will open a tracking issue and
assign the cloud agent. Do **not** auto-merge.
EOF
)

gh pr create --base main --head "$BRANCH" \
    --title "[inject] bump Node $FROM_NODE -> $TO_NODE + add bcrypt $BCRYPT_VERSION" \
    --body "$PR_BODY" >/dev/null
gh pr view "$BRANCH" --json url --jq .url
