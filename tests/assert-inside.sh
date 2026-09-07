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
for u in display-manager.service gdm.service lightdm.service; do
	if systemctl cat "${u}" >/dev/null 2>&1; then
		bad "${u} is not present (a display server changes SDL's backend)"
	else
		ok "${u} absent"
	fi
done

# --- tty1 autologin must be INERT in the image -----------------------------
if systemctl cat getty@tty1.service 2>/dev/null | grep -q -- "--autologin"; then
	bad "tty1 autologin is inert (it is selected by elspi-drm-mode, not shipped on)"
else
	ok "tty1 autologin is inert"
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
VENV_PY=$(sed -n 's/.*"venv": "\([^"]*\)".*/\1/p' /etc/elspi-image.json)/bin/python
if [ -x "${VENV_PY}" ]; then
	if OUT="$("${VENV_PY}" -c 'import kivy; print(kivy.__version__)' 2>&1)"; then
		ok "venv imports kivy (version ${OUT})"
	else
		bad "venv imports kivy -- got: ${OUT}"
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

# --- units the delta layer will drop in must be VALID once present ---------
# Nothing to verify yet at image time; recorded so the delta harness inherits
# the obligation rather than discovering it.
echo "  NOTE  reflex-ui.service is a DELTA artifact and is absent by design."

echo "  ---"
echo "  ${P} passed, ${F} failed, ${U} unknown"
if [ "${F}" -eq 0 ]; then
	echo "ELSPI-ASSERT-RESULT: PASS"
else
	echo "ELSPI-ASSERT-RESULT: FAIL"
fi
echo "ELSPI-ASSERT-END"
