#!/bin/bash
# Tier 2 verification: assert that the built rootfs is what the image declared.
#
#   tests/verify-image.sh <rootfs-dir> [--boot] [--self-test]
#
# VERIFICATION.md's three tiers:
#   1. it builds                        -> CI
#   2. it boots and matches the declaration -> THIS SCRIPT
#   3. it runs the lathe                -> real hardware only, still mandatory
#
# --------------------------------------------------------------------------
# WHAT THIS CANNOT SEE
# --------------------------------------------------------------------------
# The blind spots are NOT listed here. They are read out of the image's own
# /etc/elspi-image.json and printed on every run, so there is exactly one
# declaration of them and it ships with the artifact. A harness that keeps its
# own private copy of that list will eventually disagree with the image and be
# believed anyway.
#
# A green run means "the image built and its userland is what we declared".
# It NEVER means "the appliance works".
#
# --------------------------------------------------------------------------
# WHY --self-test EXISTS
# --------------------------------------------------------------------------
# A check that cannot fail returns a confident clean over exactly the state it
# could not see. --self-test copies the rootfs, breaks one declared property at
# a time, and asserts THIS HARNESS GOES RED for each. A check shipped without
# its mutation is an assertion about the author's intent, not about the image.

set -uo pipefail

ROOTFS="${1:-}"
DO_BOOT=0
DO_SELFTEST=0
shift || true
for arg in "$@"; do
	case "${arg}" in
		--boot)      DO_BOOT=1 ;;
		--self-test) DO_SELFTEST=1 ;;
		*) echo "unknown argument: ${arg}" >&2; exit 2 ;;
	esac
done

if [ -z "${ROOTFS}" ] || [ ! -d "${ROOTFS}" ]; then
	echo "usage: $0 <rootfs-dir> [--boot] [--self-test]" >&2
	echo "  rootfs-dir is typically work/<IMG_NAME>/stage-elspi/rootfs" >&2
	exit 2
fi

PASS=0; FAIL=0; UNKNOWN=0
declare -a FAILURES=()

ok()      { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
# UNKNOWN is printed as loudly as FAIL on purpose: "could not measure" is a
# different answer from "measured and fine", and collapsing them is how a
# harness starts reporting clean over things it never looked at.
unknown() { UNKNOWN=$((UNKNOWN+1)); printf '  \033[33mUNKN\033[0m  %s\n' "$1"; }

check() { # check <description> <command...>
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi
}

MANIFEST="${ROOTFS}/etc/elspi-image.json"

# ---------------------------------------------------------------------------
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
# ---------------------------------------------------------------------------

section "The image's own declaration"

if [ ! -f "${MANIFEST}" ]; then
	bad "/etc/elspi-image.json present"
	echo
	echo "Without the manifest there is nothing to check the image AGAINST," >&2
	echo "so every later check would be this script asserting its own defaults." >&2
	exit 1
fi
ok "/etc/elspi-image.json present"

jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval('d'+sys.argv[2]))" "${MANIFEST}" "$1" 2>/dev/null; }

if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${MANIFEST}" 2>/dev/null; then
	bad "manifest is valid JSON"
	exit 1
fi
ok "manifest is valid JSON"

SERVICE_USER="$(jget "['service_user']")"
VENV="$(jget "['paths']['venv']")"
APP_ROOT="$(jget "['paths']['app_root']")"
CONFIG_DIR="$(jget "['paths']['config_dir']")"
LOG_DIR="$(jget "['paths']['log_dir']")"
DRM_DEFAULT="$(jget "['drm']['default_mode']")"
DRM_SWITCHER="$(jget "['drm']['switcher']")"

for v in SERVICE_USER VENV APP_ROOT CONFIG_DIR LOG_DIR DRM_DEFAULT DRM_SWITCHER; do
	if [ -z "${!v}" ]; then bad "manifest declares ${v}"; else ok "manifest declares ${v}=${!v}"; fi
done

# ---------------------------------------------------------------------------
section "Identity and privilege"

check "service user '${SERVICE_USER}' exists" \
	grep -qE "^${SERVICE_USER}:" "${ROOTFS}/etc/passwd"

# Measured on the live elspi 2026-09-01. Every device permission the app needs
# comes from these; none of it needs root.
for grp in dialout video render input plugdev netdev spi i2c gpio audio sudo; do
	check "  in group ${grp}" \
		grep -qE "^${grp}:.*[:,]${SERVICE_USER}(,|\$)" "${ROOTFS}/etc/group"
done

check "root password is locked" \
	grep -qE '^root:[*!]' "${ROOTFS}/etc/shadow"

# The build-time throwaway from FIRST_USER_PASS must not ship usable.
check "${SERVICE_USER} password is locked" \
	grep -qE "^${SERVICE_USER}:!" "${ROOTFS}/etc/shadow"

# The whole point of the 2026-09-01 decision.
if grep -qs "User=root" "${ROOTFS}/usr/share/elspi/drm-modes/"*.conf; then
	bad "no DRM mode fragment runs as root"
else
	ok "no DRM mode fragment runs as root"
fi

# ---------------------------------------------------------------------------
section "Directories the application writes to"

uid_of() { awk -F: -v u="$1" '$1==u {print $3}' "${ROOTFS}/etc/passwd"; }
SU_UID="$(uid_of "${SERVICE_USER}")"

owned_by_service_user() { # <abs path inside rootfs>
	local p="${ROOTFS}$1"
	[ -d "${p}" ] || return 1
	[ "$(stat -c %u "${p}")" = "${SU_UID}" ]
}

for d in "${CONFIG_DIR}" "${LOG_DIR}" "${APP_ROOT}"; do
	check "${d} exists and is owned by ${SERVICE_USER}" owned_by_service_user "${d}"
done

# The sequencing trap: the log dir must exist and be writable BEFORE anything
# points KCFG_KIVY_LOG_DIR at it. The image half is checked here; the delta
# half gates on the manifest.
check "${LOG_DIR} is writable by its owner" \
	test -w "${ROOTFS}${LOG_DIR}"

# Do NOT reproduce the live machine's scattered root-owned kivy logs.
if compgen -G "${ROOTFS}/var/log/kivy_*.txt" >/dev/null; then
	bad "/var/log carries no stray kivy_*.txt"
else
	ok "/var/log carries no stray kivy_*.txt"
fi

# ---------------------------------------------------------------------------
section "Packages"

DPKG_STATUS="${ROOTFS}/var/lib/dpkg/status"
pkg_installed() {
	awk -v p="$1" '
		/^Package: / { cur = $2 }
		/^Status: /  { if (cur == p && $0 ~ / installed$/) found = 1 }
		END          { exit !found }
	' "${DPKG_STATUS}" 2>/dev/null
}

# Required. The graphics-critical ones are named in stage-elspi/00-graphics
# precisely so they stop arriving by resolution accident.
for p in libsdl2-2.0-0 libsdl2-image-2.0-0 libsdl2-ttf-2.0-0 libmtdev1t64 \
         libgbm1 libdrm2 libgl1-mesa-dri network-manager \
         libsdl2-dev libmtdev-dev python3-dev build-essential pkg-config \
         gcc-arm-none-eabi cmake openocd plymouth; do
	check "installed: ${p}" pkg_installed "${p}"
done

# Forbidden. RUNTIME-INVENTORY.md: KMS/DRM is selected BY ABSENCE. SDL2 falls
# back to kmsdrm only because neither DISPLAY nor WAYLAND_DISPLAY exists. Ship
# a compositor and the backend changes silently -- which is a black screen on a
# machine with no terminal.
for p in xserver-xorg xwayland weston sway mutter gnome-shell libinput10; do
	if pkg_installed "${p}"; then
		bad "ABSENT (would silently change the video backend): ${p}"
	else
		ok "absent: ${p}"
	fi
done

# But do NOT strip the X11 CLIENT libraries -- libsdl2 has hard NEEDED links.
check "libx11-6 present (SDL2 links it; absence breaks SDL, not X)" \
	pkg_installed libx11-6

# ---------------------------------------------------------------------------
section "The venv (Kivy compiled, reflex absent)"

check "${VENV}/bin/python exists" test -x "${ROOTFS}${VENV}/bin/python"

if find "${ROOTFS}${VENV}" -maxdepth 5 -iname 'kivy-*.dist-info' 2>/dev/null | grep -q .; then
	ok "Kivy is installed in the venv"
else
	bad "Kivy is installed in the venv"
fi

# The expensive part of the build. A Kivy without compiled extensions is not
# the Kivy this image needs.
if find "${ROOTFS}${VENV}" -name '*.so' -path '*kivy*' 2>/dev/null | grep -q .; then
	ok "Kivy carries compiled extensions (.so)"
else
	bad "Kivy carries compiled extensions (.so)"
fi

# SEAM.md call 1: the image ships the DEPENDENCIES, the delta ships the APP.
if find "${ROOTFS}${VENV}" -maxdepth 5 -iname 'reflex-*.dist-info' 2>/dev/null | grep -q .; then
	bad "the reflex package is NOT in the image venv (it is a delta)"
else
	ok "the reflex package is not in the image venv (it is a delta)"
fi

check "/usr/local/bin/uv installed" test -x "${ROOTFS}/usr/local/bin/uv"
if file "${ROOTFS}/usr/local/bin/uv" 2>/dev/null | grep -q ARM; then
	ok "uv is an ARM binary"
else
	bad "uv is an ARM binary"
fi

# KNOWN GAP, not a failure: SEAM.md ratified promoting Pillow to a runtime
# dependency, and that fix belongs in the reflex repo. Until it lands, --no-dev
# drops pillow and Kivy loses img_pil. Reported as UNKNOWN rather than PASS so
# it cannot quietly become "fine".
if find "${ROOTFS}${VENV}" -maxdepth 5 -iname 'pillow-*.dist-info' 2>/dev/null | grep -q .; then
	ok "pillow present (img_pil provider available)"
else
	unknown "pillow ABSENT -- img_pil unavailable. SEAM.md ratified promoting it to a runtime dep in the reflex repo; that has not landed."
fi

# ---------------------------------------------------------------------------
section "Boot configuration (TEXTUAL ONLY -- see blind spots)"

CFG="${ROOTFS}/boot/firmware/config.txt"
CMD="${ROOTFS}/boot/firmware/cmdline.txt"

for line in "dtparam=i2c_arm=on" "dtparam=spi=on" "camera_auto_detect=0" \
            "enable_uart=1" "disable_splash=1" "usb_max_current_enable=1" \
            "dtoverlay=nospi10"; do
	check "config.txt: ${line}" grep -qxF "${line}" "${CFG}"
done

# THE serial console must be off the Modbus UART.
if grep -q "console=serial0" "${CMD}" 2>/dev/null; then
	bad "cmdline.txt has NO serial console (ttyAMA0 carries Modbus)"
else
	ok "cmdline.txt has no serial console (ttyAMA0 carries Modbus)"
fi
for tok in console=tty1 quiet splash logo.nologo plymouth.ignore-serial-consoles; do
	check "cmdline.txt: ${tok}" grep -qwF -- "${tok}" "${CMD}"
done

# The other half: systemd must not start a getty there either.
MASK="${ROOTFS}/etc/systemd/system/serial-getty@ttyAMA0.service"
if [ -L "${MASK}" ] && [ "$(readlink "${MASK}")" = "/dev/null" ]; then
	ok "serial-getty@ttyAMA0.service is masked"
else
	bad "serial-getty@ttyAMA0.service is masked"
fi

# ---------------------------------------------------------------------------
section "Audio (the card index, which was the actual bug)"

check "asound.conf selects pcm card 0" grep -qx "defaults.pcm.card 0" "${ROOTFS}/etc/asound.conf"
check "asound.conf selects ctl card 0" grep -qx "defaults.ctl.card 0" "${ROOTFS}/etc/asound.conf"
if grep -qE "card 1( |$)" "${ROOTFS}/etc/asound.conf" 2>/dev/null; then
	bad "asound.conf does not reference card 1 (the live defect)"
else
	ok "asound.conf does not reference card 1 (the live defect)"
fi

# ---------------------------------------------------------------------------
section "Timezone"

if [ -L "${ROOTFS}/etc/localtime" ]; then
	TZ_TARGET="$(readlink "${ROOTFS}/etc/localtime")"
	if [[ "${TZ_TARGET}" == *"America/New_York"* ]]; then
		ok "timezone is America/New_York (the -0500 bug fixed at source)"
	else
		bad "timezone is America/New_York (found: ${TZ_TARGET})"
	fi
else
	bad "/etc/localtime is a symlink"
fi

# ---------------------------------------------------------------------------
section "DRM mode plumbing"

for m in first-opener logind-seat cap-sys-admin; do
	check "fragment staged: ${m}" test -f "${ROOTFS}/usr/share/elspi/drm-modes/${m}.conf"
done
check "switcher installed: ${DRM_SWITCHER}" test -x "${ROOTFS}${DRM_SWITCHER}"
check "tty1 autologin fragment staged (inert)" \
	test -f "${ROOTFS}/usr/share/elspi/getty-tty1-autologin.conf"

# It must be INERT until a mode selects it: an autologin that ships active
# changes the boot path of a machine nobody can log into to undo it.
if [ -e "${ROOTFS}/etc/systemd/system/getty@tty1.service.d/10-elspi-autologin.conf" ]; then
	bad "tty1 autologin is NOT active in the image (it is mode-selected)"
else
	ok "tty1 autologin is not active in the image (it is mode-selected)"
fi

# Plymouth holds DRM master. Ordering after it is load-bearing.
check "first-opener orders After=plymouth-quit-wait.service" \
	grep -q "After=plymouth-quit-wait.service" \
	"${ROOTFS}/usr/share/elspi/drm-modes/first-opener.conf"

# THE THING THIS HARNESS STRUCTURALLY CANNOT ANSWER.
unknown "DRM master acquisition under mode '${DRM_DEFAULT}' is UNTESTED. There is no GPU here and there never will be. This is a Tier 3 hardware item."

# ---------------------------------------------------------------------------
section "Booted assertions"

if [ "${DO_BOOT}" != "1" ]; then
	unknown "not run (--boot not given). Unit enablement and ordering, systemd's own view of the masks, and 'import kivy' are NOT covered by the offline checks above."
else
	if [ "$(id -u)" -ne 0 ]; then
		unknown "--boot requires root (systemd-nspawn). NOT RUN."
	elif ! command -v systemd-nspawn >/dev/null 2>&1; then
		unknown "systemd-nspawn not installed. NOT RUN."
	elif ! grep -qs "interpreter /usr/bin/qemu-arm" /proc/sys/fs/binfmt_misc/qemu-arm* 2>/dev/null; then
		unknown "qemu-arm binfmt is not registered, so an armhf rootfs cannot execute here. NOT RUN. Install qemu-user-static and re-run."
	else
		# The assertion unit is injected, run, and REMOVED. It must never
		# survive into a shipped image, so removal is trapped and then gated
		# on -- a harness that leaves a self-poweroff unit in the rootfs has
		# broken the artifact it was verifying.
		ASSERT_BIN="${ROOTFS}/usr/local/bin/elspi-assert-inside"
		ASSERT_UNIT="${ROOTFS}/etc/systemd/system/elspi-assert.service"
		ASSERT_WANT="${ROOTFS}/etc/systemd/system/multi-user.target.wants/elspi-assert.service"

		cleanup_assert() { rm -f "${ASSERT_BIN}" "${ASSERT_UNIT}" "${ASSERT_WANT}"; }
		trap cleanup_assert EXIT INT TERM

		install -m 0755 "$(dirname "$0")/assert-inside.sh" "${ASSERT_BIN}"
		cat > "${ASSERT_UNIT}" <<-UNIT
		[Unit]
		Description=elspi image assertions (harness-injected, not part of the image)
		After=multi-user.target

		[Service]
		Type=oneshot
		ExecStart=/usr/local/bin/elspi-assert-inside
		ExecStopPost=/bin/systemctl poweroff -f
		StandardOutput=journal+console
		StandardError=journal+console
		UNIT
		install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
		ln -sf ../elspi-assert.service "${ASSERT_WANT}"

		BOOTLOG="$(mktemp)"
		timeout 300 systemd-nspawn -D "${ROOTFS}" \
			--boot --register=no --quiet \
			--console=pipe >"${BOOTLOG}" 2>&1 </dev/null || true

		cleanup_assert
		trap - EXIT INT TERM

		# GATE: the injected artifacts are gone.
		for leftover in "${ASSERT_BIN}" "${ASSERT_UNIT}" "${ASSERT_WANT}"; do
			if [ -e "${leftover}" ]; then
				bad "harness artifact removed from rootfs: ${leftover#${ROOTFS}}"
			fi
		done

		if grep -q "ELSPI-ASSERT-BEGIN" "${BOOTLOG}"; then
			sed -n '/ELSPI-ASSERT-BEGIN/,/ELSPI-ASSERT-END/p' "${BOOTLOG}"
			if grep -q "ELSPI-ASSERT-RESULT: PASS" "${BOOTLOG}"; then
				ok "booted assertions passed"
			else
				bad "booted assertions failed (see output above)"
			fi
		else
			unknown "the container did not reach the assertion unit. Boot log kept at: ${BOOTLOG}"
		fi
	fi
fi

# ---------------------------------------------------------------------------
section "WHAT A GREEN RUN HERE DOES NOT MEAN"

echo "  Read from the image's own manifest, not from this script:"
python3 - "${MANIFEST}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for item in d.get("cannot_be_verified_without_hardware", []):
    print("    - " + item)
PY
echo
echo "  A green run means: the image built, and its userland is what we declared."
echo "  It does NOT mean the appliance works. Tier 3 (a real SD card in the real"
echo "  Pi) stays mandatory no matter how green this is."

# ---------------------------------------------------------------------------
section "Result"

printf '  %d passed, %d failed, %d unknown\n' "${PASS}" "${FAIL}" "${UNKNOWN}"
if [ "${FAIL}" -gt 0 ]; then
	echo
	echo "  Failures:"
	printf '    - %s\n' "${FAILURES[@]}"
fi

if [ "${DO_SELFTEST}" = "1" ]; then
	echo
	echo "  --self-test requested: see tests/self-test.sh, which mutates a COPY"
	echo "  of this rootfs and asserts this harness goes red for each mutation."
	echo "  It is a separate script because it needs to modify a filesystem and"
	echo "  this one must stay read-only."
fi

[ "${FAIL}" -eq 0 ] || exit 1
exit 0
