#!/bin/bash
# Run Tier 2 against the rootfs left behind by a build, with no sudo.
#
#   tests/verify-built-image.sh            # offline checks only
#   tests/verify-built-image.sh --boot     # plus the booted nspawn assertions
#
# The rootfs lives inside the pigen_work container's volume, not on the host,
# so this reaches it with --volumes-from rather than copying several GB out.
#
# REQUIRES the build to have kept its container. build-docker.sh reaps it with
# `docker rm -v` on success, which deletes the volume and the rootfs with it;
# build-elspi.sh therefore defaults PRESERVE_CONTAINER=1. If the container is
# gone, this says so rather than reporting a clean run over nothing -- an
# absent rootfs must never look like a passing one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${PIGEN_CONTAINER:-pigen_work}"
ROOTFS_IN_VOL="/pi-gen/work/elspi/stage-elspi/rootfs"
BOOT_ARG=""

for a in "$@"; do
	case "$a" in
		--boot) BOOT_ARG="--boot" ;;
		*) echo "unknown argument: $a" >&2; exit 2 ;;
	esac
done

# GATE: the container must exist, or there is nothing to verify.
if ! docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
	echo "UNKNOWN: container '${CONTAINER}' does not exist, so there is no rootfs to check."
	echo
	echo "  A successful build removes it unless PRESERVE_CONTAINER=1."
	echo "  Rebuild with tests/../build-elspi.sh, which now defaults to keeping it."
	echo
	echo "  NOT reporting success: nothing was verified."
	exit 2
fi

echo "== building the harness runner image =="
docker build -q -f "${HERE}/Dockerfile.verify" -t elspi-verify "${HERE}" >/dev/null || {
	echo "FATAL: could not build the harness runner image"; exit 1; }

# GATE: an armhf binfmt handler must be registered in the host kernel, or the
# booted half silently cannot execute anything in the rootfs.
if [ -n "${BOOT_ARG}" ]; then
	if ! ls /proc/sys/fs/binfmt_misc/qemu-arm >/dev/null 2>&1; then
		echo "UNKNOWN: no qemu-arm binfmt handler registered in the host kernel."
		echo "  The booted assertions cannot run. On dserver (bash):"
		echo "    sudo apt-get install -y qemu-user-static binfmt-support"
		exit 2
	fi
fi

echo "== running Tier 2 ${BOOT_ARG:+(with --boot)} =="

# binfmt_misc is NOT mounted inside a container by default -- the directory is
# there and empty, so an armhf binary is simply "cannot execute" with no
# explanation. Mounting it in the privileged container exposes the HOST's
# registrations (verified: qemu-arm, enabled, flags POF), because Docker shares
# the host user namespace here. The F flag matters: it pins the interpreter's
# fd at registration time, so the rootfs does not need a copy of qemu inside it.
#
# Done as part of the command rather than in the Dockerfile because a mount
# cannot be baked into an image.
exec docker run --rm --privileged \
	--volumes-from "${CONTAINER}" \
	-v "${HERE}":/tests:ro \
	elspi-verify \
	bash -c "mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true; exec /tests/verify-image.sh '${ROOTFS_IN_VOL}' ${BOOT_ARG}"
