#!/bin/bash
# Print the markdown block for one release's GitHub release page.
#
#   tools/release-notes.sh <tag> [--repo-slug owner/name]
#
# bash, no network, writes only to stdout.
#
# ---------------------------------------------------------------------------
# BRIEF, AND DELIBERATELY SO (2026-09-13)
#
# This used to print the flashing instructions -- which version of Imager, what
# each field on the customisation page means, why the country matters. It was a
# second copy of docs/flashing.md living on a page nobody edits again after the
# release is cut, so the two could only drift, and the release page is the copy
# a stranger finds first.
#
# So the output is now four things and nothing more: one sentence, the two
# PINNED commands, a link to docs/flashing.md AT THE TAG, and the
# required-assets line. tests/test-release-notes.sh enforces an upper bound on
# the length and the absence of the retired prose, so this cannot grow back by
# accident.
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
# The docs link is pinned the same way, to /blob/<tag>/docs/flashing.md rather
# than /blob/main/. A reader who lands on an old release should get the
# instructions that shipped WITH that image, not today's -- the fields on the
# customisation page and what consumes them are properties of the image.
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
# release and its output is pasted into the GitHub release page. Automating
# that into CI is a known gap, not yet built.

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
DOCS_URL="https://github.com/${REPO_SLUG}/blob/${TAG}/docs/flashing.md"

# --- write ------------------------------------------------------------------
cat <<MD
## Flashing this release

Flash with **Raspberry Pi Imager 2.x** from
[raspberrypi.com](https://www.raspberrypi.com/software/); the instructions that shipped with this image are in [docs/flashing.md](${DOCS_URL}).

**Windows**, from Win+R, cmd or PowerShell alike:

    cmd /c start rpi-imager --repo ${PINNED_URL}

**Linux**:

    rpi-imager --repo ${PINNED_URL}

**This release must carry three assets:** \`image_<date>-elspi.img.xz\`,
\`os_list.json\`, and \`<date>-elspi.info\`.
MD
