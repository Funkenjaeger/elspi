#!/bin/bash
# Print the markdown block for one release's GitHub release page.
#
#   tools/release-notes.sh <tag> [--repo-slug owner/name]
#
# bash, no network, writes only to stdout.
#
# ---------------------------------------------------------------------------
# WHY PINNED, NOT /latest/
#
# README.md and docs/flashing.md use
# .../releases/latest/download/os_list.json -- GitHub's stable redirect to
# whichever release is newest, right for a reader who always wants "the
# current one". A single release's page describes ONE fixed release, so the
# commands on it pin the tag instead:
# .../releases/download/<tag>/os_list.json. Both forms are redirects Imager
# follows (see docs/flashing.md); pinning here just means the commands on
# THIS page keep flashing THIS release even after a newer one ships.
#
# ---------------------------------------------------------------------------
# THE os_list.json THIS ASSUMES
#
# The os_list.json attached to this release must have been generated with
#
#     tools/make-os-list.sh <image>.img.xz \
#         --url https://github.com/<slug>/releases/download/<tag>/image_<date>-elspi.img.xz
#
# so the URL INSIDE the JSON -- the one Imager actually downloads the image
# from -- is this same pinned release asset, not a local file:// path or
# someone's build machine. make-os-list.sh does not know about GitHub
# releases or this script; getting that --url right when the release is cut
# is on whoever runs it, not something this script can check from here.
#
# No release CI exists yet -- this script is run BY HAND when cutting a
# release and its output is pasted into the GitHub release page. The pi-gen
# release-automation item on the Open Loops heap tracks adding that.

set -euo pipefail

REPO_SLUG="Funkenjaeger/elspi"
TAG=""

usage() {
	sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--repo-slug) [ "$#" -ge 2 ] || { echo "FATAL: --repo-slug needs a value" >&2; exit 2; }; REPO_SLUG="$2"; shift 2 ;;
		-h|--help) usage ;;
		-*) echo "FATAL: unknown option $1" >&2; usage ;;
		*) [ -z "${TAG}" ] || { echo "FATAL: more than one tag given" >&2; exit 2; }; TAG="$1"; shift ;;
	esac
done

# --- gate: a real tag, a real slug -----------------------------------------
[ -n "${TAG}" ] || { echo "FATAL: a release tag is required" >&2; usage; }
case "${REPO_SLUG}" in
	*/*) ;;
	*) echo "FATAL: --repo-slug must be owner/name, got '${REPO_SLUG}'" >&2; exit 2 ;;
esac

PINNED_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/os_list.json"

# --- write ------------------------------------------------------------------
cat <<MD
## Flashing this release

Raspberry Pi Imager 2.x from raspberrypi.com is required — distro packages
ship 1.x, which seeds a card via \`firstrun.sh\`, and this image ignores that
file entirely. Imager downloads and verifies the image itself; nothing is
downloaded by hand. Take the one OS entry it offers, then fill in the
customisation page (user \`default\`, public-key SSH only, Wi-Fi, country US)
— see FLASH-SESSION.md for what each field means and why.

**Windows**, from Win+R, cmd or PowerShell alike:

    cmd /c start rpi-imager --repo ${PINNED_URL}

**Linux**:

    rpi-imager --repo ${PINNED_URL}

**This release must carry three assets:** \`image_<date>-elspi.img.xz\`,
\`os_list.json\`, and \`<date>-elspi.info\`.
MD
