#!/bin/bash -e

# THE FIRST-BOOT SEED. Design (a), ratified 2026-09-12.
#
# Raspberry Pi Imager 2.x's OS-customisation page is the SUPPORTED way to seed
# this image: hostname, the `default` account's password, the desktop's public
# key, and the Wi-Fi SSID/PSK are typed into Imager at flash time and land on
# the FAT partition as cloud-init NoCloud files. No credential enters this
# repo or the image -- see docs/design/seam.md.
#
# Imager's seed does not work on a stock cloudinit-rpi image. Three defects,
# all fixed here:
#
#   1. THE DATASOURCE NEVER IDENTIFIES THE INSTANCE. Upstream's
#      stage2/04-cloud-init template carries `instance_id: rpios-image` with an
#      UNDERSCORE. cloud-init 25.2's NoCloud datasource reads `instance-id`
#      (hyphen) and falls back to the literal "nocloud". This substage rewrites
#      it -- rather than editing upstream's template, which would put a second
#      file on the merge surface forever (docs/design/fork.md).
#
#   2. NOTHING TURNS THE RADIO ON. netplan's `regulatory-domain` key is
#      networkd-only and this image uses NetworkManager; and with WPA_COUNTRY
#      unset, upstream stage2/02-net-tweaks writes NetworkManager.state with
#      WirelessEnabled=false and leaves rfkill soft-blocked. A perfectly
#      rendered Wi-Fi keyfile therefore never associates.
#
#   3. THE SEED STAYS ON THE CARD. user-data holds a password hash and
#      network-config holds a 64-hex PSK, on an unencrypted FAT partition that
#      any machine can read.
#
# The runtime half of 2 and 3 cannot happen at image-build time -- there is no
# radio and no seed yet -- so this substage installs a oneshot unit that does
# them on the machine. See files/elspi-first-boot-seed.sh and README.md.
#
# THE EDIT BELOW ASSERTS ITS ANCHOR BEFORE WRITING AND RE-GREPS AFTER, in the
# style of 03-boot-config: a sed that silently matches nothing exits 0 and
# ships an image whose datasource is anonymous.

META="${ROOTFS_DIR}/boot/firmware/meta-data"
UNIT_NAME="elspi-first-boot-seed.service"
SCRIPT_DST="${ROOTFS_DIR}/usr/local/sbin/elspi-first-boot-seed"
UNIT_DST="${ROOTFS_DIR}/etc/systemd/system/${UNIT_NAME}"
# cloud-init.target.wants, NOT multi-user.target.wants. multi-user.target plus
# the unit's After=cloud-final.service is an ORDERING CYCLE on this image, and
# systemd breaks it by deleting our job -- measured on the 2026-09-13 boot; see
# README.md and the [Install] comment in files/${UNIT_NAME}.
WANTS_TARGET="cloud-init.target"
WANTS_DIR="${ROOTFS_DIR}/etc/systemd/system/${WANTS_TARGET}.wants"
# The target we must NOT be enabled in, gated on below.
CYCLE_WANTS="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/${UNIT_NAME}"

# ---------------------------------------------------------------------------
echo "== meta-data: instance-id =="

[ -f "${META}" ] || {
	echo "FATAL: ${META} missing."
	echo "       stage2/04-cloud-init is expected to have installed it."
	echo "       Is ENABLE_CLOUD_INIT=1 still set in the build config?"
	exit 1
}

# A build stamp, not a random value: two flashes of the SAME image should look
# like the same instance to cloud-init, so re-flashing a card does not silently
# re-run per-instance modules against a machine that was already provisioned.
# Imager overwrites this file with its own `instance-id: rpi-imager-<epoch>`
# when the customisation page is used; this value is what the image carries on
# its own, and it is what makes the image's OWN seed work unassisted.
STAMP="${GIT_HASH:-${IMG_DATE:-unknown}}"
STAMP="${STAMP:0:12}"
NEW_ID="elspi-${STAMP}"

if grep -qE '^instance-id:' "${META}"; then
	# Idempotent: pi-gen re-runs stages on a resumed build.
	echo "  already hyphenated: $(grep -E '^instance-id:' "${META}")"
else
	grep -qxF "instance_id: rpios-image" "${META}" || {
		echo "FATAL: anchor 'instance_id: rpios-image' not found in ${META}."
		echo "       Upstream changed the cloud-init template. Re-derive this"
		echo "       edit; do NOT assume the misspelling is still there, and do"
		echo "       NOT assume it has been fixed."
		echo "       Current contents:"
		sed 's/^/         /' "${META}"
		exit 1
	}
	sed -i "s|^instance_id: rpios-image\$|instance-id: ${NEW_ID}|" "${META}"
	echo "  rewrote: instance_id: rpios-image -> instance-id: ${NEW_ID}"
fi

# POST-WRITE CHECKS. Both directions: the hyphen must be there AND the
# underscore must be gone. Asserting only the first would pass a file carrying
# both keys, where cloud-init's behaviour depends on YAML key order.
grep -qE '^instance-id: .+' "${META}" || {
	echo "FATAL: post-write check failed -- no 'instance-id:' line in ${META}"
	exit 1
}
if grep -qE '^instance_id:' "${META}"; then
	echo "FATAL: post-write check failed -- the misspelled 'instance_id:' key is"
	echo "       STILL present in ${META}. A file with both keys is ambiguous."
	exit 1
fi
echo "  ok: ${META} carries a hyphenated instance-id and no underscored one"

# ---------------------------------------------------------------------------
echo "== first-boot seed unit =="

install -v -m 0755 -D files/elspi-first-boot-seed.sh "${SCRIPT_DST}"
install -v -m 0644 -D "files/${UNIT_NAME}" "${UNIT_DST}"

# ENABLED BY SYMLINK, NOT BY on_chroot systemctl.
#
# This is exactly what `systemctl enable` produces for a unit in
# /etc/systemd/system whose [Install] section says WantedBy=cloud-init.target,
# and doing it directly keeps this whole substage chroot-free -- which is why
# tests/dry-run-stages.sh can run it in seconds on any Linux box instead of
# only inside a three-hour emulated build. 04-serial needs on_chroot because
# `systemctl mask` has no equally obvious file form; this does not.
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
# The symlink must RESOLVE. A dangling enablement symlink is the failure mode
# that looks enabled to `ls` and is silently ignored by systemd.
[ -e "${WANTS_DIR}/${UNIT_NAME}" ] || {
	echo "FATAL: post-write check failed -- the enablement symlink for"
	echo "       ${UNIT_NAME} dangles. Target: $(readlink "${WANTS_DIR}/${UNIT_NAME}")"
	exit 1
}

# The unit must actually declare the target it is linked into, or the
# enablement above is a symlink we invented rather than the one systemctl
# would have made.
grep -qxF "WantedBy=${WANTS_TARGET}" "${UNIT_DST}" || {
	echo "FATAL: ${UNIT_NAME} does not declare WantedBy=${WANTS_TARGET},"
	echo "       so the ${WANTS_TARGET}.wants symlink is not what"
	echo "       'systemctl enable' would have produced."
	exit 1
}

# THE ORDERING-CYCLE GATE, both halves. This is what the 2026-09-13 boot cost.
#
# multi-user.target wants us + we are After=cloud-final.service +
# cloud-final.service is After=multi-user.target == a cycle, which systemd
# breaks by DELETING our job. The unit then never runs and nothing looks
# broken: no failed unit, no error, an empty ExecMainStartTimestamp, and a
# seed still sitting on the FAT partition.
#
# Written as `if` rather than `cmd && { exit 1; }` on purpose: under `bash -e`
# a gate whose test legitimately returns non-zero in the GOOD case is one
# stray refactor away from either exiting the build or being skipped.
if [ -L "${CYCLE_WANTS}" ] || [ -e "${CYCLE_WANTS}" ]; then
	echo "FATAL: post-write check failed -- ${UNIT_NAME} is ALSO enabled in"
	echo "       multi-user.target.wants. That is an ordering cycle with"
	echo "       cloud-final.service and systemd will delete this unit's job"
	echo "       to break it, exactly as it did on 2026-09-13."
	exit 1
fi
if grep -qxF "WantedBy=multi-user.target" "${UNIT_DST}"; then
	echo "FATAL: post-write check failed -- ${UNIT_NAME} still declares"
	echo "       WantedBy=multi-user.target, so any later 'systemctl reenable'"
	echo "       would restore the ordering cycle with cloud-final.service."
	exit 1
fi

# The script must not be able to fail the boot. Checked here rather than
# trusted, because "never fails the boot" is a hard requirement on a machine
# with no terminal: a seed script that exits non-zero must still leave the
# lathe reachable.
grep -qE '^ExecStart=-' "${UNIT_DST}" || {
	echo "FATAL: ${UNIT_NAME} must prefix ExecStart with '-' so a failing seed"
	echo "       script cannot fail the boot of a machine with no terminal."
	exit 1
}

echo "  installed: /usr/local/sbin/elspi-first-boot-seed (0755)"
echo "  installed: /etc/systemd/system/${UNIT_NAME}"
echo "  enabled:   ${WANTS_TARGET}.wants/${UNIT_NAME}"
echo "  ok: not enabled in multi-user.target.wants (no cloud-final ordering cycle)"
