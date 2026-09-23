#!/bin/bash
# Build the elspi image. Wraps build-docker.sh and handles the host-side traps.
#
#   ./build-elspi.sh
#
# It takes NO arguments, and in particular no SSH key: the image is KEYLESS
# (2026-09-23). Keys and the password come from Raspberry Pi Imager's
# customisation page at flash time -- see elspi.conf's SSH block. Until then
# $1 was a public key to bake in; passing one now is refused with a message
# rather than silently ignored.
#
# OS_LIST_URL=<https-or-file-url>  (env var, not a flag -- every knob here,
#   PRESERVE_CONTAINER / CONTINUE / IMG_NAME / CONTAINER_NAME, is
#   env-var-only, so this follows the same shape). Passed straight through as
#   `--url` to tools/make-os-list.sh.
#   Unset by default: the build still succeeds and deploy/os_list.json still
#   gets written, but with a file:// URL good on THIS machine only, and this
#   script prints a loud WARNING below saying so. Set it once you know where
#   the image and its os_list.json will actually be served from -- for a
#   tagged GitHub release that is:
#     OS_LIST_URL=https://github.com/<org>/<repo>/releases/download/<tag>/os_list.json
#   See docs/flashing.md.
#
# A NEW file, per docs/design/fork.md: build-docker.sh is upstream and stays untouched.
#
# ---------------------------------------------------------------------------
# THE THREE TRAPS THIS EXISTS FOR
#
# All three were hit on 2026-09-07 doing this by hand. None of them fails in a
# way that names its own cause, and two of them fail slowly.
#
# 1. `which qemu-arm` MUST RESOLVE ON THE HOST (build-docker.sh:119), and on
#    Ubuntu the package that provides that NAME -- qemu-user-binfmt -- CONFLICTS
#    with qemu-user-static:
#
#      qemu-user-binfmt : Conflicts: qemu-user-static
#      qemu-user-static : Conflicts: qemu-user-binfmt   (and Provides it)
#
#    Installing both is impossible, and qemu-user-static is the one worth
#    having, because a STATIC interpreter is what works inside a chroot and the
#    nspawn verification harness needs exactly that. But qemu-user-static ships
#    `qemu-arm-static`, not `qemu-arm`, so the precheck fails anyway.
#
#    Resolved WITHOUT root and without picking the wrong package: unpack the
#    .deb into the user's own tree and expose the static binary under the name
#    the precheck looks for. `apt-get download` needs no privilege.
#
# 2. ONLY GIT_HASH IS FORWARDED INTO THE CONTAINER (build-docker.sh:149). A
#    build parameter exported on the host simply is not there when build.sh
#    runs, so the build misbehaves INSIDE the container, minutes in, over a
#    variable you can see set in your own shell. The REFLEX_* parameters are
#    forwarded below via PIGEN_DOCKER_OPTS, by NAME -- never name=value,
#    because that variable is expanded unquoted and a value with spaces would
#    be word-split into separate docker arguments. (This trap was first hit
#    with ELSPI_PUBKEY, the build-time key the image no longer takes.)
#
# 3. The base image is i386/debian:trixie on x86_64, not debian:trixie
#    (build-docker.sh:85-92). Worth knowing before debugging a container that
#    is not the one you tested against.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="${HOME}/.local/qemu-shim"

# KEYLESS: refuse the old `./build-elspi.sh path/to/key.pub` form out loud.
# Ignoring the argument would let someone believe their key went in.
if [ "$#" -gt 0 ]; then
	echo "FATAL: build-elspi.sh takes no arguments (got: $*)."
	echo "  The elspi image is KEYLESS: no SSH key is baked in at build time."
	echo "  Put your public key (and/or a password) on Raspberry Pi Imager's"
	echo "  customisation page when you flash -- see docs/flashing.md."
	exit 1
fi

cd "${REPO}"

# --- trap 1: a `qemu-arm` on PATH, static, without root ---------------------
if [ ! -e "${SHIM}/bin/qemu-arm" ]; then
	echo "== staging a static qemu-arm shim (no root needed) =="
	rm -rf "${SHIM}"
	mkdir -p "${SHIM}/deb" "${SHIM}/root" "${SHIM}/bin"
	( cd "${SHIM}/deb" && apt-get download qemu-user-static )
	dpkg-deb -x "${SHIM}"/deb/*.deb "${SHIM}/root"
	ln -sf "${SHIM}/root/usr/bin/qemu-arm-static" "${SHIM}/bin/qemu-arm"
fi
export PATH="${SHIM}/bin:${PATH}"

RESOLVED="$(command -v qemu-arm || true)"
[ -n "${RESOLVED}" ] || { echo "FATAL: qemu-arm not on PATH after staging the shim"; exit 1; }

# Accept both spellings file(1) uses. Ubuntu ships this as a static-PIE, which
# is still static; a gate that only matched "statically linked" rejected the
# correct binary on the first run.
if ! file -L "${RESOLVED}" | grep -Eq "statically linked|static-pie linked"; then
	echo "FATAL: ${RESOLVED} is not static -- it will not work inside the chroot:"
	file -L "${RESOLVED}"
	exit 1
fi
echo "qemu-arm: ${RESOLVED} (static)"

# --- trap 2: the app-release parameters, forwarded by NAME ------------------
# stage-elspi/10a-app-checkout's REFLEX_SOURCE / REFLEX_RELEASE /
# REFLEX_ORIGIN_URL are parameters of the BUILD (docs/design/seam.md amendment
# 2026-09-21). They are read inside the container, and build-docker.sh passes
# only `-e GIT_HASH` of its own accord, so without this they are parameters
# nobody outside the container can actually set -- which is a knob that cannot
# turn, not a configuration point.
#
# BY NAME ONLY, never name=value: PIGEN_DOCKER_OPTS is expanded unquoted.
# Only names that are SET are added -- `-e FOO` for an unset FOO passes the
# host's (absent) value and would override elspi.conf's default with empty.
for _v in REFLEX_SOURCE REFLEX_RELEASE REFLEX_ORIGIN_URL; do
	if [ -n "${!_v:-}" ]; then
		export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} -e ${_v}"
		echo "forwarding: ${_v}"
	fi
done
unset _v

# A LOCAL MIRROR PATH IS NOT AUTOMATICALLY VISIBLE INSIDE THE CONTAINER, and
# this is the one trap this loop does not remove. `REFLEX_SOURCE=/mnt/git/
# reflex.git` names a path on the HOST; the build runs in Docker, so it also
# needs bind-mounting:
#
#   REFLEX_SOURCE=/mnt/git/reflex.git \
#   PIGEN_DOCKER_OPTS="-v /mnt/git/reflex.git:/mnt/git/reflex.git:ro" \
#   ./build-elspi.sh
#
# Said here rather than left to be discovered three hours in, which is how
# long this build takes to reach the stage that would fail.
case "${REFLEX_SOURCE:-}" in
	/*)
		echo "note:     REFLEX_SOURCE=${REFLEX_SOURCE} is a host path -- bind-mount it"
		echo "          into the container too, or the clone will fail inside it."
		;;
esac

# --- trap 4: THE BUILD DESTROYS WHAT THE HARNESS NEEDS ----------------------
# On success build-docker.sh runs `docker rm -v pigen_work`, and the -v takes
# the anonymous volume holding work/ with it. The built ROOTFS lives in that
# volume -- so a successful build deletes the only thing tests/verify-image.sh
# can be pointed at, and leaves you holding a compressed .img that cannot be
# opened without root.
#
# Learned by losing one on 2026-09-07: the image built, the container was
# reaped, and Tier 2 verification then needed a whole second build.
#
# Default to keeping it. Export PRESERVE_CONTAINER=0 explicitly to reclaim the
# space once verification has run.
export PRESERVE_CONTAINER="${PRESERVE_CONTAINER:-1}"
echo "preserve: container kept (PRESERVE_CONTAINER=${PRESERVE_CONTAINER}) so the rootfs survives for verification"

# --- clear the PREVIOUS build's preserved container --------------------------
# Keeping the container is what makes verification possible, but it also means
# build-docker.sh aborts on the NEXT run: "Container pigen_work already exists
# and you did not specify CONTINUE=1." Preserving is for inspecting a build
# AFTER it finishes, not for squatting on the name forever -- so a leftover
# from a FINISHED build is cleared here rather than handed to the operator as
# a docker command to paste.
#
# A RUNNING container is a different thing entirely and is never touched: that
# is either a build in progress or the orphan that filled /disk0 on 2026-09-07.
# Removing one out from under itself is how that mess started.
CONTAINER_NAME="${CONTAINER_NAME:-pigen_work}"
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
	echo "FATAL: ${CONTAINER_NAME} is RUNNING."
	echo "  Either a build is in progress, or a previous one was interrupted and"
	echo "  left it behind. Check before killing it:"
	echo "      docker ps --filter name=${CONTAINER_NAME}"
	exit 1
fi
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
	if [ "${CONTINUE:-0}" = "1" ]; then
		echo "resume:   keeping ${CONTAINER_NAME} (CONTINUE=1)"
	else
		echo "cleanup:  removing the previous build's preserved ${CONTAINER_NAME}"
		docker rm -v "${CONTAINER_NAME}" >/dev/null \
			|| { echo "FATAL: could not remove ${CONTAINER_NAME}"; exit 1; }
	fi
fi

echo "starting build at $(date -Is)"
BUILD_START="$(date +%s)"
./build-docker.sh -c elspi.conf

# --- trap 5: A BARE .img.xz CANNOT BE SEEDED -------------------------------
# Raspberry Pi Imager 2.x never offers OS customisation for a "Use custom"
# local image (tools/make-os-list.sh's header has the QML call chain), so an
# operator who points Imager at deploy/image_*.img.xz gets an UNSEEDED card:
# no password, no key, no Wi-Fi, no country -- and stage-elspi/12-first-boot-seed,
# which exists to consume that seed, has nothing to consume. The seed arrives
# only through a --repo OS-list entry declaring init_format cloudinit-rpi.
#
# So the JSON is part of the build product, not an afterthought, and failing to
# produce it is a BUILD FAILURE. An image that shipped without it is an image
# whose documented flash procedure does not work.
IMG_XZ="$(ls -t deploy/image_*-"${IMG_NAME:-elspi}".img.xz 2>/dev/null | head -n1 || true)"
[ -n "${IMG_XZ}" ] || { echo "FATAL: the build left no deploy/image_*.img.xz to describe"; exit 1; }
if [ "$(date -r "${IMG_XZ}" +%s)" -lt "${BUILD_START}" ]; then
	echo "FATAL: ${IMG_XZ} predates this build ($(date -r "${IMG_XZ}" -Is) < $(date -d "@${BUILD_START}" -Is))."
	echo "  That is a LEFTOVER, not what was just built. Refusing to describe it."
	exit 1
fi
echo "== describing ${IMG_XZ} for Imager's --repo path =="
MAKE_OS_LIST_ARGS=("${IMG_XZ}" --out deploy/os_list.json)
[ -z "${OS_LIST_URL:-}" ] || MAKE_OS_LIST_ARGS+=(--url "${OS_LIST_URL}")
./tools/make-os-list.sh "${MAKE_OS_LIST_ARGS[@]}" \
	|| { echo "FATAL: could not write deploy/os_list.json -- see above."; exit 1; }

if [ -z "${OS_LIST_URL:-}" ]; then
	WRITTEN_URL="$(grep -m1 '"url"' deploy/os_list.json | sed -E 's/.*"url": *"([^"]*)".*/\1/')"
	echo "=================================================================="
	echo "WARNING: no OS_LIST_URL set -- deploy/os_list.json points at itself."
	echo "  url: ${WRITTEN_URL:-<see deploy/os_list.json>}"
	echo "  That file:// URL only opens on THIS machine ($(hostname 2>/dev/null || echo "this host"))."
	echo "  rpi-imager on any OTHER machine (including whatever actually flashes"
	echo "  a card) cannot open it and fails with something like 'not found: <path>'."
	echo "  This deploy/os_list.json is fine for testing a --repo flash from THIS"
	echo "  machine only. Before publishing it anywhere else, re-run with:"
	echo "      OS_LIST_URL=https://github.com/<org>/<repo>/releases/download/<tag>/os_list.json ./build-elspi.sh"
	echo "  (or whatever URL this image will actually be served from). See docs/flashing.md."
	echo "=================================================================="
fi
echo "flash it with:  tools/flash-elspi.ps1   (Windows)   or   tools/flash-elspi.sh   (Linux)"
