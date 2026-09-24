#!/bin/bash
# Launch Raspberry Pi Imager on the elspi OS-list repository.
#
#   tools/flash-elspi.sh                              # deploy/os_list.json
#   tools/flash-elspi.sh /cards/os_list.json
#   tools/flash-elspi.sh https://example.com/elspi/os_list.json
#   tools/flash-elspi.sh ./rpi-imager_2.0.11_amd64.AppImage [repo]
#
# WHY A LAUNCHER AND NOT "just open Imager"
#
# Imager 2.x never offers OS customisation for a "Use custom" local image -- see
# tools/make-os-list.sh's header for the QML call chain -- so picking
# deploy/image_*.img.xz off the disk yields an UNSEEDED card. The seed arrives
# only through an OS-list entry declaring init_format "cloudinit-rpi", handed to
# Imager as `--repo`. That is all this script does: find Imager, check it is 2.x,
# pass the JSON.
#
# What the operator sees: Imager opens with exactly ONE OS entry (this image),
# the normal Device and Storage steps, and then the customisation page.
# docs/flashing.md says what to type on it, and what each field becomes.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

IMAGER=""
OSLIST=""

for arg in "$@"; do
	case "${arg}" in
		*.AppImage|*.appimage)
			[ -z "${IMAGER}" ] || { echo "FATAL: more than one AppImage given"; exit 2; }
			IMAGER="${arg}" ;;
		*)
			[ -z "${OSLIST}" ] || { echo "FATAL: more than one OS list given"; exit 2; }
			OSLIST="${arg}" ;;
	esac
done

# --- the JSON (or URL) ------------------------------------------------------
[ -n "${OSLIST}" ] || OSLIST="${REPO_ROOT}/deploy/os_list.json"
case "${OSLIST}" in
	http://*|https://*) ;;
	*)
		if [ ! -f "${OSLIST}" ]; then
			echo "FATAL: no OS-list JSON at ${OSLIST}"
			echo
			echo "It is written by the build, next to the image:"
			echo "    ./build-elspi.sh          ->  deploy/os_list.json"
			echo "or by hand, for an image you already have:"
			echo "    tools/make-os-list.sh <image.img.xz> --out <dir>/os_list.json"
			exit 1
		fi
		OSLIST="$(cd "$(dirname "${OSLIST}")" && pwd)/$(basename "${OSLIST}")" ;;
esac

# --- find Imager ------------------------------------------------------------
# Packaged first (apt/dnf/flatpak wrapper on PATH), then an AppImage: named on
# the command line, else the newest one sitting in the current directory, which
# is where a freshly downloaded one lands.
if [ -z "${IMAGER}" ]; then
	if command -v rpi-imager >/dev/null 2>&1; then
		IMAGER="$(command -v rpi-imager)"
	else
		IMAGER="$(ls -t ./*.AppImage ./*.appimage 2>/dev/null | head -n1 || true)"
	fi
fi

if [ -z "${IMAGER}" ]; then
	echo "FATAL: no rpi-imager on PATH and no *.AppImage here."
	echo "  Install 2.x, or download the AppImage, from https://www.raspberrypi.com/software/"
	echo "  then:  tools/flash-elspi.sh ./rpi-imager_*.AppImage"
	exit 1
fi
[ -f "${IMAGER}" ] || { echo "FATAL: ${IMAGER} is not a file"; exit 1; }
[ -x "${IMAGER}" ] || { echo "FATAL: ${IMAGER} is not executable (chmod +x it)"; exit 1; }

# --- check it is 2.x --------------------------------------------------------
# `rpi-imager --version` is the honest source, but it is a GUI binary: if the
# build ignores the flag it opens a window instead of printing, so it runs under
# a timeout and anything that does not print a version in 5s counts as "did not
# answer". For an AppImage the file name carries the version, which is the
# documented fallback; a packaged binary that will not say has no fallback and
# is REFUSED rather than assumed good.
VERSION=""
SOURCE=""
if RAW="$(timeout 5 "${IMAGER}" --version 2>/dev/null)"; then
	# -o prints every match on its own line and -m1 caps LINES, not matches,
	# so "v2.0.11.1" yields two: head -n1 is what keeps this a single number.
	VERSION="$(printf '%s\n' "${RAW}" | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
	[ -z "${VERSION}" ] || SOURCE="--version"
fi
if [ -z "${VERSION}" ]; then
	VERSION="$(basename "${IMAGER}" | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
	[ -z "${VERSION}" ] || SOURCE="file name"
fi

if [ -z "${VERSION}" ]; then
	if [ "${ELSPI_SKIP_IMAGER_VERSION_CHECK:-0}" = "1" ]; then
		echo "WARNING: ${IMAGER}'s version is UNKNOWN and the check was skipped."
		echo "  If this is 1.x the card will look seeded and will not be."
		VERSION="0.0"; SOURCE="UNVERIFIED"
	else
		echo "FATAL: ${IMAGER} did not print a version and its name carries none."
		echo "  Refusing to guess: on 1.x this flashes a card that looks seeded and is not."
		echo "  Check it yourself with 'rpi-imager --version'. To proceed anyway:"
		echo "      ELSPI_SKIP_IMAGER_VERSION_CHECK=1 tools/flash-elspi.sh ..."
		exit 1
	fi
fi

MAJOR="${VERSION%%.*}"
if [ "${SOURCE}" != "UNVERIFIED" ] && [ "${MAJOR}" -lt 2 ]; then
	cat <<EOF
FATAL: ${IMAGER} reports version ${VERSION} (from ${SOURCE}).
This image needs Imager 2.0 or newer.

1.x accepts --repo, so it will LOOK like it worked -- but its customisation page
seeds a card through firstrun.sh / userconf.txt, and this image never reads
those: its first boot is cloud-init, fed from user-data / network-config /
meta-data on the FAT partition. On 1.x you get an unseeded card: no password, no
key, no Wi-Fi, no country -- and, since the image carries no SSH key of its own,
no SSH way in at all.

Install 2.x from https://www.raspberrypi.com/software/
EOF
	exit 1
fi

# --- go ---------------------------------------------------------------------
echo "Imager:  ${IMAGER} (version ${VERSION}, from ${SOURCE})"
echo "Repo:    ${OSLIST}"
echo "Expect ONE OS entry, then Device, Storage, and the customisation page."
echo "On that page: username 'default', and a PASSWORD and/or an SSH PUBLIC KEY."
echo "The image is keyless -- with neither, the card has no SSH way in (touchscreen only)."

exec "${IMAGER}" --repo "${OSLIST}"
