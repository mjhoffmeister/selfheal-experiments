<#
.SYNOPSIS
    Customer-facing self-heal demo runner.

.DESCRIPTION
    Reproduces the @-mention-PR-author handoff pattern end-to-end:

      1. Creates a throwaway worktree off origin/main at
         ../selfheal-demo-<UTC-timestamp> (your main checkout is untouched).
      2. Applies the same four mutations as scripts/inject.ps1 (Node 18 -> 22
         + a helper using the Node-22-removed crypto.createCipher API).
      3. Pushes the new branch `demo/<UTC-timestamp>` and opens a PR.
      4. Records worktree path + branch in
         .github/skills/selfheal-demo/.state/<branch>.json so
         .github/skills/selfheal-demo/reset-demo.ps1 can clean up later.
      5. Prints the PR URL and the gh-snippet you'll need after the
         tracking issue appears.

    The demo workflow .github/workflows/demo-self-heal.yml will react to the
    failed CI run, open a tracking issue that @-mentions you, and post a
    comment on the PR. You then assign Copilot to the issue (the manual
    step the demo is designed to illustrate).

    NOTE: The mutation block is a deliberate duplicate of scripts/inject.ps1
    rather than a shared helper — the experiment harness must stay
    byte-stable across trial batches. Keep both in sync if you change the
    fixture.

.PARAMETER NoPush
    Build the worktree + commits locally, skip git push and gh pr create.
    Useful for inspecting the inject diff.

.PARAMETER Force
    Skip "demo PR/issue/branch already exists" pre-flight refusal. Used by
    the chat skill so it can run unattended.

.NOTES
    Requires: git, gh (authenticated as a user — App tokens cannot assign
    Copilot, which is the whole point of this demo).
#>
[CmdletBinding()]
param(
    [switch] $NoPush,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- sanity ----------------------------------------------------------------
foreach ($cmd in @('git', 'gh')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $cmd"
    }
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Not inside a git repo.' }
Set-Location $repoRoot

$packageJson = 'src/Web/package.json'
$ciYaml      = '.github/workflows/ci.yml'
foreach ($p in @($packageJson, $ciYaml)) {
    if (-not (Test-Path $p)) { throw "Expected file missing: $p" }
}

# Pre-flight: refuse if a demo run is already in flight (unless -Force).
if (-not $Force) {
    $openDemoPrs = (gh pr list --state open --search '"[demo]" in:title' --json number --jq 'length' 2>$null)
    if ($openDemoPrs -and [int]$openDemoPrs -gt 0) {
        throw "An open demo PR already exists. Run '.github/skills/selfheal-demo/reset-demo.ps1' first, or pass -Force."
    }
}

# --- worktree --------------------------------------------------------------
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$branch    = "demo/$timestamp"
$worktree  = Join-Path (Split-Path $repoRoot -Parent) "selfheal-demo-$timestamp"

if (Test-Path $worktree) {
    throw "Worktree path already exists: $worktree"
}

git fetch origin main --quiet
git worktree add -b $branch $worktree origin/main | Out-Null
Write-Host "Worktree: $worktree (branch: $branch)"

Push-Location $worktree
try {
    # --- mutate package.json ---------------------------------------------
    $pkgText = Get-Content $packageJson -Raw
    if ($pkgText -notmatch '"node":\s*"18\.x"') {
        throw "engines.node `"18.x`" not found in $packageJson (fixture drift?)"
    }
    $pkgText = $pkgText -replace '"node":\s*"18\.x"', '"node": "22.x"'
    Set-Content -Path $packageJson -Value $pkgText -NoNewline

    # --- mutate ci.yml ---------------------------------------------------
    $ciText = Get-Content $ciYaml -Raw
    if ($ciText -notmatch "node-version:\s*'18\.20\.4'") {
        throw "node-version '18.20.4' not found in $ciYaml (fixture drift?)"
    }
    $ciText = $ciText -replace "node-version:\s*'18\.20\.4'", "node-version: '22.11.0'"
    Set-Content -Path $ciYaml -Value $ciText -NoNewline

    # --- write the helper that uses a Node-22-removed API ----------------
    # SYNCED with scripts/inject.ps1; update both if the fixture changes.
    $helper = @'
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
'@
    Set-Content -Path 'src/Web/crypto-helper.js' -Value $helper -NoNewline

    $helperTest = @'
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
'@
    Set-Content -Path 'src/Web/crypto-helper.test.js' -Value $helperTest -NoNewline

    # --- commit ----------------------------------------------------------
    git add $packageJson $ciYaml 'src/Web/crypto-helper.js' 'src/Web/crypto-helper.test.js'
    git commit -m '[demo] Bump Node 18 -> 22 + add legacy crypto helper' | Out-Null
}
finally {
    Pop-Location
}

# --- record state for reset-demo ------------------------------------------
$stateDir  = Join-Path $repoRoot '.github/skills/selfheal-demo/.state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$stateFile = Join-Path $stateDir ($timestamp + '.json')
$state = [pscustomobject]@{
    branch       = $branch
    worktree     = $worktree
    created_utc  = (Get-Date).ToUniversalTime().ToString('o')
    pr_url       = $null
}

if ($NoPush) {
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8
    Write-Host ''
    Write-Host '[dry-run] Skipped push/PR.'
    Write-Host "[dry-run] Inspect: cd $worktree; git diff origin/main..HEAD"
    Write-Host "[dry-run] Clean up with: pwsh .github/skills/selfheal-demo/reset-demo.ps1"
    return
}

# --- push + open PR --------------------------------------------------------
Push-Location $worktree
try {
    git push -u origin $branch | Out-Null
}
finally {
    Pop-Location
}

$prTitle = '[demo] Self-heal walkthrough: Node 22 + crypto.createCipher'
$prBody  = @'
> Opened by `.github/skills/selfheal-demo/run-demo.ps1` for the self-heal walkthrough demo.

This PR deliberately breaks CI (Node bump removes an API the app uses).
The `Demo Self-heal` workflow will:

1. Open a tracking issue that @-mentions you with a one-click `gh` snippet.
2. Comment on this PR linking to that issue.

Then **you** assign Copilot to the tracking issue. The agent opens a fix PR
off `main` (not off this branch).

When done, run `pwsh .github/skills/selfheal-demo/reset-demo.ps1` to clean up everything this run
created.
'@

gh pr create --base main --head $branch --title $prTitle --body $prBody | Out-Null
$prUrl = (gh pr view $branch --json url --jq .url).Trim()

$state.pr_url = $prUrl
$state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

Write-Host ''
Write-Host "Demo PR opened: $prUrl"
Write-Host "Worktree:        $worktree"
Write-Host "State recorded:  $stateFile"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Wait ~30s for CI to fail on the demo PR.'
Write-Host '  2. The Demo Self-heal workflow will open a tracking issue and comment on the PR.'
Write-Host '  3. From the tracking issue, click Assignees -> Copilot, OR run:'
Write-Host '       gh issue edit <ISSUE_NUMBER> --add-assignee copilot-swe-agent'
Write-Host '  4. The agent will open a fix PR off main within ~10 min (Batch 1 median: 8 min).'
Write-Host ''
Write-Host 'When finished:'
Write-Host '  pwsh .github/skills/selfheal-demo/reset-demo.ps1'
