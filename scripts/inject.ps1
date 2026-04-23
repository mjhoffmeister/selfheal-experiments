<#
.SYNOPSIS
    Inject the "Node major bump removes an API our code was using" scenario.

.DESCRIPTION
    Mechanical wrapper for the single experiment scenario:
      1. Branch off origin/main with a timestamped name.
      2. Bump src/Web/package.json engines.node (FROM_NODE -> TO_NODE).
      3. Bump .github/workflows/ci.yml setup-node node-version
         (FROM_NODE_FULL -> TO_NODE_FULL).
      4. Add src/Web/crypto-helper.js using `crypto.createCipher`. This API
         was deprecated in Node 10 and HARD-REMOVED in Node 22. Calling it
         throws TypeError("crypto.createCipher is not a function") at
         require-time on Node 22.
      5. Add src/Web/crypto-helper.test.js exercising it.
      6. Commit, push, open PR (no auto-merge, no labels, no body fluff).

    Records nothing. The trial logger (you, by hand) appends to
    experiments/trials.jsonl.

    See experiments/README.md for the rationale and the iteration history of
    failed inject hypotheses.

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
$helperFile  = 'src/Web/crypto-helper.js'
$helperTest  = 'src/Web/crypto-helper.test.js'

foreach ($p in @($packageJson, $ciYaml)) {
    if (-not (Test-Path $p)) { throw "Expected file missing: $p" }
}

foreach ($cmd in @('git', 'gh')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $cmd"
    }
}

$dirty = git status --porcelain
if ($dirty) { throw "Working tree not clean:`n$dirty" }

# --- branch ---------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch    = "inject/node-api-removal-$timestamp"

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

# --- write the helper that uses a Node-22-removed API ---------------------
# crypto.createCipher was removed in Node 22 (deprecated since Node 10).
# We use a plausibly-real-looking helper name ("session token signer") so
# the agent has to actually understand the API rather than recognise an
# obviously contrived stub.
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
Set-Content -Path $helperFile -Value $helper -NoNewline

$helperTestSrc = @'
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
Set-Content -Path $helperTest -Value $helperTestSrc -NoNewline

# --- commit + push --------------------------------------------------------
git add $packageJson $ciYaml $helperFile $helperTest
$commitMsg = "Bump Node $FromNode -> $ToNode + add legacy crypto helper (inject)"
git commit -m $commitMsg | Out-Null

if ($NoPush) {
    Write-Host "[dry-run] branch '$branch' built locally; skipped push/PR."
    Write-Host '[dry-run] inspect with: git diff origin/main..HEAD'
    return
}

git push -u origin $branch | Out-Null

$prTitle = "[inject] bump Node $FromNode -> $ToNode + add legacy crypto helper"
$prBody  = @"
Automated injection from ``scripts/inject.ps1``.

- Bumped ``src/Web/package.json`` engines.node: ``$FromNode`` -> ``$ToNode``
- Bumped CI ``node-version``: ``$FromNodeFull`` -> ``$ToNodeFull``
- Added ``src/Web/crypto-helper.js`` (uses ``crypto.createCipher``)
- Added ``src/Web/crypto-helper.test.js``

Expectation: CI fails. ``crypto.createCipher`` was hard-removed in Node 22, so
``require('./crypto-helper')`` throws TypeError when jest loads the test file.
Self-heal responder will open a tracking issue and assign the cloud agent.
Do **not** auto-merge.
"@

gh pr create --base main --head $branch --title $prTitle --body $prBody | Out-Null
$prUrl = gh pr view $branch --json url --jq .url
Write-Host "Opened PR: $prUrl"
