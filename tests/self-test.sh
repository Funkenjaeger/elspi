#!/bin/bash
# Prove that verify-image.sh can actually go red.
#
#   tests/self-test.sh
#
# A check that cannot fail reports a confident clean over exactly the state it
# could not see. So every property the harness claims to enforce gets MUTATED
# here, one at a time, and the harness must FAIL for each. A green harness on
# an unmutated fixture proves nothing on its own; it is the pair that means
# something.
#
# Runs on any Linux box in seconds. No pi-gen build, no Docker, no qemu -- so
# there is no excuse for it being skipped, which is how mutation tests usually
# die.
#
# NOTE ON SCOPE, stated rather than implied: this exercises the OFFLINE checks.
# The booted (--boot) assertions and everything hardware-dependent are NOT
# covered here and cannot be. See the blind-spot list the harness prints.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FIX="${WORK}/rootfs"
PASSED=0
FAILED=0

run_harness() { # -> 0 if harness passed, 1 if it failed
	"${HERE}/verify-image.sh" "${FIX}" >"${WORK}/out.txt" 2>&1
}

expect_green() {
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	if run_harness; then
		echo "  OK    baseline fixture passes"
		PASSED=$((PASSED+1))
	else
		echo "  BROKEN baseline fixture FAILS the harness -- the fixture is wrong,"
		echo "         so no mutation below proves anything. Harness output:"
		sed 's/^/           /' "${WORK}/out.txt"
		FAILED=$((FAILED+1))
	fi
}

mutate() { # mutate <name> <shell to break the fixture>
	local name="$1"; shift
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	( cd "${FIX}" && eval "$*" ) >/dev/null 2>&1
	if run_harness; then
		echo "  MISS  harness stayed GREEN after: ${name}"
		echo "        ^ this property is NOT actually enforced."
		FAILED=$((FAILED+1))
	else
		echo "  OK    harness went red for: ${name}"
		PASSED=$((PASSED+1))
	fi
}

echo "== baseline =="
expect_green

echo
echo "== mutations (each must turn the harness red) =="

# Identity and privilege
mutate "root password unlocked" \
	"sed -i 's|^root:\\*|root:\$6\$abc\$def|' etc/shadow"
mutate "service user password left usable (build throwaway ships)" \
	"sed -i 's|^default:!|default:\$6\$abc\$def|' etc/shadow"
mutate "service user dropped from the 'video' group" \
	"sed -i '/^video:/d' etc/group"
mutate "service user dropped from the 'dialout' group (Modbus)" \
	"sed -i '/^dialout:/d' etc/group"
mutate "a DRM mode fragment reverts to User=root" \
	"sed -i 's|^User=default|User=root|' usr/share/elspi/drm-modes/first-opener.conf"

# Boot configuration
mutate "SPI turned back off" \
	"sed -i 's|^dtparam=spi=on|#dtparam=spi=on|' boot/firmware/config.txt"
mutate "the Pi 5 nospi10 block dropped (ospi's regression)" \
	"sed -i '/dtoverlay=nospi10/d' boot/firmware/config.txt"
mutate "usb_max_current_enable removed (touchscreen brownouts)" \
	"sed -i '/usb_max_current_enable/d' boot/firmware/config.txt"
mutate "enable_uart removed" \
	"sed -i '/enable_uart/d' boot/firmware/config.txt"
mutate "serial console put back on the Modbus UART" \
	"sed -i 's|^console=tty1|console=serial0,115200 console=tty1|' boot/firmware/cmdline.txt"
mutate "serial-getty mask removed" \
	"rm -f etc/systemd/system/serial-getty@ttyAMA0.service"

# Graphics contract
mutate "a Wayland compositor installed (silently changes SDL's backend)" \
	"printf 'Package: weston\\nStatus: install ok installed\\nVersion: 1\\n\\n' >> var/lib/dpkg/status"
mutate "an X server installed" \
	"printf 'Package: xserver-xorg\\nStatus: install ok installed\\nVersion: 1\\n\\n' >> var/lib/dpkg/status"
mutate "the Mesa DRI driver missing (llvmpipe or hard EGL failure)" \
	"sed -i '/^Package: libgl1-mesa-dri\$/,+2d' var/lib/dpkg/status"
mutate "network-manager missing (nmcli python package shells out to it)" \
	"sed -i '/^Package: network-manager\$/,+2d' var/lib/dpkg/status"
mutate "libmtdev missing (the touch path)" \
	"sed -i '/^Package: libmtdev1t64\$/,+2d' var/lib/dpkg/status"

# The venv
mutate "Kivy has no compiled extensions" \
	"find opt/reflex-venv -name '*.so' -delete"
mutate "Kivy absent entirely" \
	"rm -rf opt/reflex-venv/lib/python3.13/site-packages/kivy-2.3.1.dist-info"
mutate "the reflex app leaked into the image venv" \
	"mkdir -p opt/reflex-venv/lib/python3.13/site-packages/reflex-1.1.0.dist-info"
# THE NAMESPACE MUTATION. This is the one that cost a build on 2026-09-07.
#
# The venv's bin/python is an absolute symlink to /usr/bin/python3. Delete the
# rootfs's python and the IMAGE is broken -- but a naive `test -x` from outside
# follows that absolute path to the BUILD HOST's /usr/bin/python3, which very
# much exists, and reports PASS. The check then measures the host it runs on
# rather than the image it was handed, and it is green either way for reasons
# unrelated to the truth.
#
# Verified 2026-09-07: the pre-fix harness stays GREEN on this mutation. That
# is what makes it worth a permanent test rather than a comment.
mutate "the venv python dangles INSIDE the rootfs (host python masks it)" \
	"rm -f usr/bin/python3 usr/bin/python3.13"

mutate "uv is a host x86 binary, not ARM" \
	"printf '\\x7fELF\\x02\\x01\\x01\\x00' > usr/local/bin/uv; head -c 64 /dev/zero >> usr/local/bin/uv"
mutate "uv missing" \
	"rm -f usr/local/bin/uv"

# Directories and ownership
mutate "the Kivy log directory missing (the sequencing trap)" \
	"rm -rf var/log/reflex"
mutate "the commissioned-config directory missing" \
	"rm -rf var/lib/reflex-config"
mutate "stray root-owned kivy logs in /var/log (the live machine's shape)" \
	"touch var/log/kivy_26-08-17_6.txt"

# Audio
mutate "asound.conf back on card 1 (the live defect)" \
	"printf 'defaults.pcm.card 1\\ndefaults.ctl.card 1\\n' > etc/asound.conf"

# Timezone
mutate "timezone reverted off America/New_York" \
	"ln -sf ../usr/share/zoneinfo/Europe/London etc/localtime"

# DRM plumbing
mutate "tty1 autologin shipped ACTIVE rather than mode-selected" \
	"mkdir -p etc/systemd/system/getty@tty1.service.d && touch etc/systemd/system/getty@tty1.service.d/10-elspi-autologin.conf"
mutate "first-opener loses its plymouth ordering (Plymouth keeps DRM master)" \
	"sed -i '/plymouth-quit-wait/d' usr/share/elspi/drm-modes/first-opener.conf"
mutate "the drm-mode switcher missing" \
	"rm -f usr/local/sbin/elspi-drm-mode"

# The manifest itself
mutate "the manifest is not valid JSON" \
	"printf 'not json' > etc/elspi-image.json"
mutate "the manifest is missing entirely" \
	"rm -f etc/elspi-image.json"

echo
echo "== result =="
echo "  ${PASSED} ok, ${FAILED} problems"
if [ "${FAILED}" -ne 0 ]; then
	echo
	echo "  A MISS above means verify-image.sh reports clean over a broken image."
	echo "  Fix the harness, not this file."
	exit 1
fi
exit 0
