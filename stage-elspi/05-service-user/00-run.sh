#!/bin/bash -e

# The service user, and the directories the application writes to.
#
# DECIDED 2026-09-01 (RUNTIME-INVENTORY.md): the image runs reflex-ui as a
# NON-ROOT service user. Root was inherited from ospi and never justified.
# Measured on the live machine, four of the five reasons for root were
# self-inflicted -- serial access, kivy config location, config-dir ownership,
# and the log directory. This stage removes all four. The fifth (DRM master)
# is 06-seat's problem and is NOT a permission problem at all.
#
# Upstream stage2/01-sys-tweaks/01-run.sh ALREADY adds the first user to
# exactly the live group set and ALREADY runs `usermod --pass='*' root`.
# We therefore ASSERT that rather than doing it again -- a second adduser loop
# would be a check that cannot fail.

SERVICE_USER="${FIRST_USER_NAME}"

# --- Gate: the groups must already be right ---------------------------------
# Measured on the live elspi 2026-09-01. Every device permission the
# application needs is granted by group membership; none of it needs root.
REQUIRED_GROUPS="dialout video render input plugdev netdev spi i2c gpio audio sudo"

for grp in ${REQUIRED_GROUPS}; do
	if ! grep -qE "^${grp}:.*[:,]${SERVICE_USER}(,|\$)" "${ROOTFS_DIR}/etc/group"; then
		echo "FATAL: user '${SERVICE_USER}' is not in group '${grp}'."
		echo "       Upstream stage2 is expected to have done this. If stage2"
		echo "       changed, this stage must add the groups itself."
		exit 1
	fi
done
echo "  groups ok: ${SERVICE_USER} in ${REQUIRED_GROUPS}"

# --- Gate: root must be locked ----------------------------------------------
# stage1 sets root's password to "root"; stage2 then does usermod --pass='*'.
# If that ever stops happening we ship a public image with a known root
# password, so this is a hard gate rather than a note.
if ! grep -qE '^root:[*!]' "${ROOTFS_DIR}/etc/shadow"; then
	echo "FATAL: root's password is not locked in /etc/shadow."
	echo "       stage1 sets root:root and stage2 is expected to clear it."
	exit 1
fi
echo "  root password locked"

on_chroot << EOF
set -e

# --- Lock the service account -----------------------------------------------
# SEAM.md call 2, RATIFIED: no credential enters this repo, and the image ships
# no usable password. The build config had to set FIRST_USER_PASS to a random
# throwaway purely to satisfy build.sh's DISABLE_FIRST_BOOT_USER_RENAME guard
# (build.sh:291 exits 1 without it). That throwaway is revoked here.
#
# Locking the password does NOT block the tty1 autologin in 06-seat: agetty
# --autologin uses login -f, which bypasses authentication. It does mean sudo
# needs a password that does not exist yet -- the interactive provision phase
# sets the real one.
passwd -l ${SERVICE_USER}

# --- Directories the application WRITES to ----------------------------------
# /var/lib/reflex-config is live commissioned machine data. reflex WRITES here,
# so read permission is not enough. It is created empty and owned; the RESTORE
# phase of provisioning fills it, and must HARD FAIL if no backup exists rather
# than generating defaults.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /var/lib/reflex-config

# The Kivy log directory. Do NOT reproduce the live state, which scatters
# root-owned kivy_*.txt files across /var/log.
#
# SEQUENCING TRAP, carried from RUNTIME-INVENTORY.md and NOT optional: this
# directory must exist and be writable BEFORE anything points KCFG_KIVY_LOG_DIR
# at it. In the image the two are created together by construction. The
# constraint therefore lands on the DELTA layer, which installs start.sh -- see
# /etc/elspi-image.json, which declares this path so the delta can gate on it
# instead of assuming it.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /var/log/reflex

# The application root. The delta layer drops the reflex-ui checkout here.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /opt/reflex

# Kivy's config.ini lands in the service user's ~/.kivy by construction now,
# not /root/.kivy. Pre-creating it keeps ownership right on first run.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /home/${SERVICE_USER}/.kivy
EOF

# --- Post-write checks ------------------------------------------------------
for d in var/lib/reflex-config var/log/reflex opt/reflex "home/${SERVICE_USER}/.kivy"; do
	if [ ! -d "${ROOTFS_DIR}/${d}" ]; then
		echo "FATAL: post-write check failed -- /${d} was not created"
		exit 1
	fi
done
echo "  created: /var/lib/reflex-config /var/log/reflex /opt/reflex ~/.kivy"

if ! grep -qE "^${SERVICE_USER}:!" "${ROOTFS_DIR}/etc/shadow"; then
	echo "FATAL: post-write check failed -- ${SERVICE_USER} password is not locked."
	echo "       The build-time throwaway from FIRST_USER_PASS would ship usable."
	exit 1
fi
echo "  ${SERVICE_USER} password locked (build-time throwaway revoked)"
