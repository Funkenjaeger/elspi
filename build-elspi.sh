#!/bin/bash
# Build the elspi image. Wraps build-docker.sh and handles the host-side traps.
#
#   ./build-elspi.sh                       # bake ~/.ssh/id_ed25519.pub
#   ./build-elspi.sh path/to/key.pub       # bake a specific public key
#
# OS_LIST_URL=<https-or-file-url>  (env var, not a flag -- $1 above is already
#   taken by the pubkey path, and every other knob here, PRESERVE_CONTAINER /
#   CONTINUE / IMG_NAME / CONTAINER_NAME, is env-var-only, so this follows the
#   same shape). Passed straight through as `--url` to tools/make-os-list.sh.
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
# 2. ONLY GIT_HASH IS FORWARDED INTO THE CONTAINER (build-docker.sh:149). An
#    ELSPI_PUBKEY exported on the host simply is not there when build.sh runs,
#    so the build dies INSIDE the container, minutes in, complaining about a
#    variable you can see set in your own shell. Forwarded here via
#    PIGEN_DOCKER_OPTS, by NAME -- never name=value, because that variable is
#    expanded unquoted and every SSH public key contains spaces.
#
# 3. The base image is i386/debian:trixie on x86_64, not debian:trixie
#    (build-docker.sh:85-92). Worth knowing before debugging a container that
#    is not the one you tested against.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="${HOME}/.local/qemu-shim"
PUBKEY_FILE="${1:-${HOME}/.ssh/id_ed25519.pub}"

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

# --- the key baked into the image -------------------------------------------
# A PUBLIC key, not a secret. It is what makes a failed UI recoverable over SSH
# instead of by power-cycling a lathe: the account ships locked, so password
# SSH cannot work, and a card with no key in it is reachable only from the
# touchscreen -- which is the thing under test.
[ -f "${PUBKEY_FILE}" ] || { echo "FATAL: no public key at ${PUBKEY_FILE}"; exit 1; }
ELSPI_PUBKEY="$(cat "${PUBKEY_FILE}")"
export ELSPI_PUBKEY
case "${ELSPI_PUBKEY}" in
	ssh-*|ecdsa-*|sk-*) ;;
	*) echo "FATAL: ${PUBKEY_FILE} does not look like an SSH public key"; exit 1 ;;
esac
echo "baking:   $(ssh-keygen -lf "${PUBKEY_FILE}" | awk '{print $1, $2, $4}')"

# --- trap 2: forward it by NAME ---------------------------------------------
export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} -e ELSPI_PUBKEY"

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
