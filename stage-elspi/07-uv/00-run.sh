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
UV_TARBALL="uv-armv7-unknown-linux-gnueabihf.tar.gz"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"

# Verified against the .sha256 published beside the asset, 2026-09-07.
# If this ever mismatches, STOP -- do not "update the hash to make it pass".
UV_SHA256="d10df2ebaa729a51d15395720c3f5e76497ae6414beb82043bb2e53f9a86314a"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "  fetching uv ${UV_VERSION} (armv7 gnueabihf)"
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

# POST-WRITE CHECK: present, executable, and an ARM binary -- not the host's.
[ -x "${ROOTFS_DIR}/usr/local/bin/uv" ] || {
	echo "FATAL: post-write check failed -- /usr/local/bin/uv not installed"
	exit 1
}
if ! file "${ROOTFS_DIR}/usr/local/bin/uv" | grep -q "ARM"; then
	echo "FATAL: installed uv is not an ARM binary:"
	file "${ROOTFS_DIR}/usr/local/bin/uv"
	exit 1
fi
echo "  installed: /usr/local/bin/uv ${UV_VERSION} (ARM)"
