#!/usr/bin/env bash
# Clean up everything created by .github/skills/selfheal-demo/run-demo.sh.
# Bash counterpart to .github/skills/selfheal-demo/reset-demo.ps1;
# behaviour is identical.
#
# Usage:
#   .github/skills/selfheal-demo/reset-demo.sh [--force]
set -euo pipefail

FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

for cmd in git gh; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not in PATH: $cmd" >&2; exit 1; }
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [ "$FORCE" = 0 ]; then
    echo 'This will close demo PRs/issues, delete demo/* branches on the remote,'
    echo 'and force-remove demo worktrees. Re-run with --force to skip this prompt.'
    printf 'Proceed? [y/N] '
    read -r resp
    case "$resp" in
        y|Y|yes) ;;
        *) echo 'Aborted.'; exit 0 ;;
    esac
fi

# --- 1. close demo PRs ----------------------------------------------------
demo_prs="$(gh pr list --state open --search '"[demo]" in:title' --json number --jq '.[].number' 2>/dev/null || true)"
if [ -n "$demo_prs" ]; then
    for n in $demo_prs; do
        echo "Closing PR #$n"
        gh pr close "$n" --delete-branch --comment 'Closed by reset-demo.sh.' >/dev/null 2>&1 || true
    done
else
    echo 'No open demo PRs.'
fi

# --- 2. close demo tracking issues ----------------------------------------
demo_issues="$(gh issue list --state open --label self-heal --search '"[demo]" in:title' --json number --jq '.[].number' 2>/dev/null || true)"
if [ -n "$demo_issues" ]; then
    for n in $demo_issues; do
        echo "Closing issue #$n"
        gh issue close "$n" --comment 'Closed by reset-demo.sh.' >/dev/null 2>&1 || true
    done
else
    echo 'No open demo tracking issues.'
fi

# --- 3. remove worktrees recorded in state files --------------------------
STATE_DIR="$REPO_ROOT/.github/skills/selfheal-demo/.state"
declare -A CLEANED
if [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/*.json; do
        [ -e "$f" ] || continue
        wt="$(grep -oE '"worktree":\s*"[^"]+"' "$f" | sed -E 's/.*"worktree":\s*"([^"]+)"/\1/' || true)"
        if [ -n "$wt" ] && [ -e "$wt" ]; then
            echo "Removing worktree: $wt"
            git worktree remove --force "$wt" >/dev/null 2>&1 || true
        fi
        [ -n "$wt" ] && CLEANED["$wt"]=1
        rm -f "$f"
    done
fi

# --- 4. fallback worktree scan -------------------------------------------
# Parse `git worktree list --porcelain`; remove any demo/* worktree we
# haven't already cleaned via state file.
current_path=''
current_branch=''
flush() {
    if [ -n "$current_branch" ] && [[ "$current_branch" == refs/heads/demo/* ]]; then
        if [ -z "${CLEANED[$current_path]:-}" ]; then
            echo "Removing stray demo worktree: $current_path"
            git worktree remove --force "$current_path" >/dev/null 2>&1 || true
        fi
    fi
    current_path=''
    current_branch=''
}
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        worktree\ *) [ -n "$current_path" ] && flush; current_path="${line#worktree }" ;;
        branch\ *)   current_branch="${line#branch }" ;;
        '')          flush ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null || true)
flush

# --- 5. delete remaining demo/* remote branches ---------------------------
git fetch --prune origin --quiet
for rb in $(git branch -r --list 'origin/demo/*' 2>/dev/null | sed 's/^[[:space:]]*//'); do
    name="${rb#origin/}"
    echo "Deleting remote branch: $name"
    git push origin --delete "$name" >/dev/null 2>&1 || true
done

# --- 6. prune worktree metadata + local branches --------------------------
git worktree prune >/dev/null 2>&1 || true
for lb in $(git branch --list 'demo/*' 2>/dev/null | sed 's/^[* ]*//'); do
    git branch -D "$lb" >/dev/null 2>&1 || true
done

echo
echo 'Reset complete.'
