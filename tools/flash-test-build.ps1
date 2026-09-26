# Flash an UNRELEASED CI build of the elspi image -- one command, nothing
# published.
#
#   tools\flash-test-build.ps1 -Branch feat/first-boot-ui
#   tools\flash-test-build.ps1 -RunId 36244494844
#   tools\flash-test-build.ps1 -Branch arm64 -Dest D:\cards\test-builds
#   tools\flash-test-build.ps1 -Branch feat/first-boot-ui -DryRun
#
# WHAT THIS IS FOR, AND WHAT IT ISN'T
#
# .github/workflows/image.yml's build job runs on every workflow_dispatch and
# keeps its image as a 14-day workflow artifact -- it publishes nothing. This
# script is the one-command version of pulling that artifact down and flashing
# it, replacing three manual steps:
#
#   1. gh run download <run-id> --repo Funkenjaeger/elspi \
#        --name elspi-image-<sha> --dir <cache>
#   2. wsl bash -lc "tools/make-os-list.sh <img> --url file://<img> \
#        --out <cache>/os_list.json"
#   3. tools\flash-elspi.ps1 <cache>\os_list.json
#
# It never tags, never creates a release, and never uploads anything -- the
# artifact is downloaded and the JSON built entirely from local files. A
# RELEASED card still comes from docs/flashing.md's
# `--repo .../releases/latest/download/os_list.json`, which this script does
# not touch.
#
# WHY A PER-RUN CACHE DIRECTORY
#
# The artifact is ~1 GB. Re-running this against the same run (to re-flash a
# second card, or after a failed flash) should not re-download it, so a
# completed download is kept under <Dest>\<run-id>\ next to a small
# `.artifact-info.json` marker recording the artifact's size and content
# digest as GitHub's API reports them. The next run compares against that API
# response (a few hundred bytes, not the artifact) before deciding to reuse or
# re-fetch -- see Test-CachedArtifact below.
#
# WHY wsl bash -lc, NOT a native PowerShell port of make-os-list.sh
#
# make-os-list.sh depends on the exact pipeline described in its own header
# (tee'd sha256sum/wc -c over the decompressed stream, `xz -t`, a re-parse
# gate on the JSON it just wrote) to get `extract_size` / `extract_sha256`
# right without decompressing twice. Reimplementing that in PowerShell would
# be the "second copy of the same logic" this repo's tools already avoid
# (tools/flash-elspi.ps1's own header). `wsl bash -lc` runs the real script
# unmodified; the only work this file does around it is converting the
# Windows paths involved to the /mnt/c/... form WSL needs for its own
# arguments, and building a Windows-style file:// URL (not a WSL path -- see
# make-os-list.sh's own WSL note) for Imager, which runs natively on Windows
# and cannot resolve /mnt/c.
#
# TESTING
#
#   pwsh tests\test-flash-test-build.ps1
#
# dot-sources this file (which only defines functions and does not run
# Main -- see the guard at the bottom) and exercises Resolve-TestBuildRun,
# ConvertTo-WslPath, Test-CachedArtifact and Assert-CommandAvailable directly,
# with gh/api calls replaced by fake functions of the same name. No network,
# no download, no Imager launch.

[CmdletBinding()]
param(
    # Branch to search for the newest successful image.yml run. Ignored if
    # -RunId is given.
    [string] $Branch,

    # A specific run id -- bypasses the branch search entirely, including the
    # "must have succeeded" filter (you asked for this run by number; a
    # warning is printed if it did not succeed, but the run is still used).
    [string] $RunId,

    # Base cache directory. The actual download goes to $Dest\<run-id>\. Fixed
    # per Evan's approval of this tool's design -- override with -Dest for a
    # one-off elsewhere.
    [string] $Dest = 'C:\projects\claude-working\elspi-test-builds',

    # Do everything up to and including the y/N confirmation prompt's
    # decision point, then print what each remaining step WOULD do (download,
    # make-os-list.sh, Imager) instead of doing it. No network cost beyond the
    # small `gh run list`/`gh run view`/`gh api .../artifacts` calls needed to
    # resolve the run and check the cache.
    [switch] $DryRun
)

$Repo = 'Funkenjaeger/elspi'

# =============================================================================
# Helpers -- pure/testable. Each external tool call goes through Invoke-Gh /
# Invoke-GhJson so a test can dot-source this file and redefine `gh` (or
# Invoke-Gh directly) as a fake function; PowerShell resolves a function
# ahead of an external exe of the same name, so `& gh @args` inside
# Invoke-Gh calls the fake once one exists in scope.
# =============================================================================

function Invoke-Gh {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Arguments)
    $out = & gh @Arguments 2>&1
    [PSCustomObject]@{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Invoke-GhJson {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Arguments)
    $result = Invoke-Gh @Arguments
    if ($result.ExitCode -ne 0) {
        throw "gh $($Arguments -join ' ') failed (exit $($result.ExitCode)): $($result.Output -join "`n")"
    }
    return ($result.Output -join "`n") | ConvertFrom-Json
}

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Step
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "[$Step] '$Name' was not found on PATH."
    }
}

function Assert-GhAuthenticated {
    param([string] $Repo = $script:Repo)
    Assert-CommandAvailable -Name 'gh' -Step 'gh auth'
    $result = Invoke-Gh 'auth' 'status'
    if ($result.ExitCode -ne 0) {
        throw "[gh auth] 'gh auth status' failed (exit $($result.ExitCode)) -- run 'gh auth login'. Output: $($result.Output -join ' / ')"
    }
}

function Assert-WslAvailable {
    Assert-CommandAvailable -Name 'wsl' -Step 'wsl'
    $probe = & wsl bash -lc 'true' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "[wsl] 'wsl bash -lc true' failed (exit $LASTEXITCODE) -- is a WSL distro installed and set as default? Output: $probe"
    }
}

function Assert-ImagerReady {
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $flashElspi = Join-Path $RepoRoot 'tools\flash-elspi.ps1'
    if (-not (Test-Path -LiteralPath $flashElspi -PathType Leaf)) {
        throw "[Imager] tools\flash-elspi.ps1 not found at $flashElspi"
    }
    & $flashElspi -CheckOnly
    if ($LASTEXITCODE -ne 0) {
        throw "[Imager] flash-elspi.ps1 -CheckOnly failed (exit $LASTEXITCODE) -- see its message above."
    }
}

# Windows absolute path -> the /mnt/<drive>/... path WSL sees it as.
#   'C:\x\y'  ->  '/mnt/c/x/y'
function ConvertTo-WslPath {
    param([Parameter(Mandatory)] [string] $Path)
    $slashed = $Path -replace '\\', '/'
    if ($slashed -match '^(?<drive>[A-Za-z]):/(?<rest>.*)$') {
        $drive = $Matches['drive'].ToLowerInvariant()
        return "/mnt/$drive/$($Matches['rest'])"
    }
    throw "ConvertTo-WslPath: '$Path' is not an absolute Windows path (expected e.g. 'C:\x\y')"
}

# Resolve which run to use.
#   -RunId given  -> gh run view that id directly (the search is skipped).
#   -Branch given -> gh run list on that branch, newest run with
#                    status=completed/conclusion=success wins; a failed or
#                    still-running run on the same branch is never picked over
#                    an older successful one.
function Resolve-TestBuildRun {
    param(
        [string] $Branch,
        [string] $RunId,
        [string] $Repo = $script:Repo
    )
    if ($RunId) {
        $run = Invoke-GhJson 'run' 'view' $RunId '--repo' $Repo `
            '--json' 'databaseId,headBranch,headSha,status,conclusion,createdAt,workflowName'
        if ($run.workflowName -ne 'image') {
            throw "Resolve-TestBuildRun: run $RunId is a '$($run.workflowName)' run, not 'image'"
        }
        if ($run.conclusion -ne 'success') {
            Write-Warning "run $RunId did not succeed (conclusion: $($run.conclusion)) -- using it anyway, you asked for it by id"
        }
        return $run
    }

    if (-not $Branch) {
        throw "Resolve-TestBuildRun: pass -Branch <name> or -RunId <id>"
    }

    $runs = Invoke-GhJson 'run' 'list' '--repo' $Repo '--workflow' 'image.yml' `
        '--branch' $Branch '--limit' '50' `
        '--json' 'databaseId,headBranch,headSha,status,conclusion,createdAt'
    $runs = @($runs)
    $successful = @($runs | Where-Object { $_.status -eq 'completed' -and $_.conclusion -eq 'success' })
    if ($successful.Count -eq 0) {
        throw "Resolve-TestBuildRun: no successful image.yml run found on branch '$Branch' (checked $($runs.Count) run(s))"
    }
    $newest = $successful | Sort-Object -Property { [datetime] $_.createdAt } -Descending | Select-Object -First 1
    return $newest
}

# The artifact metadata GitHub has for this run's elspi-image-<sha> artifact
# (size + content digest), fetched with one small `gh api` call -- not the
# artifact itself.
function Get-ArtifactInfo {
    param(
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $ArtifactName,
        [string] $Repo = $script:Repo
    )
    $resp = Invoke-GhJson 'api' "repos/$Repo/actions/runs/$RunId/artifacts"
    $match = @($resp.artifacts | Where-Object { $_.name -eq $ArtifactName -and -not $_.expired }) | Select-Object -First 1
    if (-not $match) {
        throw "Get-ArtifactInfo: no non-expired artifact named '$ArtifactName' on run $RunId"
    }
    return $match
}

# True if $CacheDir already holds a complete, still-valid download of the
# artifact described by $ArtifactInfo (an object with .size_in_bytes and
# .digest, as Get-ArtifactInfo returns). Compares against the marker file
# written by a prior successful download -- never re-hashes the ~1 GB payload.
function Test-CachedArtifact {
    param(
        [Parameter(Mandatory)] [string] $CacheDir,
        [Parameter(Mandatory)] $ArtifactInfo
    )
    $marker = Join-Path $CacheDir '.artifact-info.json'
    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    try {
        $recorded = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    } catch {
        return $false
    }
    if ($recorded.size_in_bytes -ne $ArtifactInfo.size_in_bytes) { return $false }
    if ($recorded.digest -ne $ArtifactInfo.digest) { return $false }
    $files = @(Get-ChildItem -LiteralPath $CacheDir -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne '.artifact-info.json' })
    if ($files.Count -eq 0) { return $false }
    return $true
}

# =============================================================================
# Main
# =============================================================================

function Invoke-FlashTestBuild {
    [CmdletBinding()]
    param(
        [string] $Branch,
        [string] $RunId,
        [Parameter(Mandatory)] [string] $Dest,
        [switch] $DryRun,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Repo = $script:Repo
    )

    if (-not $Branch -and -not $RunId) {
        throw "flash-test-build: pass -Branch <name> or -RunId <id>"
    }

    Write-Host "== preflight =="
    Assert-GhAuthenticated -Repo $Repo
    Assert-WslAvailable
    Assert-ImagerReady -RepoRoot $RepoRoot
    Write-Host "gh, wsl and Imager 2.x are all present."
    Write-Host ""

    Write-Host "== resolving run =="
    $run = Resolve-TestBuildRun -Branch $Branch -RunId $RunId -Repo $Repo
    $sha = $run.headSha
    $artifactName = "elspi-image-$sha"
    Write-Host ("branch:   {0}" -f $run.headBranch)
    Write-Host ("sha:      {0}" -f $sha)
    Write-Host ("run id:   {0}" -f $run.databaseId)
    Write-Host ("date:     {0}" -f $run.createdAt)
    Write-Host ("artifact: {0}" -f $artifactName)
    Write-Host ""

    $artifactInfo = Get-ArtifactInfo -RunId $run.databaseId -ArtifactName $artifactName -Repo $Repo
    $cacheDir = Join-Path $Dest "$($run.databaseId)"
    $sizeMb = [math]::Round($artifactInfo.size_in_bytes / 1MB)
    $reuse = Test-CachedArtifact -CacheDir $cacheDir -ArtifactInfo $artifactInfo

    if ($reuse) {
        Write-Host "cache:    reusing $cacheDir (already downloaded, ~$sizeMb MB, verified by size+digest against the API)"
    } else {
        Write-Host "cache:    $cacheDir (not cached yet -- would download ~$sizeMb MB)"
    }
    Write-Host ""

    if ($DryRun) {
        Write-Host "== DRY RUN: stopping before the download and the Imager launch =="
        if ($reuse) {
            Write-Host "would reuse the cached artifact above; no download"
        } else {
            Write-Host "would run: gh run download $($run.databaseId) --repo $Repo --name $artifactName --dir `"$cacheDir`""
        }
        $img = "$cacheDir\<image>.img.xz"
        $osList = "$cacheDir\os_list.json"
        $wslScript = ConvertTo-WslPath (Join-Path $RepoRoot 'tools\make-os-list.sh')
        $wslImg = ConvertTo-WslPath $img
        $wslOut = ConvertTo-WslPath $osList
        $fileUrl = "file:///" + ($img -replace '\\', '/')
        Write-Host "would run: wsl bash -lc `"'$wslScript' '$wslImg' --url '$fileUrl' --out '$wslOut'`""
        Write-Host "  (Windows path -> WSL path: $img -> $wslImg)"
        Write-Host "would run: tools\flash-elspi.ps1 `"$osList`""
        return
    }

    if (-not $reuse) {
        $answer = Read-Host "Download ~$sizeMb MB from run $($run.databaseId) ($($run.headBranch) @ $sha)? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted -- nothing downloaded."
            return
        }
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Write-Host "downloading $artifactName to $cacheDir ..."
        $dl = Invoke-Gh 'run' 'download' "$($run.databaseId)" '--repo' $Repo '--name' $artifactName '--dir' $cacheDir
        if ($dl.ExitCode -ne 0) {
            throw "[gh run download] failed (exit $($dl.ExitCode)): $($dl.Output -join "`n")"
        }

        $downloaded = @(Get-ChildItem -LiteralPath $cacheDir -File -Recurse)
        $totalSize = ($downloaded | Measure-Object -Property Length -Sum).Sum
        if ($totalSize -ne $artifactInfo.size_in_bytes) {
            throw "[gh run download] downloaded $totalSize bytes under $cacheDir but the artifact API reported $($artifactInfo.size_in_bytes) -- not caching this as complete"
        }
        [PSCustomObject]@{
            name          = $artifactName
            size_in_bytes = $artifactInfo.size_in_bytes
            digest        = $artifactInfo.digest
            run_id        = $run.databaseId
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cacheDir '.artifact-info.json') -Encoding utf8
        Write-Host "downloaded and verified ($totalSize bytes)."
    }

    $img = Get-ChildItem -LiteralPath $cacheDir -Filter '*.img.xz' -Recurse | Select-Object -First 1
    if (-not $img) { throw "[make-os-list] no *.img.xz found under $cacheDir" }

    $osListPath = Join-Path $cacheDir 'os_list.json'
    $fileUrl = "file:///" + ($img.FullName -replace '\\', '/')
    $wslScript = ConvertTo-WslPath (Join-Path $RepoRoot 'tools\make-os-list.sh')
    $wslImg = ConvertTo-WslPath $img.FullName
    $wslOut = ConvertTo-WslPath $osListPath

    Write-Host ""
    Write-Host "building os_list.json ..."
    $bashCmd = "'$wslScript' '$wslImg' --url '$fileUrl' --out '$wslOut'"
    & wsl bash -lc $bashCmd
    if ($LASTEXITCODE -ne 0) { throw "[make-os-list.sh] failed (exit $LASTEXITCODE)" }

    Write-Host ""
    Write-Host "launching Imager ..."
    & (Join-Path $RepoRoot 'tools\flash-elspi.ps1') $osListPath
    if ($LASTEXITCODE -ne 0) { throw "[flash-elspi.ps1] failed (exit $LASTEXITCODE)" }
}

# Run Main only when this file is executed directly -- not when a test
# dot-sources it (`. tools\flash-test-build.ps1`) to reach the functions
# above without triggering gh/wsl/Imager calls or the confirmation prompt.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-FlashTestBuild -Branch $Branch -RunId $RunId -Dest $Dest -DryRun:$DryRun `
        -RepoRoot (Split-Path -Parent $PSScriptRoot) -Repo $Repo
}
