# Plain-PowerShell test for tools/flash-test-build.ps1 -- no network, no ~1 GB
# download, no Imager launch.
#
# WHY PLAIN POWERSHELL, NOT PESTER
#
# The only Pester on a stock Windows box is the ancient 3.4.0 that ships in
# System32's WindowsPowerShell module path (`Get-Module -ListAvailable
# Pester`), whose Mock/Should syntax does not match anything written against
# modern Pester. Rather than pin a Pester version this repo would then need to
# install, this file uses the same trick Pester's Mock relies on anyway --
# PowerShell resolves a function ahead of an external exe of the same name --
# and defines fake `gh` functions directly. tools/flash-test-build.ps1 dot-
# sourced does not execute anything (see its own guard at the bottom), so this
# file gets its functions with zero side effects and calls them directly.
#
# Run: pwsh tests\test-flash-test-build.ps1
# Exits 0 if every case passes, 1 otherwise (one line per case either way).

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here

. (Join-Path $repoRoot 'tools\flash-test-build.ps1')

$script:failures = 0
$script:total = 0

function Assert-True {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [bool] $Condition, [string] $Detail = '')
    $script:total++
    if ($Condition) {
        Write-Host "PASS: $Name"
    } else {
        $script:failures++
        Write-Host "FAIL: $Name $Detail"
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Script, [string] $MatchMessage = $null)
    $script:total++
    try {
        & $Script
        $script:failures++
        Write-Host "FAIL: $Name (did not throw)"
    } catch {
        if ($MatchMessage -and $_.Exception.Message -notmatch [regex]::Escape($MatchMessage)) {
            $script:failures++
            Write-Host "FAIL: $Name (threw, but message did not contain '$MatchMessage': $($_.Exception.Message))"
        } else {
            Write-Host "PASS: $Name"
        }
    }
}

# =============================================================================
# 1. Run resolution: newest successful run on the branch, failed runs ignored.
# =============================================================================

function gh {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'list') {
        $global:LASTEXITCODE = 0
        # Deliberately out of chronological order, and includes a NEWER
        # failed run and an in-progress run that must both be ignored.
        return @(
            [PSCustomObject]@{ databaseId = 100; headBranch = 'feat/x'; headSha = 'sha100'; status = 'completed'; conclusion = 'success';   createdAt = '2026-09-01T00:00:00Z' },
            [PSCustomObject]@{ databaseId = 300; headBranch = 'feat/x'; headSha = 'sha300'; status = 'completed'; conclusion = 'failure';   createdAt = '2026-09-03T00:00:00Z' },
            [PSCustomObject]@{ databaseId = 200; headBranch = 'feat/x'; headSha = 'sha200'; status = 'completed'; conclusion = 'success';   createdAt = '2026-09-02T00:00:00Z' },
            [PSCustomObject]@{ databaseId = 400; headBranch = 'feat/x'; headSha = 'sha400'; status = 'in_progress'; conclusion = $null;      createdAt = '2026-09-04T00:00:00Z' }
        ) | ConvertTo-Json
    }
    throw "unexpected gh call in test 1: $($Arguments -join ' ')"
}

$resolved = Resolve-TestBuildRun -Branch 'feat/x' -Repo 'Funkenjaeger/elspi'
Assert-True 'run resolution picks the newest SUCCESSFUL run' ($resolved.databaseId -eq 200) "(got $($resolved.databaseId), expected 200 -- run 300 is newer but failed, run 400 is newer but still running)"

# Seen red: break the success filter (accept any completed run regardless of
# conclusion) and confirm this case goes red, then restore it.
function Test-RunResolutionBrokenSeenRed {
    $runs = @(
        [PSCustomObject]@{ databaseId = 100; status = 'completed'; conclusion = 'success'; createdAt = '2026-09-01T00:00:00Z' },
        [PSCustomObject]@{ databaseId = 300; status = 'completed'; conclusion = 'failure'; createdAt = '2026-09-03T00:00:00Z' }
    )
    # The broken version of the filter this case is meant to catch: sorts the
    # same way Resolve-TestBuildRun does, but skips the conclusion check.
    $broken = @($runs | Where-Object { $_.status -eq 'completed' }) |
        Sort-Object -Property { [datetime] $_.createdAt } -Descending | Select-Object -First 1
    return $broken.databaseId -eq 300   # true under the BROKEN filter -- i.e. the bug would pick the failed run
}
Assert-True 'seen red: an unfiltered "completed" check would have picked the FAILED run 300' (Test-RunResolutionBrokenSeenRed) '(confirms the success filter in Resolve-TestBuildRun is load-bearing, not a no-op)'

# =============================================================================
# 2. -RunId bypasses the search entirely.
# =============================================================================

function gh {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'view') {
        $global:LASTEXITCODE = 0
        if ($Arguments[2] -ne '999') { throw "test 2: expected run id 999, got $($Arguments[2])" }
        return [PSCustomObject]@{
            databaseId = 999; headBranch = 'some-branch'; headSha = 'deadbeef'
            status = 'completed'; conclusion = 'success'; createdAt = '2026-09-05T00:00:00Z'; workflowName = 'image'
        } | ConvertTo-Json
    }
    if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'list') {
        throw "test 2: -RunId must bypass 'gh run list' entirely, but it was called"
    }
    throw "unexpected gh call in test 2: $($Arguments -join ' ')"
}

$byId = Resolve-TestBuildRun -RunId '999' -Branch 'ignored-branch' -Repo 'Funkenjaeger/elspi'
Assert-True '-RunId bypasses the branch search' ($byId.databaseId -eq 999 -and $byId.headSha -eq 'deadbeef') "(got databaseId=$($byId.databaseId) headSha=$($byId.headSha))"

# =============================================================================
# 3. Cached artifact is reused when size + digest match; invalidated otherwise.
# =============================================================================

$cacheTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("flash-test-build-cache-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $cacheTestDir | Out-Null
try {
    $artifactInfo = [PSCustomObject]@{ size_in_bytes = 123456; digest = 'sha256:abc123' }

    Assert-True 'no marker file -> not cached' (-not (Test-CachedArtifact -CacheDir $cacheTestDir -ArtifactInfo $artifactInfo))

    'dummy image bytes' | Set-Content -LiteralPath (Join-Path $cacheTestDir 'image.img.xz')
    [PSCustomObject]@{ name = 'elspi-image-abc'; size_in_bytes = 123456; digest = 'sha256:abc123'; run_id = 1 } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cacheTestDir '.artifact-info.json')

    Assert-True 'matching marker + files present -> reused' (Test-CachedArtifact -CacheDir $cacheTestDir -ArtifactInfo $artifactInfo)

    $mismatched = [PSCustomObject]@{ size_in_bytes = 999; digest = 'sha256:abc123' }
    Assert-True 'size mismatch -> not reused (re-download)' (-not (Test-CachedArtifact -CacheDir $cacheTestDir -ArtifactInfo $mismatched))

    $mismatched2 = [PSCustomObject]@{ size_in_bytes = 123456; digest = 'sha256:different' }
    Assert-True 'digest mismatch -> not reused (re-download)' (-not (Test-CachedArtifact -CacheDir $cacheTestDir -ArtifactInfo $mismatched2))
} finally {
    Remove-Item -LiteralPath $cacheTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# 4. Path conversion: C:\x\y -> /mnt/c/x/y
# =============================================================================

Assert-True 'path conversion: simple path' ((ConvertTo-WslPath 'C:\x\y') -eq '/mnt/c/x/y') "(got '$(ConvertTo-WslPath 'C:\x\y')')"
Assert-True 'path conversion: nested claude-working path' `
    ((ConvertTo-WslPath 'C:\projects\claude-working\elspi-test-builds\36244494844\image.img.xz') -eq '/mnt/c/projects/claude-working/elspi-test-builds/36244494844/image.img.xz')
Assert-True 'path conversion: lowercases the drive letter' ((ConvertTo-WslPath 'D:\cards\x.json') -eq '/mnt/d/cards/x.json')
Assert-Throws 'path conversion: rejects a relative path' { ConvertTo-WslPath 'relative\path' } 'not an absolute Windows path'

# =============================================================================
# 5. A missing tool fails with the step named.
# =============================================================================

Assert-Throws 'missing tool: names the step (wsl)' { Assert-CommandAvailable -Name 'definitely-not-a-real-cmd-9f3a' -Step 'wsl' } '[wsl]'
Assert-Throws 'missing tool: names the step (gh auth)' {
    function gh { $global:LASTEXITCODE = 127; return $null }
    Assert-CommandAvailable -Name 'definitely-not-a-real-cmd-9f3a' -Step 'gh auth'
} '[gh auth]'
Assert-Throws 'missing tool: names the command that was not found' { Assert-CommandAvailable -Name 'totally-bogus-tool' -Step 'wsl' } 'totally-bogus-tool'

# Assert-GhAuthenticated's own "gh not authenticated" branch (gh present but
# `gh auth status` fails), exercised through a fake `gh` -- NOT by removing
# the real gh from this machine's PATH, which would just fall through to the
# real, already-authenticated gh and make a live call.
function gh {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    $global:LASTEXITCODE = 1
    return 'not logged in'
}
Assert-Throws 'missing tool: Assert-GhAuthenticated names [gh auth] when gh auth status fails' {
    Assert-GhAuthenticated -Repo 'x/y'
} '[gh auth]'
Remove-Item Function:\gh -ErrorAction SilentlyContinue

# NOTE: Imager's own missing/wrong-version case is NOT re-tested here. It is
# exercised in place by tools/flash-elspi.ps1's existing detection logic (this
# file's header explains why flash-test-build.ps1 reuses it via -CheckOnly
# rather than duplicating it), and that logic depends on real registry /
# filesystem state that isn't safe to fake from a test without touching the
# machine's actual Imager install.

# =============================================================================

Write-Host ""
Write-Host "$($script:total - $script:failures) / $($script:total) passed"
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
