#!/bin/bash
# Write an OS-list repository JSON describing ONE image: ours.
#
#   tools/make-os-list.sh <image.img.xz> [--url <https-or-file-url>] [--out <path>]
#
# Linux/WSL bash, no root, no network.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
#
# Raspberry Pi Imager 2.x NEVER offers OS customisation for a "Use custom"
# local image. `src/wizard/OSSelectionStep.qml` calls `setSrc(fileUrl)` with
# the default `initFormat` of "" (`src/imagewriter.h`), so
# `imageSupportsCustomization()` is false and `WizardContainer.qml` skips every
# customisation step. Picking our .img.xz off the disk therefore gets you an
# UNSEEDED card -- no password, no key, no Wi-Fi, no country -- and
# `stage-elspi/12-first-boot-seed` has nothing to consume.
#
# Imager DOES offer customisation for an entry in an OS-list repository that
# declares `init_format` "cloudinit-rpi", and it accepts a custom repository on
# the command line: `--repo <url-or-file>` (`src/main.cpp`, "Custom OS list
# repository URL or local file"; a non-http value is passed through
# `QUrl::fromLocalFile`). So the supported flash path for this image is a
# one-entry repository plus `--repo`, which is what this script writes and what
# `tools/flash-elspi.ps1` / `tools/flash-elspi.sh` launch.
#
# ---------------------------------------------------------------------------
# WHY THERE IS AN "imager" BLOCK, AND WHERE IT CAME FROM
#
# `tools/os_list.imager-block.json` is a committed snapshot of the `imager`
# object from the official list,
#
#     https://downloads.raspberrypi.com/os_list_imagingutility_v4.json
#
# fetched 2026-09-13, reduced to the three keys that matter
# (`latest_version`, `url`, `devices`). It is embedded verbatim below.
#
# It is here because THE DEVICE STEP READS IT. The device chooser Imager opens
# on is populated from `imager.devices`; a repository without that block gives
# a Device page with nothing on it, and our entry's `devices` tags
# (`pi4-64bit`, ...) then have nothing to match against. It is a snapshot
# rather than a fetch so that flashing works with no network and cannot change
# under us between two flashes of the same image.
#
# ---------------------------------------------------------------------------
# WHAT IT MEASURES, AND IN HOW MANY PASSES
#
# `extract_size` / `extract_sha256` describe the 7.5 GB UNCOMPRESSED image.
# Imager verifies against them as it writes, so they have to be right, and the
# decompressed bytes must never touch the disk to get them. The pipeline below
# reads the .xz ONCE and pushes the decompressed stream past `sha256sum` and
# `wc -c` together, via `tee` + process substitution -- so the .xz is hashed in
# the same read, and nothing anywhere is written but the four small results.
#
# One wrinkle worth naming: a `tee >(...)` child is NOT reaped by the pipeline
# it belongs to, so its output file can still be incomplete when the pipeline
# returns. Each child therefore writes `<x>.part` and renames, and this script
# WAITS for the final names -- and fails if they never appear. Polling for a
# file that a race could leave missing is a gate; reading the file straight
# after the pipeline would be a check that cannot fail.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="${HERE}/os_list.imager-block.json"

IMG=""
URL=""
OUT=""

usage() {
	sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--url) [ "$#" -ge 2 ] || { echo "FATAL: --url needs a value"; exit 2; }; URL="$2"; shift 2 ;;
		--out) [ "$#" -ge 2 ] || { echo "FATAL: --out needs a value"; exit 2; }; OUT="$2"; shift 2 ;;
		-h|--help) usage ;;
		-*) echo "FATAL: unknown option $1"; usage ;;
		*) [ -z "${IMG}" ] || { echo "FATAL: more than one image given"; exit 2; }; IMG="$1"; shift ;;
	esac
done

# --- gate: the tools, before anything slow --------------------------------
PY=""
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "${PY}" ] || { echo "FATAL: no python3 on PATH -- needed to write and re-parse the JSON"; exit 1; }
for c in xz sha256sum tee wc; do
	command -v "$c" >/dev/null 2>&1 || { echo "FATAL: ${c} not on PATH"; exit 1; }
done
[ -r "${BLOCK}" ] || { echo "FATAL: missing the committed imager block: ${BLOCK}"; exit 1; }

# --- gate: the image ------------------------------------------------------
[ -n "${IMG}" ] || usage
[ -f "${IMG}" ] || { echo "FATAL: no such image file: ${IMG}"; exit 1; }
[ -r "${IMG}" ] || { echo "FATAL: image is not readable: ${IMG}"; exit 1; }
IMG_ABS="$(cd "$(dirname "${IMG}")" && pwd)/$(basename "${IMG}")"
case "${IMG_ABS}" in
	*.img.xz) ;;
	*) echo "FATAL: expected an .img.xz, got ${IMG_ABS}"; exit 1 ;;
esac
xz -t -- "${IMG_ABS}" || { echo "FATAL: ${IMG_ABS} does not pass 'xz -t'"; exit 1; }

[ -n "${OUT}" ] || OUT="$(dirname "${IMG_ABS}")/os_list.json"

# --- release date, from the image name, else its mtime --------------------
BASE="$(basename "${IMG_ABS}")"
RELEASE_DATE="$(printf '%s\n' "${BASE}" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true)"
[ -n "${RELEASE_DATE}" ] || RELEASE_DATE="$(date -u -r "${IMG_ABS}" +%Y-%m-%d)"
printf '%s\n' "${RELEASE_DATE}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
	|| { echo "FATAL: could not work out a YYYY-MM-DD release date for ${BASE}"; exit 1; }

# --- the build sha, from the sibling .info if there is one ----------------
# export-image/05-finalise/01-run.sh copies /etc/rpi-issue to <img>.info, and
# scripts/common's update_issue() writes line 2 as
#     Generated using <PI_GEN>, <PI_GEN_REPO>, <GIT_HASH>, <stage>
# so the pi-gen commit is the third comma-separated field of line 2.
INFO="$(dirname "${IMG_ABS}")/${BASE#image_}"
INFO="${INFO%.img.xz}.info"
BUILD_SHA=""
if [ -r "${INFO}" ]; then
	BUILD_SHA="$(sed -n '2p' "${INFO}" | awk -F', *' '{print $3}' | tr -d '[:space:]')"
	printf '%s\n' "${BUILD_SHA}" | grep -Eq '^[0-9a-f]{7,40}$' || BUILD_SHA=""
	[ -n "${BUILD_SHA}" ] || echo "note: ${INFO} line 2 field 3 is not a commit sha; leaving it out of the name"
else
	echo "note: no sibling .info at ${INFO}; leaving the build sha out of the name"
fi
SHORT_SHA="${BUILD_SHA:0:7}"

# --- the url --------------------------------------------------------------
# Default is a file:// URL for the image where it sits now, which is what makes
# `--repo` work off a local card-flashing machine with no release published.
# --url is for a published release (https://...), where the same JSON is served
# next to the image.
if [ -z "${URL}" ]; then
	URL="$("${PY}" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "${IMG_ABS}")"
	# A file:// URL is only ever usable on the machine that built it -- WSL's
	# /mnt/c/... case (below) is one instance of that, but so is a plain
	# /home/... path on a Linux build box: it opens fine in a browser on that
	# same box and fails everywhere else, including in rpi-imager on any other
	# machine, with nothing more specific than "download failed" / "not found".
	# So this fires for every default URL, not only the WSL shape.
	echo "NOTE: no --url given; the url field below is a file:// URL for THIS"
	echo "  machine only ($(hostname 2>/dev/null || echo "this host")):"
	echo "      ${URL}"
	echo "  A file:// URL is not portable -- rpi-imager on any other machine cannot"
	echo "  open it and will fail with something like 'not found: <path>'. Re-run"
	echo "  with --url once you know where this image and this JSON will actually"
	echo "  be served from, e.g. a published release:"
	echo "      --url https://github.com/<org>/<repo>/releases/download/<tag>/os_list.json"
	# Under WSL a Windows image is at /mnt/c/... and the file:// URL built from
	# it is a path only WSL can resolve -- Imager.exe, which is the thing that
	# will read this JSON, cannot open it and says only that the download
	# failed. Measuring here is fine; the URL is not.
	case "${IMG_ABS}" in
		/mnt/[a-z]/*)
			drive="$(printf '%s' "${IMG_ABS}" | cut -d/ -f3 | tr '[:lower:]' '[:upper:]')"
			winpath="/${drive}:/$(printf '%s' "${IMG_ABS}" | cut -d/ -f4-)"
			echo "  This looks like a Windows path seen from WSL: rpi-imager.exe cannot"
			echo "  resolve ${URL} at all (not even 'wrong machine' -- WSL's /mnt is"
			echo "  invisible to it). For a flash from Windows, re-run with:"
			echo "      --url file://${winpath}"
			;;
	esac
fi
case "${URL}" in
	http://*|https://*|file://*) ;;
	*) echo "FATAL: --url must be http://, https:// or file:// -- got ${URL}"; exit 1 ;;
esac

# --- measure ---------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "measuring ${BASE} (one read of the .xz, one pass over the decompressed stream)..."
# shellcheck disable=SC2094  # distinct fds: the < redirect reads, the >() write
< "${IMG_ABS}" tee >( sha256sum | cut -d' ' -f1 > "${WORK}/xz.sha.part" \
                        && mv "${WORK}/xz.sha.part" "${WORK}/xz.sha" ) \
                 >( wc -c > "${WORK}/xz.size.part" \
                        && mv "${WORK}/xz.size.part" "${WORK}/xz.size" ) \
	| xz -dc \
	| tee >( sha256sum | cut -d' ' -f1 > "${WORK}/raw.sha.part" \
	                       && mv "${WORK}/raw.sha.part" "${WORK}/raw.sha" ) \
	| wc -c > "${WORK}/raw.size"

# See the header: tee's process-substitution children outlive the pipeline.
for f in xz.sha xz.size raw.sha; do
	n=0
	while [ ! -s "${WORK}/${f}" ]; do
		n=$((n+1))
		[ "${n}" -le 600 ] || { echo "FATAL: ${f} never appeared -- a tee child did not finish"; exit 1; }
		sleep 0.1
	done
done

XZ_SHA="$(tr -d '[:space:]' < "${WORK}/xz.sha")"
XZ_SIZE="$(tr -d '[:space:]' < "${WORK}/xz.size")"
RAW_SHA="$(tr -d '[:space:]' < "${WORK}/raw.sha")"
RAW_SIZE="$(tr -d '[:space:]' < "${WORK}/raw.size")"

for v in XZ_SHA RAW_SHA; do
	printf '%s\n' "${!v}" | grep -Eq '^[0-9a-f]{64}$' \
		|| { echo "FATAL: ${v} is not a sha256: ${!v}"; exit 1; }
done
for v in XZ_SIZE RAW_SIZE; do
	printf '%s\n' "${!v}" | grep -Eq '^[1-9][0-9]*$' \
		|| { echo "FATAL: ${v} is not a positive byte count: ${!v}"; exit 1; }
done
# A real pi image compresses about 5.5x, so this is worth SAYING -- but it is
# not a gate: incompressible input (a test fixture of /dev/urandom) legitimately
# comes out bigger than it went in, and a genuinely truncated .xz stream fails
# `xz -t` and `xz -dc` above instead.
if [ "${RAW_SIZE}" -le "${XZ_SIZE}" ]; then
	echo "note: decompressed ${RAW_SIZE} <= compressed ${XZ_SIZE} -- not a pi-gen image?"
fi
# The bytes that went past tee must be the bytes on disk. stat, not another
# read: the point of the pipeline above is that the file is read exactly once.
DISK_SIZE="$(stat -c %s "${IMG_ABS}")"
[ "${XZ_SIZE}" = "${DISK_SIZE}" ] \
	|| { echo "FATAL: streamed ${XZ_SIZE} bytes but ${IMG_ABS} is ${DISK_SIZE}"; exit 1; }

# --- write ----------------------------------------------------------------
NAME="elspi ${RELEASE_DATE}"
[ -z "${SHORT_SHA}" ] || NAME="${NAME} (${SHORT_SHA})"

"${PY}" - "${BLOCK}" "${OUT}" "${NAME}" "${URL}" "${RELEASE_DATE}" \
        "${RAW_SIZE}" "${RAW_SHA}" "${XZ_SIZE}" "${XZ_SHA}" <<'PY'
import collections
import json
import pathlib
import sys

block, out, name, url, date, raw_size, raw_sha, xz_size, xz_sha = sys.argv[1:10]

imager = json.loads(pathlib.Path(block).read_text(encoding="utf-8"),
                    object_pairs_hook=collections.OrderedDict)

entry = collections.OrderedDict((
    ("name", name),
    ("description",
     "Reflex ELS appliance image, Debian trixie arm64. On the next pages: "
     "user 'default', a password and/or an SSH key (at least one), Wi-Fi and its country."),
    ("url", url),
    ("release_date", date),
    ("extract_size", int(raw_size)),
    ("extract_sha256", raw_sha),
    ("image_download_size", int(xz_size)),
    ("image_download_sha256", xz_sha),
    # The one key this whole file exists for: it is what makes Imager 2.x
    # show the customisation pages at all.
    ("init_format", "cloudinit-rpi"),
    # 64-bit only, on the arm64 branch (the branch is the architecture,
    # docs/design/fork.md). This is an arm64 image: a 32bit tag here would
    # offer it for a Pi 1/2/Zero whose CPU cannot run it. Same three tags
    # Raspberry Pi OS (64-bit) carries.
    ("devices", ["pi5-64bit", "pi4-64bit", "pi3-64bit"]),
))

doc = collections.OrderedDict((("imager", imager), ("os_list", [entry])))
p = pathlib.Path(out)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8", newline="\n")

# --- gate: re-read what was written, do not trust what was built ----------
back = json.loads(p.read_text(encoding="utf-8"))
required = ("name", "description", "url", "release_date", "extract_size",
            "extract_sha256", "image_download_size", "image_download_sha256",
            "init_format", "devices")
if len(back.get("os_list", [])) != 1:
    raise SystemExit("FATAL: %s does not carry exactly one os_list entry" % p)
got = back["os_list"][0]
missing = [k for k in required if k not in got or got[k] in ("", None, [])]
if missing:
    raise SystemExit("FATAL: entry is missing %s" % ", ".join(missing))
if got["init_format"] != "cloudinit-rpi":
    raise SystemExit("FATAL: init_format is %r, not cloudinit-rpi -- Imager would "
                     "skip every customisation page" % got["init_format"])
if not back.get("imager", {}).get("devices"):
    raise SystemExit("FATAL: the imager block has no devices -- the Device step "
                     "would come up empty")

print("wrote %s" % p)
print(json.dumps(got, indent=2))
PY

echo "OK: ${OUT}"
