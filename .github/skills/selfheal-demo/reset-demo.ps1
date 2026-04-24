<#
.SYNOPSIS
    Clean up everything created by .github/skills/selfheal-demo/run-demo.ps1.

.DESCRIPTION
    Idempotent. Safe to re-run. "Nothing to clean" is a success path.

    Cleans up, in order:
      1. Open PRs whose title starts with `[demo]` -> close + delete branch.
      2. Open issues with the `self-heal` label whose title contains `[demo]`
         -> close.
      3. Worktrees recorded in .github/skills/selfheal-demo/.state/*.json
         -> git worktree remove --force, then delete the state file.
      4. Fallback: any worktree at git's worktree list whose branch matches
         demo/* -> git worktree remove --force (covers state-file loss).
      5. Any remaining `demo/*` branches on the remote -> push delete.
      6. `git worktree prune`.

.PARAMETER Force
    Skip the destructive-action confirmation prompt. Used by the chat skill.
#>
[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($cmd in @('git', 'gh')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $cmd"
    }
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Not inside a git repo.' }
Set-Location $repoRoot

if (-not $Force) {
    Write-Host 'This will close demo PRs/issues, delete demo/* branches on the remote,'
    Write-Host 'and force-remove demo worktrees. Re-run with -Force to skip this prompt.'
    $resp = Read-Host 'Proceed? [y/N]'
    if ($resp -notmatch '^(y|Y|yes)$') {
        Write-Host 'Aborted.'
        return
    }
}

# --- 1. close demo PRs ----------------------------------------------------
$demoPrs = gh pr list --state open --search '"[demo]" in:title' --json number,title,headRefName --jq '.' | ConvertFrom-Json
if ($demoPrs) {
    foreach ($pr in @($demoPrs)) {
        Write-Host "Closing PR #$($pr.number) ($($pr.title))"
        gh pr close $pr.number --delete-branch --comment 'Closed by reset-demo.ps1.' 2>$null | Out-Null
    }
} else {
    Write-Host 'No open demo PRs.'
}

# --- 2. close demo tracking issues ----------------------------------------
$demoIssues = gh issue list --state open --label self-heal --search '"[demo]" in:title' --json number,title --jq '.' | ConvertFrom-Json
if ($demoIssues) {
    foreach ($iss in @($demoIssues)) {
        Write-Host "Closing issue #$($iss.number) ($($iss.title))"
        gh issue close $iss.number --comment 'Closed by reset-demo.ps1.' 2>$null | Out-Null
    }
} else {
    Write-Host 'No open demo tracking issues.'
}

# --- 3. remove worktrees recorded in state files --------------------------
$stateDir = Join-Path $repoRoot '.github/skills/selfheal-demo/.state'
$cleanedWorktrees = @{}
if (Test-Path $stateDir) {
    Get-ChildItem -Path $stateDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $st = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($st.worktree -and (Test-Path $st.worktree)) {
                Write-Host "Removing worktree: $($st.worktree)"
                git worktree remove --force $st.worktree 2>$null | Out-Null
            }
            if ($st.worktree) { $cleanedWorktrees[$st.worktree] = $true }
        } catch {
            Write-Host "Skipping unreadable state file: $($_.Name) ($($_.Exception.Message))"
        }
        Remove-Item $_.FullName -Force
    }
}

# --- 4. fallback worktree scan -------------------------------------------
$wtList = git worktree list --porcelain 2>$null
$current = @{}
foreach ($line in ($wtList -split "`n")) {
    if ($line -match '^worktree (.+)$')   { if ($current.path) { } ; $current = @{ path = $matches[1] } }
    elseif ($line -match '^branch (.+)$') { $current.branch = $matches[1] }
    elseif ($line.Trim() -eq '' -and $current.Count -gt 0) {
        if ($current.branch -and $current.branch -match 'refs/heads/demo/' -and -not $cleanedWorktrees.ContainsKey($current.path)) {
            Write-Host "Removing stray demo worktree: $($current.path)"
            git worktree remove --force $current.path 2>$null | Out-Null
        }
        $current = @{}
    }
}
if ($current.branch -and $current.branch -match 'refs/heads/demo/' -and -not $cleanedWorktrees.ContainsKey($current.path)) {
    Write-Host "Removing stray demo worktree: $($current.path)"
    git worktree remove --force $current.path 2>$null | Out-Null
}

# --- 5. delete remaining demo/* remote branches ---------------------------
git fetch --prune origin --quiet
$remoteDemoBranches = (git branch -r --list 'origin/demo/*') -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($rb in $remoteDemoBranches) {
    $name = $rb -replace '^origin/', ''
    Write-Host "Deleting remote branch: $name"
    git push origin --delete $name 2>$null | Out-Null
}

# --- 6. prune worktree metadata -------------------------------------------
git worktree prune 2>$null | Out-Null

# Also delete any local demo/* branches the worktree removal left behind.
$localDemo = (git branch --list 'demo/*') -split "`n" | ForEach-Object { $_.Trim().TrimStart('*').Trim() } | Where-Object { $_ }
foreach ($lb in $localDemo) {
    git branch -D $lb 2>$null | Out-Null
}

Write-Host ''
Write-Host 'Reset complete.'
