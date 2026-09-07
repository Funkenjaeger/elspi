#!/bin/bash
# Build the elspi image. Wraps build-docker.sh and handles the host-side traps.
#
#   ./build-elspi.sh                       # bake ~/.ssh/id_ed25519.pub
#   ./build-elspi.sh path/to/key.pub       # bake a specific public key
#
# A NEW file, per FORK.md: build-docker.sh is upstream and stays untouched.
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

echo "starting build at $(date -Is)"
exec ./build-docker.sh -c elspi.conf
