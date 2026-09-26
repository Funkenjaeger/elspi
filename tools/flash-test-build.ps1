# Flash an UNRELEASED CI build of the elspi image -- one command, nothing
# published.
#
#   tools\flash-test-build.ps1 -Branch feat/first-boot-ui
#   tools\flash-test-build.ps1 -RunId 36244494844
#   tools\flash-test-build.ps1 -Branch arm64 -Dest D:\cards\test-builds
#   tools\flash-test-build.ps1 -Branch feat/first-boot-ui -DryRun
#
#   # Same thing from a Forgejo instance's CI instead of GitHub's (see FORGEJO
#   # SOURCE below). Nothing about the instance is hard-coded in this file:
#   $env:ELSPI_FORGEJO_URL     = 'https://forgejo.example'
#   $env:ELSPI_FORGEJO_REPO    = 'owner/repo'
#   $env:ELSPI_FORGEJO_PACKAGE = 'pkgowner/pkgname'
#   tools\flash-test-build.ps1 -Source forgejo -Branch arm64
#   tools\flash-test-build.ps1 -Source forgejo -RunId 42
#   tools\flash-test-build.ps1 -Source forgejo -Sha <40-hex commit sha> -DryRun
#
# WHAT THIS IS FOR, AND WHAT IT ISN'T
#
# .github/workflows/image.yml's build job runs on every workflow_dispatch and
# keeps its image as a 14-day workflow artifact -- it publishes nothing. This
# script is the one-command version of pulling that artifact down and flashing
# it, replacing three manual steps:
#
#   1. gh api repos/Funkenjaeger/elspi/actions/artifacts/<artifact-id>/zip \
#        > <cache>/elspi-image-<sha>.zip
#   2. git show <head-sha>:tools/make-os-list.sh > <cache>/make-os-list.sh
#      wsl bash -lc "<cache>/make-os-list.sh <img> --url file://<img> \
#        --out <cache>/os_list.json"
#   3. tools\flash-elspi.ps1 <cache>\os_list.json
#
# It never tags, never creates a release, and never uploads anything -- the
# artifact is downloaded and the JSON built entirely from local files. A
# RELEASED card still comes from docs/flashing.md's
# `--repo .../releases/latest/download/os_list.json`, which this script does
# not touch.
#
# WHY THE ZIP ITSELF, NOT `gh run download`
#
# `gh run download` writes the EXTRACTED files, not the archive -- and the
# artifact API's `size_in_bytes` (and `digest`) describe the ZIP, not the sum
# of what comes out of it. Comparing extracted bytes against the zip's
# reported size is off by the archive's own overhead (a few hundred bytes for
# this image), so that comparison can never actually match and a complete,
# correct download is permanently refused as incomplete. Fetching
# `.../artifacts/<id>/zip` (the same bytes `gh run download` would unpack)
# lets the downloaded file be checked byte-for-byte against `size_in_bytes`,
# and hashed against `digest` (`sha256:<hex>`, when the API provides one),
# BEFORE anything is extracted or cached as complete.
#
# WHY A PER-RUN CACHE DIRECTORY
#
# The artifact is ~1 GB. Re-running this against the same run (to re-flash a
# second card, or after a failed flash) should not re-download it, so a
# completed download is kept under <Dest>\<run-id>\ -- the verified zip AND
# what it extracts to -- next to a small `.artifact-info.json` marker
# recording the artifact's size and content digest as GitHub's API reports
# them. The next run compares against that API response (a few hundred
# bytes, not the artifact) before deciding to reuse or re-fetch -- see
# Test-CachedArtifact below.
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
# WHY THE BUILD'S OWN make-os-list.sh, NOT THIS CHECKOUT'S
#
# make-os-list.sh differs per branch -- it hardcodes the image's Imager
# device tags and description (arm64 vs armhf), because that is exactly what
# it exists to describe. Running THIS checkout's copy against an artifact
# built from a different branch/commit silently mislabels the image (a 64-bit
# arm64 build tagged with armhf's 32-bit device list, or vice versa) with no
# error at all -- the script runs fine, it is just describing the wrong
# image. Get-MakeOsListScriptForCommit reads tools/make-os-list.sh out of the
# artifact's own head_sha via `git show`, so the script used always matches
# the image being described, regardless of which branch this checkout is on.
#
# FORGEJO SOURCE (-Source forgejo)
#
# A Forgejo instance can run the same image.yml against a snapshot of this
# repo. Forgejo (v15) has no workflow-artifact API, so that workflow uploads
# the image to the instance's GENERIC PACKAGE REGISTRY instead, one package
# version per full commit sha:
#
#   {url}/api/packages/{pkgowner}/generic/{pkgname}/{sha}/image_*.img.xz
#
# (plus the *.info and build.log beside it). The flow mirrors the GitHub one,
# gate for gate:
#
#   run    -Branch: GET {url}/api/v1/repos/{repo}/actions/runs?ref=refs/heads/
#          <branch>&workflow_id=image.yml&status=success -- and the result is
#          filtered AGAIN here (status, workflow_id, newest `created` wins), so
#          a server that ignored a query filter still cannot hand back a failed
#          run. -RunId reads that one run; -Sha skips the run lookup entirely.
#   commit the sha must exist in THIS checkout (git cat-file, fetching origin
#          once if not) BEFORE anything is downloaded, because make-os-list.sh
#          comes from `git show <sha>:...` exactly as for GitHub -- the Forgejo
#          repo is a snapshot of this one, so its commits are this repo's.
#   files  GET {url}/api/v1/packages/{pkgowner}/generic/{pkgname}/{sha}/files
#          lists every file of that package version with its size and sha256.
#          Exactly one image_*.img.xz must be there, with a 64-hex sha256.
#   verify the download (an uncompressed .img.xz, not a zip) goes to
#          <name>.partial, is checked for size AND sha256 against that listing,
#          and only then is renamed into place and given its
#          .forgejo-package-info.json marker. A failed check deletes the
#          .partial: nothing unverified is ever left looking cached.
#   cache  <Dest>\forgejo-<sha>\ -- keyed by commit, since that is what the
#          package version is keyed by; separate from GitHub's <Dest>\<run-id>\.
#
# AUTH. Every Forgejo call sends `Authorization: token <t>` as a request
# header, never in a URL and never on a command line. The token is read at
# run time from -ForgejoTokenFile (default %LOCALAPPDATA%\elspi\forgejo-token)
# and never printed. Mint one in the Forgejo web UI: Settings > Applications >
# Generate New Token, scopes read:package and read:repository, and save just
# the token to that file.
#
# CONFIG. -ForgejoUrl / -ForgejoRepo / -ForgejoPackage default to
# $env:ELSPI_FORGEJO_URL / $env:ELSPI_FORGEJO_REPO / $env:ELSPI_FORGEJO_PACKAGE.
# They are parameters rather than constants because this repository is
# public and the instance is not.
#
# TESTING
#
#   pwsh tests\test-flash-test-build.ps1
#
# dot-sources this file (which only defines functions and does not run
# Main -- see the guard at the bottom) and exercises Resolve-TestBuildRun,
# ConvertTo-WslPath, Test-CachedArtifact, Confirm-DownloadedZip,
# Get-MakeOsListScriptForCommit and Assert-CommandAvailable directly, with
# gh/git calls replaced by fake functions of the same name (Invoke-GhDownloadZip
# included -- see its own comment). No network, no download, no Imager launch.
# The Forgejo side is faked the same way, through Invoke-ForgejoApi and
# Invoke-ForgejoDownload, the only two functions that touch the network.

[CmdletBinding()]
param(
    # Branch to search for the newest successful image.yml run. Ignored if
    # -RunId (or, for Forgejo, -Sha) is given.
    [string] $Branch,

    # A specific run id -- bypasses the branch search entirely, including the
    # "must have succeeded" filter (you asked for this run by number; a
    # warning is printed if it did not succeed, but the run is still used).
    # A GitHub run id, or a Forgejo one with -Source forgejo.
    [string] $RunId,

    # Where the build comes from: GitHub Actions artifacts (the default, and
    # the only source before Forgejo was added) or a Forgejo instance's
    # generic package registry. See FORGEJO SOURCE in the header.
    [ValidateSet('github', 'forgejo')]
    [string] $Source = 'github',

    # Forgejo only: a full 40-hex commit sha -- the package version to flash,
    # with no run lookup at all.
    [string] $Sha,

    # Forgejo only: base URL, e.g. https://forgejo.example (no trailing /api).
    [string] $ForgejoUrl = $env:ELSPI_FORGEJO_URL,

    # Forgejo only: owner/repo whose image.yml runs are searched.
    [string] $ForgejoRepo = $env:ELSPI_FORGEJO_REPO,

    # Forgejo only: pkgowner/pkgname of the generic package the workflow
    # uploads the image to.
    [string] $ForgejoPackage = $env:ELSPI_FORGEJO_PACKAGE,

    # Forgejo only: file holding an access token (read:package +
    # read:repository). Read at run time, never printed.
    [string] $ForgejoTokenFile = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'elspi\forgejo-token' } else { '' }),

    # Base cache directory. The actual download goes to $Dest\<run-id>\. Fixed
    # per Evan's approval of this tool's design -- override with -Dest for a
    # one-off elsewhere.
    [string] $Dest = 'C:\projects\claude-working\elspi-test-builds',

    # Do everything up to and including the y/N confirmation prompt's
    # decision point, then print what each remaining step WOULD do (download,
    # make-os-list.sh, Imager) instead of doing it. No network cost beyond the
    # small `gh run list`/`gh run view`/`gh api .../artifacts` calls needed to
    # resolve the run and check the cache.
    [switch] $DryRun,

    # Do everything -- download, verify, extract, build os_list.json -- except
    # the final Imager launch. For exercising the real download/verify path
    # end to end (including against a real ~1 GB artifact) without a GUI to
    # click through, e.g. in a test run with no display attached.
    [switch] $NoLaunch
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

# Same trick as Invoke-Gh, for `git` -- a test can redefine `git` (or
# Invoke-Git directly) as a fake function.
function Invoke-Git {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Arguments)
    $out = & git @Arguments 2>&1
    [PSCustomObject]@{ Output = $out; ExitCode = $LASTEXITCODE }
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

# Writes the content $RepoPath had AT THE BUILD'S OWN COMMIT to $OutFile --
# never $RepoRoot's checked-out copy. `git show <sha>:<path>` always reads
# the exact commit the artifact was built from, regardless of what branch
# this checkout itself happens to be on.
#
# Falls back to fetching the commit from origin when it is not present
# locally (a shallow checkout, or a checkout that hasn't fetched the
# artifact's branch), and fails loudly -- never silently falls back to the
# checkout's own copy -- if the commit still cannot be obtained.
function Get-CommitFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $OutFile
    )
    $blobSpec = "${Sha}:${RepoPath}"
    $result = Invoke-Git '-C' $RepoRoot 'show' $blobSpec
    if ($result.ExitCode -ne 0) {
        Write-Host "commit $Sha not found locally -- fetching from origin ..."
        $fetch = Invoke-Git '-C' $RepoRoot 'fetch' 'origin' $Sha
        if ($fetch.ExitCode -ne 0) {
            throw "[make-os-list] commit $Sha's $RepoPath is not available locally, and fetching it from origin failed (exit $($fetch.ExitCode)): $($fetch.Output -join "`n")"
        }
        $result = Invoke-Git '-C' $RepoRoot 'show' $blobSpec
        if ($result.ExitCode -ne 0) {
            throw "[make-os-list] fetched commit $Sha but 'git show $blobSpec' still failed (exit $($result.ExitCode)): $($result.Output -join "`n") -- refusing to fall back to the checkout's own $RepoPath, which may be for a different branch"
        }
    }
    (($result.Output -join "`n") + "`n") | Set-Content -LiteralPath $OutFile -NoNewline -Encoding utf8
}

# make-os-list.sh AND its sibling os_list.imager-block.json, both as they
# existed at the BUILD's own commit, written into $OutDir side by side.
# make-os-list.sh differs per branch (device tags, description -- e.g.
# arm64's db380b6 writes the 64-bit Imager tags pi5-64bit/pi4-64bit/pi3-64bit
# and an arm64 description, while master's writes armhf's 32-bit tags), so
# running the checkout's copy against an artifact built on a DIFFERENT
# branch/sha mislabels the image. The block file has to come from the same
# commit and land in the SAME directory: make-os-list.sh looks it up next to
# itself (its own HERE/BLOCK logic), so a script fetched from the artifact's
# commit paired with this checkout's block file (or vice versa) would be
# reading a mismatched pair even though each half, alone, looks fine.
function Get-MakeOsListScriptForCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [string] $OutDir
    )
    Get-CommitFile -RepoRoot $RepoRoot -Sha $Sha -RepoPath 'tools/make-os-list.sh' `
        -OutFile (Join-Path $OutDir 'make-os-list.sh')
    Get-CommitFile -RepoRoot $RepoRoot -Sha $Sha -RepoPath 'tools/os_list.imager-block.json' `
        -OutFile (Join-Path $OutDir 'os_list.imager-block.json')
}

# Downloads the artifact ZIP itself -- the exact bytes `size_in_bytes` and
# `digest` describe -- to $OutFile. Deliberately NOT routed through
# Invoke-Gh/Invoke-GhJson: those capture output with `2>&1` into a PowerShell
# string array, which is fine for a JSON response but would try to decode a
# >1 GB binary payload as text. `> $OutFile` redirects gh's own stdout stream
# straight to disk instead. A test can still fake this the same way the rest
# of the file fakes `gh` -- by redefining Invoke-GhDownloadZip itself (see
# this file's own header comment on Invoke-Gh).
function Invoke-GhDownloadZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ArtifactId,
        [Parameter(Mandatory)] [string] $OutFile,
        [string] $Repo = $script:Repo
    )
    & gh api "repos/$Repo/actions/artifacts/$ArtifactId/zip" > $OutFile
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue
        throw "[gh api] downloading artifact zip (id $ArtifactId) failed (exit $LASTEXITCODE)"
    }
}

# Verifies a downloaded artifact zip against the API's own metadata for it --
# byte size always, sha256 digest whenever the API provided one in the
# `sha256:<hex>` form. Throws (refusing to cache) on any mismatch. This is
# the check that was missing: c0f3b85 compared EXTRACTED file sizes against
# `size_in_bytes`, which describes the zip, not what comes out of it -- a
# comparison that is off by the archive's own overhead and can never pass.
function Confirm-DownloadedZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] $ArtifactInfo
    )
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "[gh api] artifact zip not found at $ZipPath after download"
    }
    $actualSize = (Get-Item -LiteralPath $ZipPath).Length
    if ($actualSize -ne $ArtifactInfo.size_in_bytes) {
        throw "[gh api] downloaded zip is $actualSize bytes under $ZipPath but the artifact API reported $($ArtifactInfo.size_in_bytes) -- not caching this as complete"
    }

    if ($ArtifactInfo.digest -and ($ArtifactInfo.digest -match '^sha256:(?<hash>[0-9a-fA-F]{64})$')) {
        $expected = $Matches['hash'].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "[gh api] downloaded zip sha256 $actual does not match the artifact API's digest sha256:$expected -- not caching this as complete"
        }
        Write-Host "verified: $actualSize bytes, sha256:$actual matches the artifact API."
    } elseif ($ArtifactInfo.digest) {
        Write-Warning "artifact digest '$($ArtifactInfo.digest)' is not in the expected 'sha256:<64 hex chars>' form -- verifying size only ($actualSize bytes)."
    } else {
        Write-Warning "the artifact API reported no digest for this artifact -- verifying size only ($actualSize bytes)."
    }
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
# Forgejo source -- see FORGEJO SOURCE in the header. Invoke-ForgejoApi and
# Invoke-ForgejoDownload are the only functions here that touch the network;
# a test redefines them, the same way it redefines `gh` and `git`.
# =============================================================================

$ForgejoWorkflow = 'image.yml'

function Invoke-ForgejoApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Headers
    )
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -UseBasicParsing -ErrorAction Stop
    } catch {
        # The message names the URL (which never carries the token) and the
        # HTTP status; it never includes the request headers.
        $status = $null
        if ($_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
        throw "[forgejo] GET $Uri failed$(if ($status) { " (HTTP $status)" }): $($_.Exception.Message)"
    }
}

# Streams the response body straight to $OutFile (Invoke-WebRequest -OutFile
# does not buffer the ~1 GB body in memory). Progress is silenced: on Windows
# PowerShell 5.1 the progress bar alone slows a download like this by an
# order of magnitude.
function Invoke-ForgejoDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $OutFile
    )
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "[forgejo] downloading $Uri failed: $($_.Exception.Message)"
    }
}

# Checks the Forgejo settings are present and shaped right, and returns the
# base URL without a trailing slash. Names the parameter AND the environment
# variable for anything missing.
function Assert-ForgejoConfig {
    param([string] $Url, [string] $Repo, [string] $Package)
    if (-not $Url) {
        throw "[forgejo config] no Forgejo URL -- pass -ForgejoUrl https://forgejo.example or set `$env:ELSPI_FORGEJO_URL"
    }
    if ($Url -notmatch '^https?://[^/\s?#]+(/[^\s?#]*)?$') {
        throw "[forgejo config] -ForgejoUrl '$Url' is not an http(s) base URL like https://forgejo.example"
    }
    if ($Url -match '^http://') {
        Write-Warning "-ForgejoUrl is plain http: the access token will cross the network unencrypted."
    }
    if ($Repo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
        throw "[forgejo config] -ForgejoRepo '$Repo' is not owner/repo -- pass -ForgejoRepo owner/repo or set `$env:ELSPI_FORGEJO_REPO"
    }
    if ($Package -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._+-]+$') {
        throw "[forgejo config] -ForgejoPackage '$Package' is not pkgowner/pkgname -- pass -ForgejoPackage pkgowner/pkgname or set `$env:ELSPI_FORGEJO_PACKAGE"
    }
    return $Url.TrimEnd('/')
}

# Reads the token file and returns the request headers. The token goes into
# the header value and nowhere else; no message here ever includes it.
function Get-ForgejoAuthHeader {
    param([string] $TokenFile)
    $mint = "Mint one in the Forgejo web UI: Settings > Applications > Generate New Token, with scopes read:package and read:repository, and save just the token to that file (or pass -ForgejoTokenFile <path>)."
    if (-not $TokenFile -or -not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
        throw "[forgejo auth] no token file at '$TokenFile'. $mint"
    }
    $token = (Get-Content -LiteralPath $TokenFile -Raw -ErrorAction Stop)
    if ($null -ne $token) { $token = $token.Trim() }
    if (-not $token) {
        throw "[forgejo auth] token file '$TokenFile' is empty. $mint"
    }
    if ($token -match '\s') {
        throw "[forgejo auth] token file '$TokenFile' holds more than one word -- it must contain only the token. $mint"
    }
    return @{ Authorization = "token $token"; Accept = 'application/json' }
}

function Get-ForgejoRunsUri {
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Branch)
    $ref = [uri]::EscapeDataString("refs/heads/$Branch")
    return "$BaseUrl/api/v1/repos/$Repo/actions/runs?ref=$ref&workflow_id=$script:ForgejoWorkflow&status=success&limit=20"
}

function Get-ForgejoPackageFilesUri {
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $Package, [Parameter(Mandatory)] [string] $Sha)
    $owner, $name = $Package -split '/', 2
    return "$BaseUrl/api/v1/packages/$([uri]::EscapeDataString($owner))/generic/$([uri]::EscapeDataString($name))/$Sha/files"
}

function Get-ForgejoPackageFileUri {
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $Package, [Parameter(Mandatory)] [string] $Sha, [Parameter(Mandatory)] [string] $FileName)
    $owner, $name = $Package -split '/', 2
    return "$BaseUrl/api/packages/$([uri]::EscapeDataString($owner))/generic/$([uri]::EscapeDataString($name))/$Sha/$([uri]::EscapeDataString($FileName))"
}

# Resolve which build to use, as an object with .sha, .run_id, .ref, .created.
#   -Sha given    -> that commit, no API call (the package version IS the sha).
#   -RunId given  -> that run (must be an image.yml run; a warning, not an
#                    error, if it did not succeed -- same as GitHub's -RunId).
#   -Branch given -> newest successful image.yml run on refs/heads/<branch>.
#                    The query asks the server to filter, and the answer is
#                    filtered again here, so a failed or running run is never
#                    picked even if the server ignored a filter.
function Resolve-ForgejoBuild {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [string] $Branch,
        [string] $RunId,
        [string] $Sha
    )
    if ($Sha) {
        if ($Sha -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Resolve-ForgejoBuild: -Sha '$Sha' is not a full 40-hex commit sha (the package version is the FULL sha)"
        }
        return [PSCustomObject]@{ sha = $Sha.ToLowerInvariant(); run_id = $null; ref = '(explicit -Sha)'; created = $null }
    }

    if ($RunId) {
        if ($RunId -notmatch '^[0-9]+$') { throw "Resolve-ForgejoBuild: -RunId '$RunId' is not a number" }
        $run = Invoke-ForgejoApi -Uri "$BaseUrl/api/v1/repos/$Repo/actions/runs/$RunId" -Headers $Headers
        if ($run.workflow_id -ne $script:ForgejoWorkflow) {
            throw "Resolve-ForgejoBuild: run $RunId is a '$($run.workflow_id)' run, not '$script:ForgejoWorkflow'"
        }
        if ($run.status -ne 'success') {
            Write-Warning "run $RunId did not succeed (status: $($run.status)) -- using it anyway, you asked for it by id"
        }
    } else {
        if (-not $Branch) { throw "Resolve-ForgejoBuild: pass -Branch <name>, -RunId <id> or -Sha <sha>" }
        $resp = Invoke-ForgejoApi -Uri (Get-ForgejoRunsUri -BaseUrl $BaseUrl -Repo $Repo -Branch $Branch) -Headers $Headers
        $runs = @($resp.workflow_runs | Where-Object { $_ })
        $successful = @($runs | Where-Object { $_.status -eq 'success' -and $_.workflow_id -eq $script:ForgejoWorkflow })
        if ($successful.Count -eq 0) {
            throw "Resolve-ForgejoBuild: no successful $script:ForgejoWorkflow run found on branch '$Branch' (the API returned $($runs.Count) run(s))"
        }
        $run = $successful | Sort-Object -Property { [datetime] $_.created }, { [int64] $_.id } -Descending | Select-Object -First 1
    }

    if ("$($run.commit_sha)" -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Resolve-ForgejoBuild: run $($run.id) has no usable commit_sha ('$($run.commit_sha)')"
    }
    return [PSCustomObject]@{ sha = "$($run.commit_sha)".ToLowerInvariant(); run_id = $run.id; ref = $run.prettyref; created = $run.created }
}

# The sha must be a commit THIS checkout has, because make-os-list.sh is read
# from it with `git show` (see WHY THE BUILD'S OWN make-os-list.sh). Checked
# before the download, so a sha that cannot be described never costs 1 GB.
function Assert-CommitAvailable {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Sha)
    $spec = "${Sha}^{commit}"
    if ((Invoke-Git '-C' $RepoRoot 'cat-file' '-e' $spec).ExitCode -eq 0) { return }
    Write-Host "commit $Sha not found locally -- fetching from origin ..."
    $fetch = Invoke-Git '-C' $RepoRoot 'fetch' 'origin' $Sha
    if ((Invoke-Git '-C' $RepoRoot 'cat-file' '-e' $spec).ExitCode -ne 0) {
        throw "[commit] $Sha is not in this checkout even after 'git fetch origin $Sha' (fetch exit $($fetch.ExitCode)). The Forgejo build must be of a commit this repo has -- its tools/make-os-list.sh describes the image. Refusing to download."
    }
}

# Picks the one image_*.img.xz out of a package version's file list (the
# /files endpoint's PackageFile objects: name, Size, sha256, ...). Throws if
# there is not exactly one, or if it lacks a size or a sha256 to verify the
# download against. The name also becomes a local file name, so anything
# that is not a plain file name is refused.
#
# Note the size key: Forgejo's PackageFile struct has no json tag on Size, so
# the JSON key is "Size" -- PowerShell property access is case-insensitive,
# so .Size reads it either way.
function Select-ForgejoImageFile {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Files, [string] $Sha = '')
    $images = @($Files | Where-Object { $_ -and $_.name -like 'image_*.img.xz' })
    if ($images.Count -eq 0) {
        $names = @($Files | ForEach-Object { $_.name }) -join ', '
        throw "[forgejo package] no image_*.img.xz in package version $Sha (files: $(if ($names) { $names } else { 'none' }))"
    }
    if ($images.Count -gt 1) {
        throw "[forgejo package] $($images.Count) image_*.img.xz files in package version $Sha ($(@($images | ForEach-Object { $_.name }) -join ', ')) -- expected exactly one"
    }
    $f = $images[0]
    if ($f.name -notmatch '^[A-Za-z0-9._+-]+$') {
        throw "[forgejo package] refusing file name '$($f.name)' -- not a plain file name"
    }
    if (-not ($f.Size -as [int64]) -or [int64] $f.Size -le 0) {
        throw "[forgejo package] $($f.name) has no size in the package file list -- cannot verify a download"
    }
    if ("$($f.sha256)" -notmatch '^[0-9a-fA-F]{64}$') {
        throw "[forgejo package] $($f.name) has no sha256 in the package file list -- cannot verify a download"
    }
    return [PSCustomObject]@{ name = $f.name; size = [int64] $f.Size; sha256 = "$($f.sha256)".ToLowerInvariant() }
}

# Verifies a downloaded package file against the package API's own listing:
# byte size, then sha256. Throws on either mismatch.
function Confirm-DownloadedForgejoFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $FileInfo)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "[forgejo download] $Path not found after download"
    }
    $actualSize = (Get-Item -LiteralPath $Path).Length
    if ($actualSize -ne $FileInfo.size) {
        throw "[forgejo download] $Path is $actualSize bytes but the package API lists $($FileInfo.size) for $($FileInfo.name) -- not caching this as complete"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $FileInfo.sha256) {
        throw "[forgejo download] $Path sha256 $actual does not match the package API's sha256 $($FileInfo.sha256) -- not caching this as complete"
    }
    Write-Host "verified: $actualSize bytes, sha256:$actual matches the package API."
}

# True if $CacheDir holds a verified download of exactly $FileInfo for $Sha:
# the marker written after verification agrees with the API's listing, and
# the image file is present at the recorded size. Never re-hashes 1 GB.
function Test-CachedForgejoImage {
    param([Parameter(Mandatory)] [string] $CacheDir, [Parameter(Mandatory)] $FileInfo, [Parameter(Mandatory)] [string] $Sha)
    $marker = Join-Path $CacheDir '.forgejo-package-info.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    try { $recorded = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { return $false }
    if ($recorded.commit_sha -ne $Sha) { return $false }
    if ($recorded.name -ne $FileInfo.name) { return $false }
    if ([int64] $recorded.size -ne $FileInfo.size) { return $false }
    if ($recorded.sha256 -ne $FileInfo.sha256) { return $false }
    $img = Join-Path $CacheDir $FileInfo.name
    if (-not (Test-Path -LiteralPath $img -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $img).Length -ne $FileInfo.size) { return $false }
    return $true
}

# =============================================================================
# Shared tail: build os_list.json with the build's own make-os-list.sh, then
# hand it to Imager. Used by both sources.
# =============================================================================

function Write-DryRunTail {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CacheDir,
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [string] $ImagePath
    )
    $osList = "$CacheDir\os_list.json"
    $makeOsList = "$CacheDir\make-os-list.sh"
    $wslScript = ConvertTo-WslPath $makeOsList
    $wslImg = ConvertTo-WslPath $ImagePath
    $wslOut = ConvertTo-WslPath $osList
    $fileUrl = "file:///" + ($ImagePath -replace '\\', '/')
    Write-Host "would run: git -C `"$RepoRoot`" show ${Sha}:tools/make-os-list.sh > `"$makeOsList`"  (the BUILD's own copy, not this checkout's)"
    Write-Host "would run: git -C `"$RepoRoot`" show ${Sha}:tools/os_list.imager-block.json > `"$CacheDir\os_list.imager-block.json`"  (its sibling, same commit)"
    Write-Host "would run: wsl bash -lc `"'$wslScript' '$wslImg' --url '$fileUrl' --out '$wslOut'`""
    Write-Host "  (Windows path -> WSL path: $ImagePath -> $wslImg)"
    Write-Host "would run: tools\flash-elspi.ps1 `"$osList`""
}

function Invoke-OsListAndFlash {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CacheDir,
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [string] $ImagePath,
        [switch] $NoLaunch
    )
    $osListPath = Join-Path $CacheDir 'os_list.json'
    $fileUrl = "file:///" + ($ImagePath -replace '\\', '/')
    $makeOsListPath = Join-Path $CacheDir 'make-os-list.sh'
    Get-MakeOsListScriptForCommit -RepoRoot $RepoRoot -Sha $Sha -OutDir $CacheDir
    $wslScript = ConvertTo-WslPath $makeOsListPath
    $wslImg = ConvertTo-WslPath $ImagePath
    $wslOut = ConvertTo-WslPath $osListPath

    Write-Host ""
    Write-Host "building os_list.json (using tools/make-os-list.sh from commit $Sha, not this checkout) ..."
    $bashCmd = "'$wslScript' '$wslImg' --url '$fileUrl' --out '$wslOut'"
    & wsl bash -lc $bashCmd
    if ($LASTEXITCODE -ne 0) { throw "[make-os-list.sh] failed (exit $LASTEXITCODE)" }

    Write-Host ""
    if ($NoLaunch) {
        Write-Host "-NoLaunch: skipping Imager. os_list.json is ready at $osListPath"
        return
    }
    Write-Host "launching Imager ..."
    & (Join-Path $RepoRoot 'tools\flash-elspi.ps1') $osListPath
    if ($LASTEXITCODE -ne 0) { throw "[flash-elspi.ps1] failed (exit $LASTEXITCODE)" }
}

# =============================================================================
# Main
# =============================================================================

function Invoke-FlashTestBuildForgejo {
    [CmdletBinding()]
    param(
        [string] $Branch,
        [string] $RunId,
        [string] $Sha,
        [Parameter(Mandatory)] [string] $Dest,
        [switch] $DryRun,
        [switch] $NoLaunch,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $ForgejoUrl,
        [string] $ForgejoRepo,
        [string] $ForgejoPackage,
        [string] $ForgejoTokenFile
    )
    if (-not $Branch -and -not $RunId -and -not $Sha) {
        throw "flash-test-build: pass -Branch <name>, -RunId <id> or -Sha <sha>"
    }

    Write-Host "== preflight (forgejo) =="
    $base = Assert-ForgejoConfig -Url $ForgejoUrl -Repo $ForgejoRepo -Package $ForgejoPackage
    $headers = Get-ForgejoAuthHeader -TokenFile $ForgejoTokenFile
    Assert-WslAvailable
    Assert-ImagerReady -RepoRoot $RepoRoot
    Write-Host "Forgejo settings, token file, wsl and Imager 2.x are all present."
    Write-Host ""

    Write-Host "== resolving build =="
    if (-not $Sha -and -not $RunId) {
        Write-Host ("runs:     GET {0}" -f (Get-ForgejoRunsUri -BaseUrl $base -Repo $ForgejoRepo -Branch $Branch))
    }
    $build = Resolve-ForgejoBuild -BaseUrl $base -Repo $ForgejoRepo -Headers $headers -Branch $Branch -RunId $RunId -Sha $Sha
    $sha = $build.sha
    Write-Host ("ref:      {0}" -f $build.ref)
    Write-Host ("sha:      {0}" -f $sha)
    Write-Host ("run id:   {0}" -f $(if ($build.run_id) { $build.run_id } else { '(none)' }))
    Write-Host ("date:     {0}" -f $build.created)
    Assert-CommitAvailable -RepoRoot $RepoRoot -Sha $sha

    $filesUri = Get-ForgejoPackageFilesUri -BaseUrl $base -Package $ForgejoPackage -Sha $sha
    Write-Host ("files:    GET {0}" -f $filesUri)
    $fileInfo = Select-ForgejoImageFile -Files @(Invoke-ForgejoApi -Uri $filesUri -Headers $headers) -Sha $sha
    $downloadUri = Get-ForgejoPackageFileUri -BaseUrl $base -Package $ForgejoPackage -Sha $sha -FileName $fileInfo.name
    Write-Host ("image:    {0} ({1} bytes, sha256 {2})" -f $fileInfo.name, $fileInfo.size, $fileInfo.sha256)
    Write-Host ("download: GET {0}" -f $downloadUri)
    Write-Host ""

    $cacheDir = Join-Path $Dest "forgejo-$sha"
    $imgPath = Join-Path $cacheDir $fileInfo.name
    $sizeMb = [math]::Round($fileInfo.size / 1MB)
    $reuse = Test-CachedForgejoImage -CacheDir $cacheDir -FileInfo $fileInfo -Sha $sha
    if ($reuse) {
        Write-Host "cache:    reusing $cacheDir (already downloaded, ~$sizeMb MB, verified by size+sha256 against the package API)"
    } else {
        Write-Host "cache:    $cacheDir (not cached yet -- would download ~$sizeMb MB)"
    }
    Write-Host ""

    if ($DryRun) {
        Write-Host "== DRY RUN: stopping before the download and the Imager launch =="
        if ($reuse) {
            Write-Host "would reuse the cached image above; no download"
        } else {
            Write-Host "would download: $downloadUri -> `"$imgPath.partial`", verify size+sha256, then rename to `"$imgPath`""
        }
        Write-DryRunTail -RepoRoot $RepoRoot -CacheDir $cacheDir -Sha $sha -ImagePath $imgPath
        return
    }

    if (-not $reuse) {
        $answer = Read-Host "Download ~$sizeMb MB of $($fileInfo.name) ($($build.ref) @ $sha)? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted -- nothing downloaded."
            return
        }
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $marker = Join-Path $cacheDir '.forgejo-package-info.json'
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $partial = "$imgPath.partial"
        Write-Host "downloading $($fileInfo.name) to $partial ..."
        try {
            Invoke-ForgejoDownload -Uri $downloadUri -Headers $headers -OutFile $partial
            Confirm-DownloadedForgejoFile -Path $partial -FileInfo $fileInfo
        } catch {
            Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue
            throw
        }
        Move-Item -LiteralPath $partial -Destination $imgPath -Force
        [PSCustomObject]@{
            name       = $fileInfo.name
            size       = $fileInfo.size
            sha256     = $fileInfo.sha256
            commit_sha = $sha
            run_id     = $build.run_id
        } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
        Write-Host "downloaded and verified."
    }

    Invoke-OsListAndFlash -RepoRoot $RepoRoot -CacheDir $cacheDir -Sha $sha -ImagePath $imgPath -NoLaunch:$NoLaunch
}

function Invoke-FlashTestBuild {
    [CmdletBinding()]
    param(
        [string] $Branch,
        [string] $RunId,
        [Parameter(Mandatory)] [string] $Dest,
        [switch] $DryRun,
        [switch] $NoLaunch,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Repo = $script:Repo,
        [ValidateSet('github', 'forgejo')] [string] $Source = 'github',
        [string] $Sha,
        [string] $ForgejoUrl,
        [string] $ForgejoRepo,
        [string] $ForgejoPackage,
        [string] $ForgejoTokenFile
    )

    if ($Source -eq 'forgejo') {
        Invoke-FlashTestBuildForgejo -Branch $Branch -RunId $RunId -Sha $Sha -Dest $Dest `
            -DryRun:$DryRun -NoLaunch:$NoLaunch -RepoRoot $RepoRoot `
            -ForgejoUrl $ForgejoUrl -ForgejoRepo $ForgejoRepo -ForgejoPackage $ForgejoPackage `
            -ForgejoTokenFile $ForgejoTokenFile
        return
    }
    if ($Sha) {
        throw "flash-test-build: -Sha is for -Source forgejo only; for GitHub pass -Branch <name> or -RunId <id>"
    }

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
            Write-Host "would run: gh api repos/$Repo/actions/artifacts/$($artifactInfo.id)/zip > `"$cacheDir\$artifactName.zip`""
        }
        Write-DryRunTail -RepoRoot $RepoRoot -CacheDir $cacheDir -Sha $sha -ImagePath "$cacheDir\<image>.img.xz"
        return
    }

    if (-not $reuse) {
        $answer = Read-Host "Download ~$sizeMb MB from run $($run.databaseId) ($($run.headBranch) @ $sha)? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted -- nothing downloaded."
            return
        }
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $zipPath = Join-Path $cacheDir "$artifactName.zip"
        Write-Host "downloading $artifactName to $zipPath ..."
        Invoke-GhDownloadZip -ArtifactId "$($artifactInfo.id)" -OutFile $zipPath -Repo $Repo
        Confirm-DownloadedZip -ZipPath $zipPath -ArtifactInfo $artifactInfo

        Write-Host "extracting $zipPath ..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $cacheDir -Force

        [PSCustomObject]@{
            name          = $artifactName
            size_in_bytes = $artifactInfo.size_in_bytes
            digest        = $artifactInfo.digest
            run_id        = $run.databaseId
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cacheDir '.artifact-info.json') -Encoding utf8
        Write-Host "downloaded, verified and extracted."
    }

    $img = Get-ChildItem -LiteralPath $cacheDir -Filter '*.img.xz' -Recurse | Select-Object -First 1
    if (-not $img) { throw "[make-os-list] no *.img.xz found under $cacheDir" }

    Invoke-OsListAndFlash -RepoRoot $RepoRoot -CacheDir $cacheDir -Sha $sha -ImagePath $img.FullName -NoLaunch:$NoLaunch
}

# Run Main only when this file is executed directly -- not when a test
# dot-sources it (`. tools\flash-test-build.ps1`) to reach the functions
# above without triggering gh/wsl/Imager calls or the confirmation prompt.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-FlashTestBuild -Branch $Branch -RunId $RunId -Dest $Dest -DryRun:$DryRun -NoLaunch:$NoLaunch `
        -RepoRoot (Split-Path -Parent $PSScriptRoot) -Repo $Repo `
        -Source $Source -Sha $Sha -ForgejoUrl $ForgejoUrl -ForgejoRepo $ForgejoRepo `
        -ForgejoPackage $ForgejoPackage -ForgejoTokenFile $ForgejoTokenFile
}
