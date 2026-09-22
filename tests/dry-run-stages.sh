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
#   04-serial         systemctl mask
#   05-service-user   useradd/chown inside the chroot
#   08-venv           uv sync, and the Kivy compile that is the whole risk
#   10a-app-checkout  the chown of the checkout to the service user runs
#                     through on_chroot, exactly as 08-venv's does, so the
#                     substage cannot complete here. Its two interesting
#                     halves ARE covered elsewhere and deliberately:
#                     the SELECTION by tests/test-release-selection.sh
#                     (real synthetic repos, no chroot), and the resulting
#                     checkout by tests/verify-image.sh + tests/self-test.sh
#                     against the fixture. What no offline test can reach is
#                     the clone itself; that is a Tier-1 build item.
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
# 11-manifest also consumes what 10a-app-checkout writes (docs/design/seam.md
# amendment 2026-09-21: the manifest records which release was baked). Same
# arrangement, same reason: supply the facts so the manifest logic can be
# exercised without doing the clone.
echo "v1.1.0" > "${ROOTFS_DIR}/etc/elspi/reflex-app-release"
echo "752da5c0aa8c31eed9ec6fc9301638a03d138953" > "${ROOTFS_DIR}/etc/elspi/reflex-app-commit"
echo "no"  > "${ROOTFS_DIR}/etc/elspi/reflex-app-updater-ready"
echo "no"  > "${ROOTFS_DIR}/etc/elspi/reflex-app-protocol-readable"
run_stage 11-manifest

# THE MANIFEST MUST ACTUALLY CARRY THE BAKED RELEASE. Checked here rather than
# only against the hand-authored fixture, for the reason this whole harness
# exists: verify-image.sh reads a fixture somebody wrote, so the two could
# agree with each other and both disagree with 00-run.sh.
if grep -q '"release": "v1.1.0"' "${ROOTFS_DIR}/etc/elspi-image.json"; then
	echo "  ok: the manifest records the baked release read from /etc/elspi/reflex-app-release"
	PASS=$((PASS+1))
else
	echo "  FAIL: the manifest does not carry baked_app.release=v1.1.0"
	FAIL=$((FAIL+1))
fi
# The yes/no facts must arrive as JSON booleans, not as the strings "no" --
# "updater_ready": "no" is truthy to every consumer that reads it.
if grep -q '"updater_ready": false' "${ROOTFS_DIR}/etc/elspi-image.json"; then
	echo "  ok: updater_ready rendered as a JSON boolean, not the string \"no\""
	PASS=$((PASS+1))
else
	echo "  FAIL: updater_ready is not the JSON literal false"
	grep -n 'updater_ready' "${ROOTFS_DIR}/etc/elspi-image.json" | sed 's/^/        /'
	FAIL=$((FAIL+1))
fi
# The checkout is no longer the delta layer's, and the manifest must not still
# claim it is -- one document, one owner per path.
if grep -q 'reflex monorepo checkout at' "${ROOTFS_DIR}/etc/elspi-image.json"; then
	echo "  FAIL: delta_layer_owns still claims the reflex checkout, which the"
	echo "        image now bakes (docs/design/seam.md amendment 2026-09-21)"
	FAIL=$((FAIL+1))
else
	echo "  ok: delta_layer_owns no longer claims the baked checkout"
	PASS=$((PASS+1))
fi

# 12-first-boot-seed is deliberately chroot-free -- it only rewrites
# /boot/firmware/meta-data and installs a unit under ${ROOTFS_DIR} -- which is
# exactly why it can be exercised here instead of only inside a build.
run_stage 12-first-boot-seed

# 14-first-boot-ui is the same shape as 12-first-boot-seed and chroot-free for
# the same reason. It is a SCAFFOLD (stage-elspi/14-first-boot-ui/README.md),
# not the feature task 6aa73b01 asks for -- it ships the trigger, not a
# converge/start branch, because the payload would move the application
# checkout across docs/design/seam.md's ratified line.
run_stage 14-first-boot-ui

# WHERE THE SUBSTAGE ENABLES THE UNIT, checked here rather than only in
# verify-image.sh, because this is the one harness that runs the REAL substage
# against a real tree -- verify-image.sh reads a hand-authored fixture, so the
# two could agree with each other and both disagree with 00-run.sh.
#
# It must be cloud-init.target.wants and NOT multi-user.target.wants. See
# stage-elspi/12-first-boot-seed/README.md, 2026-09-13: multi-user.target
# plus After=cloud-final.service is an ordering cycle and systemd deletes our
# job to break it.
FBS_SEED_UNIT=elspi-first-boot-seed.service
FBS_CI_WANTS="${ROOTFS_DIR}/etc/systemd/system/cloud-init.target.wants/${FBS_SEED_UNIT}"
FBS_MU_WANTS="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/${FBS_SEED_UNIT}"
if [ -e "${FBS_CI_WANTS}" ]; then
	echo "  ok: seed unit enabled in cloud-init.target.wants and the symlink resolves"
	PASS=$((PASS+1))
else
	echo "  FAIL: seed unit is not enabled in cloud-init.target.wants (or the symlink dangles)"
	FAIL=$((FAIL+1))
fi
if [ -L "${FBS_MU_WANTS}" ] || [ -e "${FBS_MU_WANTS}" ]; then
	echo "  FAIL: seed unit is enabled in multi-user.target.wants -- that is the"
	echo "        ordering cycle with cloud-final.service that stopped it running"
	echo "        on the 2026-09-13 boot"
	FAIL=$((FAIL+1))
else
	echo "  ok: seed unit is not enabled in multi-user.target.wants (no ordering cycle)"
	PASS=$((PASS+1))
fi

# Same two checks, same reason, for 14-first-boot-ui's unit.
FBUI_UNIT_NAME=elspi-first-boot-ui.service
FBUI_CI_WANTS="${ROOTFS_DIR}/etc/systemd/system/cloud-init.target.wants/${FBUI_UNIT_NAME}"
FBUI_MU_WANTS="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/${FBUI_UNIT_NAME}"
if [ -e "${FBUI_CI_WANTS}" ]; then
	echo "  ok: first-boot-ui unit enabled in cloud-init.target.wants and the symlink resolves"
	PASS=$((PASS+1))
else
	echo "  FAIL: first-boot-ui unit is not enabled in cloud-init.target.wants (or the symlink dangles)"
	FAIL=$((FAIL+1))
fi
if [ -L "${FBUI_MU_WANTS}" ] || [ -e "${FBUI_MU_WANTS}" ]; then
	echo "  FAIL: first-boot-ui unit is enabled in multi-user.target.wants -- that is"
	echo "        the same ordering cycle with cloud-final.service, via"
	echo "        elspi-first-boot-seed.service"
	FAIL=$((FAIL+1))
else
	echo "  ok: first-boot-ui unit is not enabled in multi-user.target.wants (no ordering cycle)"
	PASS=$((PASS+1))
fi

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

# 14-first-boot-ui's install+enable is `install` and `ln -sf`, both naturally
# idempotent -- but "naturally idempotent" is exactly the kind of claim this
# repo does not ship untested. A second pass must still pass its own
# post-write checks (00-run.sh) and leave the enablement symlink in place.
if ( cd "${REPO}/stage-elspi/14-first-boot-ui" && ./00-run.sh >/dev/null 2>&1 ); then
	if [ -e "${FBUI_CI_WANTS}" ]; then
		echo "  ok: 14-first-boot-ui is re-runnable and stays enabled after two passes"
		PASS=$((PASS+1))
	else
		echo "  FAIL: 14-first-boot-ui ran twice but the enablement symlink is gone"
		FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL: 14-first-boot-ui is not re-runnable"
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

# THE ORDERING-CYCLE GATE MUST ACTUALLY FIRE. Pre-plant the
# multi-user.target.wants symlink that image_2026-09-13-elspi shipped -- the
# one that made systemd delete the seed unit's job -- and the substage must
# REFUSE. A gate that is never handed the bad state is a gate nobody has seen
# go red.
NEG5="${WORK}/neg5"
mkdir -p "${NEG5}/boot/firmware" "${NEG5}/etc/systemd/system/multi-user.target.wants"
install -m 644 "${REPO}/stage2/04-cloud-init/files/meta-data" "${NEG5}/boot/firmware/"
ln -sf ../elspi-first-boot-seed.service \
	"${NEG5}/etc/systemd/system/multi-user.target.wants/elspi-first-boot-seed.service"
if ( cd "${REPO}/stage-elspi/12-first-boot-seed" && ROOTFS_DIR="${NEG5}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: seed stage accepted a rootfs with the unit enabled in"
	echo "        multi-user.target.wants (the 2026-09-13 ordering cycle)"
	FAIL=$((FAIL+1))
else
	echo "  ok: seed stage refused the multi-user.target.wants enablement (ordering cycle)"
	PASS=$((PASS+1))
fi

# THE MANIFEST'S OWN FULL-RELEASE GATE MUST FIRE. A manifest is what every
# downstream consumer believes, so "v1.2.0-rc.4 got declared as the baked
# release" has to be a build failure and not a line in a log nobody reads.
# Handed the bad state deliberately -- a gate never given it is a gate nobody
# has seen go red.
NEG6="${WORK}/neg6"
mkdir -p "${NEG6}/etc/elspi" "${NEG6}/boot/firmware"
echo "0000000000000000000000000000000000000000" > "${NEG6}/etc/elspi/reflex-lock-commit"
echo "v1.2.0-rc.4" > "${NEG6}/etc/elspi/reflex-app-release"
echo "1dfa05c0000000000000000000000000000000aa" > "${NEG6}/etc/elspi/reflex-app-commit"
echo "yes" > "${NEG6}/etc/elspi/reflex-app-updater-ready"
echo "yes" > "${NEG6}/etc/elspi/reflex-app-protocol-readable"
if ( cd "${REPO}/stage-elspi/11-manifest" && ROOTFS_DIR="${NEG6}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: 11-manifest declared a PRE-RELEASE (v1.2.0-rc.4) as the baked release"
	FAIL=$((FAIL+1))
else
	echo "  ok: 11-manifest refused to declare a pre-release as the baked release"
	PASS=$((PASS+1))
fi

# And it must refuse outright when the fact file is absent, rather than
# inventing a value or omitting the field: an image whose manifest does not say
# what app it carries is an image nobody can reason about after the fact.
NEG7="${WORK}/neg7"
mkdir -p "${NEG7}/etc/elspi" "${NEG7}/boot/firmware"
echo "0000000000000000000000000000000000000000" > "${NEG7}/etc/elspi/reflex-lock-commit"
if ( cd "${REPO}/stage-elspi/11-manifest" && ROOTFS_DIR="${NEG7}" ./00-run.sh >/dev/null 2>&1 ); then
	echo "  FAIL: 11-manifest wrote a manifest with no baked-release record at all"
	FAIL=$((FAIL+1))
else
	echo "  ok: 11-manifest refused when 10a-app-checkout had not recorded a release"
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
