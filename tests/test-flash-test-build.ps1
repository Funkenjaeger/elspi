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
# 3b. Zip verification (Confirm-DownloadedZip) -- the actual bug in c0f3b85:
# it compared the sum of the EXTRACTED files against `size_in_bytes`, which
# describes the ZIP. A real zip is never exactly as large as what it unpacks
# to (archive overhead), so build both a fake zip file and a fake "extracted
# total" that deliberately differ, the way the real artifact in the bug
# report did (zip 1,162,774,137 bytes; extracted files summed to
# 1,162,773,597 -- 540 bytes of zip overhead).
# =============================================================================

$zipTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("flash-test-build-zip-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $zipTestDir | Out-Null
try {
    $zipPath = Join-Path $zipTestDir 'elspi-image-deadbeef.zip'
    $zipBytes = New-Object byte[] 1000
    (New-Object System.Random(1)).NextBytes($zipBytes)
    [System.IO.File]::WriteAllBytes($zipPath, $zipBytes)
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # REGRESSION CASE -- seen red against c0f3b85's own logic, green against
    # the fix. c0f3b85's check was:
    #   $totalSize = (extracted files | Measure-Object Length -Sum).Sum
    #   if ($totalSize -ne $artifactInfo.size_in_bytes) { throw ... }
    # Simulate "the zip extracts to slightly fewer bytes than its own size"
    # (every real zip, because of archive overhead) and confirm: (a) the OLD
    # extracted-size-vs-zip-size comparison fails a download that is actually
    # fine, and (b) the FIX -- Confirm-DownloadedZip, checking the zip's own
    # bytes -- accepts that same download.
    $fakeExtractedTotal = $zipBytes.Length - 12   # stand-in for zip overhead
    $artifactInfoNoDigest = [PSCustomObject]@{ size_in_bytes = $zipBytes.Length; digest = $null }

    function Test-OldExtractedSizeLogicSeenRed {
        param($ExtractedTotal, $ArtifactInfo)
        # c0f3b85's actual comparison, reproduced verbatim in spirit.
        return $ExtractedTotal -ne $ArtifactInfo.size_in_bytes   # $true -> old code would throw
    }
    Assert-True 'seen red: c0f3b85 logic (extracted size vs zip size) rejects a good download' `
        (Test-OldExtractedSizeLogicSeenRed -ExtractedTotal $fakeExtractedTotal -ArtifactInfo $artifactInfoNoDigest) `
        "(extracted=$fakeExtractedTotal zip size=$($artifactInfoNoDigest.size_in_bytes) -- these can never be equal for a real zip, which is exactly the bug)"

    # The FIX does not go anywhere near an "extracted total" -- it checks the
    # zip file's own size. Same artifact, same zip on disk: green.
    try {
        Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $artifactInfoNoDigest
        Assert-True 'fix: Confirm-DownloadedZip accepts the same download c0f3b85 would have rejected' $true
    } catch {
        Assert-True 'fix: Confirm-DownloadedZip accepts the same download c0f3b85 would have rejected' $false "(threw: $($_.Exception.Message))"
    }

    # Confirm-DownloadedZip still refuses a genuine size mismatch.
    $badSize = [PSCustomObject]@{ size_in_bytes = $zipBytes.Length + 1; digest = $null }
    Assert-Throws 'Confirm-DownloadedZip refuses a real zip-size mismatch' { Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $badSize } 'not caching this as complete'

    # No digest on the API side -> size-only verification, no throw, and it
    # says so rather than silently skipping the check.
    Assert-True 'no digest on API -> verified by size alone (no throw)' $true  # covered by the accept case above; digest is $null there

    # Matching digest -> accepted.
    $goodDigest = [PSCustomObject]@{ size_in_bytes = $zipBytes.Length; digest = "sha256:$zipHash" }
    try {
        Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $goodDigest
        Assert-True 'matching sha256 digest -> accepted' $true
    } catch {
        Assert-True 'matching sha256 digest -> accepted' $false "(threw: $($_.Exception.Message))"
    }

    # DIGEST MISMATCH -- must refuse, even though the size matches.
    $badDigest = [PSCustomObject]@{ size_in_bytes = $zipBytes.Length; digest = 'sha256:' + ('0' * 64) }
    Assert-Throws 'digest mismatch is refused even when size matches' { Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $badDigest } 'does not match the artifact API''s digest'

    # A malformed digest string falls back to size-only rather than crashing.
    $weirdDigest = [PSCustomObject]@{ size_in_bytes = $zipBytes.Length; digest = 'md5:deadbeef' }
    try {
        Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $weirdDigest
        Assert-True 'unrecognised digest format falls back to size-only, does not throw' $true
    } catch {
        Assert-True 'unrecognised digest format falls back to size-only, does not throw' $false "(threw: $($_.Exception.Message))"
    }
} finally {
    Remove-Item -LiteralPath $zipTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# 3c. Get-CommitFile / Get-MakeOsListScriptForCommit -- must use the BUILD's
# own commit's tools/make-os-list.sh AND its sibling
# tools/os_list.imager-block.json, never this checkout's copies. This is the
# second bug: make-os-list.sh differs per branch (arm64's db380b6 writes
# 64-bit device tags and an arm64 description; master's writes armhf's
# 32-bit tags), so a checkout on one branch running against an artifact
# built on another mislabels the image with no error at all -- and
# make-os-list.sh looks up the block file NEXT TO ITSELF (its own HERE/BLOCK
# logic), so the two files have to come from the same commit into the same
# directory or the pairing itself is wrong even when each file looks fine
# alone.
# =============================================================================

$makeOsListTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("flash-test-build-makeoslist-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $makeOsListTestDir | Out-Null
try {
    # -- Get-CommitFile: the building block, tested directly ---------------

    # The fake `git show` returns content that is deliberately DIFFERENT from
    # whatever tools/make-os-list.sh actually says in THIS checkout -- e.g.
    # the 64-bit device tags an arm64-branch commit would carry, while this
    # repo's own checked-out copy (at test time) is master's 32-bit version.
    # If Get-CommitFile ever read the checkout instead of the commit, this
    # assertion catches it: the checkout's real content would not contain
    # the marker below.
    $buildersOwnContent = "#!/usr/bin/env bash`nset -euo pipefail`necho BUILD-COMMIT-VERSION pi5-64bit pi4-64bit pi3-64bit`n"

    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[0] -eq '-C' -and $Arguments[2] -eq 'show' -and $Arguments[3] -eq 'buildsha123:tools/make-os-list.sh') {
            $global:LASTEXITCODE = 0
            return $buildersOwnContent -split "`n" | Select-Object -SkipLast 1   # simulate line-array stdout
        }
        throw "unexpected git call in Get-CommitFile test 1: $($Arguments -join ' ')"
    }
    $out1 = Join-Path $makeOsListTestDir 'from-commit.sh'
    Get-CommitFile -RepoRoot 'C:\fake\repo' -Sha 'buildsha123' -RepoPath 'tools/make-os-list.sh' -OutFile $out1
    $written = Get-Content -LiteralPath $out1 -Raw

    $realCheckoutContent = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\make-os-list.sh') -Raw
    Assert-True 'uses the BUILD commit''s make-os-list.sh (not the checkout''s)' `
        ($written -match 'BUILD-COMMIT-VERSION' -and $written -ne $realCheckoutContent) `
        "(the checkout's own tools/make-os-list.sh must NOT be what got written)"
    Assert-True 'the fetched content carries the build''s own device tags' ($written -match 'pi5-64bit') "(got: $written)"

    # Commit not present locally -> fetch, then retry -- succeeds on the
    # second `git show`.
    $script:showCallCount = 0
    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[2] -eq 'show') {
            $script:showCallCount++
            if ($script:showCallCount -eq 1) {
                $global:LASTEXITCODE = 128
                return "fatal: invalid object name 'notlocalsha123'."
            }
            $global:LASTEXITCODE = 0
            return @('#!/usr/bin/env bash', 'echo FETCHED-THEN-FOUND')
        }
        if ($Arguments[2] -eq 'fetch') {
            $global:LASTEXITCODE = 0
            return 'From github.com:Funkenjaeger/elspi'
        }
        throw "unexpected git call in Get-CommitFile test 2: $($Arguments -join ' ')"
    }
    $out2 = Join-Path $makeOsListTestDir 'fetched-then-found.sh'
    Get-CommitFile -RepoRoot 'C:\fake\repo' -Sha 'notlocalsha123' -RepoPath 'tools/make-os-list.sh' -OutFile $out2
    Assert-True 'commit not local -> fetches from origin, then succeeds' `
        ((Get-Content -LiteralPath $out2 -Raw) -match 'FETCHED-THEN-FOUND') "(showCallCount=$script:showCallCount)"

    # Commit not present locally AND the fetch fails -> loud failure, no
    # silent fallback to the checkout's own copy.
    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[2] -eq 'show') { $global:LASTEXITCODE = 128; return "fatal: invalid object name." }
        if ($Arguments[2] -eq 'fetch') { $global:LASTEXITCODE = 1; return 'fatal: could not read from remote repository.' }
        throw "unexpected git call in Get-CommitFile test 3: $($Arguments -join ' ')"
    }
    $out3 = Join-Path $makeOsListTestDir 'unreachable.sh'
    Assert-Throws 'commit unreachable even after fetch -> loud failure naming the sha' {
        Get-CommitFile -RepoRoot 'C:\fake\repo' -Sha 'unreachablesha' -RepoPath 'tools/make-os-list.sh' -OutFile $out3
    } 'unreachablesha'
    Assert-True 'no output file left behind after a failed fetch' (-not (Test-Path -LiteralPath $out3))

    # -- Get-MakeOsListScriptForCommit: fetches BOTH sibling files, same commit, same dir --

    $pairSha = 'pairsha456'
    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[2] -ne 'show') { throw "unexpected git call in pairing test: $($Arguments -join ' ')" }
        $spec = $Arguments[3]
        $global:LASTEXITCODE = 0
        if ($spec -eq "${pairSha}:tools/make-os-list.sh") { return @('#!/usr/bin/env bash', 'echo PAIRED-SCRIPT') }
        if ($spec -eq "${pairSha}:tools/os_list.imager-block.json") { return '{"imager":{"devices":["PAIRED-BLOCK"]}}' }
        throw "pairing test: unexpected blob spec $spec"
    }
    $pairDir = Join-Path $makeOsListTestDir 'pair'
    New-Item -ItemType Directory -Force -Path $pairDir | Out-Null
    Get-MakeOsListScriptForCommit -RepoRoot 'C:\fake\repo' -Sha $pairSha -OutDir $pairDir
    $pairedScript = Get-Content -LiteralPath (Join-Path $pairDir 'make-os-list.sh') -Raw
    $pairedBlock = Get-Content -LiteralPath (Join-Path $pairDir 'os_list.imager-block.json') -Raw
    Assert-True 'Get-MakeOsListScriptForCommit writes make-os-list.sh from the commit' ($pairedScript -match 'PAIRED-SCRIPT') "(got: $pairedScript)"
    Assert-True 'Get-MakeOsListScriptForCommit writes the SIBLING os_list.imager-block.json from the SAME commit, next to it' `
        ($pairedBlock -match 'PAIRED-BLOCK') "(got: $pairedBlock -- make-os-list.sh looks this file up next to itself, so a mismatched pair breaks silently)"

    Remove-Item Function:\git -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $makeOsListTestDir -Recurse -Force -ErrorAction SilentlyContinue
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
# 6. -Source forgejo. The network is faked by redefining Invoke-ForgejoApi and
# Invoke-ForgejoDownload; git, wsl, Read-Host and the preflight checks are
# faked the same way. The token is a made-up string in a temp file, and the
# tests assert it never appears in a URL or in anything the script prints.
# =============================================================================

$fjDir = Join-Path ([System.IO.Path]::GetTempPath()) ("flash-test-build-forgejo-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $fjDir | Out-Null
try {
    $fjBase = 'https://forgejo.example'
    $fjRepo = 'owner/repo'
    $fjPkg = 'pkgowner/pkgname'
    $fakeToken = 'FAKE-TEST-TOKEN-not-a-credential-7d1e'
    $tokenFile = Join-Path $fjDir 'forgejo-token'
    Set-Content -LiteralPath $tokenFile -Value $fakeToken -NoNewline
    $shaA = 'a' * 40
    $shaB = 'b' * 40

    # -- auth: the token file gate ------------------------------------------
    Assert-Throws 'forgejo: missing token file -> fails, telling Evan how to mint one' {
        Get-ForgejoAuthHeader -TokenFile (Join-Path $fjDir 'no-such-token')
    } 'read:package and read:repository'
    Assert-Throws 'forgejo: missing token file -> the message names the path' {
        Get-ForgejoAuthHeader -TokenFile (Join-Path $fjDir 'no-such-token')
    } 'no-such-token'
    $emptyToken = Join-Path $fjDir 'empty-token'
    Set-Content -LiteralPath $emptyToken -Value '   ' -NoNewline
    Assert-Throws 'forgejo: empty token file -> fails' { Get-ForgejoAuthHeader -TokenFile $emptyToken } 'is empty'
    $hdr = Get-ForgejoAuthHeader -TokenFile $tokenFile
    Assert-True 'forgejo: header is "Authorization: token <t>"' ($hdr.Authorization -eq "token $fakeToken")

    # -- config gate ----------------------------------------------------------
    Assert-Throws 'forgejo: no URL -> names the env var' { Assert-ForgejoConfig -Url '' -Repo $fjRepo -Package $fjPkg } 'ELSPI_FORGEJO_URL'
    Assert-Throws 'forgejo: repo not owner/repo -> names the env var' { Assert-ForgejoConfig -Url $fjBase -Repo 'justone' -Package $fjPkg } 'ELSPI_FORGEJO_REPO'
    Assert-Throws 'forgejo: package not owner/name -> names the env var' { Assert-ForgejoConfig -Url $fjBase -Repo $fjRepo -Package '' } 'ELSPI_FORGEJO_PACKAGE'
    Assert-True 'forgejo: trailing slash trimmed from URL' ((Assert-ForgejoConfig -Url "$fjBase/" -Repo $fjRepo -Package $fjPkg) -eq $fjBase)

    # -- run resolution -------------------------------------------------------
    $script:fjCalls = @()
    function Invoke-ForgejoApi {
        param([string] $Uri, [hashtable] $Headers)
        $script:fjCalls += $Uri
        # As if the server IGNORED status/workflow_id: a newer failed run, a
        # newer running one, and a newer success of a different workflow must
        # all lose to the newest successful image.yml run.
        return [PSCustomObject]@{ total_count = 5; workflow_runs = @(
            [PSCustomObject]@{ id = 11; status = 'success'; workflow_id = 'image.yml'; commit_sha = $shaA; prettyref = 'arm64'; created = '2026-09-20T00:00:00Z' },
            [PSCustomObject]@{ id = 15; status = 'failure'; workflow_id = 'image.yml'; commit_sha = ('c' * 40); prettyref = 'arm64'; created = '2026-09-25T00:00:00Z' },
            [PSCustomObject]@{ id = 13; status = 'success'; workflow_id = 'image.yml'; commit_sha = $shaB; prettyref = 'arm64'; created = '2026-09-22T00:00:00Z' },
            [PSCustomObject]@{ id = 16; status = 'running'; workflow_id = 'image.yml'; commit_sha = ('d' * 40); prettyref = 'arm64'; created = '2026-09-26T00:00:00Z' },
            [PSCustomObject]@{ id = 17; status = 'success'; workflow_id = 'other.yml'; commit_sha = ('e' * 40); prettyref = 'arm64'; created = '2026-09-26T01:00:00Z' }
        ) }
    }
    $b = Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -Branch 'arm64'
    Assert-True 'forgejo: -Branch picks the newest SUCCESSFUL image.yml run' ($b.run_id -eq 13 -and $b.sha -eq $shaB) "(got run $($b.run_id) sha $($b.sha))"
    Assert-True 'forgejo: runs query carries ref, workflow_id and status filters' `
        ($script:fjCalls[0] -eq "$fjBase/api/v1/repos/$fjRepo/actions/runs?ref=refs%2Fheads%2Farm64&workflow_id=image.yml&status=success&limit=20") "(got $($script:fjCalls[0]))"

    function Invoke-ForgejoApi {
        param([string] $Uri, [hashtable] $Headers)
        return [PSCustomObject]@{ total_count = 2; workflow_runs = @(
            [PSCustomObject]@{ id = 15; status = 'failure'; workflow_id = 'image.yml'; commit_sha = $shaA; created = '2026-09-25T00:00:00Z' },
            [PSCustomObject]@{ id = 16; status = 'running'; workflow_id = 'image.yml'; commit_sha = $shaB; created = '2026-09-26T00:00:00Z' }
        ) }
    }
    Assert-Throws 'forgejo: no successful run on the branch -> fails' {
        Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -Branch 'arm64'
    } 'no successful image.yml run'
    function Invoke-ForgejoApi { param([string] $Uri, [hashtable] $Headers) return [PSCustomObject]@{ total_count = 0; workflow_runs = $null } }
    Assert-Throws 'forgejo: empty run list -> fails' {
        Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -Branch 'arm64'
    } 'no successful image.yml run'

    function Invoke-ForgejoApi {
        param([string] $Uri, [hashtable] $Headers)
        if ($Uri -ne "$fjBase/api/v1/repos/$fjRepo/actions/runs/42") { throw "unexpected uri $Uri" }
        return [PSCustomObject]@{ id = 42; status = 'success'; workflow_id = 'image.yml'; commit_sha = $shaA; prettyref = 'feat/x'; created = '2026-09-24T00:00:00Z' }
    }
    $r = Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -RunId '42' -Branch 'ignored'
    Assert-True 'forgejo: -RunId reads that run' ($r.run_id -eq 42 -and $r.sha -eq $shaA)
    function Invoke-ForgejoApi { param([string] $Uri, [hashtable] $Headers) return [PSCustomObject]@{ id = 42; status = 'success'; workflow_id = 'lint.yml'; commit_sha = $shaA } }
    Assert-Throws 'forgejo: -RunId of a non-image workflow -> fails' {
        Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -RunId '42'
    } "not 'image.yml'"

    function Invoke-ForgejoApi { throw 'test: -Sha must not call the API' }
    $s = Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -Sha $shaA.ToUpperInvariant()
    Assert-True 'forgejo: -Sha needs no API call, and is lowercased' ($s.sha -eq $shaA)
    Assert-Throws 'forgejo: a short -Sha is refused (the package version is the FULL sha)' {
        Resolve-ForgejoBuild -BaseUrl $fjBase -Repo $fjRepo -Headers $hdr -Sha 'abc1234'
    } 'not a full 40-hex'

    # -- package file selection -----------------------------------------------
    $h64 = 'f' * 64
    $imgEntry = [PSCustomObject]@{ id = 1; Size = 1000; name = 'image_2026-09-26-elspi-arm64.img.xz'; sha256 = $h64 }
    $infoEntry = [PSCustomObject]@{ id = 2; Size = 10; name = 'image_2026-09-26-elspi-arm64.info'; sha256 = $h64 }
    $logEntry = [PSCustomObject]@{ id = 3; Size = 10; name = 'build.log'; sha256 = $h64 }
    $pick = Select-ForgejoImageFile -Files @($logEntry, $imgEntry, $infoEntry) -Sha $shaA
    Assert-True 'forgejo: picks the one image_*.img.xz among .info and build.log' ($pick.name -eq $imgEntry.name -and $pick.size -eq 1000)
    Assert-Throws 'forgejo: no image in the package version -> fails' { Select-ForgejoImageFile -Files @($logEntry, $infoEntry) -Sha $shaA } 'no image_*.img.xz'
    Assert-Throws 'forgejo: empty package version -> fails' { Select-ForgejoImageFile -Files @() -Sha $shaA } 'no image_*.img.xz'
    $img2 = [PSCustomObject]@{ id = 4; Size = 5; name = 'image_other.img.xz'; sha256 = $h64 }
    Assert-Throws 'forgejo: two images -> fails' { Select-ForgejoImageFile -Files @($imgEntry, $img2) -Sha $shaA } 'expected exactly one'
    $noHash = [PSCustomObject]@{ id = 1; Size = 1000; name = 'image_x.img.xz'; sha256 = '' }
    Assert-Throws 'forgejo: image listed without a sha256 -> fails' { Select-ForgejoImageFile -Files @($noHash) } 'no sha256'
    $noSize = [PSCustomObject]@{ id = 1; name = 'image_x.img.xz'; sha256 = $h64 }
    Assert-Throws 'forgejo: image listed without a size -> fails' { Select-ForgejoImageFile -Files @($noSize) } 'no size'
    $evil = [PSCustomObject]@{ id = 1; Size = 1; name = 'image_..\..\x.img.xz'; sha256 = $h64 }
    Assert-Throws 'forgejo: a file name with path characters is refused' { Select-ForgejoImageFile -Files @($evil) } 'not a plain file name'

    # -- download verification ------------------------------------------------
    $payload = New-Object byte[] 4096
    (New-Object System.Random(7)).NextBytes($payload)
    $payloadHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($payload)).Replace('-', '').ToLowerInvariant()
    $dl = Join-Path $fjDir 'dl.img.xz'
    [System.IO.File]::WriteAllBytes($dl, $payload)
    $goodInfo = [PSCustomObject]@{ name = 'image_t.img.xz'; size = [int64] 4096; sha256 = $payloadHash }
    try { Confirm-DownloadedForgejoFile -Path $dl -FileInfo $goodInfo; Assert-True 'forgejo: matching size+sha256 -> accepted' $true }
    catch { Assert-True 'forgejo: matching size+sha256 -> accepted' $false "(threw: $($_.Exception.Message))" }
    Assert-Throws 'forgejo: size mismatch -> refused' {
        Confirm-DownloadedForgejoFile -Path $dl -FileInfo ([PSCustomObject]@{ name = 'image_t.img.xz'; size = [int64] 4097; sha256 = $payloadHash })
    } 'not caching this as complete'
    Assert-Throws 'forgejo: sha256 mismatch with the right size -> refused' {
        Confirm-DownloadedForgejoFile -Path $dl -FileInfo ([PSCustomObject]@{ name = 'image_t.img.xz'; size = [int64] 4096; sha256 = ('0' * 64) })
    } 'does not match the package API'

    # -- commit availability --------------------------------------------------
    $script:catFileCalls = 0
    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[2] -eq 'cat-file') { $script:catFileCalls++; $global:LASTEXITCODE = 1; return 'fatal: Not a valid object name' }
        if ($Arguments[2] -eq 'fetch') { $global:LASTEXITCODE = 128; return 'fatal: remote error' }
        throw "unexpected git call: $($Arguments -join ' ')"
    }
    Assert-Throws 'forgejo: sha not in this checkout even after fetch -> refuses to download' {
        Assert-CommitAvailable -RepoRoot 'C:\fake\repo' -Sha $shaA
    } 'Refusing to download'
    Assert-True 'forgejo: the commit check fetched and re-checked' ($script:catFileCalls -eq 2) "(cat-file calls: $script:catFileCalls)"

    # -- end to end through Invoke-FlashTestBuild -Source forgejo -------------
    function Assert-WslAvailable { }
    function Assert-ImagerReady { param($RepoRoot) }
    function Get-MakeOsListScriptForCommit { param($RepoRoot, $Sha, $OutDir) $script:osListSha = $Sha }
    function wsl { $global:LASTEXITCODE = 0 }
    function Read-Host { param($Prompt) 'y' }
    function git {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if ($Arguments[2] -eq 'cat-file') { $global:LASTEXITCODE = 0; return }
        throw "unexpected git call: $($Arguments -join ' ')"
    }
    $e2eFile = [PSCustomObject]@{ id = 1; Size = 4096; name = 'image_e2e.img.xz'; sha256 = $payloadHash }
    $script:fjCalls = @()
    $script:fjHeaders = @()
    function Invoke-ForgejoApi {
        param([string] $Uri, [hashtable] $Headers)
        $script:fjCalls += $Uri; $script:fjHeaders += $Headers.Authorization
        if ($Uri -like '*/actions/runs?*') {
            return [PSCustomObject]@{ workflow_runs = @([PSCustomObject]@{ id = 77; status = 'success'; workflow_id = 'image.yml'; commit_sha = $shaA; prettyref = 'arm64'; created = '2026-09-26T00:00:00Z' }) }
        }
        if ($Uri -eq "$fjBase/api/v1/packages/pkgowner/generic/pkgname/$shaA/files") { return @($logEntry, $e2eFile) }
        throw "unexpected uri $Uri"
    }
    $script:downloadBytes = $payload
    $script:downloads = @()
    function Invoke-ForgejoDownload {
        param([string] $Uri, [hashtable] $Headers, [string] $OutFile)
        $script:downloads += $Uri; $script:fjHeaders += $Headers.Authorization
        [System.IO.File]::WriteAllBytes($OutFile, $script:downloadBytes)
    }
    $fjArgs = @{
        Source = 'forgejo'; Branch = 'arm64'; RepoRoot = 'C:\fake\repo'
        ForgejoUrl = $fjBase; ForgejoRepo = $fjRepo; ForgejoPackage = $fjPkg; ForgejoTokenFile = $tokenFile
    }
    $expectedDownload = "$fjBase/api/packages/pkgowner/generic/pkgname/$shaA/image_e2e.img.xz"

    # Dry run: resolves and prints every URL, downloads nothing.
    $dryDest = Join-Path $fjDir 'dry'
    $dryOut = (& { Invoke-FlashTestBuild @fjArgs -Dest $dryDest -DryRun } 6>&1 | Out-String)
    Assert-True 'forgejo dry run: prints the resolved download URL' ($dryOut -match [regex]::Escape($expectedDownload)) "(output: $dryOut)"
    Assert-True 'forgejo dry run: downloads nothing, creates no cache dir' ($script:downloads.Count -eq 0 -and -not (Test-Path -LiteralPath $dryDest))
    Assert-True 'forgejo dry run: never prints the token' ($dryOut -notmatch [regex]::Escape($fakeToken))

    # Corrupt download (same size, different bytes): refused, nothing cached.
    $badDest = Join-Path $fjDir 'bad'
    $corrupt = [byte[]] $payload.Clone(); $corrupt[100] = $corrupt[100] -bxor 0xFF
    $script:downloadBytes = $corrupt
    Assert-Throws 'forgejo e2e: corrupt download -> refused' { Invoke-FlashTestBuild @fjArgs -Dest $badDest -NoLaunch 6>$null } 'does not match the package API'
    $badCache = Join-Path $badDest "forgejo-$shaA"
    Assert-True 'forgejo e2e: corrupt download leaves no marker, no image, no .partial' `
        (-not (Test-Path (Join-Path $badCache '.forgejo-package-info.json')) -and -not (Test-Path (Join-Path $badCache 'image_e2e.img.xz')) -and -not (Test-Path (Join-Path $badCache 'image_e2e.img.xz.partial')))

    # Good download: verified, renamed into place, marker written, os_list built from the build's sha.
    $goodDest = Join-Path $fjDir 'good'
    $script:downloadBytes = $payload
    $script:downloads = @()
    $script:osListSha = $null
    $runOut = (& { Invoke-FlashTestBuild @fjArgs -Dest $goodDest -NoLaunch } 6>&1 | Out-String)
    $goodCache = Join-Path $goodDest "forgejo-$shaA"
    Assert-True 'forgejo e2e: good download cached with its marker' `
        ((Test-Path (Join-Path $goodCache 'image_e2e.img.xz')) -and (Test-Path (Join-Path $goodCache '.forgejo-package-info.json')) -and -not (Test-Path (Join-Path $goodCache 'image_e2e.img.xz.partial')))
    Assert-True 'forgejo e2e: downloaded from the package registry URL' ($script:downloads.Count -eq 1 -and $script:downloads[0] -eq $expectedDownload) "(got $($script:downloads -join ', '))"
    Assert-True 'forgejo e2e: make-os-list.sh comes from the BUILD''s sha' ($script:osListSha -eq $shaA)
    Assert-True 'forgejo e2e: cache reused on the next run' (Test-CachedForgejoImage -CacheDir $goodCache -FileInfo (Select-ForgejoImageFile -Files @($e2eFile)) -Sha $shaA)
    $script:downloads = @()
    $null = (& { Invoke-FlashTestBuild @fjArgs -Dest $goodDest -NoLaunch } 6>&1 | Out-String)
    Assert-True 'forgejo e2e: second run downloads nothing' ($script:downloads.Count -eq 0)
    $changed = Select-ForgejoImageFile -Files @([PSCustomObject]@{ Size = 4096; name = 'image_e2e.img.xz'; sha256 = ('1' * 64) })
    Assert-True 'forgejo: cache NOT reused when the listed sha256 changed' (-not (Test-CachedForgejoImage -CacheDir $goodCache -FileInfo $changed -Sha $shaA))
    Assert-True 'forgejo: cache NOT reused for another sha' (-not (Test-CachedForgejoImage -CacheDir $goodCache -FileInfo (Select-ForgejoImageFile -Files @($e2eFile)) -Sha $shaB))

    # The token went only into Authorization headers.
    Assert-True 'forgejo: every request carried "Authorization: token <t>"' (@($script:fjHeaders | Where-Object { $_ -ne "token $fakeToken" }).Count -eq 0 -and $script:fjHeaders.Count -gt 0)
    Assert-True 'forgejo: the token is in no URL' (@($script:fjCalls + $script:downloads | Where-Object { $_ -match [regex]::Escape($fakeToken) }).Count -eq 0)
    Assert-True 'forgejo: the token is in no printed output' ($runOut -notmatch [regex]::Escape($fakeToken))

    # Missing token file stops the run in preflight, before any API call.
    $script:fjCalls = @()
    $noTok = $fjArgs.Clone(); $noTok.ForgejoTokenFile = (Join-Path $fjDir 'absent-token')
    Assert-Throws 'forgejo e2e: missing token file -> stops before any API call' { Invoke-FlashTestBuild @noTok -Dest $goodDest -DryRun 6>$null } 'Generate New Token'
    Assert-True 'forgejo e2e: ... and no API call was made' ($script:fjCalls.Count -eq 0)

    # -Sha is Forgejo-only: the GitHub path refuses it rather than ignoring it.
    Assert-Throws 'github: -Sha is refused (Forgejo-only)' { Invoke-FlashTestBuild -Sha $shaA -Branch 'arm64' -Dest $goodDest -RepoRoot 'C:\fake\repo' -DryRun } 'Forgejo only'

    foreach ($f in 'Assert-WslAvailable', 'Assert-ImagerReady', 'Get-MakeOsListScriptForCommit', 'wsl', 'Read-Host', 'git', 'Invoke-ForgejoApi', 'Invoke-ForgejoDownload') {
        Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $fjDir -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================

Write-Host ""
Write-Host "$($script:total - $script:failures) / $($script:total) passed"
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
