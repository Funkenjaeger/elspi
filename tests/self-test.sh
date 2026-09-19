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

# --- /etc/elspi-release (order 2026-09-14#5) ---------------------------
#
# This one does NOT go through run_harness()/verify-image.sh. That order's
# bound is an explicit allow-list -- stage-elspi/11-manifest/, this file,
# make-fixture.sh, assert-inside.sh, docs/provisioning.md -- and
# tests/verify-image.sh is not on it, so the Tier-2 offline harness does not
# (yet) know /etc/elspi-release exists. See REPORT.md for the gap this
# leaves: a real build's verify-image.sh run does not check this file at all
# today; only this self-test and the booted/chrooted assert-inside.sh do.
#
# So "the harness" for THESE mutations is
# stage-elspi/11-manifest/files/render-release.sh's own `validate` mode,
# exercised directly on the fixture -- the same standalone-script split that
# lets it run without a chroot in the first place.
run_release_check() { # -> 0 if the release file checks out, 1 if it failed
	"${HERE}/../stage-elspi/11-manifest/files/render-release.sh" validate "${FIX}" \
		>"${WORK}/out.txt" 2>&1
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

expect_release_green() {
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	if run_release_check; then
		echo "  OK    baseline fixture passes the /etc/elspi-release check"
		PASSED=$((PASSED+1))
	else
		echo "  BROKEN baseline fixture FAILS the release check -- the fixture is"
		echo "         wrong, so no mutation below proves anything. Output:"
		sed 's/^/           /' "${WORK}/out.txt"
		FAILED=$((FAILED+1))
	fi
}

mutate_release() { # mutate_release <name> <shell to break the fixture>
	local name="$1"; shift
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	( cd "${FIX}" && eval "$*" ) >/dev/null 2>&1
	if run_release_check; then
		echo "  MISS  release check stayed GREEN after: ${name}"
		echo "        ^ this property is NOT actually enforced."
		FAILED=$((FAILED+1))
	else
		echo "  OK    release check went red for: ${name}"
		PASSED=$((PASSED+1))
	fi
}

# --- USB automount (stage-elspi/13-usb-automount, order 2026-09-16#6) -------
#
# Same situation as /etc/elspi-release above: this order's bound is an
# explicit allow-list -- stage-elspi/13-usb-automount/, tests/assert-inside.sh,
# tests/self-test.sh, tests/make-fixture.sh, tests/test-usb-automount-name.sh,
# docs/provisioning.md -- and tests/verify-image.sh is not on it. So this
# checks the fixture's udev rule and helper directly, the same way
# run_release_check checks the fixture's release file directly.
run_usb_automount_check() { # -> 0 if the USB automount contract holds, 1 if broken
	# Explicit && chaining, NOT `set -e` in a subshell: called repeatedly as
	# an `if` condition (once per mutation, same as run_release_check), and
	# a `set -e` subshell used that way stopped honoring errexit after the
	# first call -- observed directly in this sandbox's bash 5.2.21, where a
	# later `[ -x ... ]` failure silently fell through to the next command
	# instead of aborting the subshell, so the LAST command's (unrelated)
	# exit status decided the result instead. `&&` short-circuiting does not
	# depend on that errexit machinery at all.
	local RULE="${FIX}/etc/udev/rules.d/90-elspi-usb-automount.rules"
	local HELPER="${FIX}/usr/local/lib/elspi/elspi-usb-mount-name"
	{ [ -f "${RULE}" ] && [ -x "${HELPER}" ] && grep -q 'noexec' "${RULE}"; } \
		>"${WORK}/out.txt" 2>&1
}

expect_usb_automount_green() {
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	if run_usb_automount_check; then
		echo "  OK    baseline fixture passes the USB automount check"
		PASSED=$((PASSED+1))
	else
		echo "  BROKEN baseline fixture FAILS the USB automount check -- the fixture is"
		echo "         wrong, so no mutation below proves anything. Output:"
		sed 's/^/           /' "${WORK}/out.txt"
		FAILED=$((FAILED+1))
	fi
}

mutate_usb_automount() { # mutate_usb_automount <name> <shell to break the fixture>
	local name="$1"; shift
	"${HERE}/make-fixture.sh" "${FIX}" >/dev/null
	( cd "${FIX}" && eval "$*" ) >/dev/null 2>&1
	if run_usb_automount_check; then
		echo "  MISS  USB automount check stayed GREEN after: ${name}"
		echo "        ^ this property is NOT actually enforced."
		FAILED=$((FAILED+1))
	else
		echo "  OK    USB automount check went red for: ${name}"
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

# The venv must be the service user's all the way down (Open Loops 6aac9465):
# reflex's updater `uv sync`s into it as that user, after flashing. Making an
# entry owned by SOMEONE ELSE needs chown, i.e. root -- so without root this
# mutation is reported as not run rather than registered as a pass it did not
# earn. (The fixture's service user is the invoking uid, so 54321 is "not
# the service user" whether this runs as root or not.)
if [ "$(id -u)" -eq 0 ]; then
	mutate "a package dir in the venv not owned by the service user (the root-built venv, 2026-09-17)" \
		"chown 54321 opt/reflex-venv/lib/python3.13/site-packages/kivy"
else
	echo "  UNKN  venv-ownership mutation needs root (chown); NOT RUN"
fi

# THE POLKIT RULE -- the other half of the non-root decision, and the half
# that image addcb2e shipped without. Every check in the group above was green
# on that image while the appliance UI could not turn the radio on.
mutate "the polkit rule for the service user missing (2026-09-13: nmcli radio wifi on refused)" \
	"rm -f etc/polkit-1/rules.d/50-reflex-service-user.rules"
# The rule is generated from a template by substituting the service user into
# the subject.user line. A substitution that no-ops leaves a syntactically
# perfect rule scoped to a user who does not exist on this image: inert, and
# identical to a working one in a directory listing.
mutate "the polkit rule names a user that does not exist (the substitution no-opped)" \
	"sed -i 's|default|nosuchuser|' etc/polkit-1/rules.d/50-reflex-service-user.rules"
# A rule that returned YES for EVERY action id would still name the user, so
# the scoping is its own assertion.
mutate "the polkit rule loses its NetworkManager scoping (blanket YES)" \
	"sed -i '/NetworkManager/d' etc/polkit-1/rules.d/50-reflex-service-user.rules"

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
mutate "the git PACKAGE missing (the gap on the first real card, 2026-09-13)" \
	"sed -i '/^Package: git\$/,+2d' var/lib/dpkg/status"

# --- the commands the runtime shells out to ---------------------------------
# A missing COMMAND is a different question from a missing package, and until
# 2026-09-13 nobody had asked the first one. Each of these is invoked by name
# by something that has to work on a machine with no terminal, so losing one
# is discovered by a human standing at a lathe.
mutate "/usr/bin/git missing from the rootfs (the app half is a checkout)" \
	"rm -f usr/bin/git"
mutate "nmcli missing (the nmcli python package shells out to the BINARY)" \
	"rm -f usr/bin/nmcli"
mutate "tar missing (restore cannot unpack a tarball backup)" \
	"rm -f usr/bin/tar"
mutate "passwd missing (the account ships LOCKED; phase 3 could never unlock it)" \
	"rm -f usr/bin/passwd"
# visudo lives in /usr/sbin, so this also proves the harness searches more
# than /usr/bin. Without it converge cannot validate a sudoers file before
# moving it into place, and a malformed one breaks sudo for every user on a
# machine that needs the SD card pulled to recover.
mutate "visudo missing from /usr/sbin (converge validates sudoers before installing)" \
	"rm -f usr/sbin/visudo"

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
mutate "a tty1 autologin shipped ACTIVE in the image" \
	"mkdir -p etc/systemd/system/getty@tty1.service.d && touch etc/systemd/system/getty@tty1.service.d/10-elspi-autologin.conf"
mutate "first-opener loses its plymouth ordering (Plymouth keeps DRM master)" \
	"sed -i '/plymouth-quit-wait/d' usr/share/elspi/drm-modes/first-opener.conf"
mutate "the drm-mode switcher missing" \
	"rm -f usr/local/sbin/elspi-drm-mode"

# THE DELETED RUNG (logind-seat, removed 2026-09-13 once first-opener was
# verified on hardware). These mutations are the reason the deletion is
# checkable at all: they put each piece of the seat machinery BACK, and the
# harness must go red for every one of them. Note the direction -- there is no
# mutation here for a MISSING seat piece, because a missing seat piece is now
# the correct state and nothing could go red for it.
mutate "the logind-seat fragment back in the drm-modes dir" \
	"printf '[Service]\\nUser=default\\n' > usr/share/elspi/drm-modes/logind-seat.conf"
mutate "the tty1 autologin fragment back (the seat rung's other half)" \
	"printf '[Service]\\nExecStart=-/sbin/agetty --autologin default --noclear %%I \$TERM\\n' > usr/share/elspi/getty-tty1-autologin.conf"
mutate "the switcher offering logind-seat again" \
	"sed -i 's|^VALID_MODES=.*|VALID_MODES=\"first-opener logind-seat cap-sys-admin\"|' usr/local/sbin/elspi-drm-mode"
mutate "the switcher forgetting the cap-sys-admin floor" \
	"sed -i 's|^VALID_MODES=.*|VALID_MODES=\"first-opener\"|' usr/local/sbin/elspi-drm-mode"
mutate "the manifest declaring logind-seat again" \
	"sed -i 's|\"first-opener\", \"cap-sys-admin\"|\"first-opener\", \"logind-seat\", \"cap-sys-admin\"|' etc/elspi-image.json"

# The first-boot seed (stage-elspi/12-first-boot-seed)
#
# THE FIRST MUTATION HERE IS THE WHOLE REASON THE SUBSTAGE EXISTS. Upstream's
# stage2/04-cloud-init template spells the key `instance_id` with an
# UNDERSCORE; cloud-init 25.2's NoCloud datasource reads `instance-id` and
# otherwise falls back to the literal "nocloud". An image that ships the
# underscore has a datasource that cannot tell one instance from another, and
# nothing about it looks broken.
mutate "meta-data reverted to upstream's misspelled instance_id" \
	"printf 'dsmode: local\\ninstance_id: rpios-image\\n' > boot/firmware/meta-data"
mutate "meta-data carries BOTH the hyphenated and the underscored key" \
	"printf 'instance_id: rpios-image\\n' >> boot/firmware/meta-data"
mutate "meta-data has no instance-id at all" \
	"sed -i '/^instance-id:/d' boot/firmware/meta-data"
mutate "the first-boot seed script missing" \
	"rm -f usr/local/sbin/elspi-first-boot-seed"
mutate "the first-boot seed script is not executable" \
	"chmod 0644 usr/local/sbin/elspi-first-boot-seed"
mutate "the first-boot seed unit missing" \
	"rm -f etc/systemd/system/elspi-first-boot-seed.service"
mutate "the first-boot seed unit is installed but NOT enabled" \
	"rm -f etc/systemd/system/cloud-init.target.wants/elspi-first-boot-seed.service"
# A dangling enablement symlink looks enabled to `ls` and is silently ignored
# by systemd. This is the mutation that a `test -L` check would sail past.
mutate "the first-boot seed enablement symlink dangles" \
	"ln -sf ../elspi-first-boot-seed-TYPO.service etc/systemd/system/cloud-init.target.wants/elspi-first-boot-seed.service"
mutate "the seed unit loses its WantedBy, so the wants symlink is invented" \
	"sed -i '/^WantedBy=cloud-init.target\$/d' etc/systemd/system/elspi-first-boot-seed.service"

# THE 2026-09-13 ORDERING CYCLE, put back one half at a time.
#
# These two mutations reconstruct the image that shipped and did not run the
# seed. Every OTHER check in the harness was green on it -- the unit was
# installed, executable, '-' prefixed, After=cloud-final, and enabled by a
# symlink that resolved. It just happened to be enabled in the one target
# cloud-final.service is itself ordered after, so systemd deleted our job:
#
#   Job elspi-first-boot-seed.service/start deleted to break ordering cycle
#   starting with cloud-final.service/start
#
# The FIRST of the two is the shape that actually shipped. It is a pure
# ADDITION to a correct fixture, which is why nothing else can catch it.
mutate "the seed unit ALSO enabled in multi-user.target.wants (the 2026-09-13 ordering cycle)" \
	"mkdir -p etc/systemd/system/multi-user.target.wants && ln -sf ../elspi-first-boot-seed.service etc/systemd/system/multi-user.target.wants/elspi-first-boot-seed.service"
mutate "the seed unit declares WantedBy=multi-user.target too ('systemctl reenable' restores the cycle)" \
	"printf 'WantedBy=multi-user.target\\n' >> etc/systemd/system/elspi-first-boot-seed.service"
# Without the '-' prefix a failing seed script fails the boot of a machine
# that has no terminal and no serial console.
mutate "the seed unit's ExecStart loses its '-' prefix (can fail the boot)" \
	"sed -i 's|^ExecStart=-|ExecStart=|' etc/systemd/system/elspi-first-boot-seed.service"
# Ordering IS the design. Run before cloud-init has consumed the seed and the
# script neutralises credentials nobody has read yet.
mutate "the seed unit loses its After=cloud-final ordering" \
	"sed -i '/^After=cloud-final.service\$/d' etc/systemd/system/elspi-first-boot-seed.service"

# The manifest itself
mutate "the manifest does not declare the first-boot seed" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d.pop('first_boot_seed',None);json.dump(d,open(p,'w'))\""
mutate "the manifest is not valid JSON" \
	"printf 'not json' > etc/elspi-image.json"
mutate "the manifest is missing entirely" \
	"rm -f etc/elspi-image.json"

echo
echo "== /etc/elspi-release (order 2026-09-14#5) =="
echo "   Checked via render-release.sh validate, not verify-image.sh -- see the"
echo "   comment above run_release_check() for why."
expect_release_green

mutate_release "the release file is missing" \
	"rm -f etc/elspi-release"
mutate_release "the flat file and the manifest disagree on REFLEX_COMMIT" \
	"sed -i 's|^ELSPI_REFLEX_COMMIT=.*|ELSPI_REFLEX_COMMIT=\"deadbeef\"|' etc/elspi-release"
mutate_release "ELSPI_IMAGE_RELEASE is not an integer" \
	"sed -i 's|^ELSPI_IMAGE_RELEASE=.*|ELSPI_IMAGE_RELEASE=notanumber|' etc/elspi-release"

echo
echo "== USB automount (order 2026-09-16#6) =="
echo "   Checked directly against the fixture's udev rule and helper, not"
echo "   through verify-image.sh -- see the comment above"
echo "   run_usb_automount_check() for why."
expect_usb_automount_green

mutate_usb_automount "the udev rule missing" \
	"rm -f etc/udev/rules.d/90-elspi-usb-automount.rules"
mutate_usb_automount "the sanitizer helper not executable" \
	"chmod 0644 usr/local/lib/elspi/elspi-usb-mount-name"
mutate_usb_automount "'noexec' dropped from the systemd-mount options" \
	"sed -i 's/,noexec//' etc/udev/rules.d/90-elspi-usb-automount.rules"

# --- render-release.sh without python3 (order 2026-09-18#1) ----------------
#
# WIRED IN HERE rather than added to .github/workflows/tier1.yml, because
# tier1.yml names every tests/*.sh runner it invokes one at a time (only
# deltas/tests/*.sh is globbed), and the workflow is outside this order's
# bound. self-test.sh is already a tier1 step, so hanging the new runner off
# it is what makes it actually RUN in CI rather than sit in tests/ being
# nobody's job -- which is how tests/test-swd-doc.sh and
# tests/test-usb-automount-name.sh are currently not collected anywhere.
#
# Kept as its OWN script rather than inlined: it needs a restricted PATH, an
# `env -i` and a golden byte-for-byte comparison, none of which fit the
# mutate_*/expect_* shape above, and it has to stay runnable on its own when
# somebody is debugging the extraction.
echo
echo "== render-release.sh with no python3 on PATH (order 2026-09-18#1) =="
echo "   The 2026-09-17 image build died three hours in because jget() shelled"
echo "   out to python3 on the BUILD HOST, which has none. Delegated to"
echo "   tests/test-render-release-no-python3.sh -- see its header."
if bash "${HERE}/test-render-release-no-python3.sh" >"${WORK}/out.txt" 2>&1; then
	echo "  OK    render-release.sh renders byte-identically with no python3"
	PASSED=$((PASSED+1))
else
	echo "  FAIL  render-release.sh needs python3, or its output moved."
	echo "        tests/test-render-release-no-python3.sh said:"
	sed 's/^/           /' "${WORK}/out.txt"
	FAILED=$((FAILED+1))
fi

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
