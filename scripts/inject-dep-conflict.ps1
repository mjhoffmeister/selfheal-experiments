<#
.SYNOPSIS
    Inject the "Node bump + native-module conflict" scenario.

.DESCRIPTION
    Mechanical wrapper for the single experiment scenario:
      1. Branch off origin/main with a timestamped name.
      2. Bump src/Web/package.json engines.node (FROM_NODE → TO_NODE).
      3. Bump .github/workflows/ci.yml setup-node node-version (FROM_NODE_FULL → TO_NODE_FULL).
      4. Add src/Web/.npmrc with `engine-strict=true` (defence-in-depth; not
         the primary failure trigger).
      5. Add an older bcrypt as a direct dependency (BcryptVersion). Older
         bcrypt has no prebuilt binaries for newer Node majors and falls
         over during node-gyp build at `npm ci` time. THIS is the primary
         failure trigger.
      6. Regenerate package-lock.json via `npm install --package-lock-only
         --ignore-scripts` so the lock matches the new package.json without
         actually invoking native postinstall on the local machine.
      7. Commit, push, open PR (no auto-merge, no labels, no body fluff).

    Records nothing. The trial logger (you, by hand) appends to
    experiments/trials.jsonl.

    See experiments/README.md for the rationale and the list of alternative
    inject variants considered.

    NOTE on scenario class drift: the original framing was "transitive
    engines conflict". Empirically, modern packages declare permissive
    engines, so a bare engines.node bump produces no failure. This variant
    is honest about what it actually exercises: "native-module install
    fails after a Node major bump". This is still a realistic failure mode
    real Node services hit when bumping Node.

.PARAMETER FromNode
    Engines.node value to replace. Default: '18.x'.

.PARAMETER ToNode
    New engines.node value. Default: '22.x'.

.PARAMETER FromNodeFull
    setup-node version to replace in ci.yml. Default: '18.20.4'.

.PARAMETER ToNodeFull
    New setup-node version. Default: '22.11.0'.

.PARAMETER BcryptVersion
    Old bcrypt version to add as a direct dep. Default: '5.0.1' (pre-Node-22
    prebuilds).

.PARAMETER NoPush
    Skip git push and gh pr create (dry-run mode for local inspection).

.NOTES
    Requires: git, gh (authenticated), node + npm in PATH, running in repo root.
#>
[CmdletBinding()]
param(
    [string] $FromNode      = '18.x',
    [string] $ToNode        = '22.x',
    [string] $FromNodeFull  = '18.20.4',
    [string] $ToNodeFull    = '22.11.0',
    [string] $BcryptVersion = '5.0.1',
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- sanity ----------------------------------------------------------------
$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Not inside a git repo.' }
Set-Location $repoRoot

$packageJson = 'src/Web/package.json'
$packageLock = 'src/Web/package-lock.json'
$ciYaml      = '.github/workflows/ci.yml'
$npmrc       = 'src/Web/.npmrc'

foreach ($p in @($packageJson, $packageLock, $ciYaml)) {
    if (-not (Test-Path $p)) { throw "Expected file missing: $p" }
}

foreach ($cmd in @('git', 'gh', 'npm')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $cmd"
    }
}

$dirty = git status --porcelain
if ($dirty) { throw "Working tree not clean:`n$dirty" }

# --- branch ---------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch    = "inject/dep-conflict-$timestamp"

git fetch origin main --quiet
git switch -c $branch origin/main | Out-Null

# --- mutate package.json --------------------------------------------------
# Use ConvertFrom-Json/ConvertTo-Json so adding the bcrypt dep can't break
# the file's structure. Round-tripping rewrites the file with 2-space
# indentation (npm's default), which matches the existing fixture.
$pkg = Get-Content $packageJson -Raw | ConvertFrom-Json
if ($pkg.engines.node -ne $FromNode) {
    throw "engines.node mismatch: expected '$FromNode', found '$($pkg.engines.node)'"
}
$pkg.engines.node = $ToNode

# Add bcrypt as a direct dep. If it's already there (re-run after manual
# tinkering), overwrite — no need to fail.
if ($pkg.dependencies.PSObject.Properties.Name -contains 'bcrypt') {
    $pkg.dependencies.bcrypt = $BcryptVersion
} else {
    $pkg.dependencies | Add-Member -NotePropertyName 'bcrypt' -NotePropertyValue $BcryptVersion
}

# ConvertTo-Json defaults to depth 2; we have nested objects (engines,
# dependencies, devDependencies, scripts) so depth 10 is plenty.
($pkg | ConvertTo-Json -Depth 10) + "`n" | Set-Content -Path $packageJson -NoNewline

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

# --- regenerate lockfile --------------------------------------------------
# `--package-lock-only` updates the lock without touching node_modules.
# `--ignore-scripts` prevents bcrypt's preinstall/install/postinstall from
# running on the local machine — those scripts are exactly what will fail
# on the CI runner under Node 22, which is the failure we want to surface.
Push-Location 'src/Web'
try {
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund --silent
    if ($LASTEXITCODE -ne 0) { throw "npm install --package-lock-only failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- commit + push --------------------------------------------------------
git add $packageJson $packageLock $ciYaml $npmrc
$commitMsg = "Bump Node $FromNode -> $ToNode + add bcrypt $BcryptVersion (inject)"
git commit -m $commitMsg | Out-Null

if ($NoPush) {
    Write-Host "[dry-run] branch '$branch' built locally; skipped push/PR."
    Write-Host '[dry-run] inspect with: git diff origin/main..HEAD'
    return
}

git push -u origin $branch | Out-Null

$prTitle = "[inject] bump Node $FromNode -> $ToNode + add bcrypt $BcryptVersion"
$prBody  = @"
Automated injection from ``scripts/inject-dep-conflict.ps1``.

- Bumped ``src/Web/package.json`` engines.node: ``$FromNode`` -> ``$ToNode``
- Bumped CI ``node-version``: ``$FromNodeFull`` -> ``$ToNodeFull``
- Added direct dep ``bcrypt@$BcryptVersion`` (no Node-22 prebuilt binaries)
- Added ``src/Web/.npmrc`` with ``engine-strict=true``
- Regenerated ``package-lock.json``

Expectation: CI fails at ``npm ci`` (bcrypt's node-gyp build can't produce a
Node-22-compatible binary). Self-heal responder will open a tracking issue and
assign the cloud agent. Do **not** auto-merge.
"@

gh pr create --base main --head $branch --title $prTitle --body $prBody | Out-Null
$prUrl = gh pr view $branch --json url --jq .url
Write-Host "Opened PR: $prUrl"
