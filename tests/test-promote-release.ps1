# Plain-PowerShell test for tools/promote-release.ps1 -- no network, no WSL,
# nothing published. Same approach as tests/test-flash-test-build.ps1: the
# script is dot-sourced (its Main does not run) and gh, git, wsl, Read-Host
# and the few functions that shell out are replaced by fakes of the same name.
#
# Every case runs the WHOLE flow (Invoke-PromoteRelease) against a small
# on-disk fixture shaped like a real flash-test-build cache directory: an
# artifact zip holding a fake image and .info, the extracted copies beside it,
# the .artifact-info.json marker, and the bench os_list.json. Each red case
# breaks exactly one thing and expects the gate that owns it, by its [label].
#
# Run:     pwsh tests\test-promote-release.ps1
# Mutants: pwsh tests\test-promote-release.ps1 -ScriptUnderTest <copy.ps1>
#          (the copy needs flash-test-build.ps1 beside it)
# Exits 0 if every case passes, 1 otherwise.

param([string] $ScriptUnderTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRootForTest = Split-Path -Parent $here
if (-not $ScriptUnderTest) { $ScriptUnderTest = Join-Path $repoRootForTest 'tools\promote-release.ps1' }

. $ScriptUnderTest

$script:failures = 0
$script:total = 0

function Assert-True {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [bool] $Condition, [string] $Detail = '')
    $script:total++
    if ($Condition) { Write-Host "PASS: $Name" } else { $script:failures++; Write-Host "FAIL: $Name $Detail" }
}

# Runs $Script, expecting a throw whose message contains $MatchMessage.
function Assert-Throws {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Script, [Parameter(Mandatory)] [string] $MatchMessage)
    $script:total++
    try {
        & $Script
        $script:failures++
        Write-Host "FAIL: $Name (did not throw)"
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($MatchMessage)) {
            $script:failures++
            Write-Host "FAIL: $Name (threw, but not '$MatchMessage': $($_.Exception.Message))"
        } else {
            Write-Host "PASS: $Name"
        }
    }
}

# =============================================================================
# Fixture
# =============================================================================

$FixSha = '74e2208d772e5830d8c48deb0ef687aa042ce840'
$OtherSha = '1111111111111111111111111111111111111111'
$SnapSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'   # a Forgejo snapshot commit: NOT in elspi
$FixRepo = 'Funkenjaeger/elspi'
$FixRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("promote-release-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $FixRoot | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-FixHash { param([string] $Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function New-InfoText {
    param([string] $Sha, [string] $Arch)
    "Raspberry Pi reference 2026-09-26`nGenerated using pi-gen, https://github.com/RPi-Distro/pi-gen, $Sha, stage-elspi`n`nPackages:`nii  dpkg                                 1.22.22                              $Arch        Debian package management system`nii  dpkg-dev                             1.22.22                              all          Debian package development tools`n"
}

function New-OsListJson {
    param([string] $Url, [string] $ImagePath, [string] $Arch)
    $dev = if ($Arch -eq 'arm64') { @('pi5-64bit', 'pi4-64bit', 'pi3-64bit') } else { @('pi5-32bit', 'pi4-32bit') }
    [ordered]@{
        imager  = @{ devices = @('x') }
        os_list = @([ordered]@{
            name = 'elspi 2026-09-26'; url = $Url; release_date = '2026-09-26'
            extract_size = 5460983808; extract_sha256 = ('e' * 64)
            image_download_size = (Get-Item -LiteralPath $ImagePath).Length
            image_download_sha256 = (Get-FixHash $ImagePath)
            init_format = 'cloudinit-rpi'; devices = $dev
        })
    } | ConvertTo-Json -Depth 5
}

# A GitHub cache dir, as flash-test-build.ps1 leaves it.
function New-GithubFixture {
    param([string] $Arch = 'arm64', [string] $RunId = '555')
    $dir = Join-Path $FixRoot $RunId
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    $src = Join-Path $dir 'src'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    $bytes = New-Object byte[] 8192
    (New-Object System.Random 42).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes((Join-Path $src 'image_2026-09-26-elspi.img.xz'), $bytes)
    [System.IO.File]::WriteAllText((Join-Path $src '2026-09-26-elspi.info'), (New-InfoText -Sha $FixSha -Arch $Arch))
    [System.IO.File]::WriteAllText((Join-Path $src 'build.log'), 'log')
    $zip = Join-Path $dir "elspi-image-$FixSha.zip"
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $zip, [System.IO.Compression.CompressionLevel]::NoCompression, $false)
    Get-ChildItem $src | Move-Item -Destination $dir
    Remove-Item $src
    [ordered]@{ name = "elspi-image-$FixSha"; size_in_bytes = (Get-Item $zip).Length; digest = "sha256:$(Get-FixHash $zip)"; run_id = [int64] $RunId } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir '.artifact-info.json') -Encoding utf8
    $img = Join-Path $dir 'image_2026-09-26-elspi.img.xz'
    New-OsListJson -Url "file:///$($img -replace '\\','/')" -ImagePath $img -Arch $Arch | Set-Content -LiteralPath (Join-Path $dir 'os_list.json') -Encoding utf8
    return $dir
}

# A Forgejo cache dir: the image and its marker only (flash-test-build does not
# keep the .info); the .info and elspi-commit.txt are served by the fake
# registry below. The package is keyed by the SNAPSHOT commit; the marker's
# elspi_sha is the elspi commit.
function New-ForgejoFixture {
    param([switch] $NoElspiSha)
    $dir = Join-Path $FixRoot "forgejo-$SnapSha"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $bytes = New-Object byte[] 4096
    (New-Object System.Random 7).NextBytes($bytes)
    $img = Join-Path $dir 'image_2026-09-26-elspi.img.xz'
    [System.IO.File]::WriteAllBytes($img, $bytes)
    $m = [ordered]@{ name = 'image_2026-09-26-elspi.img.xz'; size = [int64] 4096; sha256 = (Get-FixHash $img); commit_sha = $SnapSha; elspi_sha = $FixSha; run_id = 42 }
    if ($NoElspiSha) { $m.Remove('elspi_sha') }
    $m | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir '.forgejo-package-info.json') -Encoding utf8
    $global:FjSources = @{
        '2026-09-26-elspi.info' = (Join-Path $FixRoot 'fj-src.info')
        'elspi-commit.txt'      = (Join-Path $FixRoot 'fj-src-elspi-commit.txt')
    }
    [System.IO.File]::WriteAllText($global:FjSources['2026-09-26-elspi.info'], (New-InfoText -Sha $FixSha -Arch 'arm64'))
    [System.IO.File]::WriteAllText($global:FjSources['elspi-commit.txt'], "$FixSha`n")
    return $dir
}

# =============================================================================
# Fakes. State lives in $global: so each case can set it.
# =============================================================================

function Reset-Fakes {
    $global:GhCalls = @()
    $global:GhWrites = @()
    $global:GitWrites = @()
    $global:ReadHostCalls = 0
    $global:Answer = ''
    $global:CommitArch = 'arm64'
    $global:MergeBaseExit = 0
    $global:XzExit = 0
    $global:UsedTags = @('v2026.09.13')
    $global:LatestTag = 'v2026.09.13'
    $global:RunHeadSha = $FixSha
    $global:Release = $null
    $global:RefSha = $null
}

function gh {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $A)
    $global:GhCalls += , ($A -join ' ')
    $global:LASTEXITCODE = 0
    $j = $A -join ' '
    if ($j -eq 'auth status') { return 'Logged in' }
    if ($A[0] -eq 'run' -and $A[1] -eq 'view') {
        return (@{ databaseId = [int64] $A[2]; headBranch = 'arm64'; headSha = $global:RunHeadSha; status = 'completed'; conclusion = 'success'; workflowName = 'image'; event = 'workflow_dispatch' } | ConvertTo-Json)
    }
    if ($A[0] -eq 'release' -and $A[1] -eq 'list') {
        return (ConvertTo-Json -InputObject @($global:UsedTags | ForEach-Object { @{ tagName = $_ } }))
    }
    if ($A[0] -eq 'api' -and $A[1] -like '*/releases/latest') {
        if (-not $global:LatestTag) { $global:LASTEXITCODE = 1; return 'Not Found' }
        return $global:LatestTag
    }
    if ($A[0] -eq 'release' -and $A[1] -eq 'create') {
        $global:GhWrites += , $j
        $files = @($A[([array]::IndexOf($A, '--notes-file') + 2)..($A.Count - 1)])
        $global:Release = [PSCustomObject]@{
            tag_name = $A[2]; draft = $true; prerelease = ($A -contains '--prerelease')
            assets = @($files | ForEach-Object { [PSCustomObject]@{ name = (Split-Path -Leaf $_); size = (Get-Item -LiteralPath $_).Length; digest = "sha256:$(Get-FixHash $_)" } })
        }
        $global:StagedOsList = @($files | Where-Object { $_ -like '*os_list.json' })[0]
        $global:RefSha = $A[([array]::IndexOf($A, '--target') + 1)]
        return 'created'
    }
    if ($A[0] -eq 'api' -and $A[1] -like '*/releases?per_page=100') { return (ConvertTo-Json -InputObject @($global:Release) -Depth 5) }
    if ($A[0] -eq 'release' -and $A[1] -eq 'edit') {
        $global:GhWrites += , $j
        $global:Release.draft = $false
        if ($A -contains '--latest') { $global:LatestTag = $A[2] }
        return 'edited'
    }
    if ($A[0] -eq 'api' -and $A[1] -like '*/git/ref/tags/*') { return (@{ object = @{ type = 'commit'; sha = $global:RefSha } } | ConvertTo-Json) }
    if ($A[0] -eq 'api' -and $A[1] -like '*/releases/tags/*') { return ($global:Release | ConvertTo-Json -Depth 5) }
    $global:GhWrites += , "UNEXPECTED: $j"
    $global:LASTEXITCODE = 99
    return "unexpected gh call: $j"
}

function git {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $A)
    $global:LASTEXITCODE = 0
    $a2 = if ($A[0] -eq '-C') { @($A[2..($A.Count - 1)]) } else { $A }
    switch ($a2[0]) {
        'ls-remote' {
            if ($a2 -contains '--tags') { return @($global:UsedTags | ForEach-Object { "$OtherSha`trefs/tags/$_" }) }
            $ref = $a2[-1]
            return "$('f' * 40)`t$ref"
        }
        'cat-file' { return '' }
        'fetch' { return '' }
        'merge-base' { $global:LASTEXITCODE = $global:MergeBaseExit; return '' }
        'show' {
            if ($a2[1] -like '*:build.sh') { return @('#!/bin/bash', "export ARCH=$global:CommitArch", 'echo') }
            return @('#!/bin/bash', 'echo fake')
        }
        default { $global:GitWrites += , ($A -join ' '); return '' }
    }
}

function wsl { $global:LASTEXITCODE = 0 }
function Read-Host { param($Prompt) $global:ReadHostCalls++; return $global:Answer }
function Invoke-XzTest { param([string] $Path) [PSCustomObject]@{ ExitCode = $global:XzExit; Output = 'fake xz' } }
function Invoke-MakeOsList {
    param([string] $ScriptPath, [string] $ImagePath, [string] $Url, [string] $OutPath)
    New-OsListJson -Url $Url -ImagePath $ImagePath -Arch $global:CommitArch | Set-Content -LiteralPath $OutPath -Encoding utf8
}
function Invoke-ReleaseNotesScript {
    param([string] $ScriptPath, [string] $Tag, [string] $RepoSlug, [string] $OutPath)
    "Flash it: rpi-imager --repo https://github.com/$RepoSlug/releases/download/$Tag/os_list.json" | Set-Content -LiteralPath $OutPath -Encoding utf8
}
function Invoke-AnonymousGet {
    param([string] $Uri, [switch] $RangeProbe)
    if ($RangeProbe) { return 206 }
    return (Get-FixHash $global:StagedOsList)
}
function Invoke-ForgejoApi {
    param([string] $Uri, [hashtable] $Headers)
    $global:FjUris += , $Uri
    $m = Get-Content (Join-Path $global:FjDir '.forgejo-package-info.json') -Raw | ConvertFrom-Json
    return @([PSCustomObject]@{ name = $m.name; Size = $m.size; sha256 = $m.sha256 }) +
        @($global:FjSources.Keys | ForEach-Object { [PSCustomObject]@{ name = $_; Size = (Get-Item $global:FjSources[$_]).Length; sha256 = (Get-FixHash $global:FjSources[$_]) } })
}
function Invoke-ForgejoDownload {
    param([string] $Uri, [hashtable] $Headers, [string] $OutFile)
    $global:FjUris += , $Uri
    Copy-Item -LiteralPath $global:FjSources[[uri]::UnescapeDataString(($Uri -split '/')[-1])] -Destination $OutFile
}

function Invoke-Case {
    param([string] $Dir, [string] $TagArg, [switch] $Pre, [switch] $Dry)
    Invoke-PromoteRelease -CacheDir $Dir -Tag $TagArg -Prerelease ([bool] $Pre) -DryRun ([bool] $Dry) -Dest $FixRoot `
        -RepoRoot $repoRootForTest -Repo $FixRepo -ForgejoUrl 'https://forgejo.example' -ForgejoRepo 'owner/repo' `
        -ForgejoPackage 'pkgowner/pkgname' -ForgejoTokenFile $global:FjToken 6>$null 3>$null
}

$global:FjToken = Join-Path $FixRoot 'token'
Set-Content -LiteralPath $global:FjToken -Value 'faketoken' -NoNewline

try {
    # =========================================================================
    # 1. Green: arm64 dry run. Picks the bare CalVer tag, marks latest, and
    #    creates NOTHING -- even with the confirmation answer primed to say yes.
    # =========================================================================
    Reset-Fakes
    $dir = New-GithubFixture
    $global:Answer = 'v2026.09.26'
    $r = Invoke-Case -Dir $dir -Dry
    Assert-True 'dry run: tag is the image date, bare CalVer for arm64' ($r.Tag -eq 'v2026.09.26') "(got $($r.Tag))"
    Assert-True 'dry run: arm64 is marked latest' ($r.Latest -and ($r.Commands.Publish -contains '--latest') -and ($r.Commands.Publish -contains '--prerelease=false'))
    Assert-True 'dry run: create targets the build commit as a draft' (($r.Commands.Create -join ' ') -match "--target $FixSha --draft")
    Assert-True 'dry run: three assets (image, .info, os_list.json)' ((@($r.Assets | ForEach-Object { $_.name }) -join ',') -eq 'image_2026-09-26-elspi.img.xz,2026-09-26-elspi.info,os_list.json')
    Assert-True 'dry run: no gh write, no git write' (($global:GhWrites.Count -eq 0) -and ($global:GitWrites.Count -eq 0)) "(gh: $($global:GhWrites -join ' | '); git: $($global:GitWrites -join ' | '))"
    Assert-True 'dry run: never asks for confirmation' ($global:ReadHostCalls -eq 0)
    Assert-True 'dry run: not published' (-not $r.Published)

    # Second release of the day gets .1.
    Reset-Fakes
    $global:UsedTags = @('v2026.09.13', 'v2026.09.26')
    $r = Invoke-Case -Dir $dir -Dry
    Assert-True 'tag: a used day gets .1' ($r.Tag -eq 'v2026.09.26.1') "(got $($r.Tag))"

    # =========================================================================
    # 2. Each gate goes red.
    # =========================================================================
    Reset-Fakes
    $dir = New-GithubFixture
    $mk = Join-Path $dir '.artifact-info.json'
    $m = Get-Content $mk -Raw | ConvertFrom-Json
    $m.digest = 'sha256:' + ('0' * 64)
    $m | ConvertTo-Json | Set-Content -LiteralPath $mk -Encoding utf8
    Assert-Throws 'red: zip digest mismatch' { Invoke-Case -Dir $dir -Dry } '[zip digest]'

    Reset-Fakes
    $dir = New-GithubFixture
    $img = Join-Path $dir 'image_2026-09-26-elspi.img.xz'
    $b = [System.IO.File]::ReadAllBytes($img); $b[100] = $b[100] -bxor 0xFF; [System.IO.File]::WriteAllBytes($img, $b)
    Assert-Throws 'red: extracted image is not the zip entry (same size, one byte flipped)' { Invoke-Case -Dir $dir -Dry } '[zip contents]'

    Reset-Fakes
    $dir = New-GithubFixture
    $global:XzExit = 1
    Assert-Throws 'red: xz -t fails' { Invoke-Case -Dir $dir -Dry } '[xz -t]'

    Reset-Fakes
    $dir = New-GithubFixture
    $global:CommitArch = 'armhf'
    Assert-Throws 'red: image .info says arm64, build.sh at its commit says armhf' { Invoke-Case -Dir $dir -Dry } '[arch] the image is arm64'

    Reset-Fakes
    $dir = New-GithubFixture
    Assert-Throws 'red: -Tag with -armhf on an arm64 image' { Invoke-Case -Dir $dir -TagArg 'v2026.09.26-armhf' -Dry } "[arch] tag 'v2026.09.26-armhf'"

    Reset-Fakes
    $dir = New-GithubFixture
    $global:MergeBaseExit = 1
    Assert-Throws 'red: commit is not on arm64' { Invoke-Case -Dir $dir -Dry } '[branch]'

    Reset-Fakes
    $dir = New-GithubFixture
    $global:UsedTags = @('v2026.09.13', 'v2026.09.26')
    Assert-Throws 'red: -Tag that already exists' { Invoke-Case -Dir $dir -TagArg 'v2026.09.26' -Dry } '[tag] v2026.09.26 already exists'

    Reset-Fakes
    $dir = New-GithubFixture
    $global:RunHeadSha = $OtherSha
    Assert-Throws 'red: the run built a different commit' { Invoke-Case -Dir $dir -Dry } '[build sha]'

    Reset-Fakes
    $dir = New-GithubFixture
    $bench = Join-Path $dir 'os_list.json'
    (Get-Content $bench -Raw) -replace ('e' * 64), ('d' * 64) | Set-Content -LiteralPath $bench -Encoding utf8
    Assert-Throws 'red: release os_list disagrees with the bench os_list' { Invoke-Case -Dir $dir -Dry } '[os_list] extract_sha256'

    # =========================================================================
    # 3. armhf is never latest.
    # =========================================================================
    Reset-Fakes
    $dir = New-GithubFixture -Arch armhf
    $global:CommitArch = 'armhf'
    $r = Invoke-Case -Dir $dir -Dry
    Assert-True 'armhf: tag carries -armhf' ($r.Tag -eq 'v2026.09.26-armhf') "(got $($r.Tag))"
    Assert-True 'armhf: dry run is not latest' ((-not $r.Latest) -and ($r.Commands.Publish -contains '--latest=false') -and -not ($r.Commands.Publish -contains '--latest'))

    Reset-Fakes
    $dir = New-GithubFixture -Arch armhf
    $global:CommitArch = 'armhf'
    $global:Answer = 'v2026.09.26-armhf'
    $r = Invoke-Case -Dir $dir
    $bare = @($global:GhWrites | Where-Object { ($_ -split ' ') -contains '--latest' })
    Assert-True 'armhf: a real publish sends no --latest' ($r.Published -and $bare.Count -eq 0 -and $global:LatestTag -eq 'v2026.09.13') "(writes: $($global:GhWrites -join ' | '))"

    $bad = [PSCustomObject]@{ Latest = $true; Create = @('release', 'create'); Publish = @('release', 'edit', '--latest') }
    Assert-Throws 'armhf: Assert-NeverLatestArmhf refuses a --latest argument list' { Assert-NeverLatestArmhf -Commands $bad -Arch 'armhf' -Prerelease $false } '[latest]'

    # =========================================================================
    # 4. Real publish (faked gh), prerelease, abort, read-back.
    # =========================================================================
    Reset-Fakes
    $dir = New-GithubFixture
    $global:Answer = 'v2026.09.26'
    $r = Invoke-Case -Dir $dir
    Assert-True 'publish: draft created, then published latest' ($r.Published -and $global:GhWrites.Count -eq 2 -and $global:GhWrites[0] -match '^release create v2026.09.26 .*--draft' -and $global:GhWrites[1] -match '--latest$' -and $global:LatestTag -eq 'v2026.09.26') "(writes: $($global:GhWrites -join ' | '))"

    Reset-Fakes
    $dir = New-GithubFixture
    $global:Answer = 'y'
    $r = Invoke-Case -Dir $dir
    Assert-True 'publish: anything but the tag aborts with nothing sent' ((-not $r.Published) -and $global:GhWrites.Count -eq 0 -and $global:ReadHostCalls -eq 1)

    Reset-Fakes
    $dir = New-GithubFixture
    $r = Invoke-Case -Dir $dir -Pre -Dry
    Assert-True 'prerelease: not latest, created with --prerelease' ((-not $r.Latest) -and ($r.Commands.Create -contains '--prerelease') -and -not ($r.Commands.Publish -contains '--latest'))

    Reset-Fakes
    $dir = New-GithubFixture
    $global:Answer = 'v2026.09.26'
    function Invoke-AnonymousGet { param([string] $Uri, [switch] $RangeProbe) if ($RangeProbe) { return 206 }; return ('0' * 64) }
    Assert-Throws 'read-back: a served os_list.json that differs is caught, and says it IS published' { Invoke-Case -Dir $dir } 'IS published'
    function Invoke-AnonymousGet { param([string] $Uri, [switch] $RangeProbe) if ($RangeProbe) { return 206 }; return (Get-FixHash $global:StagedOsList) }

    # =========================================================================
    # 5. Forgejo cache.
    # =========================================================================
    Reset-Fakes
    $global:FjUris = @()
    $global:FjDir = New-ForgejoFixture
    $r = Invoke-Case -Dir $global:FjDir -Dry
    Assert-True 'forgejo: dry run fetches the .info and picks the tag' ($r.Tag -eq 'v2026.09.26' -and (Test-Path (Join-Path $global:FjDir '2026-09-26-elspi.info')) -and $global:GhWrites.Count -eq 0)
    Assert-True 'forgejo: --target is the ELSPI commit, never the snapshot' ($r.Sha -eq $FixSha -and $r.Commands.Create[[array]::IndexOf($r.Commands.Create, '--target') + 1] -eq $FixSha) "(target: $($r.Commands.Create[[array]::IndexOf($r.Commands.Create, '--target') + 1]))"
    Assert-True 'forgejo: the registry is read by the SNAPSHOT (package) sha' (@($global:FjUris | Where-Object { $_ -match "/$SnapSha/" }).Count -ge 2 -and @($global:FjUris | Where-Object { $_ -match $FixSha }).Count -eq 0) "(uris: $($global:FjUris -join ' | '))"

    Reset-Fakes
    $global:FjDir = New-ForgejoFixture -NoElspiSha
    Assert-Throws 'red: forgejo marker without elspi_sha is refused' { Invoke-Case -Dir $global:FjDir -Dry } 'has no elspi_sha'

    Reset-Fakes
    $global:FjDir = New-ForgejoFixture
    [System.IO.File]::WriteAllText($global:FjSources['elspi-commit.txt'], "$OtherSha`n")
    Assert-Throws "red: the package's elspi-commit.txt disagrees with the marker" { Invoke-Case -Dir $global:FjDir -Dry } 'elspi-commit.txt says'

    Reset-Fakes
    $global:FjDir = New-ForgejoFixture
    $img = Join-Path $global:FjDir 'image_2026-09-26-elspi.img.xz'
    $b = [System.IO.File]::ReadAllBytes($img); $b[10] = $b[10] -bxor 0xFF; [System.IO.File]::WriteAllBytes($img, $b)
    Assert-Throws 'red: forgejo image does not match its marker' { Invoke-Case -Dir $global:FjDir -Dry } '[forgejo digest]'

    # =========================================================================
    # 6. Resolving the cache dir.
    # =========================================================================
    $null = New-GithubFixture
    Assert-True '-RunId resolves to <Dest>\<run-id>' ((Resolve-PromoteCacheDir -RunId '555' -Dest $FixRoot) -eq (Join-Path $FixRoot '555'))
    Assert-True '-Sha finds a Forgejo cache by its snapshot sha' ((Resolve-PromoteCacheDir -Sha $SnapSha -Dest $FixRoot) -eq $global:FjDir)
    Assert-Throws '-Sha held by both a GitHub and a Forgejo cache is ambiguous' { Resolve-PromoteCacheDir -Sha $FixSha -Dest $FixRoot } '2 cache directories'
} finally {
    Remove-Item -Recurse -Force -LiteralPath $FixRoot -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:total - $script:failures)/$($script:total) passed"
if ($script:failures -gt 0) { exit 1 }
exit 0
