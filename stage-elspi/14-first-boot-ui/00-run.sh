#!/bin/bash -e

# stage-elspi/14-first-boot-ui -- "a fresh elspi card boots straight into the
# UI: no SSH, no mandatory backup". README.md in this directory has the full
# reasoning.
#
# SHORT VERSION: a oneshot unit, enabled and ordered after the first-boot seed
# and after Plymouth, whose script (files/elspi-first-boot-ui.sh) runs the
# delta layer's CONVERGE phase against the checkout 10a-app-checkout baked in
# -- offline, because 10b-app-install already did the one networked step at
# build time -- and then starts reflex-ui.service, once. It starts nothing
# unless the baked release carries reflex's commissioning guard
# (files/commissioning-guard.sh), so a fresh card comes up UNCOMMISSIONED and
# says so on screen, never on silent defaults.
#
# This substage therefore installs three things beside the unit: the hook
# script, the guard check, and THE DELTA LAYER ITSELF (deltas/, minus its
# tests) at /usr/local/lib/elspi/deltas, because converge is what the hook
# runs and a card must not need a network clone of this repository to boot.
# The same copy is what an operator can run for recovery with no network.
#
# Chroot-free, like 12-first-boot-seed, for the same reason: it only touches
# ${ROOTFS_DIR}, so tests/dry-run-stages.sh can exercise it on any Linux box
# instead of only inside a multi-hour emulated build.

UNIT_NAME="elspi-first-boot-ui.service"
SCRIPT_DST="${ROOTFS_DIR}/usr/local/sbin/elspi-first-boot-ui"
UNIT_DST="${ROOTFS_DIR}/etc/systemd/system/${UNIT_NAME}"
LIB_DST="${ROOTFS_DIR}/usr/local/lib/elspi"
GUARD_DST="${LIB_DST}/commissioning-guard"
DELTAS_DST="${LIB_DST}/deltas"
# The repository's deltas/, two levels up from this substage: pi-gen runs each
# 00-run.sh from inside its own substage directory (build.sh pushd), and the
# build container carries the whole repository (Dockerfile: COPY . /pi-gen/).
DELTAS_SRC="$(cd ../../deltas 2>/dev/null && pwd)"
WANTS_TARGET="cloud-init.target"
WANTS_DIR="${ROOTFS_DIR}/etc/systemd/system/${WANTS_TARGET}.wants"
# The target we must NOT be enabled in, gated on below -- same trap
# 12-first-boot-seed documents in full.
CYCLE_WANTS="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/${UNIT_NAME}"

install -v -m 0755 -D files/elspi-first-boot-ui.sh "${SCRIPT_DST}"
install -v -m 0644 -D "files/${UNIT_NAME}" "${UNIT_DST}"
install -v -m 0755 -D files/commissioning-guard.sh "${GUARD_DST}"

# --- the delta layer, baked in --------------------------------------------------
# The EXACT files, not a curated subset: converge sources lib.sh and reads
# files/50-reflex-service-user.rules relative to itself, and the other phases
# ride along so recovery on a card with no network does not start with a git
# clone. tests/ stays behind (it is the repository's, not the card's).
# Refreshed wholesale so a resumed build cannot keep a stale file.
if [ -z "${DELTAS_SRC}" ] || [ ! -f "${DELTAS_SRC}/01-converge.sh" ] || [ ! -f "${DELTAS_SRC}/lib.sh" ]; then
	echo "FATAL: the repository's deltas/ is not at ../../deltas from $(pwd)"
	echo "       (resolved: '${DELTAS_SRC}'). The first-boot hook runs converge"
	echo "       from the image's own copy; without it the card cannot boot into the UI."
	exit 1
fi
[ -n "${ROOTFS_DIR}" ] || { echo "FATAL: ROOTFS_DIR is empty -- refusing to touch ${DELTAS_DST}"; exit 1; }
rm -rf "${DELTAS_DST}"
install -d -m 0755 "${DELTAS_DST}/files"
DELTA_SCRIPTS="lib.sh 01-converge.sh 02-restore.sh 03-interactive.sh provision.sh"
for f in ${DELTA_SCRIPTS}; do
	install -m 0755 "${DELTAS_SRC}/${f}" "${DELTAS_DST}/${f}"
done
install -m 0644 "${DELTAS_SRC}/README.md" "${DELTAS_DST}/README.md"
for f in "${DELTAS_SRC}"/files/*; do
	install -m 0644 "${f}" "${DELTAS_DST}/files/$(basename "${f}")"
done
# Which commit of this repository the copy came from, for whoever reads it on
# a card months later. GIT_HASH is forwarded into the build by build-docker.sh
# (11-manifest reads the same variable for image_build_sha).
printf '%s\n' "${GIT_HASH:-unknown}" > "${DELTAS_DST}/SOURCE_COMMIT"

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
	echo "       input -- a first boot that waits for a keyboard is the failure it exists to avoid."
	exit 1
fi

# --- POST-WRITE CHECKS: the payload the hook runs -----------------------------
# Byte-identical to the repository's copy, executable, and parseable. A copy
# that differs, lost its mode, or does not parse would surface only as a card
# that never reaches the UI.
[ -x "${GUARD_DST}" ] || { echo "FATAL: post-write check failed -- ${GUARD_DST} is not executable"; exit 1; }
cmp -s files/commissioning-guard.sh "${GUARD_DST}" \
	|| { echo "FATAL: post-write check failed -- ${GUARD_DST} differs from files/commissioning-guard.sh"; exit 1; }
for f in ${DELTA_SCRIPTS}; do
	[ -x "${DELTAS_DST}/${f}" ] || { echo "FATAL: post-write check failed -- ${DELTAS_DST}/${f} is not executable"; exit 1; }
	cmp -s "${DELTAS_SRC}/${f}" "${DELTAS_DST}/${f}" \
		|| { echo "FATAL: post-write check failed -- ${DELTAS_DST}/${f} differs from deltas/${f}"; exit 1; }
	bash -n "${DELTAS_DST}/${f}" \
		|| { echo "FATAL: post-write check failed -- ${DELTAS_DST}/${f} does not parse (bash -n)"; exit 1; }
done
[ -s "${DELTAS_DST}/files/50-reflex-service-user.rules" ] \
	|| { echo "FATAL: post-write check failed -- converge's polkit template did not land in ${DELTAS_DST}/files"; exit 1; }
[ ! -e "${DELTAS_DST}/tests" ] \
	|| { echo "FATAL: post-write check failed -- ${DELTAS_DST}/tests exists; the contract tests are not shipped"; exit 1; }
# The hook must actually point at what was just installed -- a path typo in
# either place would pass every check above.
grep -qF 'CONVERGE="${LIBDIR}/deltas/01-converge.sh"' "${SCRIPT_DST}" \
	&& grep -qF 'LIBDIR="${R}/usr/local/lib/elspi"' "${SCRIPT_DST}" \
	&& grep -qF 'GUARD="${LIBDIR}/commissioning-guard"' "${SCRIPT_DST}" \
	|| { echo "FATAL: post-write check failed -- ${SCRIPT_DST} does not name /usr/local/lib/elspi/{deltas/01-converge.sh,commissioning-guard}"; exit 1; }
# The hook's converge runs OFFLINE, and that is a property, not an accident.
grep -qF 'UV_OFFLINE=1' "${SCRIPT_DST}" \
	|| { echo "FATAL: post-write check failed -- ${SCRIPT_DST} no longer runs converge with UV_OFFLINE=1"; exit 1; }

echo "  installed: /usr/local/sbin/elspi-first-boot-ui (0755; converges the baked checkout offline and starts reflex-ui, once -- see README.md)"
echo "  installed: /usr/local/lib/elspi/commissioning-guard (0755)"
echo "  installed: /usr/local/lib/elspi/deltas (${DELTA_SCRIPTS}; from ${GIT_HASH:-unknown})"
echo "  installed: /etc/systemd/system/${UNIT_NAME}"
echo "  enabled:   ${WANTS_TARGET}.wants/${UNIT_NAME}"
echo "  ok: ordered After=elspi-first-boot-seed.service and After=plymouth-quit-wait.service"
