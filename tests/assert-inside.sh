#!/bin/bash
# Assertions that only a BOOTED system can answer.
#
# Injected into the rootfs by verify-image.sh --boot, run once by a oneshot
# unit, then removed. It is not part of the image.
#
# Everything checkable by reading files belongs in verify-image.sh's offline
# section, which is faster and needs no privilege. What is here is specifically
# what needs systemd's own view: unit enablement, mask resolution, generator
# output, and whether the interpreter actually runs under qemu-user.

set -uo pipefail

# WRITE TO A FILE, not just the console.
#
# The first attempt scraped systemd-nspawn's --console=pipe. Inside a container
# that produced NOTHING -- systemd's output goes to its journal, not to the
# console nspawn hands you, so the harness reported "did not reach the
# assertion unit" about a unit that may well have run. Console capture is the
# fragile part of this design, so the result goes somewhere that survives the
# boot and can be read from outside afterwards.
#
# /var/log is inside the rootfs, which lives in the build volume, so it is
# still there when nspawn exits. /run would not be: it is tmpfs.
OUT=/var/log/elspi-assert.out
exec > >(tee "${OUT}") 2>&1

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS  $1"; }
bad() { F=$((F+1)); echo "  FAIL  $1"; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi; }

echo "ELSPI-ASSERT-BEGIN"

# --- am I actually booted, or in a chroot? ----------------------------------
# These run in two modes and MUST NOT pretend to be the same one.
#
#   booted  -- systemd-nspawn --boot, systemd is PID 1
#   chroot  -- no init; systemctl still answers from unit files on disk
#
# Most of what is worth asserting here -- is-enabled, masks, unit contents,
# `import kivy` -- is answerable in BOTH. What genuinely needs a running
# manager is is-system-running and the failed-unit list. Those are reported
# UNKNOWN rather than skipped silently when there is no init: a check that
# quietly evaporates in one mode is how a harness ends up claiming more than it
# measured.
U=0
unk() { U=$((U+1)); echo "  UNKN  $1"; }

BOOTED=0
if [ -d /proc/1 ] && grep -qa 'systemd' /proc/1/comm 2>/dev/null; then
	BOOTED=1
fi
echo "  MODE  $([ "${BOOTED}" = 1 ] && echo 'booted (systemd is PID 1)' || echo 'chroot (no init running)')"

if [ "${BOOTED}" = 1 ]; then
	STATE="$(systemctl is-system-running 2>/dev/null || true)"
	case "${STATE}" in
		running|degraded) ok "systemd reached '${STATE}'" ;;
		*)                bad "systemd reached '${STATE}' (expected running/degraded)" ;;
	esac

	# 'degraded' is normal in a container -- hardware units fail with no
	# hardware. Print what failed so a REAL regression is not hidden behind
	# that expectation.
	echo "  --- failed units (expected: hardware-dependent only) ---"
	systemctl --failed --no-legend --no-pager 2>/dev/null | sed 's/^/      /' || true
	echo "  --------------------------------------------------------"
else
	unk "systemd was not started, so 'is-system-running' and the failed-unit list are NOT covered. Everything below is read from unit files on disk."
fi

# --- the mask, as systemd resolves it, not as a symlink on disk ------------
chk "serial-getty@ttyAMA0.service is masked" \
	bash -c '[ "$(systemctl is-enabled serial-getty@ttyAMA0.service 2>/dev/null)" = masked ]'

# --- no display server got pulled in ---------------------------------------
# Test for the UNIT FILE, not `systemctl cat`.
#
# In a chroot, `systemctl cat` prints "Running in chroot, ignoring command
# 'cat'" and EXITS 0 -- for every unit, present or not. Built on that, this
# check reported all three display managers as installed on an image that has
# no display-manager unit at all. A check that cannot pass is the mirror image
# of one that cannot fail, and it is just as much a lie.
#
# Reading the unit paths works identically booted or chrooted.
unit_file_present() { # <unit name>
	local u="$1" d
	for d in /lib/systemd/system /usr/lib/systemd/system /etc/systemd/system; do
		[ -e "${d}/${u}" ] && return 0
	done
	return 1
}

for u in display-manager.service gdm.service gdm3.service lightdm.service sddm.service; do
	if unit_file_present "${u}"; then
		bad "${u} is absent (a display server changes SDL's backend)"
	else
		ok "${u} absent"
	fi
done

# --- there must be NO tty1 autologin at all --------------------------------
# It used to be inert-but-staged, installable by `elspi-drm-mode logind-seat`.
# That mode was deleted 2026-09-13 (first-opener was verified on hardware), so
# nothing installs an autologin any more and the check is unconditional: an
# autologin on a machine nobody can log into to undo it is not a thing to
# tolerate as a side effect.
if systemctl cat getty@tty1.service 2>/dev/null | grep -q -- "--autologin"; then
	bad "no tty1 autologin (the logind-seat mode that installed one is deleted)"
else
	ok "no tty1 autologin"
fi

# --- the interpreter genuinely runs under qemu-user -------------------------
# This is the check that proves the armhf userland is executable at all. If it
# fails, every other 'absent' result above is meaningless.
if PYV="$(/usr/bin/python3 --version 2>&1)"; then
	ok "system python runs: ${PYV}"
else
	bad "system python does not execute in this rootfs"
fi

if UVV="$(/usr/local/bin/uv --version 2>&1)"; then
	ok "uv runs: ${UVV}"
else
	bad "uv does not execute in this rootfs"
fi

# --- the venv imports Kivy --------------------------------------------------
# `import kivy` does NOT create a window, so it is safe without a GPU. It does
# exercise the compiled extensions, which is the expensive thing the build
# produced. It is NOT evidence that the display works -- see the blind spots.
# Record this BEFORE the probe runs, so "the probe created it" and "the image
# shipped it" stay distinguishable. They are different findings with different
# owners, and collapsing them is how the harness ended up deleting an image
# artifact and calling it cleanup.
KIVYROOT_BEFORE="$([ -e /root/.kivy ] && echo PRESENT || echo ABSENT)"

VENV_PY=$(sed -n 's/.*"venv": "\([^"]*\)".*/\1/p' /etc/elspi-image.json)/bin/python
if [ -x "${VENV_PY}" ]; then
	# DO NOT LET KIVY WRITE INTO THE IMAGE.
	#
	# Importing kivy creates ~/.kivy and a log file. Run as root in a chroot
	# that is /root/.kivy -- INSIDE THE ARTIFACT, and precisely the path the
	# 2026-09-01 non-root decision exists to eliminate. The first run of this
	# check created it. A harness that leaves droppings in the thing it is
	# certifying has damaged the evidence.
	#
	# Point Kivy's home and log dir at /tmp, and keep the version out of the
	# banner noise by asking for it on its own line.
	# Kivy's banner goes to stderr, which the redirect below already discards.
	# An earlier version tried sys.stderr.close() to silence it and broke the
	# probe outright: Kivy REPLACES sys.stderr with its own ProcessingStream,
	# which has no close(), so the import raised AttributeError and a working
	# venv reported as "failed to import kivy".
	OUT="$(KIVY_HOME=/tmp/.kivy-probe KCFG_KIVY_LOG_DIR=/tmp KIVY_NO_ARGS=1 \
		"${VENV_PY}" -c 'import kivy; print(kivy.__version__)' 2>/dev/null)"
	if [ -n "${OUT}" ]; then
		ok "venv imports kivy (version ${OUT})"
	else
		bad "venv failed to import kivy"
	fi
	rm -rf /tmp/.kivy-probe
	# DO NOT DELETE /root/.kivy HERE.
	#
	# This used to `rm -rf /root/.kivy` unconditionally, "to clean up". That
	# was wrong twice over. A verification harness must not modify the
	# artifact it certifies -- and worse, it deleted something it had NOT
	# created: a pristine 2026-09-07 build shipped /root/.kivy already, and
	# this line quietly erased the evidence while reporting success.
	#
	# So: compare, never touch. If the probe created it, that is the probe's
	# bug and it fails here. If it was already there, that is an IMAGE
	# finding, reported as such and left in place for the integrity check
	# outside to corroborate.
	if [ "${KIVYROOT_BEFORE}" = "ABSENT" ] && [ -e /root/.kivy ]; then
		bad "this probe CREATED /root/.kivy inside the image"
	elif [ "${KIVYROOT_BEFORE}" = "PRESENT" ]; then
		unk "/root/.kivy was ALREADY in the image before this probe ran -- an image finding, not a harness one. Left in place deliberately."
	else
		ok "this probe did not create /root/.kivy"
	fi
else
	bad "venv python not executable at ${VENV_PY}"
fi

# --- the app is NOT in the image -------------------------------------------
if "${VENV_PY}" -c 'import reflex' >/dev/null 2>&1; then
	bad "reflex is absent from the image venv (it is a delta)"
else
	ok "reflex is absent from the image venv (it is a delta)"
fi

# --- /etc/elspi-release agrees with /etc/elspi-image.json (order 2026-09-14#5) ---
#
# The generation logic lives in stage-elspi/11-manifest/files/render-release.sh
# (its `validate` mode does the same three checks); NOT shelled out to here,
# because this script is copied into the rootfs and run ALONE -- see
# verify-image.sh's `install -m 0755 ... assert-inside.sh ${ASSERT_BIN}` --
# so it cannot assume anything else from the source tree rode along with it.
if [ -f /etc/elspi-release ]; then
	ok "/etc/elspi-release exists"

	if grep -vE '^[A-Za-z_][A-Za-z0-9_]*=.*$|^[[:space:]]*(#.*)?$' /etc/elspi-release | grep -q .; then
		bad "/etc/elspi-release parses as KEY=VALUE"
	else
		ok "/etc/elspi-release parses as KEY=VALUE"
	fi

	# Sourced in a SUBSHELL, never this one, so a malformed flat file cannot
	# clobber this script's own variables.
	FLAT_RELEASE="$(set -a; . /etc/elspi-release 2>/dev/null; printf '%s' "${ELSPI_IMAGE_RELEASE:-}")"
	FLAT_REFLEX="$(set -a; . /etc/elspi-release 2>/dev/null; printf '%s' "${ELSPI_REFLEX_COMMIT:-}")"
	JSON_RELEASE="$(python3 -c "import json; print(json.load(open('/etc/elspi-image.json')).get('image_release',''))" 2>/dev/null)"
	JSON_REFLEX="$(python3 -c "import json; print(json.load(open('/etc/elspi-image.json')).get('reflex_lock_commit',''))" 2>/dev/null)"

	if [ -n "${JSON_RELEASE}" ] && [ "${FLAT_RELEASE}" = "${JSON_RELEASE}" ]; then
		ok "ELSPI_IMAGE_RELEASE (${FLAT_RELEASE}) agrees with /etc/elspi-image.json"
	else
		bad "ELSPI_IMAGE_RELEASE ('${FLAT_RELEASE}') agrees with the manifest's image_release ('${JSON_RELEASE}')"
	fi

	if [ -n "${JSON_REFLEX}" ] && [ "${FLAT_REFLEX}" = "${JSON_REFLEX}" ]; then
		ok "ELSPI_REFLEX_COMMIT (${FLAT_REFLEX}) agrees with /etc/elspi-image.json"
	else
		bad "ELSPI_REFLEX_COMMIT ('${FLAT_REFLEX}') agrees with the manifest's reflex_lock_commit ('${JSON_REFLEX}')"
	fi
else
	bad "/etc/elspi-release exists"
fi

# --- units the delta layer will drop in must be VALID once present ---------
# Nothing to verify yet at image time; recorded so the delta harness inherits
# the obligation rather than discovering it.
echo "  NOTE  reflex-ui.service is a DELTA artifact and is absent by design."

# --- the venv belongs to the service user (Open Loops 6aac9465) -----------
# The in-app updater runs `uv sync` into /opt/reflex-venv as the service user,
# AFTER flashing the firmware; a root-owned venv (the state elspi shipped in
# until 2026-09-17) fails that sync. Every entry, symlinks included, must be
# the service user's -- and the system interpreter bin/python points at must
# still be root's, or a chown followed the link.
VENV_DIR=/opt/reflex-venv
VENV_USER="$(awk -F: '$3>=1000 && $3<65534{print $1; exit}' /etc/passwd)"
if [ -z "${VENV_USER}" ]; then
	unk "no non-system user in /etc/passwd to check ${VENV_DIR}'s owner against"
elif [ ! -d "${VENV_DIR}" ]; then
	bad "${VENV_DIR} is owned by ${VENV_USER} (directory missing)"
else
	NOT_OURS="$(find "${VENV_DIR}" ! -user "${VENV_USER}" -print -quit 2>/dev/null)"
	if [ -z "${NOT_OURS}" ]; then
		ok "${VENV_DIR} is wholly owned by ${VENV_USER}"
	else
		bad "${VENV_DIR} is wholly owned by ${VENV_USER} (first entry that is not: ${NOT_OURS} [$(stat -c %U "${NOT_OURS}")])"
	fi
fi
if [ "$(stat -L -c %u /usr/bin/python3 2>/dev/null)" = "0" ]; then
	ok "/usr/bin/python3 is still root-owned"
else
	bad "/usr/bin/python3 is still root-owned (a venv chown followed a symlink)"
fi

# --- USB automount (stage-elspi/13-usb-automount, order 2026-09-16#6) ------
# Reads unit files and installed files off disk, exactly like the checks
# above -- answerable booted or chrooted, no mount actually needs to happen
# for these.
USB_RULE=/etc/udev/rules.d/90-elspi-usb-automount.rules
USB_HELPER=/usr/local/lib/elspi/elspi-usb-mount-name

chk "the USB automount udev rule exists (${USB_RULE})" \
	test -f "${USB_RULE}"
if [ -f "${USB_RULE}" ]; then
	if [ "$(stat -c %a "${USB_RULE}" 2>/dev/null)" = "644" ]; then
		ok "the USB automount udev rule is mode 644"
	else
		bad "the USB automount udev rule is mode 644 (got $(stat -c %a "${USB_RULE}" 2>/dev/null))"
	fi
else
	bad "the USB automount udev rule is mode 644 (file missing)"
fi

chk "the USB automount name-sanitizer helper exists (${USB_HELPER})" \
	test -f "${USB_HELPER}"
chk "the USB automount name-sanitizer helper is executable" \
	test -x "${USB_HELPER}"
if [ -f "${USB_HELPER}" ]; then
	if [ "$(stat -c %a "${USB_HELPER}" 2>/dev/null)" = "755" ]; then
		ok "the USB automount helper is mode 755"
	else
		bad "the USB automount helper is mode 755 (got $(stat -c %a "${USB_HELPER}" 2>/dev/null))"
	fi
else
	bad "the USB automount helper is mode 755 (file missing)"
fi

# The rule must carry the SERVICE user's ACTUAL uid/gid from THIS image's own
# /etc/passwd, not a literal chosen when the rule was written -- a rule that
# happens to say uid=1000 because 1000 is usually the first user is
# indistinguishable from a rule that CORRECTLY resolved the service user's
# uid, right up until an image is built with a different first user, or the
# uid allocation shifts upstream. So this checks AGREEMENT with the real
# account, not just that some number is present.
if [ -f "${USB_RULE}" ]; then
	FIRST_USER="$(awk -F: '$3>=1000 && $3<65534{print $1; exit}' /etc/passwd)"
	if [ -n "${FIRST_USER}" ]; then
		EXPECT_UID="$(id -u "${FIRST_USER}" 2>/dev/null || true)"
		EXPECT_GID="$(id -g "${FIRST_USER}" 2>/dev/null || true)"
		if [ -n "${EXPECT_UID}" ] && grep -q "uid=${EXPECT_UID}\b" "${USB_RULE}"; then
			ok "the USB automount rule's uid= agrees with ${FIRST_USER}'s real uid (${EXPECT_UID})"
		else
			bad "the USB automount rule's uid= agrees with ${FIRST_USER}'s real uid (${EXPECT_UID}); rule carries: $(grep -o 'uid=[0-9]*' "${USB_RULE}" || echo NONE)"
		fi
		if [ -n "${EXPECT_GID}" ] && grep -q "gid=${EXPECT_GID}\b" "${USB_RULE}"; then
			ok "the USB automount rule's gid= agrees with ${FIRST_USER}'s real gid (${EXPECT_GID})"
		else
			bad "the USB automount rule's gid= agrees with ${FIRST_USER}'s real gid (${EXPECT_GID}); rule carries: $(grep -o 'gid=[0-9]*' "${USB_RULE}" || echo NONE)"
		fi
	else
		unk "no non-system user found in /etc/passwd to compare the rule's uid/gid against"
	fi

	# The number must have a NAME behind it in the source the rule was
	# rendered from, not just be a bare literal here -- i.e. this image's
	# rule is not hand-edited. The rendered rule necessarily contains only
	# the resolved number (that is the point of the substitution), so the
	# thing this can check on a live image is that it is NOT the disarmed
	# template placeholder and NOT the single most common accidental
	# literal (root, uid=0), either of which would indicate the
	# substitution never ran.
	if grep -q '@@SERVICE_UID@@\|@@SERVICE_GID@@' "${USB_RULE}"; then
		bad "the USB automount rule still carries an unsubstituted @@SERVICE_UID@@/@@SERVICE_GID@@ placeholder"
	else
		ok "the USB automount rule has no leftover @@SERVICE_UID@@/@@SERVICE_GID@@ placeholder"
	fi
	if grep -q 'uid=0\b' "${USB_RULE}"; then
		bad "the USB automount rule mounts as uid=0 (root) -- the service user's uid did not resolve"
	else
		ok "the USB automount rule does not mount as uid=0"
	fi
fi

echo "  ---"
echo "  ${P} passed, ${F} failed, ${U} unknown"
if [ "${F}" -eq 0 ]; then
	echo "ELSPI-ASSERT-RESULT: PASS"
else
	echo "ELSPI-ASSERT-RESULT: FAIL"
fi
echo "ELSPI-ASSERT-END"
