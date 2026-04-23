<#
.SYNOPSIS
    Inject the "engines.node bump → transitive dep conflict" scenario.

.DESCRIPTION
    Mechanical wrapper for the single experiment scenario:
      1. Branch off origin/main with a timestamped name.
      2. Bump src/Web/package.json engines.node (FROM_NODE → TO_NODE).
      3. Bump .github/workflows/ci.yml setup-node node-version (FROM_NODE_FULL → TO_NODE_FULL).
      4. Add src/Web/.npmrc with `engine-strict=true` so npm ci fails on engine mismatch.
      5. Commit, push, open PR (no auto-merge, no labels, no body fluff).

    Records nothing. The trial logger (you, by hand) appends to
    experiments/trials.jsonl.

    See experiments/README.md for the rationale and the list of alternative
    inject variants considered.

.PARAMETER FromNode
    Engines.node value to replace. Default: '18.x'.

.PARAMETER ToNode
    New engines.node value. Default: '22.x'.

.PARAMETER FromNodeFull
    setup-node version to replace in ci.yml. Default: '18.20.4'.

.PARAMETER ToNodeFull
    New setup-node version. Default: '22.11.0'.

.PARAMETER NoPush
    Skip git push and gh pr create (dry-run mode for local inspection).

.NOTES
    Requires: git, gh (authenticated), running in repo root.
#>
[CmdletBinding()]
param(
    [string] $FromNode      = '18.x',
    [string] $ToNode        = '22.x',
    [string] $FromNodeFull  = '18.20.4',
    [string] $ToNodeFull    = '22.11.0',
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- sanity ----------------------------------------------------------------
$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Not inside a git repo.' }
Set-Location $repoRoot

$packageJson = 'src/Web/package.json'
$ciYaml      = '.github/workflows/ci.yml'
$npmrc       = 'src/Web/.npmrc'

foreach ($p in @($packageJson, $ciYaml)) {
    if (-not (Test-Path $p)) { throw "Expected file missing: $p" }
}

$dirty = git status --porcelain
if ($dirty) { throw "Working tree not clean:`n$dirty" }

# --- branch ---------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch    = "inject/dep-conflict-$timestamp"

git fetch origin main --quiet
git switch -c $branch origin/main | Out-Null

# --- mutate package.json --------------------------------------------------
$pkgText = Get-Content $packageJson -Raw
$pattern = '"node":\s*"' + [regex]::Escape($FromNode) + '"'
if ($pkgText -notmatch $pattern) {
    throw "engines.node `"$FromNode`" not found in $packageJson"
}
$pkgText = $pkgText -replace $pattern, ('"node": "{0}"' -f $ToNode)
Set-Content -Path $packageJson -Value $pkgText -NoNewline

# --- mutate ci.yml --------------------------------------------------------
$ciText = Get-Content $ciYaml -Raw
$ciPattern = "node-version:\s*'" + [regex]::Escape($FromNodeFull) + "'"
if ($ciText -notmatch $ciPattern) {
    throw "node-version '$FromNodeFull' not found in $ciYaml"
}
$ciText = $ciText -replace $ciPattern, ("node-version: '{0}'" -f $ToNodeFull)
Set-Content -Path $ciYaml -Value $ciText -NoNewline

# --- write .npmrc ---------------------------------------------------------
@(
    '# Injected by scripts/inject-dep-conflict.ps1.'
    '# engine-strict turns engines mismatches into hard errors at install time.'
    'engine-strict=true'
) -join "`n" | Set-Content -Path $npmrc -NoNewline

# --- commit + push --------------------------------------------------------
git add $packageJson $ciYaml $npmrc
$commitMsg = "Bump Node engines $FromNode -> $ToNode (inject)"
git commit -m $commitMsg | Out-Null

if ($NoPush) {
    Write-Host "[dry-run] branch '$branch' built locally; skipped push/PR."
    Write-Host '[dry-run] inspect with: git diff origin/main..HEAD'
    return
}

git push -u origin $branch | Out-Null

$prTitle = "[inject] bump engines.node $FromNode -> $ToNode"
$prBody  = @"
Automated injection from ``scripts/inject-dep-conflict.ps1``.

- Bumped ``src/Web/package.json`` engines.node: ``$FromNode`` -> ``$ToNode``
- Bumped CI ``node-version``: ``$FromNodeFull`` -> ``$ToNodeFull``
- Added ``src/Web/.npmrc`` with ``engine-strict=true``

Expectation: CI fails. Self-heal responder will open a tracking issue and assign
the cloud agent. Do **not** auto-merge.
"@

gh pr create --base main --head $branch --title $prTitle --body $prBody | Out-Null
$prUrl = gh pr view $branch --json url --jq .url
Write-Host "Opened PR: $prUrl"
