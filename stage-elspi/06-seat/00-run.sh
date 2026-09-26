#!/bin/bash -e

# DRM MASTER ARBITRATION -- the one real reason reflex-ui ran as root.
#
# THE DIRECTORY NAME IS HISTORICAL. It is called 06-seat because the first cut
# of this substage shipped a seat-based mode (autologin on tty1 plus a
# `systemd --user` unit). That mode is gone -- see below -- and the name is
# kept only because other things reference this path (tests/dry-run-stages.sh
# runs `06-seat` by name, and renumbering a substage reorders the build).
# What it installs now: the two DRM-mode fragments and the switcher.
#
# docs/design/runtime-inventory.md, measured 2026-09-01: user `default` already holds
# video(44) and render(992), so /dev/dri/card0 PERMISSION IS ALREADY SATISFIED.
# "It needs root for DRM" is the wrong model. What root bought is the right to
# be DRM master.
#
# The modes cannot be tested here: the verification harness is systemd-nspawn
# with no GPU, so whether a mode actually takes DRM master is a hardware
# question and stays one. That is why the substage ships SELECTABLE drop-ins
# plus a switcher rather than one baked-in answer, because of the constraint
# that dominates everything about this machine: EVAN HAS NO TERMINAL ON ELSPI.
# It is a touchscreen. A wrong guess that ships as the only option costs a
# reflash and a lathe power cycle per attempt. With the switcher, the flash
# session tries a mode over SSH with
# `elspi-drm-mode <mode> && systemctl restart reflex-ui`, seconds per attempt,
# no rebuild.
#
# ---------------------------------------------------------------------------
# THE TWO MODES, and the third one that was deleted
# ---------------------------------------------------------------------------
#
# first-opener (DEFAULT, AND VERIFIED ON HARDWARE 2026-09-13):
#   A plain system unit running as the service user, ordered after Plymouth has
#   released the display. It was reasoning from the kernel source when it was
#   written -- on open(), the DRM core calls drm_master_open(), which makes the
#   opener master when the device has no master yet, and that path carries no
#   CAP_SYS_ADMIN check; the capability check lives in drm_master_check_perm(),
#   which only guards the SET_MASTER ioctl for a process that is NOT already
#   master. A console-only machine with no compositor has no other master --
#   once Plymouth is gone. It took the display on the first attempt on the real
#   Pi, so the hypothesis is now a measurement. The ordering stays load-bearing
#   rather than cosmetic: Plymouth's DRM renderer IS a master, and if it is
#   still up when the app opens card0, the app does not get master and SDL2's
#   kmsdrm backend fails.
#
# cap-sys-admin:
#   A floor rather than a preference. CAP_SYS_ADMIN satisfies
#   drm_master_check_perm() directly. It is close to root and buys back some of
#   what the non-root decision was for, so it is the last resort -- but it is
#   still narrower than User=root, and having it pre-staged means a flash
#   session always has a way to leave the lathe working. It STAYS, verified
#   default or not: it is the documented fallback.
#
# logind-seat -- DELETED 2026-09-13:
#   Option 1 from docs/design/runtime-inventory.md verbatim: autologin on tty1 so logind
#   creates a session on seat0, plus a `systemd --user` unit, so the app runs
#   as the seat's active session. It existed for exactly one reason -- the case
#   where first-opener did not work -- and that case did not happen. Keeping an
#   untested, strictly-more-machinery mode (an autologin drop-in, a user unit
#   generated from the system unit's ExecStart, a mode in which the system unit
#   is deliberately inert) on a machine with no terminal is maintenance for a
#   fallback nobody needs. The 2026-09-13 flash-session notes said to delete
#   it if first-opener worked. It worked. The switcher now REFUSES the name by
#   hand so the failure explains itself.
#
# The unit itself is a DELTA (docs/design/seam.md), so this stage ships the FRAGMENTS and
# the switcher; the delta layer calls the switcher.

MODES_DIR="${ROOTFS_DIR}/usr/share/elspi/drm-modes"
install -d -m 0755 "${MODES_DIR}"

install -m 0644 files/first-opener.conf  "${MODES_DIR}/first-opener.conf"
install -m 0644 files/cap-sys-admin.conf "${MODES_DIR}/cap-sys-admin.conf"

install -d -m 0755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 files/elspi-drm-mode "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode"

# --- Post-write checks ------------------------------------------------------
for f in "${MODES_DIR}/first-opener.conf" \
         "${MODES_DIR}/cap-sys-admin.conf" \
         "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode"; do
	[ -f "${f}" ] || { echo "FATAL: post-write check failed -- ${f} missing"; exit 1; }
done

# The switcher hardcodes the mode names; if a fragment is ever renamed without
# updating it, fail at build time rather than at 2am on a lathe.
for mode in first-opener cap-sys-admin; do
	grep -q "${mode}" "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode" || {
		echo "FATAL: elspi-drm-mode does not know about mode '${mode}'"
		exit 1
	}
done

# The deleted rung, asserted as ABSENT. A fragment left in the tree would be
# staged by the loop above the moment someone re-added the install line, and a
# switcher that still accepted the name would silently offer a mode whose
# machinery (the autologin fragment) is no longer shipped.
#
# `if` rather than `[ ... ] && { ... }`: this script runs under `bash -e`, and
# an AND-list whose test is false exits the whole build with status 1.
if [ -e "${MODES_DIR}/logind-seat.conf" ]; then
	echo "FATAL: logind-seat.conf is staged -- that mode was deleted 2026-09-13"
	exit 1
fi
if [ -e "${ROOTFS_DIR}/usr/share/elspi/getty-tty1-autologin.conf" ]; then
	echo "FATAL: the tty1 autologin fragment is staged -- it belonged to logind-seat"
	exit 1
fi
if grep -q 'VALID_MODES=.*logind-seat' "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode"; then
	echo "FATAL: elspi-drm-mode still offers logind-seat as a valid mode"
	exit 1
fi

echo "  drm modes staged: first-opener (default, verified on hardware) cap-sys-admin"
echo "  switcher: /usr/local/sbin/elspi-drm-mode  (logind-seat deleted 2026-09-13)"
