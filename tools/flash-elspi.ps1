# Launch Raspberry Pi Imager on the elspi OS-list repository.
#
#   tools\flash-elspi.ps1                      # deploy\os_list.json in this repo
#   tools\flash-elspi.ps1 D:\cards\os_list.json
#   tools\flash-elspi.ps1 https://example.com/elspi/os_list.json
#
# WHY A LAUNCHER AND NOT "just open Imager"
#
# Imager 2.x never offers OS customisation for a "Use custom" local image --
# see tools/make-os-list.sh's header for the QML call chain -- so picking
# deploy\image_*.img.xz off the disk yields an UNSEEDED card. The seed arrives
# only through an OS-list entry declaring init_format "cloudinit-rpi", handed to
# Imager as `--repo`. That is all this script does: find Imager, check it is 2.x,
# pass the JSON.
#
# What the operator sees: Imager opens with exactly ONE OS entry (this image),
# the normal Device and Storage steps, and then the customisation page.
# docs/flashing.md says what to type on it, and what each field becomes.
#
# NOTE: rpi-imager.exe requests elevation in its manifest, so Windows shows a
# UAC prompt when it starts. That is Imager, not this script, and it is also why
# the version is read from the file's VersionInfo rather than by running
# `rpi-imager --version` -- that would raise UAC just to print a number.
#
# -CheckOnly (added for tools/flash-test-build.ps1): run just the "find Imager,
# check it is 2.x" half below, print what was found, and return -- without
# touching $Repo or calling Start-Process. That lets a caller fail on a
# missing/old Imager before it spends a ~1 GB download, while still reusing
# this file's own detection logic instead of a second copy of it.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Repo,

    [switch] $CheckOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $CheckOnly) {
    # --- the JSON (or URL) ---------------------------------------------------
    if (-not $Repo) { $Repo = Join-Path $repoRoot 'deploy\os_list.json' }

    if ($Repo -notmatch '^https?://') {
        if (-not (Test-Path -LiteralPath $Repo -PathType Leaf)) {
            Write-Host @"
No OS-list JSON at: $Repo

It is written by the build, next to the image:
    ./build-elspi.sh          ->  deploy/os_list.json
or by hand, for an image you already have:
    tools/make-os-list.sh <image.img.xz> --out <path>\os_list.json
"@
            exit 1
        }
        $Repo = (Resolve-Path -LiteralPath $Repo).Path
    }
}

# --- find Imager ------------------------------------------------------------
$exe = $null

$uninstall = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$entry = Get-ItemProperty $uninstall -ErrorAction SilentlyContinue |
         Where-Object { $_.DisplayName -eq 'Raspberry Pi Imager' -and $_.InstallLocation } |
         Select-Object -First 1
if ($entry) {
    $candidate = Join-Path $entry.InstallLocation 'rpi-imager.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $exe = $candidate }
}

if (-not $exe) {
    $default = 'C:\Program Files\Raspberry Pi Ltd\Imager\rpi-imager.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf) { $exe = $default }
}

if (-not $exe) {
    Write-Host @"
Raspberry Pi Imager was not found (no "Raspberry Pi Imager" uninstall entry with
an InstallLocation, and nothing at the default path).

Install 2.x from https://www.raspberrypi.com/software/
"@
    exit 1
}

# --- check it is 2.x --------------------------------------------------------
# The installed 2.0.11.1 reports ProductVersion as "v2.0.11.1" -- leading "v".
$raw = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
$version = $null
if ($raw -and ($raw -match '(\d+)\.(\d+)')) {
    $version = [version] ("{0}.{1}" -f $Matches[1], $Matches[2])
}

if (-not $version) {
    Write-Host "Could not read a version out of ${exe} (ProductVersion = '$raw'). Refusing to guess."
    exit 1
}

if ($version -lt [version] '2.0') {
    Write-Host @"
$exe reports version $raw. This image needs Imager 2.0 or newer.

1.x accepts --repo, so it will LOOK like it worked -- but its customisation page
seeds a card through firstrun.sh / userconf.txt, and this image never reads
those: its first boot is cloud-init, fed from user-data / network-config /
meta-data on the FAT partition. On 1.x you get an unseeded card: no password, no
key, no Wi-Fi, no country -- and, since the image carries no SSH key of its own,
no SSH way in at all.

Install 2.x from https://www.raspberrypi.com/software/
"@
    exit 1
}

if ($CheckOnly) {
    Write-Host "Imager:  $exe ($raw)"
    exit 0
}

# --- go ---------------------------------------------------------------------
Write-Host "Imager:  $exe ($raw)"
Write-Host "Repo:    $Repo"
Write-Host "Expect ONE OS entry, then Device, Storage, and the customisation page."
Write-Host "On that page: username 'default', and a PASSWORD and/or an SSH PUBLIC KEY."
Write-Host "The image is keyless -- with neither, the card has no SSH way in (touchscreen only)."
Write-Host "(Imager asks for administrator rights -- it writes raw disks.)"

Start-Process -FilePath $exe -ArgumentList @('--repo', $Repo) | Out-Null
