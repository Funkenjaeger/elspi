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
# 2. THE DELTA LAYER gates on it. The sequencing trap from RUNTIME-INVENTORY.md
#    -- the log directory must exist and be writable BEFORE KCFG_KIVY_LOG_DIR
#    points at it -- is enforceable only if the delta can ASK where that
#    directory is instead of assuming. On a machine with no terminal, a delta
#    that assumes wrong costs a lathe power cycle.

MANIFEST="${ROOTFS_DIR}/etc/elspi-image.json"

REFLEX_COMMIT="$(tr -d '[:space:]' < "${ROOTFS_DIR}/etc/elspi/reflex-lock-commit")"
[ -n "${REFLEX_COMMIT}" ] || { echo "FATAL: reflex-lock-commit missing or empty"; exit 1; }

BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${MANIFEST}" <<- JSON
	{
	  "image": "elspi",
	  "arch": "armhf",
	  "release": "trixie",
	  "built_utc": "${BUILD_DATE}",
	  "pi_gen_upstream_pin": "314262c",
	  "reflex_lock_commit": "${REFLEX_COMMIT}",

	  "service_user": "${FIRST_USER_NAME}",
	  "runs_as_root": false,

	  "paths": {
	    "venv": "/opt/reflex-venv",
	    "app_parent": "/home/${FIRST_USER_NAME}/projects",
	    "app_root": "/home/${FIRST_USER_NAME}/projects/reflex",
	    "config_dir": "/var/lib/reflex-config",
	    "log_dir": "/var/log/reflex"
	  },

	  "drm": {
	    "default_mode": "first-opener",
	    "modes": ["first-opener", "logind-seat", "cap-sys-admin"],
	    "switcher": "/usr/local/sbin/elspi-drm-mode",
	    "verified_on_hardware": false
	  },

	  "delta_layer_owns": [
	    "reflex monorepo checkout at /home/default/projects/reflex",
	    "reflex-ui.service",
	    "start.sh and its KCFG_* environment",
	    "the single sudoers NOPASSWD rule",
	    "restore of /var/lib/reflex-config from backup (HARD FAIL if absent)",
	    "the interactive phase: password, authorized_keys, network credentials",
	    "reinstall of the OT state-pull forced-command key"
	  ],

	  "cannot_be_verified_without_hardware": [
	    "DRM master acquisition (no GPU in the harness)",
	    "KMS/DRM and the V3D driver",
	    "the touchscreen",
	    "SPI, I2C and the UART link to the STM32",
	    "anything config.txt or a dtoverlay actually DOES (firmware level)",
	    "usb_max_current_enable=1 brownout mitigation",
	    "audio output on card 0"
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

for key in log_dir config_dir venv app_parent default_mode reflex_lock_commit; do
	grep -q "\"${key}\"" "${MANIFEST}" || {
		echo "FATAL: manifest is missing required key '${key}'"
		exit 1
	}
done

echo "  wrote /etc/elspi-image.json (reflex lock ${REFLEX_COMMIT})"
