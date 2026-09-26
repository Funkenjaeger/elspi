#!/bin/bash -e

# A PINNED, CHECKSUM-VERIFIED uv.
#
# docs/design/seam.md: "uv, not pip. If the image builds the venv, it must reproduce
# uv.lock exactly, and pip would re-resolve." And: "fetch a PINNED uv and
# verify its checksum rather than curl-to-shell the latest."
#
# On the live elspi uv is a ~50 MB binary hand-placed at
# /home/default/.local/bin/uv, version 0.11.23, provisioned by nothing. That is
# one of the things this image exists to stop being true. It goes in
# /usr/local/bin, owned by root, from a pinned URL with a verified hash.
#
# Downloaded on the BUILD HOST, not in the chroot: the host has the network and
# runs natively, so this costs nothing under qemu-user.

UV_VERSION="0.11.23"

# THE BRANCH IS THE ARCHITECTURE (docs/design/fork.md): build.sh exports ARCH,
# armhf on master and arm64 on this branch. The uv binary must match the
# rootfs userland, or `uv --version` in 08-venv's chroot has no loader to run
# under. Both pins are here so this file reads the same on either branch.
#
# Each hash was verified against the .sha256 published beside the asset
# (armhf 2026-09-07; arm64 2026-09-26, also matching the GitHub release
# asset digest). If one ever mismatches, STOP -- do not "update the hash to
# make it pass".
case "${ARCH:?build.sh exports ARCH; this stage cannot pick a uv without it}" in
	armhf)
		UV_TARBALL="uv-armv7-unknown-linux-gnueabihf.tar.gz"
		UV_SHA256="d10df2ebaa729a51d15395720c3f5e76497ae6414beb82043bb2e53f9a86314a"
		UV_FILE_MATCH="ARM, EABI5"
		;;
	arm64)
		UV_TARBALL="uv-aarch64-unknown-linux-gnu.tar.gz"
		UV_SHA256="1873a77350f6621279ae1a0d2227f2bd8b67131598f14a7eb0ba2215d3da2c98"
		UV_FILE_MATCH="ARM aarch64"
		;;
	*)
		echo "FATAL: no pinned uv for ARCH=${ARCH}"
		exit 1
		;;
esac
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "  fetching uv ${UV_VERSION} (${UV_TARBALL}, ARCH=${ARCH})"
curl -fsSL --retry 3 -o "${WORK}/${UV_TARBALL}" "${UV_URL}"

# GATE: verify before unpacking, and branch on the result.
echo "${UV_SHA256}  ${WORK}/${UV_TARBALL}" | sha256sum -c - || {
	echo "FATAL: uv ${UV_VERSION} checksum MISMATCH."
	echo "       expected ${UV_SHA256}"
	echo "       got      $(sha256sum < "${WORK}/${UV_TARBALL}" | cut -d' ' -f1)"
	echo "       Do not update the hash to make this pass. Find out why it moved."
	exit 1
}
echo "  checksum ok"

tar -xzf "${WORK}/${UV_TARBALL}" -C "${WORK}"

# The tarball unpacks into a versioned directory; find the binary rather than
# assuming the layout, but fail loudly if it is not exactly one.
mapfile -t FOUND < <(find "${WORK}" -type f -name uv)
if [ "${#FOUND[@]}" -ne 1 ]; then
	echo "FATAL: expected exactly one 'uv' binary in the tarball, found ${#FOUND[@]}"
	printf '  %s\n' "${FOUND[@]}"
	exit 1
fi

install -m 0755 "${FOUND[0]}" "${ROOTFS_DIR}/usr/local/bin/uv"

# POST-WRITE CHECK: present, executable, and an ARM binary OF THIS ARCH --
# not the host's, and not the other ARM ABI's.
[ -x "${ROOTFS_DIR}/usr/local/bin/uv" ] || {
	echo "FATAL: post-write check failed -- /usr/local/bin/uv not installed"
	exit 1
}
if ! file "${ROOTFS_DIR}/usr/local/bin/uv" | grep -qF "${UV_FILE_MATCH}"; then
	echo "FATAL: installed uv is not a '${UV_FILE_MATCH}' binary (ARCH=${ARCH}):"
	file "${ROOTFS_DIR}/usr/local/bin/uv"
	exit 1
fi
echo "  installed: /usr/local/bin/uv ${UV_VERSION} (${UV_FILE_MATCH})"
