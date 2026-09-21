#!/bin/bash -e

# stage-elspi/14-first-boot-ui -- the image-side HOOK for task 6aa73b01 item 1
# ("make a fresh elspi card boot straight into the UI: no SSH, no mandatory
# backup, SWD chapter documented"). README.md in this directory has the full
# reasoning, and -- importantly -- what this substage deliberately does NOT
# do yet and why.
#
# SHORT VERSION: item 1 asks to bake a reflex checkout into the image and
# auto-run converge at first boot. Doing that HERE would move the application
# across docs/design/seam.md's ratified line (the app is deltas-owned; see
# 11-manifest's delta_layer_owns declaration) -- exactly the re-litigation
# this order was told not to do. So this substage ships the TRIGGER (a unit,
# enabled, correctly ordered against Plymouth and the existing first-boot
# seed) without the PAYLOAD. files/elspi-first-boot-ui.sh is a real, tested
# no-op today and stays that way until Evan decides to amend the seam.
#
# Chroot-free, like 12-first-boot-seed, for the same reason: it only touches
# ${ROOTFS_DIR}, so tests/dry-run-stages.sh can exercise it on any Linux box
# instead of only inside a multi-hour emulated build.

UNIT_NAME="elspi-first-boot-ui.service"
SCRIPT_DST="${ROOTFS_DIR}/usr/local/sbin/elspi-first-boot-ui"
UNIT_DST="${ROOTFS_DIR}/etc/systemd/system/${UNIT_NAME}"
WANTS_TARGET="cloud-init.target"
WANTS_DIR="${ROOTFS_DIR}/etc/systemd/system/${WANTS_TARGET}.wants"
# The target we must NOT be enabled in, gated on below -- same trap
# 12-first-boot-seed documents in full.
CYCLE_WANTS="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/${UNIT_NAME}"

install -v -m 0755 -D files/elspi-first-boot-ui.sh "${SCRIPT_DST}"
install -v -m 0644 -D "files/${UNIT_NAME}" "${UNIT_DST}"

# ENABLED BY SYMLINK, NOT `on_chroot systemctl`, for the same reason
# 12-first-boot-seed is: it keeps this substage chroot-free.
install -d "${WANTS_DIR}"
ln -sf "../${UNIT_NAME}" "${WANTS_DIR}/${UNIT_NAME}"

# --- POST-WRITE CHECKS ------------------------------------------------------
[ -x "${SCRIPT_DST}" ] || {
	echo "FATAL: post-write check failed -- ${SCRIPT_DST} is not executable"
	exit 1
}
[ -f "${UNIT_DST}" ] || {
	echo "FATAL: post-write check failed -- ${UNIT_DST} was not installed"
	exit 1
}
[ -L "${WANTS_DIR}/${UNIT_NAME}" ] || {
	echo "FATAL: post-write check failed -- ${UNIT_NAME} is not enabled"
	echo "       (no symlink in ${WANTS_TARGET}.wants)"
	exit 1
}
# The symlink must RESOLVE. A dangling enablement symlink looks enabled to
# `ls` and is silently ignored by systemd.
[ -e "${WANTS_DIR}/${UNIT_NAME}" ] || {
	echo "FATAL: post-write check failed -- the enablement symlink for"
	echo "       ${UNIT_NAME} dangles. Target: $(readlink "${WANTS_DIR}/${UNIT_NAME}")"
	exit 1
}
grep -qxF "WantedBy=${WANTS_TARGET}" "${UNIT_DST}" || {
	echo "FATAL: ${UNIT_NAME} does not declare WantedBy=${WANTS_TARGET},"
	echo "       so the ${WANTS_TARGET}.wants symlink is not what"
	echo "       'systemctl enable' would have produced."
	exit 1
}

# THE ORDERING-CYCLE GATE. Written as `if` rather than `cmd && { exit 1; }`:
# this script runs under `bash -e`, and an AND-list whose test legitimately
# returns non-zero in the GOOD case is one stray refactor away from either
# exiting the build or being silently skipped -- see 12-first-boot-seed for
# the same note, and the 2026-09-13 boot for what happens if this is missing.
if [ -L "${CYCLE_WANTS}" ] || [ -e "${CYCLE_WANTS}" ]; then
	echo "FATAL: post-write check failed -- ${UNIT_NAME} is ALSO enabled in"
	echo "       multi-user.target.wants. That is an ordering cycle with"
	echo "       cloud-final.service, exactly as it was for"
	echo "       elspi-first-boot-seed.service on 2026-09-13."
	exit 1
fi
if grep -qxF "WantedBy=multi-user.target" "${UNIT_DST}"; then
	echo "FATAL: post-write check failed -- ${UNIT_NAME} declares"
	echo "       WantedBy=multi-user.target, so a later 'systemctl reenable'"
	echo "       would restore the ordering cycle with cloud-final.service."
	exit 1
fi

# LOAD-BEARING ORDERING, asserted here so a build that quietly drops either
# edge fails loudly instead of shipping a hook that could one day race
# Plymouth for DRM master or converge before the seed has run.
grep -qxF "After=plymouth-quit-wait.service" "${UNIT_DST}" || {
	echo "FATAL: post-write check failed -- ${UNIT_NAME} does not declare"
	echo "       After=plymouth-quit-wait.service"
	exit 1
}
grep -qxF "After=elspi-first-boot-seed.service" "${UNIT_DST}" || {
	echo "FATAL: post-write check failed -- ${UNIT_NAME} does not declare"
	echo "       After=elspi-first-boot-seed.service"
	exit 1
}

grep -qxF "ExecStart=-/usr/local/sbin/elspi-first-boot-ui" "${UNIT_DST}" || {
	echo "FATAL: ${UNIT_NAME} must prefix ExecStart with '-' so a failing hook"
	echo "       cannot fail the boot of a machine with no terminal."
	exit 1
}

# NO INTERACTIVE STEP, EVER. The script installed here is the one thing in
# this substage that could grow a prompt later without anyone noticing;
# tests/verify-image.sh asserts the same thing against the built rootfs.
if grep -qE '^\s*read\b' "${SCRIPT_DST}"; then
	echo "FATAL: post-write check failed -- ${SCRIPT_DST} appears to call"
	echo "       'read' (an interactive step). This hook must never block on"
	echo "       input -- that is the whole point of task 6aa73b01."
	exit 1
fi

echo "  installed: /usr/local/sbin/elspi-first-boot-ui (0755, NOOP until a checkout is baked in -- see README.md)"
echo "  installed: /etc/systemd/system/${UNIT_NAME}"
echo "  enabled:   ${WANTS_TARGET}.wants/${UNIT_NAME}"
echo "  ok: ordered After=elspi-first-boot-seed.service and After=plymouth-quit-wait.service"
