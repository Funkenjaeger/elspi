#!/bin/bash -e

# /etc/elspi-image.json -- what this image CLAIMS about itself.
#
# Two consumers, and they are the reason this exists rather than being implicit:
#
# 1. THE VERIFICATION HARNESS asserts against this rather than against numbers
#    typed twice. A harness that hardcodes its own expectations is checking
#    that its author can copy a path; one that reads the image's declaration
#    and checks reality against it is checking the image.
#
# 2. THE DELTA LAYER gates on it. The sequencing trap from docs/design/runtime-inventory.md
#    -- the log directory must exist and be writable BEFORE KCFG_KIVY_LOG_DIR
#    points at it -- is enforceable only if the delta can ASK where that
#    directory is instead of assuming. On a machine with no terminal, a delta
#    that assumes wrong costs a lathe power cycle.

MANIFEST="${ROOTFS_DIR}/etc/elspi-image.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REFLEX_COMMIT="$(tr -d '[:space:]' < "${ROOTFS_DIR}/etc/elspi/reflex-lock-commit")"
[ -n "${REFLEX_COMMIT}" ] || { echo "FATAL: reflex-lock-commit missing or empty"; exit 1; }

# WHICH RELEASE OF THE APP IS BAKED IN (docs/design/seam.md amendment
# 2026-09-21). READ, not re-derived: stage-elspi/10a-app-checkout measured it
# when it did the clone and wrote these files, exactly as 08-venv writes
# reflex-lock-commit above. A second `git describe` here could disagree with
# the checkout it is describing -- one measurement, not two.
_read_fact() { # _read_fact <file> <what it is>
	local f="${ROOTFS_DIR}/etc/elspi/$1" v
	if [ ! -f "${f}" ]; then
		echo "FATAL: /etc/elspi/$1 is missing -- $2." >&2
		echo "       stage-elspi/10a-app-checkout writes it and must run before" >&2
		echo "       this stage. (tests/dry-run-stages.sh seeds it; a real build" >&2
		echo "       gets it from the substage.)" >&2
		exit 1
	fi
	v="$(tr -d '[:space:]' < "${f}")"
	[ -n "${v}" ] || { echo "FATAL: /etc/elspi/$1 is empty -- $2" >&2; exit 1; }
	printf '%s' "${v}"
}
APP_RELEASE="$(_read_fact reflex-app-release "the baked application release tag")"
APP_COMMIT="$(_read_fact reflex-app-commit "the commit that tag resolves to")"
APP_UPDATER_READY="$(_read_fact reflex-app-updater-ready "whether the baked release carries the in-app updater's own prerequisites")"
APP_PROTOCOL_READABLE="$(_read_fact reflex-app-protocol-readable "whether els_stop_map.py is readable at the baked tag")"
# From stage-elspi/10b-app-install (2026-09-26): whether the baked release
# carries reflex's commissioning guard -- the condition for starting it at
# first boot -- and that the app is installed in the venv with an offline
# re-sync proven. Same one-measurement rule as the facts above.
APP_COMMISSIONING_GUARD="$(_read_fact reflex-app-commissioning-guard "whether the baked release carries the commissioning guard (10b-app-install)")"
APP_INSTALLED_OFFLINE_OK="$(_read_fact reflex-app-installed-offline-ok "whether the baked app is installed in the venv with an offline re-sync proven (10b-app-install)")"

# The declared value must be a FULL release, checked HERE as well as at the
# clone. Not belt-and-braces: this is the field the manifest publishes to the
# UI and the delta layer, and a manifest that says "v1.2.0-rc.4" is a manifest
# that has to be believed by everything downstream. Through the same script
# the selection uses, never a second regex.
if ! bash "${HERE}/../10a-app-checkout/files/select-release.sh" check "${APP_RELEASE}" >/dev/null; then
	echo "FATAL: the baked release '${APP_RELEASE}' is not a full release."
	echo "       docs/design/seam.md's 2026-09-21 amendment: the image ships the"
	echo "       latest FULL release, never a development rc.*. Refusing to"
	echo "       declare it in the manifest."
	exit 1
fi

# JSON booleans, from the yes/no the substage recorded.
case "${APP_UPDATER_READY}" in
	yes) APP_UPDATER_READY_JSON=true ;;
	no)  APP_UPDATER_READY_JSON=false ;;
	*)   echo "FATAL: reflex-app-updater-ready is '${APP_UPDATER_READY}', expected yes or no"; exit 1 ;;
esac
case "${APP_PROTOCOL_READABLE}" in
	yes) APP_PROTOCOL_READABLE_JSON=true ;;
	no)  APP_PROTOCOL_READABLE_JSON=false ;;
	*)   echo "FATAL: reflex-app-protocol-readable is '${APP_PROTOCOL_READABLE}', expected yes or no"; exit 1 ;;
esac
case "${APP_COMMISSIONING_GUARD}" in
	yes) APP_COMMISSIONING_GUARD_JSON=true ;;
	no)  APP_COMMISSIONING_GUARD_JSON=false ;;
	*)   echo "FATAL: reflex-app-commissioning-guard is '${APP_COMMISSIONING_GUARD}', expected yes or no"; exit 1 ;;
esac
# 10b-app-install writes only "yes": it FATALs rather than record a failed
# offline proof. Anything else here is a build that did not run it.
[ "${APP_INSTALLED_OFFLINE_OK}" = yes ] || { echo "FATAL: reflex-app-installed-offline-ok is '${APP_INSTALLED_OFFLINE_OK}', expected yes"; exit 1; }

# THE FIRST-BOOT START, declared from what was measured. The hook
# (stage-elspi/14-first-boot-ui) starts the app only when the guard is there;
# the manifest says the same thing rather than a constant.
if [ "${APP_COMMISSIONING_GUARD}" = yes ]; then
	STARTED_ON_FIRST_BOOT_JSON=true
	FBUI_STATUS="converges the baked checkout OFFLINE with the image's own copy of the delta layer (paths below), then starts reflex-ui.service, once. The baked release carries the commissioning guard, so a fresh card comes up UNCOMMISSIONED on the application's defaults and saves nothing until a restore or a deliberate dismissal. Never restores. See stage-elspi/14-first-boot-ui/README.md."
else
	STARTED_ON_FIRST_BOOT_JSON=false
	FBUI_STATUS="the baked release predates reflex's commissioning guard, so the hook REFUSES to start it (verdict=REFUSED_NO_GUARD) and the card is provisioned by hand. See stage-elspi/14-first-boot-ui/README.md."
fi

BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# THE DEFAULTS AN UNSEEDED CARD KEEPS. build.sh exports all four (with its own
# defaults when the config sets none), so an empty one here means this is not
# the build it claims to be. Declared so tests/verify-image.sh can check the
# rootfs against what the build was ASKED for -- elspi.conf's defaults, or a
# site build config's -- rather than against a zone typed into the harness.
# Imager's customisation page replaces hostname, timezone and keymap per card
# (cloud-init user-data); it has no locale field, so locale is what every
# card keeps. See elspi.conf's "Locale, keyboard, time" block.
for _v in TARGET_HOSTNAME TIMEZONE_DEFAULT LOCALE_DEFAULT KEYBOARD_KEYMAP; do
	[ -n "${!_v:-}" ] || { echo "FATAL: ${_v} is empty -- build.sh always exports it"; exit 1; }
done
unset _v

# The build knobs elspi.conf exports (a site build config may have set them),
# as JSON booleans. Unset means elspi.conf was not the config, and its
# defaults -- off, no site config -- are what 03-boot-config applied too.
case "${ELSPI_USB_MAX_CURRENT:-0}" in
	1) USB_MAX_CURRENT_JSON=true ;;
	0) USB_MAX_CURRENT_JSON=false ;;
	*) echo "FATAL: ELSPI_USB_MAX_CURRENT is '${ELSPI_USB_MAX_CURRENT}', expected 0 or 1"; exit 1 ;;
esac
case "${ELSPI_SITE_CONF_APPLIED:-0}" in
	1) SITE_CONF_JSON=true ;;
	0) SITE_CONF_JSON=false ;;
	*) echo "FATAL: ELSPI_SITE_CONF_APPLIED is '${ELSPI_SITE_CONF_APPLIED}', expected 0 or 1"; exit 1 ;;
esac

# IMAGE_BUILD_SHA -- the git rev of THIS repo (elspi is a soft fork of pi-gen
# itself; there is no separate "elspi repo" checkout) at build time.
# build-docker.sh:67 already computes this on the host and forwards it into
# the container by NAME as GIT_HASH (build-elspi.sh's trap #2) specifically so
# every stage can see it; 12-first-boot-seed/00-run.sh already reads it for
# the same reason. Read here, not re-derived with a second `git rev-parse`,
# so there is one measurement of "what commit is this build" and not two that
# could disagree if the build runs from a dirty tree.
IMAGE_BUILD_SHA="${GIT_HASH:-unknown}"

# IMAGE_RELEASE -- the monotonic integer the reflex updater (order
# 2026-09-14#6) compares against. NOT measured: it is a manually maintained
# counter, like a version file, bumped by the rule in docs/provisioning.md.
# Starts at 1 for v2026.09.13's successor -- this is that successor.
IMAGE_RELEASE=1

# The runtime versions ACTUALLY INSTALLED, measured now rather than hardcoded,
# so a version bump elsewhere in the build (a trixie point release, a Kivy or
# uv version bump in files/uv.lock) cannot leave the manifest lying about what
# shipped.
#
# python and uv are ARM binaries in this rootfs; on_chroot runs them under the
# qemu-user emulation build-elspi.sh sets up, exactly as stage-elspi/08-venv
# already does to build the venv in the first place.
#
# GUARDED on `on_chroot` being DEFINED, not just attempted-and-caught: a real
# pi-gen build always has it (build.sh sources scripts/common before any
# stage runs), but tests/dry-run-stages.sh -- which CI's tier1 job runs on a
# plain Ubuntu runner with no chroot and no qemu, deliberately, per its own
# header -- calls this script directly and does not. That harness already
# documents three OTHER substages (04-serial, 05-service-user, 08-venv) it
# cannot exercise chroot-free; this is now a fourth, and the fallback below
# says so loudly rather than reporting a measured value that was never taken.
if command -v on_chroot >/dev/null 2>&1; then
	RUNTIME_VERSIONS="$(on_chroot << 'EOF'
set -e
/usr/bin/python3 --version 2>&1
/usr/local/bin/uv --version 2>&1
EOF
	)"
	PYTHON_VERSION="$(echo "${RUNTIME_VERSIONS}" | sed -n '1p')"
	UV_VERSION="$(echo "${RUNTIME_VERSIONS}" | sed -n '2p')"
	[ -n "${PYTHON_VERSION}" ] || { echo "FATAL: could not measure python3 --version in the chroot"; exit 1; }
	[ -n "${UV_VERSION}" ] || { echo "FATAL: could not measure uv --version in the chroot"; exit 1; }
else
	echo "  WARNING: on_chroot is not defined -- this is not a real pi-gen build"
	echo "           (tests/dry-run-stages.sh, most likely). python/uv versions"
	echo "           are UNMEASURED placeholders, not what would actually ship."
	PYTHON_VERSION="unmeasured (no chroot available)"
	UV_VERSION="unmeasured (no chroot available)"
fi

# Kivy's version comes from its installed dist-info, not from importing it:
# `import kivy` creates $HOME/.kivy (see tests/assert-inside.sh's own note on
# this, and the 2026-09-01 non-root decision), and the manifest stage has no
# business creating that as a side effect of measuring a version string. This
# is also, precisely, "measure the venv" rather than "assume 08-venv's pin
# matches what's on disk": if the .so build failed over to a different
# resolved version, this catches it instead of reporting yesterday's number.
#
# Same dry-run guard as above, on the venv's PRESENCE rather than a command:
# tests/dry-run-stages.sh never builds /opt/reflex-venv (08-venv is one of the
# substages it explicitly cannot exercise chroot-free), so its absence here
# means "not a real build" rather than "the build lost Kivy".
if [ -d "${ROOTFS_DIR}/opt/reflex-venv" ]; then
	KIVY_DIST_INFO="$(find "${ROOTFS_DIR}/opt/reflex-venv" -maxdepth 5 -iname 'kivy-*.dist-info' -print -quit)"
	[ -n "${KIVY_DIST_INFO}" ] || { echo "FATAL: no kivy-*.dist-info found under /opt/reflex-venv"; exit 1; }
	KIVY_VERSION="$(basename "${KIVY_DIST_INFO}" .dist-info | sed 's/^kivy-//')"
else
	echo "  WARNING: /opt/reflex-venv does not exist -- this is not a real pi-gen"
	echo "           build. kivy version is an UNMEASURED placeholder."
	KIVY_VERSION="unmeasured (no venv)"
fi

# NOTE ON delta_layer_owns BELOW: "reflex monorepo checkout at
# /home/default/projects/reflex" was its first entry for as long as the seam
# put the app in the deltas. docs/design/seam.md's ratified 2026-09-21
# amendment moves the checkout into the image, so it is declared as baked_app
# above and is NO LONGER in that list. Leaving it would make one document
# claim the same path for two different owners, and the delta layer reads this
# file to decide what it still has to do.
cat > "${MANIFEST}" <<- JSON
	{
	  "image": "elspi",
	  "arch": "armhf",
	  "release": "trixie",
	  "built_utc": "${BUILD_DATE}",
	  "pi_gen_upstream_pin": "314262c",
	  "reflex_lock_commit": "${REFLEX_COMMIT}",
	  "image_build_sha": "${IMAGE_BUILD_SHA}",
	  "image_release": ${IMAGE_RELEASE},

	  "runtime_versions": {
	    "python": "${PYTHON_VERSION}",
	    "kivy": "${KIVY_VERSION}",
	    "uv": "${UV_VERSION}"
	  },

	  "baked_app": {
	    "release": "${APP_RELEASE}",
	    "commit": "${APP_COMMIT}",
	    "root": "/home/${FIRST_USER_NAME}/projects/reflex",
	    "source_form": "git-checkout-with-tag-history",
	    "selected_by": "stage-elspi/10a-app-checkout/files/select-release.sh",
	    "updater_ready": ${APP_UPDATER_READY_JSON},
	    "protocol_version_readable": ${APP_PROTOCOL_READABLE_JSON},
	    "commissioning_guard": ${APP_COMMISSIONING_GUARD_JSON},
	    "installed_in_venv": true,
	    "started_on_first_boot": ${STARTED_ON_FIRST_BOOT_JSON}
	  },

	  "service_user": "${FIRST_USER_NAME}",
	  "runs_as_root": false,

	  "build_defaults": {
	    "hostname": "${TARGET_HOSTNAME}",
	    "timezone": "${TIMEZONE_DEFAULT}",
	    "locale": "${LOCALE_DEFAULT}",
	    "keymap": "${KEYBOARD_KEYMAP}",
	    "replaced_per_card_by_imager": ["hostname", "timezone", "keymap"],
	    "site_build_config_applied": ${SITE_CONF_JSON}
	  },

	  "boot_config": {
	    "usb_max_current_enable": ${USB_MAX_CURRENT_JSON}
	  },

	  "paths": {
	    "venv": "/opt/reflex-venv",
	    "app_parent": "/home/${FIRST_USER_NAME}/projects",
	    "app_root": "/home/${FIRST_USER_NAME}/projects/reflex",
	    "config_dir": "/var/lib/reflex-config",
	    "log_dir": "/var/log/reflex"
	  },

	  "drm": {
	    "default_mode": "first-opener",
	    "modes": ["first-opener", "cap-sys-admin"],
	    "switcher": "/usr/local/sbin/elspi-drm-mode",
	    "verified_on_hardware": true
	  },

	  "first_boot_seed": {
	    "source": "raspberry-pi-imager-2.x-os-customisation",
	    "unit": "/etc/systemd/system/elspi-first-boot-seed.service",
	    "script": "/usr/local/sbin/elspi-first-boot-seed",
	    "neutralises_after_use": [
	      "/boot/firmware/user-data",
	      "/boot/firmware/network-config"
	    ],
	    "leaves_intact": ["/boot/firmware/meta-data"],
	    "verified_on_hardware": true
	  },

	  "ssh": {
	    "enabled": true,
	    "key_source": "imager-seed",
	    "keys_installed_by": "/usr/local/sbin/elspi-first-boot-seed",
	    "baked_authorized_keys": false,
	    "auth": "imager-choice",
	    "image_sets_auth_options": false
	  },

	  "first_boot_ui": {
	    "unit": "/etc/systemd/system/elspi-first-boot-ui.service",
	    "script": "/usr/local/sbin/elspi-first-boot-ui",
	    "deltas": "/usr/local/lib/elspi/deltas",
	    "commissioning_guard_check": "/usr/local/lib/elspi/commissioning-guard",
	    "offline": true,
	    "runs_once": true,
	    "restores_config": false,
	    "status": "${FBUI_STATUS}",
	    "verified_on_hardware": false
	  },

	  "delta_layer_owns": [
	    "reflex-ui.service",
	    "start.sh and its KCFG_* environment",
	    "the single sudoers NOPASSWD rule",
	    "restore of /var/lib/reflex-config from backup (HARD FAIL if absent)",
	    "the interactive phase: the dev-role question, and any credential the Imager seed did not carry"
	  ],

	  "cannot_be_verified_without_hardware": [
	    "DRM master acquisition (no GPU in the harness)",
	    "KMS/DRM and the V3D driver",
	    "the touchscreen",
	    "SPI, I2C and the UART link to the STM32",
	    "anything config.txt or a dtoverlay actually DOES (firmware level)",
	    "whether usb_max_current_enable (off unless a site build turns it on) prevents a USB touchscreen's brownouts",
	    "audio output on card 0",
	    "the first-boot-ui hook (stage-elspi/14-first-boot-ui): its branches are exercised offline (tests/test-first-boot-ui.sh) and 10b-app-install proves the offline re-sync at build time, but converge-then-start of the baked app at first boot has not yet run on a real card, and the UNCOMMISSIONED strip is the application's to show",
	    "SSH login on a real card with the key or password typed into Imager (the image is keyless since 2026-09-23; the seed unit's key install is verified offline only)"
	  ]
	}
JSON

# POST-WRITE CHECKS -- valid JSON, and carrying the fields consumers depend on.
if command -v python3 >/dev/null 2>&1; then
	python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${MANIFEST}" || {
		echo "FATAL: ${MANIFEST} is not valid JSON"
		exit 1
	}
fi

for key in log_dir config_dir venv app_parent default_mode reflex_lock_commit \
           first_boot_seed first_boot_ui unit script image_build_sha image_release \
           runtime_versions baked_app updater_ready protocol_version_readable \
           commissioning_guard started_on_first_boot deltas commissioning_guard_check \
           ssh key_source build_defaults boot_config usb_max_current_enable; do
	grep -q "\"${key}\"" "${MANIFEST}" || {
		echo "FATAL: manifest is missing required key '${key}'"
		exit 1
	}
done

echo "  wrote /etc/elspi-image.json (reflex lock ${REFLEX_COMMIT}, baked app ${APP_RELEASE})"

# /etc/elspi-release -- the SAME data, reshaped for the UI and the reflex
# updater (order 2026-09-14#6). One declaration (above), two renderings: this
# is the flat os-release-shaped one. Generated FROM the manifest just written,
# by files/render-release.sh, so there is exactly one place that maps JSON
# keys to flat KEY=VALUE names and the tests can drive that same mapping on a
# synthetic fixture without a chroot.
bash "${HERE}/files/render-release.sh" generate "${ROOTFS_DIR}" || {
	echo "FATAL: render-release.sh generate failed"
	exit 1
}
