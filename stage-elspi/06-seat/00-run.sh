#!/bin/bash -e

# DRM MASTER ARBITRATION -- the one real reason reflex-ui ran as root.
#
# RUNTIME-INVENTORY.md, measured 2026-09-01: user `default` already holds
# video(44) and render(992), so /dev/dri/card0 PERMISSION IS ALREADY SATISFIED.
# "It needs root for DRM" is the wrong model. What root bought is the right to
# be DRM master.
#
# The task body says the stage must decide HOW, not WHETHER, and lists three
# untested options. NONE OF THEM CAN BE TESTED HERE: the verification harness
# is systemd-nspawn with no GPU, so whether a mode actually takes DRM master is
# a hardware question and stays one.
#
# So this stage does NOT gamble on one option. It bakes all three as selectable
# drop-ins plus a switcher, because of the constraint that dominates everything
# about this machine: EVAN HAS NO TERMINAL ON ELSPI. It is a touchscreen. A
# wrong guess that ships as the only option costs a reflash and a lathe power
# cycle per attempt. With the switcher, the flash session tries a mode over SSH
# with `elspi-drm-mode <mode> && systemctl restart reflex-ui`, seconds per
# attempt, no rebuild.
#
# ---------------------------------------------------------------------------
# THE THREE MODES, and why `first-opener` is the default
# ---------------------------------------------------------------------------
#
# first-opener (DEFAULT):
#   A plain system unit running as the service user, ordered after Plymouth has
#   released the display. The reasoning -- and it is REASONING FROM THE KERNEL
#   SOURCE, NOT A MEASUREMENT, so treat it as a hypothesis: on open(), the DRM
#   core calls drm_master_open(), which makes the opener master when the device
#   has no master yet, and that path carries no CAP_SYS_ADMIN check. The
#   capability check lives in drm_master_check_perm(), which only guards the
#   SET_MASTER ioctl for a process that is NOT already master. A console-only
#   machine with no compositor has no other master -- once Plymouth is gone.
#   Hence the ordering: Plymouth's DRM renderer IS a master, and if it is still
#   up when the app opens card0, the app does not get master and SDL2's kmsdrm
#   backend fails. That ordering is the likeliest single cause of a failure
#   here, which is why it is explicit rather than incidental.
#
# logind-seat:
#   Option 1 from RUNTIME-INVENTORY.md verbatim -- autologin on tty1 so logind
#   creates a session on seat0, plus a `systemd --user` unit, so the app runs
#   as the seat's active session. This is how compositors do it. Deliberately
#   NOT the default: it is strictly more machinery, and it is only NEEDED if
#   the first-opener hypothesis is wrong.
#   NOTE: lingering is deliberately NOT enabled. A lingering user manager
#   starts at boot with no session and therefore no seat, which is the opposite
#   of what this mode is for.
#
# cap-sys-admin:
#   Option 3, as a floor rather than a preference. CAP_SYS_ADMIN satisfies
#   drm_master_check_perm() directly. It is close to root and buys back some of
#   what the non-root decision was for, so it is the last resort -- but it is
#   still narrower than User=root, and having it pre-staged means the flash
#   session always has a way to leave the lathe working.
#
# The unit itself is a DELTA (SEAM.md), so this stage ships the FRAGMENTS and
# the switcher; the delta layer calls the switcher.

MODES_DIR="${ROOTFS_DIR}/usr/share/elspi/drm-modes"
install -d -m 0755 "${MODES_DIR}"

install -m 0644 files/first-opener.conf  "${MODES_DIR}/first-opener.conf"
install -m 0644 files/logind-seat.conf   "${MODES_DIR}/logind-seat.conf"
install -m 0644 files/cap-sys-admin.conf "${MODES_DIR}/cap-sys-admin.conf"

# The tty1 autologin fragment, shipped INERT. `elspi-drm-mode logind-seat`
# activates it; every other mode removes it.
install -d -m 0755 "${ROOTFS_DIR}/usr/share/elspi"
install -m 0644 files/autologin.conf "${ROOTFS_DIR}/usr/share/elspi/getty-tty1-autologin.conf"

install -d -m 0755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 files/elspi-drm-mode "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode"

# --- Post-write checks ------------------------------------------------------
for f in "${MODES_DIR}/first-opener.conf" \
         "${MODES_DIR}/logind-seat.conf" \
         "${MODES_DIR}/cap-sys-admin.conf" \
         "${ROOTFS_DIR}/usr/share/elspi/getty-tty1-autologin.conf" \
         "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode"; do
	[ -f "${f}" ] || { echo "FATAL: post-write check failed -- ${f} missing"; exit 1; }
done

# The switcher hardcodes the mode names; if a fragment is ever renamed without
# updating it, fail at build time rather than at 2am on a lathe.
for mode in first-opener logind-seat cap-sys-admin; do
	grep -q "${mode}" "${ROOTFS_DIR}/usr/local/sbin/elspi-drm-mode" || {
		echo "FATAL: elspi-drm-mode does not know about mode '${mode}'"
		exit 1
	}
done

echo "  drm modes staged: first-opener (default) logind-seat cap-sys-admin"
echo "  switcher: /usr/local/sbin/elspi-drm-mode"
