# Publish a BENCH-TESTED build of the elspi image as a GitHub release --
# the exact bytes that were flashed, never a rebuild.
#
#   tools\promote-release.ps1 -RunId 36268741724 -DryRun
#   tools\promote-release.ps1 -RunId 36268741724
#   tools\promote-release.ps1 -CacheDir D:\cards\test-builds\36268741724
#   tools\promote-release.ps1 -Sha <40-hex commit sha>          # a Forgejo build
#   tools\promote-release.ps1 -RunId 36268741724 -Tag v2026.09.26.1
#   tools\promote-release.ps1 -RunId 36268741724 -Prerelease
#
# THE FLOW THIS IS THE LAST STEP OF (2026-09-26, decision D4)
#
#   1. build     gh workflow run image --ref arm64      (a test build, xz -1)
#   2. flash     tools\flash-test-build.ps1 -Branch arm64
#                (downloads, verifies and caches the build under
#                 <Dest>\<run-id>\ or <Dest>\forgejo-<sha>\, then flashes it)
#   3. bench     the card is tested on the real machine
#   4. promote   THIS script, on that same cache directory
#
# Until 2026-09-26 a pushed v-tag made .github/workflows/image.yml build the
# image AGAIN and publish that second build. The bytes released were never the
# bytes tested (and the reflex release a build bakes can move between two
# builds). image.yml no longer reacts to tags at all; this script creates the
# tag, pointing at the build's own commit, as part of publishing the release.
#
# WHAT IS VERIFIED BEFORE ANYTHING IS SENT -- any failure stops everything
#
#   [zip digest]      GitHub cache: the artifact zip's size and sha256 against
#                     .artifact-info.json (which recorded GitHub's own digest
#                     when flash-test-build downloaded it).
#   [zip contents]    the extracted image_*.img.xz and *.info -- the files that
#                     get uploaded -- are byte-identical to the entries in that
#                     zip: sha256 of each entry's stream against sha256 of the
#                     file on disk, no temp copy. (A central-directory CRC-32
#                     compare would be cheaper, but CRC-32 is not a digest; the
#                     zip is the thing GitHub vouched for, so the uploaded files
#                     are tied to it with the same hash GitHub used.)
#   [forgejo digest]  Forgejo cache: the image's size and sha256 against
#                     .forgejo-package-info.json, and that marker against the
#                     registry's live listing. The .info is fetched from the
#                     same package version if flash-test-build did not keep it,
#                     and checked against the listing's sha256. A Forgejo
#                     build's package is keyed by a SNAPSHOT commit that is not
#                     in elspi; the marker must also carry `elspi_sha`, which
#                     must equal the package's elspi-commit.txt, and every
#                     elspi-side step below uses that commit (see
#                     Read-ForgejoMarker).
#   [xz -t]           the image decompresses cleanly.
#   [build sha]       the marker's commit, the .info's pi-gen commit (line 2)
#                     and, for GitHub, the run's headSha are one commit, and
#                     the run is a successful `image` run.
#   [arch]            the image's architecture is READ FROM THE IMAGE -- the
#                     architecture of the `dpkg` package in the .info's package
#                     list, which is the rootfs's native architecture -- and
#                     must equal the `export ARCH=` line of build.sh at that
#                     commit. A -Tag whose -armhf suffix disagrees is refused.
#   [branch]          the commit is an ancestor of GitHub's arm64 tip (master
#                     for an armhf build), so the release points at the line.
#   [tag]             the tag is free: no such tag on GitHub, and no release
#                     (draft included) using that name.
#   [os_list]         os_list.json is written by tools/make-os-list.sh FROM THAT
#                     COMMIT (git show, as flash-test-build does), with --url
#                     set to this release's own image asset. It is read back:
#                     url, image_download_size/sha256 against the file being
#                     uploaded, 64-bit device tags for arm64 (32-bit for
#                     armhf), and -- when the bench os_list.json flash-test-build
#                     wrote is in the cache dir -- extract_size, extract_sha256
#                     and image_download_sha256 identical to the one the tested
#                     card was flashed from.
#   [asset size]      every asset is under GitHub's 2 GiB per-asset limit.
#
# THE TAG (decision D8): bare CalVer for arm64, `-armhf` suffix for armhf,
# `.N` for a second release of one day -- v2026.09.26, v2026.09.26.1,
# v2026.09.26-armhf. The date is the IMAGE's date (its file name, which is also
# the release_date inside os_list.json), not today's: the tag names the bytes.
# -Tag overrides the pick; it is validated the same way.
#
# PUBLISH MODE. Default: a full release (not a pre-release); arm64 is marked
# --latest, which is what .../releases/latest/download/os_list.json in the docs
# follows. armhf is NEVER latest, whatever else is asked. -Prerelease publishes
# a pre-release that is not latest. The release is created as a DRAFT first,
# its three assets are read back by digest, and only then is it published;
# after publishing, the tag's commit, the assets' digests, releases/latest and
# an anonymous download of os_list.json are all read back again.
#
# NOTHING IS SENT WITHOUT A TYPED CONFIRMATION: the summary shows tag, target
# commit, arch, mode and every asset's name, size and sha256, and the tag must
# be typed back. -DryRun runs every check above (the os_list.json and release
# notes it writes stay in <cache>\promote-<tag>\), prints the exact gh commands,
# and creates nothing on GitHub.
#
# RELEASE NOTES come from tools/release-notes.sh at the build's commit: one
# sentence, the two commands pinned to this tag, and one link to the flashing
# docs at this tag.
#
# NEEDS: gh (authenticated, with write access for a real run), git, and WSL
# (xz, make-os-list.sh and release-notes.sh run there, as for
# flash-test-build.ps1). Functions shared with flash-test-build.ps1 are
# dot-sourced from it rather than copied.
#
# TESTING: pwsh tests\test-promote-release.ps1 (fakes gh, git and wsl; no
# network, nothing published).

#Requires -Version 7.0

[CmdletBinding()]
param(
    # A cache directory flash-test-build.ps1 wrote (<Dest>\<run-id>\ or
    # <Dest>\forgejo-<sha>\).
    [string] $CacheDir,

    # A GitHub run id: the cache directory is <Dest>\<run-id>.
    [string] $RunId,

    # A full commit sha: <Dest>\forgejo-<sha>, else the one GitHub cache
    # directory whose artifact is elspi-image-<sha>.
    [string] $Sha,

    # Override the picked tag (validated: vYYYY.MM.DD[.N][-armhf], suffix
    # matching the image's arch, and not already used).
    [string] $Tag,

    # Publish as a pre-release (never latest) instead of a release.
    [switch] $Prerelease,

    # Verify everything and print the exact gh commands; create nothing.
    [switch] $DryRun,

    # Same default as flash-test-build.ps1's -Dest.
    [string] $Dest = 'C:\projects\claude-working\elspi-test-builds',

    # Forgejo caches only -- same settings and token file as
    # flash-test-build.ps1 -Source forgejo.
    [string] $ForgejoUrl = $env:ELSPI_FORGEJO_URL,
    [string] $ForgejoRepo = $env:ELSPI_FORGEJO_REPO,
    [string] $ForgejoPackage = $env:ELSPI_FORGEJO_PACKAGE,
    [string] $ForgejoTokenFile = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'elspi\forgejo-token' } else { '' })
)

# Captured BEFORE dot-sourcing flash-test-build.ps1: its own param block binds
# its defaults into this scope and would overwrite -RunId, -Sha, -Dest, -DryRun
# and the Forgejo settings of the same names.
$script:PromoteIsDotSourced = ($MyInvocation.InvocationName -eq '.')
$script:PromoteArgs = @{
    CacheDir = $CacheDir; RunId = $RunId; Sha = $Sha; Tag = $Tag
    Prerelease = [bool] $Prerelease; DryRun = [bool] $DryRun; Dest = $Dest
    ForgejoUrl = $ForgejoUrl; ForgejoRepo = $ForgejoRepo
    ForgejoPackage = $ForgejoPackage; ForgejoTokenFile = $ForgejoTokenFile
}

# Invoke-Gh, Invoke-GhJson, Invoke-Git, ConvertTo-WslPath, Get-CommitFile,
# Get-MakeOsListScriptForCommit, Assert-CommitAvailable, the Forgejo helpers
# and $Repo. Its Main does not run when dot-sourced.
. (Join-Path $PSScriptRoot 'flash-test-build.ps1')

$script:GiB2 = 2147483648
$script:TagPattern = '^v(?<y>\d{4})\.(?<m>\d{2})\.(?<d>\d{2})(?<n>\.[1-9]\d{0,2})?(?<armhf>-armhf)?$'

# =============================================================================
# Small helpers. Everything that runs a program goes through a function a test
# can redefine: Invoke-Gh/Invoke-Git (flash-test-build.ps1), Invoke-GhWrite,
# Invoke-XzTest, Invoke-MakeOsList, Invoke-ReleaseNotesScript,
# Invoke-AnonymousGet.
# =============================================================================

function Get-Sha256OfFile {
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Sha256OfZipEntry {
    param([Parameter(Mandatory)] [string] $ZipPath, [Parameter(Mandatory)] [string] $EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = @($zip.Entries | Where-Object { $_.FullName -eq $EntryName })
        if ($entry.Count -ne 1) { throw "[zip contents] $EntryName is in $ZipPath $($entry.Count) times, expected once" }
        $stream = $entry[0].Open()
        try {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            $bytes = $hasher.ComputeHash($stream)
        } finally { $stream.Dispose() }
        return [PSCustomObject]@{ sha256 = (-join ($bytes | ForEach-Object { $_.ToString('x2') })); length = [int64] $entry[0].Length }
    } finally { $zip.Dispose() }
}

function Get-ZipEntryNames {
    param([Parameter(Mandatory)] [string] $ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { return @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
}

# A WSL path safe to put inside single quotes in a bash -lc string.
function ConvertTo-QuotableWslPath {
    param([Parameter(Mandatory)] [string] $Path)
    $w = ConvertTo-WslPath $Path
    if ($w.Contains("'")) { throw "path '$Path' contains a single quote; move the cache somewhere without one" }
    return $w
}

function Invoke-XzTest {
    param([Parameter(Mandatory)] [string] $Path)
    $w = ConvertTo-QuotableWslPath $Path
    $out = & wsl bash -lc "xz -t -- '$w'" 2>&1
    [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Invoke-MakeOsList {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $ImagePath,
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutPath
    )
    $s = ConvertTo-QuotableWslPath $ScriptPath
    $i = ConvertTo-QuotableWslPath $ImagePath
    $o = ConvertTo-QuotableWslPath $OutPath
    & wsl bash -lc "bash '$s' '$i' --url '$Url' --out '$o'" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "[os_list] make-os-list.sh failed (exit $LASTEXITCODE)" }
}

function Invoke-ReleaseNotesScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [string] $RepoSlug,
        [Parameter(Mandatory)] [string] $OutPath
    )
    $s = ConvertTo-QuotableWslPath $ScriptPath
    $o = ConvertTo-QuotableWslPath $OutPath
    & wsl bash -lc "bash '$s' '$Tag' --repo-slug '$RepoSlug' > '$o'"
    if ($LASTEXITCODE -ne 0) { throw "[notes] release-notes.sh failed (exit $LASTEXITCODE)" }
}

# gh for the WRITE calls: output streams to the console (a 1 GB upload shows
# progress), only the exit code comes back.
function Invoke-GhWrite {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    & gh @Arguments | Out-Host
    return $LASTEXITCODE
}

# Anonymous HTTPS GET, the way Imager fetches (no gh token, redirects
# followed). Returns the body's sha256, or with -RangeProbe the HTTP status of
# a one-byte range request.
function Invoke-AnonymousGet {
    param([Parameter(Mandatory)] [string] $Uri, [switch] $RangeProbe)
    $ProgressPreference = 'SilentlyContinue'
    if ($RangeProbe) {
        $r = Invoke-WebRequest -Uri $Uri -Headers @{ Range = 'bytes=0-0' } -UseBasicParsing -ErrorAction Stop
        return [int] $r.StatusCode
    }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        return Get-Sha256OfFile $tmp
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function Format-GhCommand {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $parts = foreach ($a in $Arguments) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
    return 'gh ' + ($parts -join ' ')
}

# =============================================================================
# Resolving the cache directory
# =============================================================================

function Resolve-PromoteCacheDir {
    param([string] $CacheDir, [string] $RunId, [string] $Sha, [Parameter(Mandatory)] [string] $Dest)
    $given = @($CacheDir, $RunId, $Sha | Where-Object { $_ })
    if ($given.Count -ne 1) { throw "promote-release: pass exactly one of -CacheDir <dir>, -RunId <id> or -Sha <sha>" }
    if ($CacheDir) {
        $dir = $CacheDir
    } elseif ($RunId) {
        if ($RunId -notmatch '^[0-9]+$') { throw "promote-release: -RunId '$RunId' is not a number" }
        $dir = Join-Path $Dest $RunId
    } else {
        if ($Sha -notmatch '^[0-9a-fA-F]{40}$') { throw "promote-release: -Sha '$Sha' is not a full 40-hex commit sha" }
        # Either cache kind, by the elspi commit (or a Forgejo package sha).
        $s = $Sha.ToLowerInvariant()
        $hits = @(Get-ChildItem -LiteralPath $Dest -Directory -ErrorAction SilentlyContinue | Where-Object {
            $g = Join-Path $_.FullName '.artifact-info.json'
            $f = Join-Path $_.FullName '.forgejo-package-info.json'
            ((Test-Path -LiteralPath $g) -and ((Get-Content -LiteralPath $g -Raw | ConvertFrom-Json).name -eq "elspi-image-$s")) -or
            ((Test-Path -LiteralPath $f) -and ($s -in @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) | ForEach-Object { $_.elspi_sha; $_.package_sha; $_.commit_sha })))
        })
        if ($hits.Count -ne 1) { throw "promote-release: $($hits.Count) cache directories under $Dest hold commit $s, expected one -- pass -CacheDir" }
        $dir = $hits[0].FullName
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "promote-release: cache directory $dir does not exist -- flash-test-build.ps1 writes it" }
    return (Resolve-Path -LiteralPath $dir).ProviderPath
}

# =============================================================================
# Gates. Each Assert-* throws with a [label] naming what failed, and is called
# on its own line in Invoke-PromoteRelease.
# =============================================================================

function Read-GithubMarker {
    param([Parameter(Mandatory)] [string] $CacheDir)
    $m = Get-Content -LiteralPath (Join-Path $CacheDir '.artifact-info.json') -Raw | ConvertFrom-Json
    if ("$($m.name)" -notmatch '^elspi-image-(?<sha>[0-9a-f]{40})$') { throw "[marker] .artifact-info.json name '$($m.name)' is not elspi-image-<40-hex sha>" }
    $sha = $Matches['sha']
    if ("$($m.digest)" -notmatch '^sha256:[0-9a-f]{64}$') { throw "[marker] .artifact-info.json has no sha256 digest ('$($m.digest)') -- a release needs one; re-download with flash-test-build.ps1" }
    if (-not ($m.size_in_bytes -as [int64])) { throw "[marker] .artifact-info.json has no size_in_bytes" }
    return [PSCustomObject]@{ name = $m.name; sha = $sha; size = [int64] $m.size_in_bytes; digest = $m.digest.Substring(7); run_id = "$($m.run_id)" }
}

function Assert-ZipDigest {
    param([Parameter(Mandatory)] [string] $ZipPath, [Parameter(Mandatory)] $Marker)
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "[zip digest] $ZipPath is missing -- the zip is what GitHub's digest describes" }
    $size = (Get-Item -LiteralPath $ZipPath).Length
    if ($size -ne $Marker.size) { throw "[zip digest] $ZipPath is $size bytes, the marker recorded $($Marker.size)" }
    $got = Get-Sha256OfFile $ZipPath
    if ($got -ne $Marker.digest) { throw "[zip digest] $ZipPath sha256 $got does not match the marker's sha256:$($Marker.digest)" }
    Write-Host "  [zip digest]     OK  $size bytes, sha256:$got"
}

# The zip's one image_*.img.xz and one *.info, and where flash-test-build
# extracted them.
function Get-ZipPayload {
    param([Parameter(Mandatory)] [string] $ZipPath, [Parameter(Mandatory)] [string] $CacheDir)
    $names = Get-ZipEntryNames $ZipPath
    $img = @($names | Where-Object { $_ -match '^image_[^/\\]+\.img\.xz$' })
    $info = @($names | Where-Object { $_ -match '^[^/\\]+\.info$' })
    if ($img.Count -ne 1) { throw "[zip contents] expected exactly one image_*.img.xz in the zip, found $($img.Count)" }
    if ($info.Count -ne 1) { throw "[zip contents] expected exactly one *.info in the zip, found $($info.Count)" }
    return [PSCustomObject]@{ ImageEntry = $img[0]; InfoEntry = $info[0]; Image = (Join-Path $CacheDir $img[0]); Info = (Join-Path $CacheDir $info[0]) }
}

# $Expected: @{ entryName = sha256-of-the-file-on-disk }.
function Assert-ExtractedMatchesZip {
    param([Parameter(Mandatory)] [string] $ZipPath, [Parameter(Mandatory)] [hashtable] $Expected, [Parameter(Mandatory)] [string] $CacheDir)
    foreach ($name in $Expected.Keys) {
        $file = Join-Path $CacheDir $name
        $e = Get-Sha256OfZipEntry -ZipPath $ZipPath -EntryName $name
        $len = (Get-Item -LiteralPath $file).Length
        if ($e.length -ne $len) { throw "[zip contents] $file is $len bytes, the zip's entry is $($e.length)" }
        if ($e.sha256 -ne $Expected[$name]) { throw "[zip contents] $file (sha256 $($Expected[$name])) is not the zip's entry (sha256 $($e.sha256))" }
        Write-Host "  [zip contents]   OK  $name = zip entry, sha256:$($e.sha256)"
    }
}

# A Forgejo build has TWO commits. The Forgejo repo is a snapshot of elspi plus
# one workflow commit, so the run and the package version are keyed by the
# SNAPSHOT commit, which is not in elspi; the elspi commit is its parent.
# Everything elspi-side -- the tag's --target, the branch check, build.sh's
# ARCH, make-os-list.sh and release-notes.sh -- uses the ELSPI commit, which
# the marker must record as `elspi_sha`. The package sha is `package_sha`, or
# `commit_sha` in markers written before the two were split. A marker with no
# elspi_sha is refused rather than guessed at.
function Read-ForgejoMarker {
    param([Parameter(Mandatory)] [string] $CacheDir)
    $m = Get-Content -LiteralPath (Join-Path $CacheDir '.forgejo-package-info.json') -Raw | ConvertFrom-Json
    if ("$($m.elspi_sha)" -notmatch '^[0-9a-f]{40}$') { throw "[marker] .forgejo-package-info.json has no elspi_sha (got '$($m.elspi_sha)') -- a Forgejo build's package sha is a snapshot commit that is not in elspi, so the elspi commit must be recorded; re-download with a flash-test-build.ps1 that writes it" }
    $pkg = if ($m.package_sha) { "$($m.package_sha)" } else { "$($m.commit_sha)" }
    if ($pkg -notmatch '^[0-9a-f]{40}$') { throw "[marker] .forgejo-package-info.json has no 40-hex package sha (package_sha / commit_sha)" }
    if ("$($m.name)" -notmatch '^image_[A-Za-z0-9._+-]+\.img\.xz$') { throw "[marker] .forgejo-package-info.json name '$($m.name)' is not image_*.img.xz" }
    if ("$($m.sha256)" -notmatch '^[0-9a-f]{64}$') { throw "[marker] .forgejo-package-info.json has no sha256" }
    return [PSCustomObject]@{ name = $m.name; sha = "$($m.elspi_sha)"; package_sha = $pkg; size = [int64] $m.size; sha256 = $m.sha256; run_id = "$($m.run_id)" }
}

function Assert-ForgejoImageDigest {
    param([Parameter(Mandatory)] [string] $ImagePath, [Parameter(Mandatory)] [string] $ImageSha256, [Parameter(Mandatory)] $Marker)
    $len = (Get-Item -LiteralPath $ImagePath).Length
    if ($len -ne $Marker.size) { throw "[forgejo digest] $ImagePath is $len bytes, the marker recorded $($Marker.size)" }
    if ($ImageSha256 -ne $Marker.sha256) { throw "[forgejo digest] $ImagePath sha256 $ImageSha256 does not match the marker's $($Marker.sha256)" }
    Write-Host "  [forgejo digest] OK  $len bytes, sha256:$ImageSha256"
}

# The registry's live listing must still describe the marker's image, and the
# .info beside it is taken from the same package version (downloaded if the
# cache lacks it) and checked against the listing.
function Sync-ForgejoInfo {
    param(
        [Parameter(Mandatory)] [string] $CacheDir, [Parameter(Mandatory)] $Marker,
        [string] $ForgejoUrl, [string] $ForgejoRepo, [string] $ForgejoPackage, [string] $ForgejoTokenFile
    )
    $base = Assert-ForgejoConfig -Url $ForgejoUrl -Repo $ForgejoRepo -Package $ForgejoPackage
    $headers = Get-ForgejoAuthHeader -TokenFile $ForgejoTokenFile
    $pkg = $Marker.package_sha
    $files = @(Invoke-ForgejoApi -Uri (Get-ForgejoPackageFilesUri -BaseUrl $base -Package $ForgejoPackage -Sha $pkg) -Headers $headers)
    $img = Select-ForgejoImageFile -Files $files -Sha $pkg
    if ($img.name -ne $Marker.name -or $img.size -ne $Marker.size -or $img.sha256 -ne $Marker.sha256) {
        throw "[forgejo registry] the package version now lists $($img.name) $($img.size) bytes sha256 $($img.sha256); the cache marker recorded $($Marker.name) $($Marker.size) sha256 $($Marker.sha256)"
    }
    # A small file of the package version, verified against the listing and
    # kept in the cache dir.
    $fetch = {
        param([string] $Name)
        $listed = @($files | Where-Object { $_.name -eq $Name })
        if ($listed.Count -ne 1 -or "$($listed[0].sha256)" -notmatch '^[0-9a-fA-F]{64}$') {
            throw "[forgejo registry] package version $pkg does not list exactly one $Name with a sha256"
        }
        $fi = [PSCustomObject]@{ name = $Name; size = [int64] $listed[0].Size; sha256 = "$($listed[0].sha256)".ToLowerInvariant() }
        $path = Join-Path $CacheDir $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $partial = "$path.partial"
            Invoke-ForgejoDownload -Uri (Get-ForgejoPackageFileUri -BaseUrl $base -Package $ForgejoPackage -Sha $pkg -FileName $Name) -Headers $headers -OutFile $partial
            try { Confirm-DownloadedForgejoFile -Path $partial -FileInfo $fi } catch { Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue; throw }
            Move-Item -LiteralPath $partial -Destination $path -Force
        } else {
            Confirm-DownloadedForgejoFile -Path $path -FileInfo $fi
        }
        return $path
    }
    # The package's own record of the elspi commit must agree with the marker.
    $recorded = (Get-Content -LiteralPath (& $fetch 'elspi-commit.txt') -Raw).Trim()
    if ($recorded -ne $Marker.sha) { throw "[forgejo registry] the package's elspi-commit.txt says '$recorded', the marker's elspi_sha is $($Marker.sha)" }
    $infoName = ($Marker.name -replace '^image_', '') -replace '\.img\.xz$', '.info'
    $path = & $fetch $infoName
    Write-Host "  [forgejo registry] OK  $($Marker.name), $infoName and elspi-commit.txt ($recorded) match package version $pkg"
    return $path
}

function Assert-XzIntegrity {
    param([Parameter(Mandatory)] [string] $ImagePath)
    $r = Invoke-XzTest -Path $ImagePath
    if ($r.ExitCode -ne 0) { throw "[xz -t] $ImagePath fails 'xz -t' (exit $($r.ExitCode)): $($r.Output -join ' / ')" }
    Write-Host "  [xz -t]          OK"
}

# Line 2 of the .info: "Generated using pi-gen, <repo>, <GIT_HASH>, <stage>".
function Get-InfoBuildSha {
    param([Parameter(Mandatory)] [string] $InfoPath)
    $line = @(Get-Content -LiteralPath $InfoPath -TotalCount 2)[1]
    $f = @("$line" -split ',\s*')
    if ($f.Count -lt 3 -or $f[2].Trim() -notmatch '^[0-9a-f]{40}$') { throw "[build sha] $InfoPath line 2 carries no 40-hex pi-gen commit: '$line'" }
    return $f[2].Trim()
}

# The architecture of the `dpkg` package in the .info's package list: the
# rootfs's native architecture, i.e. what the image IS.
function Get-InfoArch {
    param([Parameter(Mandatory)] [string] $InfoPath)
    $hits = @(Select-String -LiteralPath $InfoPath -Pattern '^ii\s+dpkg\s+\S+\s+(\S+)\s' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($hits.Count -ne 1) { throw "[arch] $InfoPath does not list the dpkg package exactly once (found $($hits.Count)) -- cannot read the image's architecture" }
    return $hits[0]
}

function Get-CommitArch {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Sha)
    $r = Invoke-Git '-C' $RepoRoot 'show' "${Sha}:build.sh"
    if ($r.ExitCode -ne 0) { throw "[arch] git show ${Sha}:build.sh failed (exit $($r.ExitCode))" }
    $lines = @($r.Output | ForEach-Object { "$_" } | Where-Object { $_ -match '^export ARCH=' })
    if ($lines.Count -ne 1) { throw "[arch] build.sh at $Sha has $($lines.Count) 'export ARCH=' lines, expected one" }
    return ($lines[0] -replace '^export ARCH=', '').Trim()
}

function Assert-BuildShaConsistent {
    # $PackageSha: a Forgejo build's snapshot commit, whose pi-gen GIT_HASH
    # may be either commit.
    param([Parameter(Mandatory)] [string] $MarkerSha, [Parameter(Mandatory)] [string] $InfoSha, $Run, [string] $PackageSha)
    if ($InfoSha -ne $MarkerSha -and (-not $PackageSha -or $InfoSha -ne $PackageSha)) { throw "[build sha] the .info says the image was built from $InfoSha, the marker says $MarkerSha$(if ($PackageSha) { " (package $PackageSha)" })" }
    if ($Run) {
        if ($Run.workflowName -ne 'image') { throw "[build sha] run $($Run.databaseId) is a '$($Run.workflowName)' run, not 'image'" }
        if ($Run.conclusion -ne 'success') { throw "[build sha] run $($Run.databaseId) concluded '$($Run.conclusion)', not success" }
        if ($Run.headSha -ne $MarkerSha) { throw "[build sha] run $($Run.databaseId) built $($Run.headSha), the marker says $MarkerSha" }
    }
    Write-Host "  [build sha]      OK  $MarkerSha"
}

function Assert-ArchConsistent {
    param([Parameter(Mandatory)] [string] $InfoArch, [Parameter(Mandatory)] [string] $CommitArch)
    if ($InfoArch -notin @('arm64', 'armhf')) { throw "[arch] the image's dpkg architecture is '$InfoArch'; only arm64 and armhf are released" }
    if ($InfoArch -ne $CommitArch) { throw "[arch] the image is $InfoArch (its .info) but build.sh at its commit says ARCH=$CommitArch -- refusing" }
    Write-Host "  [arch]           OK  $InfoArch (image .info and build.sh agree)"
}

function Assert-TagMatchesArch {
    param([Parameter(Mandatory)] [string] $Tag, [Parameter(Mandatory)] [string] $Arch)
    if ($Tag -notmatch $script:TagPattern) { throw "[tag] '$Tag' is not vYYYY.MM.DD[.N][-armhf]" }
    $isArmhf = [bool] $Matches['armhf']
    if ($isArmhf -and $Arch -ne 'armhf') { throw "[arch] tag '$Tag' says armhf but the image is $Arch" }
    if (-not $isArmhf -and $Arch -eq 'armhf') { throw "[arch] the image is armhf, so its tag needs the -armhf suffix (got '$Tag')" }
}

function Get-ReleaseBranch {
    param([Parameter(Mandatory)] [string] $Arch)
    if ($Arch -eq 'arm64') { return 'arm64' } else { return 'master' }
}

function Assert-OnBranch {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Sha, [Parameter(Mandatory)] [string] $Branch, [Parameter(Mandatory)] [string] $GitUrl)
    $ls = Invoke-Git 'ls-remote' $GitUrl "refs/heads/$Branch"
    $tip = @($ls.Output | ForEach-Object { "$_" } | Where-Object { $_ -match "^[0-9a-f]{40}\s+refs/heads/$([regex]::Escape($Branch))$" } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($ls.ExitCode -ne 0 -or $tip.Count -ne 1) { throw "[branch] could not read GitHub's $Branch tip (git ls-remote exit $($ls.ExitCode))" }
    $tip = $tip[0]
    if ((Invoke-Git '-C' $RepoRoot 'cat-file' '-e' "${tip}^{commit}").ExitCode -ne 0) {
        $null = Invoke-Git '-C' $RepoRoot 'fetch' '--no-tags' $GitUrl "refs/heads/$Branch"
    }
    $r = Invoke-Git '-C' $RepoRoot 'merge-base' '--is-ancestor' $Sha $tip
    if ($r.ExitCode -eq 1) { throw "[branch] $Sha is not on $Branch (GitHub's $Branch is at $tip) -- a release points at the line" }
    if ($r.ExitCode -ne 0) { throw "[branch] git merge-base --is-ancestor $Sha $tip failed (exit $($r.ExitCode)): $($r.Output -join ' / ')" }
    Write-Host "  [branch]         OK  on $Branch (tip $tip)"
}

# Every tag on GitHub, plus every release name (drafts have no tag yet).
function Get-UsedTagNames {
    param([Parameter(Mandatory)] [string] $GitUrl, [Parameter(Mandatory)] [string] $Repo)
    $ls = Invoke-Git 'ls-remote' '--tags' '--refs' $GitUrl
    if ($ls.ExitCode -ne 0) { throw "[tag] git ls-remote --tags $GitUrl failed (exit $($ls.ExitCode))" }
    $tags = @($ls.Output | ForEach-Object { "$_" } | Where-Object { $_ -match 'refs/tags/' } | ForEach-Object { ($_ -split 'refs/tags/', 2)[1].Trim() })
    $rel = @(Invoke-GhJson 'release' 'list' '--repo' $Repo '--limit' '1000' '--json' 'tagName' | ForEach-Object { $_.tagName })
    return @($tags + $rel | Where-Object { $_ } | Sort-Object -Unique)
}

function Select-ReleaseTag {
    param([Parameter(Mandatory)] [string] $ImageName, [Parameter(Mandatory)] [string] $Arch, [AllowEmptyCollection()] [string[]] $Used = @(), [string] $Explicit)
    if ($Explicit) { return $Explicit }
    if ($ImageName -notmatch '^image_(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})') { throw "[tag] cannot read a YYYY-MM-DD date from $ImageName -- pass -Tag" }
    $base = "v$($Matches['y']).$($Matches['m']).$($Matches['d'])"
    $suffix = if ($Arch -eq 'armhf') { '-armhf' } else { '' }
    foreach ($n in @('') + (1..99 | ForEach-Object { ".$_" })) {
        $t = "$base$n$suffix"
        if ($t -notin $Used) { return $t }
    }
    throw "[tag] no free tag for $base$suffix"
}

function Assert-TagFree {
    param([Parameter(Mandatory)] [string] $Tag, [AllowEmptyCollection()] [string[]] $Used = @())
    if ($Tag -in $Used) { throw "[tag] $Tag already exists on GitHub (as a tag or a release) -- refusing; pick another with -Tag" }
    Write-Host "  [tag]            OK  $Tag is unused"
}

function Assert-OsListDescribesImage {
    param(
        [Parameter(Mandatory)] [string] $OsListPath, [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [int64] $ImageSize, [Parameter(Mandatory)] [string] $ImageSha256,
        [Parameter(Mandatory)] [string] $Arch, [string] $BenchOsListPath
    )
    $doc = Get-Content -LiteralPath $OsListPath -Raw | ConvertFrom-Json
    $e = @($doc.os_list)
    if ($e.Count -ne 1) { throw "[os_list] $OsListPath has $($e.Count) entries, expected one" }
    $e = $e[0]
    if ($e.url -ne $Url) { throw "[os_list] url is '$($e.url)', expected '$Url'" }
    if ([int64] $e.image_download_size -ne $ImageSize) { throw "[os_list] image_download_size $($e.image_download_size) is not the image's $ImageSize bytes" }
    if ($e.image_download_sha256 -ne $ImageSha256) { throw "[os_list] image_download_sha256 $($e.image_download_sha256) is not the image's $ImageSha256" }
    $want = if ($Arch -eq 'arm64') { '-64bit$' } else { '-32bit$' }
    $dev = @($e.devices)
    if ($dev.Count -eq 0 -or @($dev | Where-Object { $_ -notmatch $want }).Count -ne 0) { throw "[os_list] devices [$($dev -join ', ')] do not all match $want for an $Arch image" }
    if ($e.init_format -ne 'cloudinit-rpi') { throw "[os_list] init_format is '$($e.init_format)', not cloudinit-rpi" }
    if ($BenchOsListPath -and (Test-Path -LiteralPath $BenchOsListPath -PathType Leaf)) {
        $b = @((Get-Content -LiteralPath $BenchOsListPath -Raw | ConvertFrom-Json).os_list)[0]
        foreach ($k in 'extract_size', 'extract_sha256', 'image_download_size', 'image_download_sha256') {
            if ("$($b.$k)" -ne "$($e.$k)") { throw "[os_list] $k is $($e.$k), but the os_list.json the bench card was flashed from says $($b.$k)" }
        }
        Write-Host "  [os_list]        OK  url, sizes, sha256s and devices; identical to the bench os_list.json"
    } else {
        Write-Warning "no bench os_list.json in the cache dir -- the release os_list could not be compared with the one the tested card was flashed from"
        Write-Host "  [os_list]        OK  url, sizes, sha256s and devices"
    }
}

function Assert-AssetSizes {
    param([Parameter(Mandatory)] [object[]] $Assets)
    foreach ($a in $Assets) {
        if ($a.size -ge $script:GiB2) { throw "[asset size] $($a.name) is $($a.size) bytes, over GitHub's 2 GiB release-asset limit" }
    }
}

# =============================================================================
# The gh commands
# =============================================================================

function Get-PublishCommands {
    param(
        [Parameter(Mandatory)] [string] $Tag, [Parameter(Mandatory)] [string] $Sha, [Parameter(Mandatory)] [string] $Arch,
        [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $NotesPath,
        [Parameter(Mandatory)] [string[]] $Files, [bool] $Prerelease
    )
    $latest = ($Arch -eq 'arm64') -and -not $Prerelease
    $create = @('release', 'create', $Tag, '--repo', $Repo, '--target', $Sha, '--draft')
    if ($Prerelease) { $create += '--prerelease' }
    $create += @('--latest=false', '--title', "elspi $Tag", '--notes-file', $NotesPath) + $Files
    $publish = @('release', 'edit', $Tag, '--repo', $Repo, '--draft=false')
    if ($Prerelease) { $publish += '--latest=false' }
    elseif ($latest) { $publish += @('--prerelease=false', '--latest') }
    else { $publish += @('--prerelease=false', '--latest=false') }
    return [PSCustomObject]@{ Latest = $latest; Create = $create; Publish = $publish }
}

# armhf is never latest -- checked on the final argument lists, not on the
# flag that produced them.
function Assert-NeverLatestArmhf {
    param([Parameter(Mandatory)] $Commands, [Parameter(Mandatory)] [string] $Arch, [bool] $Prerelease)
    $all = @($Commands.Create) + @($Commands.Publish)
    if (($Arch -ne 'arm64' -or $Prerelease) -and ($all -contains '--latest' -or $Commands.Latest)) {
        throw "[latest] refusing: an $Arch$(if ($Prerelease) { ' pre-release' }) would be marked --latest"
    }
}

# =============================================================================
# Read-back after sending
# =============================================================================

function Assert-ReleaseAssets {
    param([Parameter(Mandatory)] $Release, [Parameter(Mandatory)] [object[]] $Expected, [Parameter(Mandatory)] [string] $Stage)
    $assets = @($Release.assets)
    if ($assets.Count -ne $Expected.Count) { throw "[$Stage] the release has $($assets.Count) assets, expected $($Expected.Count): $(@($assets | ForEach-Object { $_.name }) -join ', ')" }
    foreach ($x in $Expected) {
        $a = @($assets | Where-Object { $_.name -eq $x.name })
        if ($a.Count -ne 1) { throw "[$Stage] asset $($x.name) is missing from the release" }
        if ([int64] $a[0].size -ne $x.size) { throw "[$Stage] asset $($x.name) is $($a[0].size) bytes on GitHub, $($x.size) locally" }
        if (-not $a[0].digest) { throw "[$Stage] GitHub reports no digest for $($x.name) -- UNKNOWN, not verified" }
        if ($a[0].digest -ne "sha256:$($x.sha256)") { throw "[$Stage] asset $($x.name) is $($a[0].digest) on GitHub, sha256:$($x.sha256) locally" }
    }
    Write-Host "  [$Stage] OK  $($Expected.Count) assets match by size and sha256"
}

function Get-DraftRelease {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Tag)
    $all = @(Invoke-GhJson 'api' "repos/$Repo/releases?per_page=100")
    $d = @($all | ForEach-Object { $_ } | Where-Object { $_.tag_name -eq $Tag -and $_.draft })
    if ($d.Count -ne 1) { throw "[draft] expected one draft release named $Tag, found $($d.Count)" }
    return $d[0]
}

function Get-LatestTag {
    param([Parameter(Mandatory)] [string] $Repo)
    $r = Invoke-Gh 'api' "repos/$Repo/releases/latest" '--jq' '.tag_name'
    if ($r.ExitCode -ne 0) { return $null }
    return ("$($r.Output -join '')").Trim()
}

function Assert-PublishedRelease {
    param(
        [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Tag, [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [bool] $Prerelease, [Parameter(Mandatory)] [bool] $Latest,
        [Parameter(Mandatory)] [object[]] $Expected, [Parameter(Mandatory)] [string] $OsListSha256, [Parameter(Mandatory)] [string] $ImageName
    )
    $ref = Invoke-GhJson 'api' "repos/$Repo/git/ref/tags/$Tag"
    if ($ref.object.type -ne 'commit' -or $ref.object.sha -ne $Sha) { throw "[read-back] tag $Tag points at $($ref.object.type) $($ref.object.sha), not commit $Sha" }
    $rel = Invoke-GhJson 'api' "repos/$Repo/releases/tags/$Tag"
    if ($rel.draft) { throw "[read-back] $Tag is still a draft" }
    if ([bool] $rel.prerelease -ne $Prerelease) { throw "[read-back] $Tag prerelease=$($rel.prerelease), expected $Prerelease" }
    Assert-ReleaseAssets -Release $rel -Expected $Expected -Stage 'read-back'
    $now = Get-LatestTag -Repo $Repo
    if ($Latest -and $now -ne $Tag) { throw "[read-back] releases/latest is '$now', not $Tag" }
    if (-not $Latest -and $now -eq $Tag) { throw "[read-back] releases/latest is $Tag, which must not be latest" }
    $pinned = "https://github.com/$Repo/releases/download/$Tag/os_list.json"
    if ((Invoke-AnonymousGet -Uri $pinned) -ne $OsListSha256) { throw "[read-back] an anonymous GET of $pinned is not the os_list.json that was uploaded" }
    if ($Latest) {
        $l = "https://github.com/$Repo/releases/latest/download/os_list.json"
        if ((Invoke-AnonymousGet -Uri $l) -ne $OsListSha256) { throw "[read-back] an anonymous GET of $l is not this release's os_list.json" }
    }
    $code = Invoke-AnonymousGet -Uri "https://github.com/$Repo/releases/download/$Tag/$ImageName" -RangeProbe
    if ($code -notin 200, 206) { throw "[read-back] the image url answered HTTP $code" }
    Write-Host "  [read-back] OK  tag -> $Sha, latest = $now, os_list.json served anonymously and identical"
}

# =============================================================================
# Main
# =============================================================================

function Invoke-PromoteRelease {
    [CmdletBinding()]
    param(
        [string] $CacheDir, [string] $RunId, [string] $Sha, [string] $Tag,
        [bool] $Prerelease, [bool] $DryRun,
        [Parameter(Mandatory)] [string] $Dest, [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Repo = $script:Repo,
        [string] $ForgejoUrl, [string] $ForgejoRepo, [string] $ForgejoPackage, [string] $ForgejoTokenFile
    )
    $ErrorActionPreference = 'Stop'
    $gitUrl = "https://github.com/$Repo.git"

    Write-Host "== preflight =="
    Assert-GhAuthenticated -Repo $Repo
    Assert-WslAvailable
    $dir = Resolve-PromoteCacheDir -CacheDir $CacheDir -RunId $RunId -Sha $Sha -Dest $Dest
    $hasGh = Test-Path -LiteralPath (Join-Path $dir '.artifact-info.json') -PathType Leaf
    $hasFj = Test-Path -LiteralPath (Join-Path $dir '.forgejo-package-info.json') -PathType Leaf
    if ($hasGh -eq $hasFj) { throw "promote-release: $dir must hold exactly one of .artifact-info.json (GitHub) or .forgejo-package-info.json (Forgejo)" }
    Write-Host "cache: $dir ($(if ($hasGh) { 'GitHub artifact' } else { 'Forgejo package' }))"
    Write-Host ""

    Write-Host "== verifying the cached bytes =="
    $run = $null
    if ($hasGh) {
        $marker = Read-GithubMarker -CacheDir $dir
        $zip = Join-Path $dir "$($marker.name).zip"
        Assert-ZipDigest -ZipPath $zip -Marker $marker
        $payload = Get-ZipPayload -ZipPath $zip -CacheDir $dir
        $imagePath = $payload.Image
        $infoPath = $payload.Info
        foreach ($p in $imagePath, $infoPath) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "[zip contents] $p is missing -- the zip holds it but it was not extracted" } }
        $imageSha = Get-Sha256OfFile $imagePath
        $infoSha = Get-Sha256OfFile $infoPath
        Assert-ExtractedMatchesZip -ZipPath $zip -CacheDir $dir -Expected @{ $payload.ImageEntry = $imageSha; $payload.InfoEntry = $infoSha }
        $run = Invoke-GhJson 'run' 'view' $marker.run_id '--repo' $Repo '--json' 'databaseId,headBranch,headSha,status,conclusion,workflowName,event'
    } else {
        $marker = Read-ForgejoMarker -CacheDir $dir
        $imagePath = Join-Path $dir $marker.name
        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw "[forgejo digest] $imagePath is missing" }
        $imageSha = Get-Sha256OfFile $imagePath
        Assert-ForgejoImageDigest -ImagePath $imagePath -ImageSha256 $imageSha -Marker $marker
        $infoPath = Sync-ForgejoInfo -CacheDir $dir -Marker $marker -ForgejoUrl $ForgejoUrl -ForgejoRepo $ForgejoRepo -ForgejoPackage $ForgejoPackage -ForgejoTokenFile $ForgejoTokenFile
        $infoSha = Get-Sha256OfFile $infoPath
    }
    $sha = $marker.sha
    Assert-XzIntegrity -ImagePath $imagePath
    Assert-BuildShaConsistent -MarkerSha $sha -InfoSha (Get-InfoBuildSha -InfoPath $infoPath) -Run $run -PackageSha $marker.package_sha
    Assert-CommitAvailable -RepoRoot $RepoRoot -Sha $sha
    $arch = Get-InfoArch -InfoPath $infoPath
    Assert-ArchConsistent -InfoArch $arch -CommitArch (Get-CommitArch -RepoRoot $RepoRoot -Sha $sha)
    $branch = Get-ReleaseBranch -Arch $arch
    Assert-OnBranch -RepoRoot $RepoRoot -Sha $sha -Branch $branch -GitUrl $gitUrl

    $imageName = Split-Path -Leaf $imagePath
    $used = Get-UsedTagNames -GitUrl $gitUrl -Repo $Repo
    $tagName = Select-ReleaseTag -ImageName $imageName -Arch $arch -Used $used -Explicit $Tag
    Assert-TagMatchesArch -Tag $tagName -Arch $arch
    Assert-TagFree -Tag $tagName -Used $used
    Write-Host ""

    Write-Host "== os_list.json and release notes, from commit $sha =="
    $stage = Join-Path $dir "promote-$tagName"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $osList = Join-Path $stage 'os_list.json'
    $notes = Join-Path $stage 'notes.md'
    Remove-Item -LiteralPath $osList, $notes -ErrorAction SilentlyContinue
    $imageUrl = "https://github.com/$Repo/releases/download/$tagName/$imageName"
    Get-MakeOsListScriptForCommit -RepoRoot $RepoRoot -Sha $sha -OutDir $stage
    Invoke-MakeOsList -ScriptPath (Join-Path $stage 'make-os-list.sh') -ImagePath $imagePath -Url $imageUrl -OutPath $osList
    $imageSize = (Get-Item -LiteralPath $imagePath).Length
    Assert-OsListDescribesImage -OsListPath $osList -Url $imageUrl -ImageSize $imageSize -ImageSha256 $imageSha -Arch $arch -BenchOsListPath (Join-Path $dir 'os_list.json')
    Get-CommitFile -RepoRoot $RepoRoot -Sha $sha -RepoPath 'tools/release-notes.sh' -OutFile (Join-Path $stage 'release-notes.sh')
    Invoke-ReleaseNotesScript -ScriptPath (Join-Path $stage 'release-notes.sh') -Tag $tagName -RepoSlug $Repo -OutPath $notes
    $pinnedList = "https://github.com/$Repo/releases/download/$tagName/os_list.json"
    if (-not (Test-Path -LiteralPath $notes) -or -not (Select-String -LiteralPath $notes -SimpleMatch $pinnedList -Quiet)) { throw "[notes] $notes does not carry the pinned $pinnedList" }

    $assets = @(
        [PSCustomObject]@{ name = $imageName; path = $imagePath; size = [int64] $imageSize; sha256 = $imageSha },
        [PSCustomObject]@{ name = (Split-Path -Leaf $infoPath); path = $infoPath; size = (Get-Item -LiteralPath $infoPath).Length; sha256 = $infoSha },
        [PSCustomObject]@{ name = 'os_list.json'; path = $osList; size = (Get-Item -LiteralPath $osList).Length; sha256 = (Get-Sha256OfFile $osList) }
    )
    Assert-AssetSizes -Assets $assets
    $cmds = Get-PublishCommands -Tag $tagName -Sha $sha -Arch $arch -Repo $Repo -NotesPath $notes -Files @($assets | ForEach-Object { $_.path }) -Prerelease $Prerelease
    Assert-NeverLatestArmhf -Commands $cmds -Arch $arch -Prerelease $Prerelease
    $prevLatest = Get-LatestTag -Repo $Repo
    Write-Host ""

    $mode = if ($Prerelease) { 'PRE-release, not latest' } elseif ($cmds.Latest) { "release, marked LATEST (was: $prevLatest)" } else { "release, NOT latest (latest stays $prevLatest)" }
    Write-Host "== what would be published =="
    Write-Host ("tag:     {0}" -f $tagName)
    Write-Host ("target:  {0} (on {1})" -f $sha, $branch)
    Write-Host ("arch:    {0}" -f $arch)
    Write-Host ("mode:    {0}" -f $mode)
    foreach ($a in $assets) { Write-Host ("asset:   {0}  {1:N0} bytes  sha256:{2}" -f $a.name, $a.size, $a.sha256) }
    Write-Host ""
    Write-Host "commands:"
    Write-Host ("  " + (Format-GhCommand $cmds.Create))
    Write-Host "  (read the draft's assets back by digest)"
    Write-Host ("  " + (Format-GhCommand $cmds.Publish))
    Write-Host "  (read back: tag -> commit, asset digests, releases/latest, anonymous os_list.json)"
    Write-Host ""

    $result = [PSCustomObject]@{ Tag = $tagName; Sha = $sha; Arch = $arch; Latest = $cmds.Latest; Commands = $cmds; Assets = $assets; Published = $false }
    if ($DryRun) {
        Write-Host "DRY RUN: every check passed; nothing was created on GitHub."
        return $result
    }

    $answer = Read-Host "Type the tag ($tagName) to publish it; anything else aborts"
    if ($answer -ne $tagName) {
        Write-Host "Aborted -- nothing was sent."
        return $result
    }

    Write-Host "== creating the draft =="
    $rc = Invoke-GhWrite -Arguments $cmds.Create
    if ($rc -ne 0) { throw "[create] gh release create failed (exit $rc). If a draft $tagName was left behind, inspect it with: gh release view $tagName --repo $Repo" }
    Assert-ReleaseAssets -Release (Get-DraftRelease -Repo $Repo -Tag $tagName) -Expected $assets -Stage 'draft'

    Write-Host "== publishing =="
    $rc = Invoke-GhWrite -Arguments $cmds.Publish
    if ($rc -ne 0) { throw "[publish] gh release edit failed (exit $rc); the draft $tagName is still there and unpublished" }
    $result.Published = $true
    try {
        Assert-PublishedRelease -Repo $Repo -Tag $tagName -Sha $sha -Prerelease $Prerelease -Latest $cmds.Latest `
            -Expected $assets -OsListSha256 $assets[2].sha256 -ImageName $imageName
    } catch {
        $undo = if ($cmds.Latest -and $prevLatest) { " To point latest back: gh release edit $prevLatest --repo $Repo --latest" } else { '' }
        throw "$($_.Exception.Message) -- $tagName IS published.$undo"
    }
    Write-Host ""
    Write-Host "published: https://github.com/$Repo/releases/tag/$tagName"
    return $result
}

if (-not $script:PromoteIsDotSourced) {
    $a = $script:PromoteArgs
    $null = Invoke-PromoteRelease -CacheDir $a.CacheDir -RunId $a.RunId -Sha $a.Sha -Tag $a.Tag `
        -Prerelease $a.Prerelease -DryRun $a.DryRun -Dest $a.Dest -RepoRoot (Split-Path -Parent $PSScriptRoot) `
        -ForgejoUrl $a.ForgejoUrl -ForgejoRepo $a.ForgejoRepo -ForgejoPackage $a.ForgejoPackage -ForgejoTokenFile $a.ForgejoTokenFile
}
