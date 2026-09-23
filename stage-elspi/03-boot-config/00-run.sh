#!/bin/bash -e

# Firmware-level configuration: SPI, I2C, UART, camera off, quiet+splash, and
# -- when a site build asks for it -- the USB touchscreen brownout workaround.
#
# docs/design/seam.md puts all of this in the IMAGE: it needs a reboot, and wrong means no
# display or no Modbus. Cheap to bake, painful to retrofit.
#
# EVERY edit below ASSERTS ITS ANCHOR BEFORE WRITING and RE-GREPS THE TARGET
# AFTER. A sed that silently matches nothing is the failure mode this guards
# against -- it exits 0 and the image ships without SPI.

CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"

[ -f "${CONFIG}" ]  || { echo "FATAL: ${CONFIG} missing"; exit 1; }
[ -f "${CMDLINE}" ] || { echo "FATAL: ${CMDLINE} missing"; exit 1; }

# --- helper: uncomment a line that upstream ships commented -----------------
uncomment_or_die() {
	local key="$1" file="$2"
	if grep -qE "^${key}\$" "${file}"; then
		echo "  already active: ${key}"
		return 0
	fi
	grep -qE "^#${key}\$" "${file}" || {
		echo "FATAL: anchor '#${key}' not found in ${file}."
		echo "       Upstream changed the template; re-derive this edit."
		exit 1
	}
	sed -i "s|^#${key}\$|${key}|" "${file}"
	grep -qE "^${key}\$" "${file}" || {
		echo "FATAL: post-write check failed -- '${key}' not active in ${file}"
		exit 1
	}
	echo "  uncommented: ${key}"
}

# --- helper: replace an exact line -----------------------------------------
replace_or_die() {
	local from="$1" to="$2" file="$3"
	if grep -qxF "${to}" "${file}"; then
		echo "  already set: ${to}"
		return 0
	fi
	grep -qxF "${from}" "${file}" || {
		echo "FATAL: anchor '${from}' not found in ${file}."
		echo "       Upstream changed the template; re-derive this edit."
		exit 1
	}
	sed -i "s|^${from}\$|${to}|" "${file}"
	grep -qxF "${to}" "${file}" || {
		echo "FATAL: post-write check failed -- '${to}' absent from ${file}"
		exit 1
	}
	echo "  set: ${to}"
}

# --- helper: append a line that has no upstream anchor ----------------------
append_once() {
	local line="$1" file="$2"
	if grep -qxF "${line}" "${file}"; then
		echo "  already present: ${line}"
		return 0
	fi
	printf '%s\n' "${line}" >> "${file}"
	grep -qxF "${line}" "${file}" || {
		echo "FATAL: post-write check failed -- '${line}' absent from ${file}"
		exit 1
	}
	echo "  appended: ${line}"
}

echo "== config.txt =="

# The hardware interfaces the lathe actually uses. Upstream ships these
# COMMENTED; ospi's already-edited file is NOT our starting point.
uncomment_or_die "dtparam=i2c_arm=on" "${CONFIG}"
uncomment_or_die "dtparam=spi=on"     "${CONFIG}"

# GENERIC APPLIANCE HYGIENE, not one site's hardware: the application uses no
# camera on any machine, so autodetect only costs boot time and loads
# overlays for nothing.
replace_or_die "camera_auto_detect=1" "camera_auto_detect=0" "${CONFIG}"

# Guard, not an edit: upstream's Pi 5 SPI block is one of the two lines ospi
# dropped, and elspi IS a Pi 5 that uses SPI. If it ever goes missing upstream,
# fail here rather than ship a board that cannot talk to its own peripherals.
grep -qxF "dtoverlay=nospi10" "${CONFIG}" || {
	echo "FATAL: upstream's [pi5] dtoverlay=nospi10 block is gone from config.txt."
	echo "       This is the exact regression ospi shipped. Do not proceed."
	exit 1
}
echo "  guard ok: [pi5] dtoverlay=nospi10 present"

# Modbus to the STM32 rides the GPIO UART. Not in stock config.txt.
append_once "enable_uart=1" "${CONFIG}"

# Firmware rainbow splash off (Plymouth owns the boot visuals).
append_once "disable_splash=1" "${CONFIG}"

# A BUILD KNOB, OFF BY DEFAULT: ELSPI_USB_MAX_CURRENT (elspi.conf). A Pi 5
# powering a USB touchscreen may need usb_max_current_enable=1 -- "force high
# current USB mode to mitigate brownouts of USB-attached touchscreen display"
# -- but it is a property of one panel and supply, not of the appliance, so a
# site build config turns it on. OFF is enforced too, not merely skipped: a
# resumed build whose knob changed must not keep the previous pass's line.
case "${ELSPI_USB_MAX_CURRENT:-0}" in
	1)
		append_once "usb_max_current_enable=1" "${CONFIG}"
		;;
	0)
		if grep -q '^usb_max_current_enable=' "${CONFIG}"; then
			sed -i '/^usb_max_current_enable=/d' "${CONFIG}"
			echo "  removed: usb_max_current_enable (ELSPI_USB_MAX_CURRENT=0)"
		fi
		if grep -q '^usb_max_current_enable=' "${CONFIG}"; then
			echo "FATAL: post-write check failed -- usb_max_current_enable is still in ${CONFIG}"
			exit 1
		fi
		echo "  off: usb_max_current_enable (ELSPI_USB_MAX_CURRENT=0, the default)"
		;;
	*)
		echo "FATAL: ELSPI_USB_MAX_CURRENT must be 0 or 1 (got '${ELSPI_USB_MAX_CURRENT}')"
		exit 1
		;;
esac

echo "== cmdline.txt =="

# THE SERIAL CONSOLE MUST COME OFF ttyAMA0.
#
# Upstream ships "console=serial0,115200 console=tty1". The live elspi has NO
# serial console, because that UART carries Modbus to the STM32. A getty and
# minimalmodbus on the same line is a corrupted control link, not a warning.
if grep -q "console=serial0,115200 " "${CMDLINE}"; then
	sed -i "s|console=serial0,115200 ||" "${CMDLINE}"
	echo "  removed: console=serial0,115200"
elif grep -q "console=serial0" "${CMDLINE}"; then
	echo "FATAL: cmdline.txt carries a serial console in an unexpected form:"
	cat "${CMDLINE}"
	echo "       Re-derive this edit rather than shipping Modbus behind a getty."
	exit 1
else
	echo "  already absent: console=serial0"
fi
if grep -q "console=serial0" "${CMDLINE}"; then
	echo "FATAL: post-write check failed -- serial console still on the kernel cmdline"
	exit 1
fi

# Quiet boot + Plymouth, matching the live machine.
# cmdline.txt is a single line by contract; assert that before appending to it,
# because "s|$| tok|" would otherwise append to every line of a multi-line file.
lines=$(wc -l < "${CMDLINE}")
[ "${lines}" -le 1 ] || {
	echo "FATAL: cmdline.txt has ${lines} lines; it must be one. Refusing to append."
	exit 1
}
for tok in quiet splash logo.nologo plymouth.ignore-serial-consoles; do
	if grep -qwF -- "${tok}" "${CMDLINE}"; then
		echo "  already present: ${tok}"
	else
		sed -i "s|\$| ${tok}|" "${CMDLINE}"
		grep -qwF -- "${tok}" "${CMDLINE}" || {
			echo "FATAL: post-write check failed -- '${tok}' absent from cmdline.txt"
			exit 1
		}
		echo "  appended: ${tok}"
	fi
done

echo "== resulting cmdline.txt =="
cat "${CMDLINE}"
