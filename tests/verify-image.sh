#!/bin/bash
# Tier 2 verification: assert that the built rootfs is what the image declared.
#
#   tests/verify-image.sh <rootfs-dir> [--boot] [--self-test]
#
# docs/design/verification.md's three tiers:
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
DO_CHROOT=0
DO_SELFTEST=0
shift || true
for arg in "$@"; do
	case "${arg}" in
		--boot)      DO_BOOT=1 ;;
		--chroot)    DO_CHROOT=1 ;;
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

# --- find WITHOUT a pipe ----------------------------------------------------
# `find ... | grep -q .` is wrong in this file, and wrong in a way that looks
# like a real defect. This script runs under `set -o pipefail`; grep -q exits
# at the FIRST match, find is still walking, find takes SIGPIPE, and the
# pipeline's status is failure. The check then reports ABSENT for something
# there are 38 copies of.
#
# It is a race, so it does not fail every time -- which is worse. Measured
# 2026-09-07: the Kivy .so check failed this way against an image that was
# entirely correct, while the dist-info check beside it passed.
#
# -print -quit makes find stop on its own. No pipe, no signal, no race.
found_any() { # <dir> <find predicates...>
	local dir="$1"; shift
	local hit
	hit="$(find "${dir}" "$@" -print -quit 2>/dev/null)"
	[ -n "${hit}" ]
}


# --- resolving paths INSIDE the rootfs --------------------------------------
# A symlink in a rootfs whose target starts with "/" means "/" OF THAT ROOTFS.
# The shell, running outside, resolves it against the real root instead. Every
# such test is then answering a question about the wrong filesystem -- and it
# fails in the direction that looks like a defect, so it costs a build.
rootfs_exists() { # <absolute path as seen from inside the rootfs>
	local p="$1" target hops=0
	while [ "${hops}" -lt 10 ]; do
		if [ -e "${ROOTFS}${p}" ] && [ ! -L "${ROOTFS}${p}" ]; then
			return 0
		fi
		if [ ! -L "${ROOTFS}${p}" ]; then
			return 1
		fi
		target="$(readlink "${ROOTFS}${p}")"
		case "${target}" in
			/*) p="${target}" ;;                      # absolute: rootfs-relative
			*)  p="$(dirname "${p}")/${target}" ;;    # relative: alongside
		esac
		hops=$((hops + 1))
	done
	return 1
}

# --- is this command on the image's PATH? -----------------------------------
# Built on rootfs_exists for the same reason it exists: on a merged-usr trixie
# rootfs /bin, /sbin and /usr/sbin are all symlinks into /usr/bin, and half of
# these binaries are themselves symlinks. Anything that follows a link has to
# say which root it means.
#
# The directories are the ones a non-login systemd service and a root shell
# actually search; nothing here looks in the service user's ~/bin, because a
# runtime that depends on that is a different (and worse) arrangement.
rootfs_has_binary() { # <command name>
	local n="$1" d
	for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
		rootfs_exists "${d}/${n}" && return 0
	done
	return 1
}

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
# app_parent is what stage-elspi/05-service-user creates; app_root is where the
# checkout lives.
#
# THAT SECOND CLAUSE CHANGED 2026-09-21. It used to read "app_root is where the
# DELTA puts the checkout and does NOT exist in a freshly built image. Checking
# app_root here would fail on every correct image -- the distinction is the
# seam." docs/design/seam.md's ratified amendment moves the checkout into the
# image, so the opposite is now true: an image with nothing at app_root is a
# build that lost its application, and the section below is what says so.
APP_PARENT="$(jget "['paths']['app_parent']")"
APP_ROOT="$(jget "['paths']['app_root']")"
# The baked release (seam.md amendment 2026-09-21), read out of the image's own
# declaration like everything else in this section.
APP_RELEASE="$(jget "['baked_app']['release']")"
APP_COMMIT="$(jget "['baked_app']['commit']")"
CONFIG_DIR="$(jget "['paths']['config_dir']")"
LOG_DIR="$(jget "['paths']['log_dir']")"
DRM_DEFAULT="$(jget "['drm']['default_mode']")"
DRM_SWITCHER="$(jget "['drm']['switcher']")"
# The mode LIST, read out of the manifest for the same reason as the rest of
# this section: the harness checks reality against the image's declaration
# rather than against a list retyped here. Space-separated, order preserved.
DRM_MODES="$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['drm']['modes']))" "${MANIFEST}" 2>/dev/null)"
# The first-boot seed, read out of the manifest rather than hardcoded here --
# same arrangement as drm.switcher, which 06-seat creates and 11-manifest
# merely declares. A harness that keeps its own copy of these paths is checking
# that its author can copy a path.
FBS_UNIT="$(jget "['first_boot_seed']['unit']")"
FBS_SCRIPT="$(jget "['first_boot_seed']['script']")"
# The first-boot UI hook (stage-elspi/14-first-boot-ui) -- same arrangement as
# the seed above. It is a SCAFFOLD, not a feature: see its own README.md.
FBUI_UNIT="$(jget "['first_boot_ui']['unit']")"
FBUI_SCRIPT="$(jget "['first_boot_ui']['script']")"
# SSH (keyless since 2026-09-23): where keys come from and who decides the
# authentication policy. Read here and asserted to be exactly the declared
# policy in the SSH section below.
SSH_KEY_SOURCE="$(jget "['ssh']['key_source']")"
SSH_AUTH="$(jget "['ssh']['auth']")"

for v in SERVICE_USER VENV APP_PARENT APP_ROOT CONFIG_DIR LOG_DIR DRM_DEFAULT DRM_SWITCHER \
         DRM_MODES FBS_UNIT FBS_SCRIPT FBUI_UNIT FBUI_SCRIPT APP_RELEASE APP_COMMIT \
         SSH_KEY_SOURCE SSH_AUTH; do
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

# The build-time throwaway from FIRST_USER_PASS must not ship usable -- nor
# ship at all. EXACTLY '!': passwd -l's '!<hash>' carried the throwaway's hash
# into a public image, and cloud-init unlocks that shape on first boot
# (stage-elspi/12-first-boot-seed/README.md, "The unlock hole").
check "${SERVICE_USER} password field is a bare '!' (locked, no hash shipped)" \
	grep -qE "^${SERVICE_USER}:!:" "${ROOTFS}/etc/shadow"

# The whole point of the 2026-09-01 decision.
if grep -qs "User=root" "${ROOTFS}/usr/share/elspi/drm-modes/"*.conf; then
	bad "no DRM mode fragment runs as root"
else
	ok "no DRM mode fragment runs as root"
fi

# --- the polkit rule that makes non-root actually WORK ----------------------
# FOUND ON THE FIRST REAL CARD 2026-09-13, and invisible to every check above.
# The service user runs under systemd with no logind session, so polkit
# classifies it as neither active nor inactive and NetworkManager's "any"
# default -- "no" for enable-disable-wifi -- applies. The UI's Network screen
# runs `nmcli radio wifi on` at startup and got "Not authorized to perform
# this operation". The netdev membership asserted above does NOT cover it:
# Debian's shipped rules file handles only settings.modify.system, and only
# for a local ACTIVE session.
#
# So the group checks and the "no fragment runs as root" check were both green
# on an image whose appliance UI could not touch the radio. This is the
# assertion that says the OTHER half of the non-root decision shipped.
POLKIT_RULE="${ROOTFS}/etc/polkit-1/rules.d/50-reflex-service-user.rules"
if [ ! -f "${POLKIT_RULE}" ]; then
	bad "polkit rule /etc/polkit-1/rules.d/50-reflex-service-user.rules present"
else
	ok "polkit rule /etc/polkit-1/rules.d/50-reflex-service-user.rules present"
	# NAMING THE USER IS THE WHOLE CONTENT. A rule scoped to a user that does
	# not exist on this image is inert, and is indistinguishable from a
	# working one in a directory listing -- which is exactly how a template
	# whose substitution silently no-opped would ship.
	check "  the polkit rule names '${SERVICE_USER}'" \
		grep -q "subject.user === \"${SERVICE_USER}\"" "${POLKIT_RULE}"
	# It must be the NetworkManager namespace, not a blanket YES. A rule that
	# returned YES for every action id would also pass the check above.
	check "  it is scoped to the NetworkManager action namespace" \
		grep -q 'org\.freedesktop\.NetworkManager\.' "${POLKIT_RULE}"
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

for d in "${CONFIG_DIR}" "${LOG_DIR}" "${APP_PARENT}"; do
	check "${d} exists and is owned by ${SERVICE_USER}" owned_by_service_user "${d}"
done

# The sequencing trap: the log dir must exist and be writable BEFORE anything
# points KCFG_KIVY_LOG_DIR at it. The image half is checked here; the delta
# half gates on the manifest.
check "${LOG_DIR} is writable by its owner" \
	test -w "${ROOTFS}${LOG_DIR}"

# /root/.kivy must not ship. Kivy's setup.py imports kivy at BUILD time, which
# creates $HOME/.kivy -- /root in the chroot -- so a pristine image carried it
# until 08-venv started setting KIVY_HOME. Asserted here as well as in the
# stage, because the stage gate only fires on the machine that builds.
if [ -e "${ROOTFS}/root/.kivy" ]; then
	bad "/root/.kivy absent (Kivy's build-time import must not land in root's home)"
else
	ok "/root/.kivy absent"
fi

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
         gcc-arm-none-eabi cmake openocd plymouth git; do
	check "installed: ${p}" pkg_installed "${p}"
done

# Forbidden. docs/design/runtime-inventory.md: KMS/DRM is selected BY ABSENCE. SDL2 falls
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
section "Executables the runtime shells out to"

# WHY THIS SECTION EXISTS. The card written from image addcb2e (2026-09-13)
# had no git. Nothing in this harness noticed, because a missing COMMAND is
# not the same question as a missing package and nobody had asked the first
# one: the app half of the machine is a git checkout, the in-app updater runs
# git fetch/show/checkout, and deltas/01-converge.sh syncs the venv against
# it. It had to be apt-installed by hand -- a package mirror back on the
# recovery path, which is the one thing the baked venv exists to remove.
#
# git is asserted twice on purpose. As a PACKAGE above (that is the contract
# stage-elspi/08-venv/00-packages declares) and as a BINARY here at the path
# every one of those callers resolves. The two can disagree: a package can be
# installed-but-unconfigured, and dpkg status is a claim about a database
# while this is a claim about the filesystem.
check "/usr/bin/git exists in the rootfs" rootfs_exists /usr/bin/git

# THE REST OF THE SHELL-OUT SET.
#
# Every one of these is invoked by name by something that has to work on a
# machine with no terminal, so a missing one is discovered by a human standing
# at a lathe. Grounded in real call sites rather than guessed at:
#
#   git        the checkout, the in-app updater, converge's uv sync
#   systemctl  the UI's own restart button, converge (enable, daemon-reload,
#              show -p User)
#   sudo       the UI's restart path; converge and restore run probes as the
#              service user through it
#   nmcli      the UI's Network screen -- the nmcli PYTHON package shells out
#              to this BINARY, which no Python manifest can express
#   uv         converge's `uv sync --no-dev --frozen` (at /usr/local/bin/uv,
#              not a distro path: it is installed by stage-elspi/07-uv)
#   python3    the venv's interpreter, and lib.sh's manifest reader
#   sed grep awk    all three delta phases parse with them
#   getent     restore and phase 3 resolve the service user's home
#   stat       converge's and restore's ownership gates
#   find       restore and phase 3
#   mktemp     converge's validate-before-install of the sudoers files
#   tar        restore unpacks a tarball backup
#   ssh-keygen phase 3 prints authorized_keys fingerprints, and the first-boot
#              seed unit validates and fingerprints the Imager seed's keys
#   passwd     phase 3 sets the service account's password; the account ships
#              LOCKED, so without this the machine cannot be commissioned
#   openocd    the firmware toolchain docs/design/seam.md call 3 bakes in unconditionally
#   install    every file the delta layer puts in place
#   visudo     converge validates each sudoers file BEFORE moving it in, and a
#              malformed /etc/sudoers.d file breaks sudo for every user on a
#              machine that cannot be rescued without pulling the card
for b in git systemctl sudo nmcli uv python3 sed grep awk getent stat find \
         mktemp tar ssh-keygen passwd openocd install visudo; do
	check "  on PATH: ${b}" rootfs_has_binary "${b}"
done

# ---------------------------------------------------------------------------
section "The venv (Kivy compiled, reflex absent)"

# NOTE: rootfs_exists, not `test -x`.
#
# uv writes ${VENV}/bin/python as an ABSOLUTE symlink to /usr/bin/python3.
# Following that from outside resolves it against the HOST root, not the
# rootfs, so `test -x` reports missing for a venv that is entirely correct.
# That exact mistake failed a real build on 2026-09-07 after everything in it
# had succeeded. A path test on a rootfs has to say which root it means.
check "${VENV}/bin/python exists (resolved within the rootfs)" \
	rootfs_exists "${VENV}/bin/python"

if found_any "${ROOTFS}${VENV}" -maxdepth 5 -iname 'kivy-*.dist-info'; then
	ok "Kivy is installed in the venv"
else
	bad "Kivy is installed in the venv"
fi

# The expensive part of the build. A Kivy without compiled extensions is not
# the Kivy this image needs.
if found_any "${ROOTFS}${VENV}" -name '*.so' -path '*kivy*'; then
	ok "Kivy carries compiled extensions (.so)"
else
	bad "Kivy carries compiled extensions (.so)"
fi

# docs/design/seam.md call 1: the image ships the DEPENDENCIES, the delta ships the APP.
if found_any "${ROOTFS}${VENV}" -maxdepth 5 -iname 'reflex-*.dist-info'; then
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

# KNOWN GAP, not a failure: docs/design/seam.md ratified promoting Pillow to a runtime
# dependency, and that fix belongs in the reflex repo. Until it lands, --no-dev
# drops pillow and Kivy loses img_pil. Reported as UNKNOWN rather than PASS so
# it cannot quietly become "fine".
if found_any "${ROOTFS}${VENV}" -maxdepth 5 -iname 'pillow-*.dist-info'; then
	ok "pillow present (img_pil provider available)"
else
	unknown "pillow ABSENT -- img_pil unavailable. docs/design/seam.md ratified promoting it to a runtime dep in the reflex repo; that has not landed."
fi

# The service user owns the WHOLE venv. reflex's in-app
# updater runs `uv sync` into it as that user, after flashing the firmware;
# the root:root venv elspi shipped until 2026-09-17 fails that sync. find -P
# (the default) judges symlinks themselves, matching 08-venv's `chown -R -h`.
venv_owned_by_service_user() {
	[ -n "${SU_UID}" ] && [ -d "${ROOTFS}${VENV}" ] \
		&& [ -z "$(find "${ROOTFS}${VENV}" ! -uid "${SU_UID}" -print -quit)" ]
}
check "${VENV} is wholly owned by ${SERVICE_USER} (the updater syncs into it as that user)" \
	venv_owned_by_service_user

# ---------------------------------------------------------------------------
section "The baked application (seam.md amendment 2026-09-21)"

# RATIFIED 2026-09-21: "The image now ships the app, pinned to the latest FULL
# release. Not a development rc.*, not a floating branch." Everything in this
# section is a property ui/reflex/utils/updater.py already depends on -- any
# one of them missing makes the updater refuse every update on a freshly
# flashed card, which is the assumption the amendment rests on.

APP_DIR="${ROOTFS}${APP_ROOT}"
SELECT_RELEASE="$(cd "$(dirname "$0")/.." && pwd)/stage-elspi/10a-app-checkout/files/select-release.sh"

# --- (A) present, and the service user's ------------------------------------
if [ -d "${APP_DIR}" ]; then
	ok "a checkout exists at ${APP_ROOT}"
else
	bad "a checkout exists at ${APP_ROOT} -- the image has no application"
fi

# The updater runs `git fetch`, `git checkout` and `uv sync` AS THE SERVICE
# USER. Same reasoning as the venv's ownership check above, plus one
# git-specific edge: git refuses a repository whose owner
# is not the caller ("detected dubious ownership"), which in a log looks
# nothing like a permissions problem. find -P judges symlinks themselves.
app_owned_by_service_user() {
	[ -n "${SU_UID}" ] && [ -d "${APP_DIR}" ] \
		&& [ -z "$(find "${APP_DIR}" ! -uid "${SU_UID}" -print -quit)" ]
}
check "${APP_ROOT} is wholly owned by ${SERVICE_USER} (the updater runs git and uv as that user)" \
	app_owned_by_service_user

# --- (B) a REAL repository, with tag history, that `git show <tag>:` works on-
# THE DISTINCTION THIS SECTION EXISTS FOR. A source tarball, a `git archive`
# export or a copied tree all produce a directory at app_root that looks
# finished. None of them can be updated in place: updater.py's
# resolve_checkout() refuses them outright, and its protocol-version read is a
# `git show` against an object store that is not there.
if [ -d "${APP_DIR}/.git" ] && git -C "${APP_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
	ok "${APP_ROOT} is a real git repository (not an export or a copied tree)"
	APP_IS_REPO=1
else
	bad "${APP_ROOT} is a real git repository (not an export or a copied tree)"
	APP_IS_REPO=0
fi

if [ "${APP_IS_REPO}" -eq 1 ]; then
	# A shallow clone answers for its tip and lies about everything else.
	if [ -e "${APP_DIR}/.git/shallow" ]; then
		bad "${APP_ROOT} is not a shallow clone"
	else
		ok "${APP_ROOT} is not a shallow clone"
	fi

	# TAG HISTORY, which is the literal wording of the amendment's item 1. An
	# export carries none; a `--depth 1 --single-branch` clone carries one.
	APP_TAGS="$(git -C "${APP_DIR}" tag 2>/dev/null | wc -l)"
	if [ "${APP_TAGS}" -ge 2 ]; then
		ok "${APP_ROOT} carries tag history (${APP_TAGS} tags)"
	else
		bad "${APP_ROOT} carries tag history (found ${APP_TAGS} tag(s) -- an export or a depth-1 clone)"
	fi

	# The declared tag must actually be IN the repository...
	if git -C "${APP_DIR}" rev-parse --verify --quiet "refs/tags/${APP_RELEASE}^{commit}" >/dev/null 2>&1; then
		ok "the declared release tag ${APP_RELEASE} resolves inside the checkout"
	else
		bad "the declared release tag ${APP_RELEASE} resolves inside the checkout"
	fi

	# ...and it must be what is CHECKED OUT, compared by commit id rather than
	# by name. A checkout sitting on a branch that merely contains the tag is a
	# different tree from the release.
	APP_HEAD="$(git -C "${APP_DIR}" rev-parse --verify HEAD 2>/dev/null || true)"
	if [ -n "${APP_HEAD}" ] && [ "${APP_HEAD}" = "${APP_COMMIT}" ]; then
		ok "HEAD is the declared commit (${APP_COMMIT})"
	else
		bad "HEAD is the declared commit: manifest says ${APP_COMMIT}, checkout is at ${APP_HEAD:-NONE}"
	fi

	# THE UPDATER'S READ MECHANISM, exercised rather than assumed. A path the
	# release certainly has, so this measures `git show <tag>:<path>` against
	# this object store and nothing else.
	if git -C "${APP_DIR}" show "${APP_RELEASE}:ui/pyproject.toml" >/dev/null 2>&1; then
		ok "git show ${APP_RELEASE}:ui/pyproject.toml works against the checkout"
	else
		bad "git show ${APP_RELEASE}:ui/pyproject.toml works against the checkout"
	fi

	# THE EXACT READ THE AMENDMENT NAMES. Whether els_stop_map.py exists at a
	# given tag is a property of THE RELEASE, not of this build -- it landed
	# after v1.1.0 -- so its absence is reported as UNKNOWN, BY NAME, and never
	# as a pass or a skip. The mechanism itself is already proven by the check
	# above; what this cannot tell you is whether the BAKED release can read
	# its own protocol version.
	if git -C "${APP_DIR}" show "${APP_RELEASE}:ui/reflex/utils/els_stop_map.py" >/dev/null 2>&1; then
		ok "git show ${APP_RELEASE}:ui/reflex/utils/els_stop_map.py succeeds (the updater's protocol read)"
	else
		unknown "ui/reflex/utils/els_stop_map.py is ABSENT at the baked tag ${APP_RELEASE}. That is the file updater.py reads a release's protocol version out of. The MECHANISM is fine (the git show check above passed); the baked release simply predates the in-app updater, so the first update on a fresh card is a manual one."
	fi

	# resolve_checkout()'s four required paths, named one at a time. The two
	# fw/scripts entries are RELEASE properties like els_stop_map.py above, so
	# they are UNKNOWN rather than FAIL; .git and ui/pyproject.toml are checked
	# as failures because without them nothing about the stage worked.
	check "${APP_ROOT}/ui/pyproject.toml (resolve_checkout requires it)" \
		test -f "${APP_DIR}/ui/pyproject.toml"
	for p in fw/scripts/modbus-flash.py fw/scripts/reflex_image.py; do
		if [ -f "${APP_DIR}/${p}" ]; then
			ok "${APP_ROOT}/${p} (resolve_checkout requires it)"
		else
			unknown "${APP_ROOT}/${p} is ABSENT at ${APP_RELEASE}. updater.py's resolve_checkout() lists it among the four files it refuses without, so in-app update on this image refuses at preflight until the app is updated by hand. A property of the baked release, not of this build."
		fi
	done

	# NO CREDENTIAL SHIPS -- seam call 2, and this repo is public. Checked on
	# the artifact rather than trusted to the stage that wrote it.
	if grep -qE '://[^/[:space:]]+:[^@/[:space:]]+@' "${APP_DIR}/.git/config" 2>/dev/null; then
		bad "${APP_ROOT}/.git/config carries no URL with embedded credentials"
	else
		ok "${APP_ROOT}/.git/config carries no URL with embedded credentials"
	fi

	# The build host's source path must not be what the card fetches from.
	APP_ORIGIN="$(git -C "${APP_DIR}" remote get-url origin 2>/dev/null || true)"
	case "${APP_ORIGIN}" in
		https://*|http://*)
			ok "origin is a fetchable URL (${APP_ORIGIN}), not the build host's path" ;;
		"")
			bad "origin is a fetchable URL, not the build host's path (no origin at all)" ;;
		*)
			bad "origin is a fetchable URL, not the build host's path (found: ${APP_ORIGIN})" ;;
	esac

	# --- (B2) the build-time .git scrub, RE-CHECKED HERE --------------------
	# 10a-app-checkout's own gate 7/7b asserts every one of these at build time,
	# right after writing them. This harness does not trust that self-report --
	# same reason it re-measures ownership and tag history above rather than
	# reading the stage's echo -- so each property is re-measured against the
	# ARTIFACT: a checkout carrying its clone reflog, a mirror's stray branches,
	# the build host's own local-mirror path or the builder's git identity would
	# each tell whoever pokes at a shipped card something about how and where it
	# was built, which is exactly what the anonymous-clone scrub exists to avoid.

	# No reflog: it records "clone: from <source>" and is stamped with the
	# builder's identity.
	if [ -e "${APP_DIR}/.git/logs" ]; then
		bad "${APP_ROOT}/.git/logs is absent -- present, it would record the build source and the builder's identity"
	else
		ok "${APP_ROOT}/.git/logs is absent"
	fi
	if [ -z "$(git -C "${APP_DIR}" reflog show --all 2>/dev/null | head -n1)" ]; then
		ok "${APP_ROOT} carries no reflog entries"
	else
		bad "${APP_ROOT} carries reflog entries -- they record the build source and the builder's identity"
	fi

	# No ref outside a tag or origin's own remote-tracking refs: a mirror's
	# work-in-progress branch, a local branch, a stash or a note would each keep
	# its own commits reachable in the object store too.
	STRAY_REF="$(git -C "${APP_DIR}" for-each-ref --format='%(refname)' | grep -Ev '^refs/(tags|remotes/origin)/' | head -n1 || true)"
	if [ -z "${STRAY_REF}" ]; then
		ok "${APP_ROOT} carries no refs outside tags and origin's remote-tracking refs"
	else
		bad "${APP_ROOT} carries ${STRAY_REF}, which is not a tag or a remote-tracking ref of origin"
	fi

	# No /mnt/git string anywhere under .git outside the object store: that is
	# this estate's local-mirror path, and a checkout naming it would tell
	# whoever pokes at a shipped card exactly where and how it was built.
	LEAKED_PATH="$(grep -rIlF --exclude-dir=objects -- '/mnt/git' "${APP_DIR}/.git" 2>/dev/null | head -n1 || true)"
	if [ -z "${LEAKED_PATH}" ]; then
		ok "${APP_ROOT}/.git names no /mnt/git build-source path"
	else
		bad "${LEAKED_PATH#"${ROOTFS}"} names a /mnt/git build-source path"
	fi

	# No builder git identity anywhere under .git outside the object store,
	# computed the same way 10a-app-checkout computes it at build time. This
	# only measures anything when this harness runs on a host with a git
	# identity configured (the build host or a CI runner right after the build);
	# elsewhere it is UNKNOWN rather than a pass it did not earn.
	BUILDER_IDENT="$(git var GIT_COMMITTER_IDENT 2>/dev/null | sed -E 's/ [0-9]+ [-+][0-9]{4}$//' || true)"
	if [ -n "${BUILDER_IDENT}" ]; then
		LEAKED_IDENT="$(grep -rIlF --exclude-dir=objects -- "${BUILDER_IDENT}" "${APP_DIR}/.git" 2>/dev/null | head -n1 || true)"
		if [ -z "${LEAKED_IDENT}" ]; then
			ok "${APP_ROOT}/.git records no builder git identity (${BUILDER_IDENT})"
		else
			bad "${LEAKED_IDENT#"${ROOTFS}"} records the builder's git identity (${BUILDER_IDENT})"
		fi
	else
		unknown "this host has no git identity configured, so the builder-identity leak check could not be measured"
	fi

	# origin is the PUBLIC anonymous URL exactly, not merely fetchable. Same
	# default 10a-app-checkout and elspi.conf use for REFLEX_ORIGIN_URL, and
	# overridable the same way for a synthetic rootfs in the test harness.
	REFLEX_ORIGIN_URL="${REFLEX_ORIGIN_URL:-https://github.com/Funkenjaeger/reflex.git}"
	if [ "${APP_ORIGIN}" = "${REFLEX_ORIGIN_URL}" ]; then
		ok "origin is the anonymous HTTPS URL (${REFLEX_ORIGIN_URL})"
	else
		bad "origin is the anonymous HTTPS URL: expected ${REFLEX_ORIGIN_URL}, found '${APP_ORIGIN}'"
	fi
fi

# --- (C) the baked release is a FULL release --------------------------------
# THE CHECK THAT MAKES "full release" MEAN SOMETHING. Through the stage's own
# selection script, never a second regex here: a harness with its own copy of
# the rule can agree with itself while disagreeing with the thing that shipped.
if [ -x "${SELECT_RELEASE}" ] || [ -f "${SELECT_RELEASE}" ]; then
	if bash "${SELECT_RELEASE}" check "${APP_RELEASE}" >/dev/null 2>&1; then
		ok "the baked release ${APP_RELEASE} is a FULL release (not an rc.*, not a branch)"
	else
		bad "the baked release ${APP_RELEASE} is a FULL release -- the selection rule REFUSES it. seam.md 2026-09-21: never a development rc.*"
	fi
else
	unknown "cannot find ${SELECT_RELEASE}, so the baked release '${APP_RELEASE}' was NOT checked against the selection rule. This harness is being run from outside the repo."
fi

# --- (D) the manifest and the on-disk record agree --------------------------
# Two files, written from one measurement by two different stages. Worth
# checking precisely because they could disagree -- and a disagreement means
# the manifest is describing an image that is not this one.
APP_RELEASE_FILE="${ROOTFS}/etc/elspi/reflex-app-release"
if [ -f "${APP_RELEASE_FILE}" ]; then
	APP_RELEASE_ONDISK="$(tr -d '[:space:]' < "${APP_RELEASE_FILE}")"
	if [ "${APP_RELEASE_ONDISK}" = "${APP_RELEASE}" ]; then
		ok "/etc/elspi/reflex-app-release agrees with the manifest (${APP_RELEASE})"
	else
		bad "/etc/elspi/reflex-app-release ('${APP_RELEASE_ONDISK}') disagrees with the manifest's baked_app.release ('${APP_RELEASE}')"
	fi
else
	bad "/etc/elspi/reflex-app-release exists (10a-app-checkout writes it; 11-manifest reads it)"
fi

# ---------------------------------------------------------------------------
section "Boot configuration (TEXTUAL ONLY -- see blind spots)"

CFG="${ROOTFS}/boot/firmware/config.txt"
CMD="${ROOTFS}/boot/firmware/cmdline.txt"

for line in "dtparam=i2c_arm=on" "dtparam=spi=on" "camera_auto_detect=0" \
            "enable_uart=1" "disable_splash=1" "dtoverlay=nospi10"; do
	check "config.txt: ${line}" grep -qxF "${line}" "${CFG}"
done

# usb_max_current_enable is a BUILD KNOB (ELSPI_USB_MAX_CURRENT, off unless a
# site build config turns it on), so config.txt is checked against what the
# manifest DECLARES, in both directions: declared on and missing is a panel
# that browns out; declared off and present is an image asking more of the
# supply than its manifest admits.
USB_DECLARED="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["boot_config"]["usb_max_current_enable"]; print({True: "on", False: "off"}[v])' "${MANIFEST}" 2>/dev/null || true)"
case "${USB_DECLARED}" in
	on)  check "config.txt: usb_max_current_enable=1 (the manifest declares it on)" grep -qxF "usb_max_current_enable=1" "${CFG}" ;;
	off) if grep -q '^usb_max_current_enable=' "${CFG}" 2>/dev/null; then
		     bad "config.txt has no usb_max_current_enable (the manifest declares it off)"
	     else
		     ok "config.txt has no usb_max_current_enable (the manifest declares it off)"
	     fi ;;
	*)   bad "the manifest declares boot_config.usb_max_current_enable as a boolean" ;;
esac

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

# The zone an UNSEEDED card keeps -- Imager's customisation page replaces it
# per card through cloud-init. Checked against what the build DECLARED
# (build_defaults.timezone: elspi.conf's Etc/UTC, or a site build config's),
# not against a zone typed into this harness, so a site build is verified by
# the same line as a public one.
TZ_DECLARED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_defaults"]["timezone"])' "${MANIFEST}" 2>/dev/null || true)"
if [ -z "${TZ_DECLARED}" ]; then
	bad "the manifest declares build_defaults.timezone"
elif [ -L "${ROOTFS}/etc/localtime" ]; then
	TZ_TARGET="$(readlink "${ROOTFS}/etc/localtime")"
	if [[ "${TZ_TARGET}" == */zoneinfo/"${TZ_DECLARED}" ]]; then
		ok "timezone is the declared build default ${TZ_DECLARED}"
	else
		bad "timezone is the declared build default ${TZ_DECLARED} (found: ${TZ_TARGET})"
	fi
else
	bad "/etc/localtime is a symlink"
fi

# ---------------------------------------------------------------------------
section "DRM mode plumbing"

# TWO rungs since 2026-09-13. first-opener took the display on the real Pi at
# the first attempt, so the logind-seat rung -- autologin on tty1 plus a
# `systemd --user` unit -- was deleted rather than maintained, which is what
# the flash-session notes said to do with it. cap-sys-admin STAYS: it is the
# documented floor that leaves the lathe working.
if [ "${DRM_MODES}" = "first-opener cap-sys-admin" ]; then
	ok "manifest declares exactly the two surviving modes (${DRM_MODES})"
else
	bad "manifest declares exactly 'first-opener cap-sys-admin' (found: ${DRM_MODES})"
fi

for m in ${DRM_MODES}; do
	check "fragment staged: ${m}" test -f "${ROOTFS}/usr/share/elspi/drm-modes/${m}.conf"
done
check "switcher installed: ${DRM_SWITCHER}" test -x "${ROOTFS}${DRM_SWITCHER}"

# --- the deleted rung, asserted ABSENT in each of its three forms ----------
# A fragment, a switcher that still accepts the name, or the autologin file it
# installed. The last one is the dangerous residue: an autologin that ships
# active changes the boot path of a machine nobody can log into to undo it.
if [ -e "${ROOTFS}/usr/share/elspi/drm-modes/logind-seat.conf" ]; then
	bad "the logind-seat fragment is gone (that mode was deleted 2026-09-13)"
else
	ok "the logind-seat fragment is gone (that mode was deleted 2026-09-13)"
fi

if [ -e "${ROOTFS}/usr/share/elspi/getty-tty1-autologin.conf" ]; then
	bad "the tty1 autologin fragment is gone (it existed only for logind-seat)"
else
	ok "the tty1 autologin fragment is gone (it existed only for logind-seat)"
fi

if [ -e "${ROOTFS}/etc/systemd/system/getty@tty1.service.d/10-elspi-autologin.conf" ]; then
	bad "no tty1 autologin is active in the image"
else
	ok "no tty1 autologin is active in the image"
fi

# Asserted on the switcher's VALID_MODES LINE, not on the whole file: the
# script still mentions logind-seat on purpose, in the comment and in the
# RETIRED_MODES list that makes it refuse the name with an explanation instead
# of a bare "unknown mode". Grepping the file would go red on the refusal
# itself.
SWITCHER_FILE="${ROOTFS}${DRM_SWITCHER}"
if grep -q '^VALID_MODES="first-opener cap-sys-admin"$' "${SWITCHER_FILE}"; then
	ok "the switcher offers exactly first-opener and cap-sys-admin"
else
	bad "the switcher offers exactly first-opener and cap-sys-admin (VALID_MODES line: $(grep -m1 '^VALID_MODES=' "${SWITCHER_FILE}" 2>/dev/null || echo '<none>'))"
fi

# Plymouth holds DRM master. Ordering after it is load-bearing.
check "first-opener orders After=plymouth-quit-wait.service" \
	grep -q "After=plymouth-quit-wait.service" \
	"${ROOTFS}/usr/share/elspi/drm-modes/first-opener.conf"

# THE THING THIS HARNESS STRUCTURALLY CANNOT ANSWER.
unknown "DRM master acquisition under mode '${DRM_DEFAULT}' is NOT OBSERVABLE HERE. There is no GPU and there never will be; this is a Tier 3 hardware item. It was settled on the real Pi on 2026-09-13 -- first-opener took the display at the first attempt -- and this harness still cannot confirm that, so it does not claim to."

# ---------------------------------------------------------------------------
section "First-boot seed (cloud-init / Raspberry Pi Imager 2.x)"

# Design (a), ratified 2026-09-12: Imager's OS-customisation page is the
# supported first-boot seed. See stage-elspi/12-first-boot-seed/README.md.
#
# ALL OF THIS IS TEXTUAL. It says the seed machinery is INSTALLED and WIRED UP.
# It says nothing about whether the radio comes on, whether the PSK associates,
# or whether cloud-init applies the password -- those need a card and a Pi.

META="${ROOTFS}/boot/firmware/meta-data"

check "meta-data present on the boot partition" test -f "${META}"

# THE DEFECT THE SUBSTAGE EXISTS FOR. cloud-init 25.2's NoCloud datasource
# reads `instance-id`; upstream's stage2/04-cloud-init template ships
# `instance_id` with an UNDERSCORE, which nothing reads, so the datasource
# falls back to the literal "nocloud" and cannot tell one instance from
# another. Nothing about that looks broken from the outside.
check "meta-data declares a hyphenated 'instance-id:'" \
	grep -qE '^instance-id: .+' "${META}"

# Both directions. Asserting only the hyphen would pass a file carrying BOTH
# keys, where cloud-init's behaviour then depends on YAML key order.
if grep -qE '^instance_id:' "${META}" 2>/dev/null; then
	bad "meta-data carries NO misspelled 'instance_id:' key (a file with both is ambiguous)"
else
	ok "meta-data carries no misspelled 'instance_id:' key"
fi

# --- the unit and its script ------------------------------------------------
FBS_UNIT_FILE="${ROOTFS}${FBS_UNIT}"
FBS_SCRIPT_FILE="${ROOTFS}${FBS_SCRIPT}"

check "seed unit installed: ${FBS_UNIT}"     test -f "${FBS_UNIT_FILE}"
check "seed script installed: ${FBS_SCRIPT}" test -f "${FBS_SCRIPT_FILE}"
check "seed script is executable"            test -x "${FBS_SCRIPT_FILE}"

# --- enabled, and enabled in a way systemd will actually honour -------------
#
# cloud-init.target, NOT multi-user.target. Measured on the first boot of
# image_2026-09-13-elspi: a unit that is WantedBy=multi-user.target and
# After=cloud-final.service is an ORDERING CYCLE on this image, because
# cloud-final.service is itself After=multi-user.target. systemd broke the
# cycle by deleting OUR job and the seed never ran.
FBS_WANTS="${ROOTFS}/etc/systemd/system/cloud-init.target.wants/$(basename "${FBS_UNIT}")"

# TWO tests, not one. `test -L` alone passes a DANGLING symlink, which looks
# enabled to `ls` and is silently ignored by systemd -- so `-e` (which follows
# the link) is the one that matters. The unit ships a RELATIVE target, so
# following it from outside stays inside the rootfs.
if [ ! -L "${FBS_WANTS}" ]; then
	bad "seed unit is enabled (no symlink in cloud-init.target.wants)"
elif [ ! -e "${FBS_WANTS}" ]; then
	bad "seed unit's enablement symlink RESOLVES (it dangles: -> $(readlink "${FBS_WANTS}"))"
else
	ok "seed unit is enabled in cloud-init.target and the symlink resolves"
fi

# THE ORDERING-CYCLE CHECK. This is the assertion the 2026-09-13 boot proved
# was missing, and it is deliberately phrased as a NEGATIVE: the unit must not
# be wanted by any target that cloud-final.service is ordered After=.
#
# On this image cloud-final.service is After=multi-user.target and
# WantedBy=cloud-init.target, and cloud-init.target is
# After=cloud-config.service multi-user.target cloud-final.service. So pulling
# our unit in from multi-user.target while ordering it after cloud-final gives
# systemd multi-user.target -> us -> cloud-final -> multi-user.target, and it
# resolves that by DELETING a job. Journal, first boot:
#
#   cloud-final.service: Found ordering cycle on multi-user.target/start
#   Job elspi-first-boot-seed.service/start deleted to break ordering cycle
#   starting with cloud-final.service/start
#
# Nothing else in this harness can see that. Every other check was green on
# the image that did not run the seed.
FBS_WANTS_MU="${ROOTFS}/etc/systemd/system/multi-user.target.wants/$(basename "${FBS_UNIT}")"
if [ -L "${FBS_WANTS_MU}" ] || [ -e "${FBS_WANTS_MU}" ]; then
	bad "seed unit is NOT wanted by multi-user.target (it is: ordering cycle -- cloud-final.service is After=multi-user.target, so systemd deletes our job)"
else
	ok "seed unit is not wanted by multi-user.target (no ordering cycle with cloud-final.service)"
fi

# The symlink above is only the right one if the unit asks to be wanted there.
check "seed unit declares WantedBy=cloud-init.target" \
	grep -qxF "WantedBy=cloud-init.target" "${FBS_UNIT_FILE}"

# And it must not ALSO ask for multi-user.target -- a unit declaring both would
# be re-enabled into the cycle by any later `systemctl reenable`.
if grep -qxF "WantedBy=multi-user.target" "${FBS_UNIT_FILE}" 2>/dev/null; then
	bad "seed unit declares NO WantedBy=multi-user.target (it does -- 'systemctl reenable' would restore the ordering cycle)"
else
	ok "seed unit declares no WantedBy=multi-user.target"
fi

# THE SEED SCRIPT MUST NOT BE ABLE TO FAIL THE BOOT. elspi has no terminal and
# no serial console (03-boot-config takes it off the Modbus UART), so a unit
# that can fail the boot costs a power cycle and an SD-card swap.
check "seed unit's ExecStart is '-' prefixed (cannot fail the boot)" \
	grep -qE '^ExecStart=-' "${FBS_UNIT_FILE}"

# Ordering IS the design: run before cloud-init has consumed the seed and the
# script neutralises credentials nobody has read yet.
check "seed unit orders After=cloud-final.service" \
	grep -qE '^After=.*cloud-final\.service' "${FBS_UNIT_FILE}"

# The script installs the Imager seed's SSH keys into /home (the image is
# keyless). ProtectHome=yes -- which this unit shipped with until 2026-09-23 --
# hides /home from the service, and every key install would then fail with the
# seed wiped afterwards.
if grep -qiE '^ProtectHome=(yes|true|on|1|read-only|tmpfs)[[:space:]]*$' "${FBS_UNIT_FILE}" 2>/dev/null; then
	bad "seed unit does NOT hide /home (it sets $(grep -iE '^ProtectHome=' "${FBS_UNIT_FILE}"); the seeded SSH keys could never be installed)"
else
	ok "seed unit does not hide /home (ProtectHome is off, so it can install the seeded SSH keys)"
fi

# What none of the above can see.
unknown "The first-boot seed has NEVER RUN -- image_2026-09-13-elspi booted on the real Pi and systemd deleted the unit's job to break an ordering cycle, so not one step executed. The checks above would have been green on that image except for the two ordering-cycle assertions added afterwards. Whether the radio comes on, whether the regulatory domain takes, whether cloud-init applies the Imager password, whether the seeded SSH keys land in authorized_keys, and whether the seed is actually erased from the FAT partition are all still Tier 3 items needing a real card in the real Pi. (The key install and password paths ARE exercised offline, against a synthetic rootfs, by tests/test-first-boot-seed.sh.)"

# ---------------------------------------------------------------------------
section "SSH: keyless image, authentication is the operator's Imager choice"

# DECIDED 2026-09-23. Two properties, both stated in the manifest and both
# checked against the rootfs here:
#
#   1. NO KEY IS BAKED IN. This image is built from a public repo into public
#      release images; nobody's personal key belongs in one. Keys arrive from
#      Imager's customisation page and the seed unit installs them.
#   2. THE IMAGE SETS NO SSH AUTHENTICATION OPTION. Imager decides per card:
#      "public-key only" becomes PasswordAuthentication no, password SSH
#      becomes yes, both written by cloud-init to sshd_config.d/50-cloud-init.conf.
#      sshd takes the FIRST value it reads, so any option the image set -- a
#      drop-in sorting ahead of "50-", or a line in sshd_config's body -- would
#      override that choice or stand in for it. Before 2026-09-23 the image set
#      PasswordAuthentication no (PUBKEY_ONLY_SSH=1), which made the password an
#      operator typed into Imager useless over SSH.
if [ "${SSH_KEY_SOURCE}" = "imager-seed" ]; then
	ok "manifest declares ssh.key_source=imager-seed"
else
	bad "manifest declares ssh.key_source=imager-seed (found: '${SSH_KEY_SOURCE}')"
fi
if [ "${SSH_AUTH}" = "imager-choice" ]; then
	ok "manifest declares ssh.auth=imager-choice"
else
	bad "manifest declares ssh.auth=imager-choice (found: '${SSH_AUTH}')"
fi

SU_HOME="$(awk -F: -v u="${SERVICE_USER}" '$1==u {print $6}' "${ROOTFS}/etc/passwd")"
for ak in "${SU_HOME:-/home/${SERVICE_USER}}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
	if [ -e "${ROOTFS}${ak}" ] || [ -L "${ROOTFS}${ak}" ]; then
		bad "no baked SSH key: ${ak} is ABSENT (it exists -- the image is supposed to be keyless)"
	else
		ok "no baked SSH key: ${ak} is absent"
	fi
done

SSHD_AUTH_RE='^[[:space:]]*(PasswordAuthentication|AuthenticationMethods|PubkeyAuthentication)[[:space:]]'
SSHD_CFG="${ROOTFS}/etc/ssh/sshd_config"
if [ ! -f "${SSHD_CFG}" ]; then
	bad "/etc/ssh/sshd_config present (ENABLE_SSH=1 -- is openssh-server installed?)"
else
	ok "/etc/ssh/sshd_config present"
	if grep -qiE "${SSHD_AUTH_RE}" "${SSHD_CFG}"; then
		bad "sshd_config's body sets no SSH authentication option (it does: $(grep -m1 -iE "${SSHD_AUTH_RE}" "${SSHD_CFG}" | tr -s ' \t' ' '))"
	else
		ok "sshd_config's body sets no SSH authentication option"
	fi
	# cloud-init writes 50-cloud-init.conf only when sshd_config Includes the
	# drop-in directory; without the Include it edits sshd_config in place,
	# after any line already there. Either way works, but the Include is what
	# the rest of this reasoning -- and the seed unit's report -- assumes.
	check "sshd_config Includes /etc/ssh/sshd_config.d/*.conf" \
		grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CFG}"
fi

SSHD_OVERRIDES=""
for f in "${ROOTFS}/etc/ssh/sshd_config.d"/*.conf; do
	[ -f "${f}" ] || continue
	if grep -qiE "${SSHD_AUTH_RE}" "${f}"; then
		SSHD_OVERRIDES="${SSHD_OVERRIDES} ${f#"${ROOTFS}"}"
	fi
done
if [ -n "${SSHD_OVERRIDES}" ]; then
	bad "no sshd_config.d drop-in sets an SSH authentication option (found:${SSHD_OVERRIDES}) -- it would override the choice made on Imager's page"
else
	ok "no sshd_config.d drop-in sets an SSH authentication option (Imager's 50-cloud-init.conf is what sshd reads first)"
fi

# ---------------------------------------------------------------------------
section "First-boot UI hook (stage-elspi/14-first-boot-ui)"

# THIS IS A SCAFFOLD, NOT THE FEATURE. The goal is a fresh card that boots
# into the UI with converge run automatically. The checkout IS baked in since
# the 2026-09-21 seam amendment (10a-app-checkout), but starting it unattended
# is a separate decision and the hook's converge/start branch is unwritten.
# So this section asserts only the TRIGGER: a unit that exists, is enabled,
# and is ordered correctly -- not that it starts anything, because today it
# never does. See stage-elspi/14-first-boot-ui/README.md.

FBUI_UNIT_FILE="${ROOTFS}${FBUI_UNIT}"
FBUI_SCRIPT_FILE="${ROOTFS}${FBUI_SCRIPT}"

check "first-boot-ui unit installed: ${FBUI_UNIT}"     test -f "${FBUI_UNIT_FILE}"
check "first-boot-ui script installed: ${FBUI_SCRIPT}" test -f "${FBUI_SCRIPT_FILE}"
check "first-boot-ui script is executable"             test -x "${FBUI_SCRIPT_FILE}"

# --- enabled, and enabled in a way systemd will actually honour -------------
# Same two-part check as the seed above, for the same reason: `-L` alone
# passes a DANGLING symlink, which looks enabled to `ls` and is silently
# ignored by systemd.
FBUI_WANTS="${ROOTFS}/etc/systemd/system/cloud-init.target.wants/$(basename "${FBUI_UNIT}")"
if [ ! -L "${FBUI_WANTS}" ]; then
	bad "first-boot-ui unit is enabled (no symlink in cloud-init.target.wants)"
elif [ ! -e "${FBUI_WANTS}" ]; then
	bad "first-boot-ui unit's enablement symlink RESOLVES (it dangles: -> $(readlink "${FBUI_WANTS}"))"
else
	ok "first-boot-ui unit is enabled in cloud-init.target and the symlink resolves"
fi

check "first-boot-ui unit declares WantedBy=cloud-init.target" \
	grep -qxF "WantedBy=cloud-init.target" "${FBUI_UNIT_FILE}"

# THE SAME ORDERING-CYCLE CHECK the seed section runs, for the same reason:
# this unit's After= chain reaches cloud-final.service (via
# elspi-first-boot-seed.service), and cloud-final.service is itself
# After=multi-user.target. Being wanted by multi-user.target as well would be
# the 2026-09-13 cycle again.
FBUI_WANTS_MU="${ROOTFS}/etc/systemd/system/multi-user.target.wants/$(basename "${FBUI_UNIT}")"
if [ -L "${FBUI_WANTS_MU}" ] || [ -e "${FBUI_WANTS_MU}" ]; then
	bad "first-boot-ui unit is NOT wanted by multi-user.target (it is: ordering cycle via elspi-first-boot-seed.service -> cloud-final.service -> multi-user.target)"
else
	ok "first-boot-ui unit is not wanted by multi-user.target (no ordering cycle)"
fi

if grep -qxF "WantedBy=multi-user.target" "${FBUI_UNIT_FILE}" 2>/dev/null; then
	bad "first-boot-ui unit declares NO WantedBy=multi-user.target (it does -- 'systemctl reenable' would restore the ordering cycle)"
else
	ok "first-boot-ui unit declares no WantedBy=multi-user.target"
fi

# ORDERING -- what this order's tests: field specifically asked for. Plymouth
# holds DRM master until it quits; this unit orders after it even though the
# shipped script never opens card0 today, so whoever writes the real
# converge/start branch inherits correct ordering rather than rediscovering
# the hazard stage-elspi/06-seat's DRM-mode fragments already exist for.
check "first-boot-ui unit orders After=plymouth-quit-wait.service" \
	grep -qxF "After=plymouth-quit-wait.service" "${FBUI_UNIT_FILE}"

check "first-boot-ui unit orders After=elspi-first-boot-seed.service" \
	grep -qxF "After=elspi-first-boot-seed.service" "${FBUI_UNIT_FILE}"

check "first-boot-ui unit's ExecStart is '-' prefixed (cannot fail the boot)" \
	grep -qE '^ExecStart=-' "${FBUI_UNIT_FILE}"

# NO INTERACTIVE STEP, EVER -- the literal ask in this order's tests: field
# ("the UI reaches its start path with no interactive step"). A `read` in the
# installed script would be exactly that.
if grep -qE '^\s*read\b' "${FBUI_SCRIPT_FILE}" 2>/dev/null; then
	bad "first-boot-ui script has no interactive 'read' step"
else
	ok "first-boot-ui script has no interactive 'read' step"
fi

# THE BLIND SPOT THIS STAGE ADDS. Read out of the manifest, not retyped here
# as a fixed string -- membership, not equality, because the exact wording is
# free to evolve and this check only needs to know the topic was not quietly
# dropped. tests/self-test.sh proves this goes red if it is.
if python3 - "${MANIFEST}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("cannot_be_verified_without_hardware", [])
sys.exit(0 if any("first-boot-ui" in i for i in items) else 1)
PY
then
	ok "cannot_be_verified_without_hardware declares the first-boot-ui blind spot"
else
	bad "cannot_be_verified_without_hardware declares the first-boot-ui blind spot"
fi

# THE THING THIS SCAFFOLD CANNOT PROVE, STATED OUT LOUD RATHER THAN LEFT
# IMPLICIT. Not a hardware limit like the others in this section -- a
# SEAM limit: the checkout is baked in, but the branch that would converge
# and start it has not been written.
unknown "The first-boot-ui hook's converge/start branch has NEVER RUN, on any image: the app is baked in at .paths.app_root, but that branch is unwritten, so the hook logs verdict=UNIMPLEMENTED and starts nothing. The checks above prove the trigger is wired correctly; they cannot and do not prove anything starts, because nothing does yet."

# ---------------------------------------------------------------------------
section "Artifact integrity"

# THE HARNESS MUST NOT CHANGE THE ARTIFACT IT CERTIFIES.
#
# It did. Twice on 2026-09-07: systemd-nspawn's --timezone/--resolv-conf
# defaults rewrote /etc/localtime and /etc/resolv.conf with the build host's
# values, and a kivy probe created /root/.kivy. The first of those then
# surfaced as a phantom image defect on the NEXT run.
#
# Both causes are fixed. This exists because the next one will be different:
# anything that executes inside a rootfs can write to it, and a mutation that
# lands in a field nobody re-checks is invisible. Snapshot the fields the image
# deliberately controls, and re-assert them after the executing tiers run.
snapshot_integrity() {
	INTEG_TZ="$(readlink "${ROOTFS}/etc/localtime" 2>/dev/null || echo MISSING)"
	INTEG_RESOLV="$(md5sum "${ROOTFS}/etc/resolv.conf" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"
	INTEG_KIVYROOT="$([ -e "${ROOTFS}/root/.kivy" ] && echo PRESENT || echo ABSENT)"
}
check_integrity() {
	local now
	now="$(readlink "${ROOTFS}/etc/localtime" 2>/dev/null || echo MISSING)"
	if [ "${now}" = "${INTEG_TZ}" ]; then
		ok "/etc/localtime unchanged by the harness"
	else
		bad "THE HARNESS CHANGED /etc/localtime: '${INTEG_TZ}' -> '${now}'"
	fi
	now="$(md5sum "${ROOTFS}/etc/resolv.conf" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"
	if [ "${now}" = "${INTEG_RESOLV}" ]; then
		ok "/etc/resolv.conf unchanged by the harness"
	else
		bad "THE HARNESS CHANGED /etc/resolv.conf"
	fi
	now="$([ -e "${ROOTFS}/root/.kivy" ] && echo PRESENT || echo ABSENT)"
	if [ "${now}" = "${INTEG_KIVYROOT}" ]; then
		ok "/root/.kivy unchanged by the harness (${now})"
	elif [ "${INTEG_KIVYROOT}" = "ABSENT" ]; then
		bad "THE HARNESS CREATED /root/.kivy"
	else
		# Report the direction. The first version of this message said
		# "CREATED" for both directions and printed "THE HARNESS CREATED
		# /root/.kivy (PRESENT -> ABSENT)" -- a removal described as a
		# creation, which sent the investigation the wrong way for a while.
		bad "THE HARNESS DELETED /root/.kivy, which the image already had -- a harness must not erase what it is inspecting"
	fi
}
snapshot_integrity
echo "  snapshot taken: localtime=${INTEG_TZ}, /root/.kivy=${INTEG_KIVYROOT}"

# ---------------------------------------------------------------------------
section "In-image assertions (chroot)"

# WHY THIS EXISTS ALONGSIDE --boot, rather than instead of it.
#
# docs/design/verification.md planned `systemd-nspawn --boot` because it "really starts
# systemd". That plan DID NOT SURVIVE CONTACT for an armhf rootfs under
# qemu-user inside Docker: measured 2026-09-07, nspawn produces no console
# output and never reaches the assertion unit, with /run on tmpfs, with
# --keep-unit and --register=no for the missing bus, with cgroup delegation,
# and with systemd.journald.forward_to_console=1. The armhf systemd binary
# itself runs fine under qemu-user (`systemd --version` reports 257), so the
# blocker is booting it as PID 1 in that nesting, not the emulation.
#
# A chroot answers most of the same questions and actually works: systemctl
# reads unit files, symlinks and masks straight off the disk, so is-enabled,
# `cat`, and the presence or absence of a display manager are all real answers.
# `import kivy` and `uv --version` genuinely execute the armhf binaries.
#
# What it CANNOT answer is anything requiring a running manager -- unit
# ordering as actually resolved, is-system-running, the failed-unit list.
# assert-inside.sh detects which mode it is in and marks those UNKNOWN rather
# than letting them vanish.
if [ "${DO_CHROOT}" = "1" ]; then
	if [ "$(id -u)" -ne 0 ]; then
		unknown "--chroot requires root. NOT RUN."
	else
		CHROOT_BIN="${ROOTFS}/usr/local/bin/elspi-assert-inside"
		install -m 0755 "$(dirname "$0")/assert-inside.sh" "${CHROOT_BIN}"
		mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true
		chroot "${ROOTFS}" /usr/local/bin/elspi-assert-inside 2>&1 | sed 's/^/  /' || true
		umount "${ROOTFS}/proc" 2>/dev/null || true
		rm -f "${CHROOT_BIN}" "${ROOTFS}/var/log/elspi-assert.out"

		# GATE: the injected script must not survive into the image.
		if [ -e "${CHROOT_BIN}" ]; then
			bad "harness artifact removed from rootfs: /usr/local/bin/elspi-assert-inside"
		fi
	fi
else
	unknown "--chroot not given: systemd's own view of unit files, masks, and 'import kivy' were NOT exercised."
fi

# ---------------------------------------------------------------------------
section "Booted assertions"

if [ "${DO_BOOT}" != "1" ]; then
	unknown "not run (--boot not given). Unit enablement and ordering, systemd's own view of the masks, and 'import kivy' are NOT covered by the offline checks above."
else
	if [ "$(id -u)" -ne 0 ]; then
		unknown "--boot requires root (systemd-nspawn). NOT RUN."
	elif ! command -v systemd-nspawn >/dev/null 2>&1; then
		unknown "systemd-nspawn not installed. NOT RUN."
	# Ask whether an armhf handler is REGISTERED AND ENABLED -- not where its
	# interpreter happens to live. This check first hardcoded
	# "interpreter /usr/bin/qemu-arm" and skipped the booted assertions on a
	# host that was correctly set up: Debian's qemu-user-static registers
	# /usr/libexec/qemu-binfmt/arm-binfmt-P instead. The path is a packaging
	# detail; the capability is the question.
	elif ! grep -qs '^enabled' /proc/sys/fs/binfmt_misc/qemu-arm 2>/dev/null; then
		unknown "no enabled qemu-arm binfmt handler is visible here, so an armhf rootfs cannot execute. NOT RUN. (Inside a container, binfmt_misc must also be mounted -- see tests/verify-built-image.sh.)"
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

		# --keep-unit: nspawn otherwise tries to allocate a scope unit on the
		# system bus, and there is no bus here ("Failed to open bus").
		# --register=no: no machined either.
		# /run must be tmpfs or nspawn refuses ("Attempted to remove disk file
		# system under /run/systemd/nspawn/propagate") -- the caller arranges
		# that; see tests/verify-built-image.sh.
		RESULT_IN_ROOTFS="${ROOTFS}/var/log/elspi-assert.out"
		rm -f "${RESULT_IN_ROOTFS}"

		BOOTLOG="$(mktemp)"
		# --timezone=off --resolv-conf=off ARE NOT OPTIONAL.
		#
		# nspawn defaults both to "auto", which writes the HOST's timezone and
		# resolv.conf INTO the container rootfs. Measured 2026-09-07: a boot
		# attempt repointed the image's /etc/localtime to the host's Etc/UTC,
		# and replaced /etc/resolv.conf with Docker's.
		#
		# Both are fields this image deliberately controls -- the timezone is
		# the declared build default -- so the harness was silently undoing
		# the thing it then went on to check, and a later run duly reported
		# the host's zone as an image defect. (The public default is now
		# Etc/UTC itself, which would make the same clobbering INVISIBLE on a
		# UTC host: all the more reason it stays off.)
		timeout 300 systemd-nspawn -D "${ROOTFS}" \
			--boot --register=no --keep-unit --quiet \
			--timezone=off --resolv-conf=off \
			--console=pipe >"${BOOTLOG}" 2>&1 </dev/null || true

		# The RESULT FILE is the source of truth, not the console. systemd
		# sends its output to the journal, so --console=pipe can come back
		# empty from a boot that ran the unit perfectly well.
		if [ -f "${RESULT_IN_ROOTFS}" ]; then
			cat "${RESULT_IN_ROOTFS}"
			cp "${RESULT_IN_ROOTFS}" "${BOOTLOG}"
		fi
		rm -f "${RESULT_IN_ROOTFS}"

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
section "Artifact integrity, re-checked"

if [ "${DO_CHROOT}" = "1" ] || [ "${DO_BOOT}" = "1" ]; then
	check_integrity
else
	echo "  no executing tier ran; nothing could have mutated the rootfs"
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
