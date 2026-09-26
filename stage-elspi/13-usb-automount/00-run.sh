#!/bin/bash -e

# USB automount for the commissioning bundle's Export/Import buttons.
#
# ORDER 2026-09-16#6. PREMISE (verified against master, tip ad4c518):
# `git grep -i "automount|udisks|systemd-mount|/media"` over stage-elspi,
# docs and deltas finds nothing, so nothing on the image mounts removable
# media today. reflex's ui/reflex/utils/usb.py (integration branch)
# discovers media purely by reading /proc/mounts for a mountpoint under
# /run/media or /media (REMOVABLE_ROOTS, list_removable()) -- it never
# mounts anything itself, on purpose (its own module docstring: no
# subprocess, no polkit prompt, no udisks dependency). So without this
# stage the Setup screen's Export/Import buttons can never find a stick.
#
# DECIDED (Evan): a udev rule plus systemd-mount baked into the image, with
# NO udisks2 and no mount logic in the app. stage2/01-sys-tweaks/00-packages
# already installs udisks2 (for its own reasons, unrelated to this stage);
# this design does not use it. See files/90-elspi-usb-automount.rules for
# why systemd-mount specifically (systemd-udevd.service's PrivateMounts=yes
# rules out a plain `mount` from a udev RUN+=) and for the --bind-device /
# --collect unmount story.

SERVICE_USER="${FIRST_USER_NAME}"

# --- Resolve the service user's uid/gid from the TARGET rootfs -------------
# NOT from the build host: the build host's uid running ./build.sh is an
# accident of who ran the build, and vfat/exfat's kernel uid=/gid= mount
# options accept only numbers, never a username, so the numbers baked into
# the udev rule have to come from somewhere real. stage2/01-sys-tweaks
# already created ${SERVICE_USER} by this point in the stage list, so its
# real uid/gid are read out of ${ROOTFS_DIR}/etc/passwd directly -- no
# on_chroot needed, this is a plain file read, not a privileged operation.
SERVICE_UID="$(awk -F: -v u="${SERVICE_USER}" '$1==u{print $3}' "${ROOTFS_DIR}/etc/passwd")"
SERVICE_GID="$(awk -F: -v u="${SERVICE_USER}" '$1==u{print $4}' "${ROOTFS_DIR}/etc/passwd")"

if [ -z "${SERVICE_UID}" ] || [ -z "${SERVICE_GID}" ]; then
	echo "FATAL: could not resolve uid/gid for '${SERVICE_USER}' from"
	echo "       ${ROOTFS_DIR}/etc/passwd. Upstream stage2 and"
	echo "       stage-elspi/05-service-user are expected to have already"
	echo "       created this user by this point in the stage list."
	exit 1
fi
echo "  resolved ${SERVICE_USER}: uid=${SERVICE_UID} gid=${SERVICE_GID}"

# --- Assert the substitution anchors BEFORE writing -------------------------
# Same discipline as stage-elspi/05-service-user's polkit rule: a template
# whose anchor moved makes the sed below a silent no-op, and the image would
# ship a udev rule mounting every stick 0:0 -- root-owned, unwritable by the
# service user, and the Export button fails with EACCES on the first real
# card instead of in this check.
RULE_SRC="files/90-elspi-usb-automount.rules"
if ! grep -q '@@SERVICE_UID@@' "${RULE_SRC}" || ! grep -q '@@SERVICE_GID@@' "${RULE_SRC}"; then
	echo "FATAL: ${RULE_SRC} has no @@SERVICE_UID@@/@@SERVICE_GID@@ anchor to"
	echo "       substitute. The image would ship a rule with the wrong (or no)"
	echo "       uid/gid, and it would look installed."
	exit 1
fi

install -d -m 0755 "${ROOTFS_DIR}/etc/udev/rules.d"
RULE="${ROOTFS_DIR}/etc/udev/rules.d/90-elspi-usb-automount.rules"
sed -e "s/@@SERVICE_UID@@/${SERVICE_UID}/g" \
    -e "s/@@SERVICE_GID@@/${SERVICE_GID}/g" \
    "${RULE_SRC}" > "${RULE}"
chmod 0644 "${RULE}"

# --- The sanitizer helper ----------------------------------------------------
# Installed as its own file (not inlined in the rule) specifically so
# tests/test-usb-automount-name.sh can drive it directly, without a udev
# environment.
install -d -m 0755 "${ROOTFS_DIR}/usr/local/lib/elspi"
HELPER="${ROOTFS_DIR}/usr/local/lib/elspi/elspi-usb-mount-name"
install -m 0755 files/elspi-usb-mount-name "${HELPER}"

# --- Post-write checks -------------------------------------------------------
if [ ! -f "${RULE}" ]; then
	echo "FATAL: post-write check failed -- the udev rule was not written"
	exit 1
fi
if ! grep -q "uid=${SERVICE_UID}" "${RULE}" || ! grep -q "gid=${SERVICE_GID}" "${RULE}"; then
	echo "FATAL: post-write check failed -- the installed rule does not carry"
	echo "       uid=${SERVICE_UID} gid=${SERVICE_GID}. Contents:"
	sed 's/^/         /' "${RULE}"
	exit 1
fi
if [ "$(stat -c %a "${RULE}")" != "644" ]; then
	echo "FATAL: post-write check failed -- rule mode is $(stat -c %a "${RULE}"),"
	echo "       expected 644"
	exit 1
fi
echo "  udev rule installed: /etc/udev/rules.d/90-elspi-usb-automount.rules (uid=${SERVICE_UID} gid=${SERVICE_GID})"

if [ ! -x "${HELPER}" ]; then
	echo "FATAL: post-write check failed -- ${HELPER} is not executable"
	exit 1
fi
if [ "$(stat -c %a "${HELPER}")" != "755" ]; then
	echo "FATAL: post-write check failed -- helper mode is $(stat -c %a "${HELPER}"),"
	echo "       expected 755"
	exit 1
fi
echo "  helper installed: /usr/local/lib/elspi/elspi-usb-mount-name"
