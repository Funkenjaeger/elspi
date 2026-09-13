#!/bin/bash
# Exercise the chroot-free stage scripts against a scratch rootfs.
#
#   tests/dry-run-stages.sh
#
# A pi-gen build takes hours and needs Docker, qemu and root. Most of what can
# go wrong in these particular scripts cannot wait that long to be found: they
# are sed edits against upstream templates, and a sed whose anchor has moved
# matches nothing, exits 0, and ships an image with SPI switched off.
#
# So the substages that touch only ${ROOTFS_DIR} -- no on_chroot -- are run
# here against a scratch tree seeded with THE REAL upstream stage1 templates.
# That makes this a genuine test of the anchors, not of a fixture someone wrote
# to match the code.
#
# NOT covered (they need a real chroot with an armhf interpreter):
#   04-serial        systemctl mask
#   05-service-user  useradd/chown inside the chroot
#   08-venv          uv sync, and the Kivy compile that is the whole risk
# Those are Tier-1/Tier-2 build items. This script does not pretend otherwise.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export ROOTFS_DIR="${WORK}/rootfs"
export FIRST_USER_NAME=default

mkdir -p "${ROOTFS_DIR}"/boot/firmware "${ROOTFS_DIR}"/etc "${ROOTFS_DIR}"/usr/local/bin

# Seed with the REAL upstream templates. If upstream moves these, the anchor
# checks below start failing here rather than three hours into a build.
install -m 644 "${REPO}/stage1/00-boot-files/files/config.txt"  "${ROOTFS_DIR}/boot/firmware/"
install -m 644 "${REPO}/stage1/00-boot-files/files/cmdline.txt" "${ROOTFS_DIR}/boot/firmware/"

# The REAL upstream cloud-init meta-data template, for the same reason: if
# upstream ever fixes (or moves) its misspelled `instance_id` key, the anchor
# assertion in 12-first-boot-seed starts failing HERE rather than three hours
# into a build -- or, worse, than not at all.
install -m 644 "${REPO}/stage2/04-cloud-init/files/meta-data" "${ROOTFS_DIR}/boot/firmware/"

PASS=0; FAIL=0
run_stage() { # run_stage <substage-dir>
	local d="$1"
	printf '\n\033[1m-- %s --\033[0m\n' "${d}"
	if ( cd "${REPO}/stage-elspi/${d}" && ./00-run.sh ); then
		PASS=$((PASS+1))
	else
		echo "  STAGE FAILED: ${d}"
		FAIL=$((FAIL+1))
	fi
}

run_stage 03-boot-config
run_stage 06-seat
run_stage 09-audio

# 07-uv downloads a pinned tarball and verifies its checksum. Skipped without
# network, and reported as skipped rather than passed.
if curl -fsS --max-time 10 -o /dev/null https://github.com 2>/dev/null; then
	run_stage 07-uv
else
	echo
	echo "-- 07-uv --"
	echo "  SKIPPED (no network). NOT a pass: the checksum gate was not exercised."
fi

# 11-manifest consumes what 08-venv writes; supply it so the manifest logic can
# be exercised without the venv build.
install -d "${ROOTFS_DIR}/etc/elspi"
echo "0000000000000000000000000000000000000000" > "${ROOTFS_DIR}/etc/elspi/reflex-lock-commit"
run_stage 11-manifest

# 12-first-boot-seed is deliberately chroot-free -- it only rewrites
# /boot/firmware/meta-data and installs a unit under ${ROOTFS_DIR} -- which is
# exactly why it can be exercised here instead of only inside a build.
run_stage 12-first-boot-seed

# --- IDEMPOTENCE ------------------------------------------------------------
# pi-gen re-runs stages on a resumed build. A second pass must not double-append
# usb_max_current_enable or re-break an already-correct file.
echo
printf '\033[1m-- second pass (idempotence) --\033[0m\n'
if ( cd "${REPO}/stage-elspi/03-boot-config" && ./00-run.sh >/dev/null ); then
	DUPES=$(grep -c "^usb_max_current_enable=1$" "${ROOTFS_DIR}/boot/firmware/config.txt")
	if [ "${DUPES}" -eq 1 ]; then
		echo "  ok: usb_max_current_enable appears exactly once after two passes"
		PASS=$((PASS+1))
	else
		echo "  FAIL: usb_max_current_enable appears ${DUPES} times after two passes"
		FAIL=$((FAIL+1))
	fi
	TOKENS=$(grep -o "quiet" "${ROOTFS_DIR}/boot/firmware/cmdline.txt" | wc -l)
	if [ "${TOKENS}" -eq 1 ]; then
		echo "  ok: cmdline token 'quiet' appears exactly once after two passes"
		PASS=$((PASS+1))
	else
		echo "  FAIL: cmdline token 'quiet' appears ${TOKENS} times after two passes"
		FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL: 03-boot-config is not re-runnable"
	FAIL=$((FAIL+1))
fi

# The seed substage must survive a resumed build too. Its first pass consumed
# the `instance_id` anchor, so a second pass has to take the already-done path
# rather than failing for a missing anchor.
if ( cd "${REPO}/stage-elspi/12-first-boot-seed" && ./00-run.sh >/dev/null 2>&1 ); then
	IDS=$(grep -c "^instance-id:" "${ROOTFS_DIR}/boot/firmware/meta-data")
	OLD=$(grep -c "^instance_id:" "${ROOTFS_DIR}/boot/firmware/meta-data" || true)
	if [ "${IDS}" -eq 1 ] && [ "${OLD}" -eq 0 ]; then
		echo "  ok: meta-data has exactly one instance-id and no instance_id after two passes"
		PASS=$((PASS+1))
	else
		echo "  FAIL: after two passes meta-data has ${IDS} instance-id and ${OLD} instance_id lines"
		FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL: 12-first-boot-seed is not re-runnable"
	FAIL=$((FAIL+1))
fi

# --- NEGATIVE CONTROL -------------------------------------------------------
# The anchor guard must actually fire. Remove upstream's Pi 5 SPI block and the
# stage must REFUSE, because that is precisely the regression ospi shipped.
echo
printf '\033[1m-- negative control: the guards must fire --\033[0m\n'
NEG="${WORK}/neg"
mkdir -p "${NEG}/boot/firmware"
grep -v "dtoverlay=nospi10" "${REPO}/stage1/00-boot-files/files/config.txt" > "${NEG}/boot/firmware/config.txt"
install -m 644 "${REPO}/stage1/00-boot-files/files/cmdline.txt" "${NEG}/boot/firmware/cmdline.txt"
if ( cd "${REPO}/stage-elspi/03-boot-config" && ROOTFS_DIR="${NEG}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: stage accepted a config.txt with the Pi 5 nospi10 block missing"
	FAIL=$((FAIL+1))
else
	echo "  ok: stage refused a config.txt missing the Pi 5 nospi10 block"
	PASS=$((PASS+1))
fi

NEG2="${WORK}/neg2"
mkdir -p "${NEG2}/boot/firmware"
sed 's|^#dtparam=spi=on|dtparam=spi=REMOVED|' "${REPO}/stage1/00-boot-files/files/config.txt" \
	| grep -v "^dtparam=spi=REMOVED" > "${NEG2}/boot/firmware/config.txt"
install -m 644 "${REPO}/stage1/00-boot-files/files/cmdline.txt" "${NEG2}/boot/firmware/cmdline.txt"
if ( cd "${REPO}/stage-elspi/03-boot-config" && ROOTFS_DIR="${NEG2}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: stage accepted a config.txt with no spi anchor at all"
	FAIL=$((FAIL+1))
else
	echo "  ok: stage refused a config.txt with no spi anchor (sed would have no-opped)"
	PASS=$((PASS+1))
fi

# Same question for the seed substage. A meta-data carrying NEITHER the
# upstream misspelling nor an already-hyphenated key means upstream moved the
# template; the stage must REFUSE rather than ship an image whose NoCloud
# datasource falls back to the literal "nocloud".
NEG3="${WORK}/neg3"
mkdir -p "${NEG3}/boot/firmware"
grep -v "instance_id" "${REPO}/stage2/04-cloud-init/files/meta-data" \
	> "${NEG3}/boot/firmware/meta-data"
if ( cd "${REPO}/stage-elspi/12-first-boot-seed" && ROOTFS_DIR="${NEG3}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: seed stage accepted a meta-data with no instance_id anchor"
	FAIL=$((FAIL+1))
else
	echo "  ok: seed stage refused a meta-data with no instance_id anchor"
	PASS=$((PASS+1))
fi

# And it must refuse outright if meta-data is absent, rather than creating one
# -- an invented seed file would mask a mis-set ENABLE_CLOUD_INIT.
NEG4="${WORK}/neg4"
mkdir -p "${NEG4}/boot/firmware"
if ( cd "${REPO}/stage-elspi/12-first-boot-seed" && ROOTFS_DIR="${NEG4}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: seed stage accepted a boot partition with no meta-data at all"
	FAIL=$((FAIL+1))
else
	echo "  ok: seed stage refused a boot partition with no meta-data"
	PASS=$((PASS+1))
fi

echo
echo "== resulting config.txt (tail) =="
tail -8 "${ROOTFS_DIR}/boot/firmware/config.txt" | sed 's/^/  /'
echo "== resulting cmdline.txt =="
sed 's/^/  /' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
