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
# The unit this image shipped until 2026-09-23. With /home hidden, the seed
# script cannot install a single Imager key -- and the image is keyless.
mutate "the seed unit hides /home again (ProtectHome=yes: no seeded key could be installed)" \
	"sed -i 's|^ProtectHome=no\$|ProtectHome=yes|' etc/systemd/system/elspi-first-boot-seed.service"

# --- KEYLESS, and SSH auth is the operator's Imager choice (2026-09-23) -----
#
# A public key baked into a public release image is the thing this decision
# exists to stop. The key below is not a key anyone holds: it is the right
# SHAPE, which is all the harness may look at.
mutate "a public key baked into the service user's authorized_keys" \
	"mkdir -p home/default/.ssh && printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZpeHR1cmUtbm90LWEtcmVhbC1rZXktZml4dHVyZQ baked\\n' > home/default/.ssh/authorized_keys"
mutate "a public key baked into root's authorized_keys" \
	"mkdir -p root/.ssh && printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZpeHR1cmUtbm90LWEtcmVhbC1rZXktZml4dHVyZQ baked\\n' > root/.ssh/authorized_keys"
# The drop-in first specified for the keyless change, and withdrawn before it
# shipped (2026-09-23). Sorting ahead of cloud-init's 50-cloud-init.conf, it
# would silently beat an operator who chose password SSH on Imager's page.
mutate "a key-only sshd drop-in sorting AHEAD of cloud-init's 50-cloud-init.conf" \
	"printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' > etc/ssh/sshd_config.d/10-elspi-keyonly.conf"
# Sorting after it loses to Imager's choice, but decides whenever Imager made
# none -- still a policy the image imposed.
mutate "an sshd drop-in sorting AFTER cloud-init's that still sets an auth option" \
	"printf 'PasswordAuthentication no\\n' > etc/ssh/sshd_config.d/90-late.conf"
# What PUBKEY_ONLY_SSH=1 makes upstream stage2/01-sys-tweaks do.
mutate "sshd_config's body says PasswordAuthentication no (PUBKEY_ONLY_SSH=1 is back)" \
	"sed -i 's|^#PasswordAuthentication yes\$|PasswordAuthentication no|' etc/ssh/sshd_config"
mutate "sshd_config no longer Includes sshd_config.d" \
	"sed -i '/^Include /d' etc/ssh/sshd_config"
mutate "the manifest declares a build-time key source" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['ssh']['key_source']='build-time';json.dump(d,open(p,'w'))\""
mutate "the manifest declares the image's own key-only SSH policy" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['ssh']['auth']='pubkey-only';json.dump(d,open(p,'w'))\""
mutate "the manifest does not declare ssh at all" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d.pop('ssh',None);json.dump(d,open(p,'w'))\""

# --- THE BAKED APPLICATION (stage-elspi/10a-app-checkout, seam.md amendment
#     2026-09-21) -----------------------------------------------------------
#
# The amendment's item 1 is "bake the app as a REAL GIT CHECKOUT CARRYING TAG
# HISTORY", and every way of getting that subtly wrong produces a directory at
# the app root that looks finished. These mutations are the shapes: no
# checkout, an export with the .git removed, a shallow clone, a depth-1 clone
# with a single tag, a tree sitting somewhere other than the release. On a
# freshly flashed card each of them turns every in-app update into a refusal,
# and none of them is visible in a directory listing.
mutate "no checkout at the app root at all (the image lost its application)" \
	"rm -rf home/default/projects/reflex"
# THE TARBALL. This is the one the amendment argues against by name: "a source
# tarball, or a detached export, cannot be updated in place".
mutate "the checkout is an EXPORT -- the .git directory removed" \
	"rm -rf home/default/projects/reflex/.git"
mutate "the checkout is SHALLOW (git show against an unfetched tag would lie)" \
	"touch home/default/projects/reflex/.git/shallow"
# A --depth 1 --single-branch clone: one tag, which is not tag history.
mutate "the checkout carries only one tag (a depth-1 clone, not tag history)" \
	"git -C home/default/projects/reflex tag -d v0.9.0"
mutate "the declared release tag is not in the checkout" \
	"git -C home/default/projects/reflex tag -d v1.0.0"
# Checked out somewhere that merely CONTAINS the tag is a different tree from
# the release, and looks identical to `ls`.
mutate "HEAD is not the declared commit (checked out one commit back)" \
	"git -C home/default/projects/reflex checkout -q --detach v0.9.0"
mutate "the checkout is not a reflex monorepo tree (no ui/pyproject.toml)" \
	"rm -f home/default/projects/reflex/ui/pyproject.toml"
# THE BUILD HOST'S PATH SHIPPED AS origin. The card in the machine shop then
# fetches from a directory that exists only on whoever built the image.
mutate "origin is the build host's local mirror path, not a fetchable URL" \
	"git -C home/default/projects/reflex remote set-url origin /mnt/git/reflex.git"
# seam call 2: no credential enters this repo, and the image ships none.
mutate "the shipped .git/config carries a credentialled URL" \
	"git -C home/default/projects/reflex remote set-url origin https://user:tokenvalue@github.com/Funkenjaeger/reflex.git"

# THE SELECTION, asserted on the ARTIFACT rather than only at build time. A
# manifest declaring an rc.* is a manifest everything downstream believes.
mutate "the manifest declares a PRE-RELEASE as the baked release" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['baked_app']['release']='v1.2.0-rc.4';json.dump(d,open(p,'w'))\""
mutate "the manifest declares a ui-* half-of-the-pair tag as the baked release" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['baked_app']['release']='ui-v1.0.0';json.dump(d,open(p,'w'))\""
mutate "the manifest declares a branch name as the baked release" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['baked_app']['release']='dev';json.dump(d,open(p,'w'))\""
mutate "the manifest does not declare baked_app at all" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d.pop('baked_app',None);json.dump(d,open(p,'w'))\""
# Two files, one measurement. A disagreement means the manifest is describing
# an image that is not this one.
mutate "/etc/elspi/reflex-app-release disagrees with the manifest" \
	"printf 'v0.9.0\\n' > etc/elspi/reflex-app-release"
mutate "/etc/elspi/reflex-app-release is missing" \
	"rm -f etc/elspi/reflex-app-release"
mutate "the manifest's baked_app.commit is not what is checked out" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['baked_app']['commit']='0'*40;json.dump(d,open(p,'w'))\""

# Ownership, same shape and same reason as the venv's mutation above: making an
# entry owned by SOMEONE ELSE needs chown, i.e. root. Without it this is
# reported as not run rather than counted as a pass it did not earn.
if [ "$(id -u)" -eq 0 ]; then
	mutate "the app checkout is not owned by the service user (git refuses 'dubious ownership'; uv sync cannot write)" \
		"chown 54321 home/default/projects/reflex/ui/pyproject.toml"
else
	echo "  UNKN  app-checkout-ownership mutation needs root (chown); NOT RUN"
fi

# The manifest itself
mutate "the manifest does not declare the first-boot seed" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d.pop('first_boot_seed',None);json.dump(d,open(p,'w'))\""
mutate "the manifest is not valid JSON" \
	"printf 'not json' > etc/elspi-image.json"
mutate "the manifest is missing entirely" \
	"rm -f etc/elspi-image.json"

# The first-boot UI hook (stage-elspi/14-first-boot-ui, task 6aa73b01)
#
# THIS IS A SCAFFOLD, NOT THE FEATURE -- see stage-elspi/14-first-boot-ui/
# README.md. The mutations below prove the TRIGGER is actually enforced:
# that it exists, is enabled, and is ordered correctly. They do not and
# cannot prove anything STARTS, because nothing does yet on any image built
# by this repo.
mutate "the first-boot-ui script missing" \
	"rm -f usr/local/sbin/elspi-first-boot-ui"
mutate "the first-boot-ui script is not executable" \
	"chmod 0644 usr/local/sbin/elspi-first-boot-ui"
mutate "the first-boot-ui unit missing" \
	"rm -f etc/systemd/system/elspi-first-boot-ui.service"
mutate "the first-boot-ui unit is installed but NOT enabled" \
	"rm -f etc/systemd/system/cloud-init.target.wants/elspi-first-boot-ui.service"
# A dangling enablement symlink looks enabled to `ls` and is silently ignored
# by systemd -- the same trap the seed's own mutation above proves.
mutate "the first-boot-ui enablement symlink dangles" \
	"ln -sf ../elspi-first-boot-ui-TYPO.service etc/systemd/system/cloud-init.target.wants/elspi-first-boot-ui.service"
mutate "the first-boot-ui unit loses its WantedBy, so the wants symlink is invented" \
	"sed -i '/^WantedBy=cloud-init.target\$/d' etc/systemd/system/elspi-first-boot-ui.service"
# THE SAME 2026-09-13 ORDERING CYCLE, reconstructed for this unit too: its
# After= chain reaches cloud-final.service via elspi-first-boot-seed.service,
# so enabling it in multi-user.target.wants as well recreates the cycle that
# made systemd delete the seed's job.
mutate "the first-boot-ui unit ALSO enabled in multi-user.target.wants (the 2026-09-13 ordering cycle, again)" \
	"mkdir -p etc/systemd/system/multi-user.target.wants && ln -sf ../elspi-first-boot-ui.service etc/systemd/system/multi-user.target.wants/elspi-first-boot-ui.service"
mutate "the first-boot-ui unit declares WantedBy=multi-user.target too ('systemctl reenable' restores the cycle)" \
	"printf 'WantedBy=multi-user.target\\n' >> etc/systemd/system/elspi-first-boot-ui.service"
# Without the '-' prefix a failing hook fails the boot of a machine with no
# terminal -- same reasoning as the seed unit above.
mutate "the first-boot-ui unit's ExecStart loses its '-' prefix (can fail the boot)" \
	"sed -i 's|^ExecStart=-|ExecStart=|' etc/systemd/system/elspi-first-boot-ui.service"
# LOAD-BEARING ORDERING -- what this order's tests: field specifically asked
# for. Plymouth's DRM renderer is a master until it quits; anything downstream
# that might one day open card0 must not race it.
mutate "the first-boot-ui unit loses its After=plymouth-quit-wait.service ordering" \
	"sed -i '/^After=plymouth-quit-wait.service\$/d' etc/systemd/system/elspi-first-boot-ui.service"
mutate "the first-boot-ui unit loses its After=elspi-first-boot-seed.service ordering" \
	"sed -i '/^After=elspi-first-boot-seed.service\$/d' etc/systemd/system/elspi-first-boot-ui.service"
# NO INTERACTIVE STEP, EVER -- the literal ask in this order's tests: field.
mutate "the first-boot-ui script grows an interactive 'read'" \
	"printf '\\nread -r ANSWER\\n' >> usr/local/sbin/elspi-first-boot-ui"
# The manifest declaration of the hook itself, and the blind spot it adds.
mutate "the manifest does not declare the first-boot-ui hook" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d.pop('first_boot_ui',None);json.dump(d,open(p,'w'))\""
mutate "the manifest drops the first-boot-ui blind spot from cannot_be_verified_without_hardware" \
	"python3 -c \"import json;p='etc/elspi-image.json';d=json.load(open(p));d['cannot_be_verified_without_hardware']=[i for i in d['cannot_be_verified_without_hardware'] if 'first-boot-ui' not in i];json.dump(d,open(p,'w'))\""

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

# --- the release SELECTION (order 2026-09-21#2) ----------------------------
#
# Wired in HERE for the same reason test-render-release-no-python3.sh is: CI's
# tier1.yml names every tests/*.sh runner it invokes one at a time, and
# self-test.sh is already one of those steps, so hanging the new runner off it
# is what makes it RUN rather than sit in tests/ being nobody's job.
#
# Its own script because it needs real synthetic git repositories on disk --
# the selection reads candidates with `git ls-remote`, and a string-table test
# would exercise the regex while skipping the half that talks to git.
echo
echo "== the release selection refuses what it claims to (order 2026-09-21#2) =="
echo "   docs/design/seam.md 2026-09-21: the image ships the latest FULL release,"
echo "   'not a development rc.*, not a floating branch'. Delegated to"
echo "   tests/test-release-selection.sh -- see its header."
if bash "${HERE}/test-release-selection.sh" >"${WORK}/out.txt" 2>&1; then
	echo "  OK    the selection picks full releases and refuses everything else"
	PASSED=$((PASSED+1))
else
	echo "  FAIL  the release selection accepted something it must refuse,"
	echo "        or refused something it must accept."
	echo "        tests/test-release-selection.sh said:"
	sed 's/^/           /' "${WORK}/out.txt"
	FAILED=$((FAILED+1))
fi

# --- the substage itself, run for real (order 2026-09-21#2) ----------------
# Collected here for the same reason as the two runners above. Everything else
# in this file checks the harness against a fixture SOMEBODY WROTE; this one
# runs stage-elspi/10a-app-checkout against a synthetic source and checks what
# it actually produced, which is the gap a fixture-only test leaves open.
echo
echo "== the app-checkout substage, run for real (order 2026-09-21#2) =="
echo "   Against a synthetic reflex-shaped source in a temp dir -- no network"
echo "   and no reflex checkout. Delegated to tests/test-app-checkout-stage.sh."
if bash "${HERE}/test-app-checkout-stage.sh" >"${WORK}/out.txt" 2>&1; then
	echo "  OK    the substage bakes the full release and its guards fire"
	PASSED=$((PASSED+1))
else
	echo "  FAIL  stage-elspi/10a-app-checkout did not do what it claims, or a"
	echo "        guard that must refuse did not."
	echo "        tests/test-app-checkout-stage.sh said:"
	sed 's/^/           /' "${WORK}/out.txt"
	FAILED=$((FAILED+1))
fi

# --- the first-boot seed script itself, run for real (2026-09-23) ----------
# Collected here for the same reason as the runners above. Everything in the
# seed section of verify-image.sh checks that the unit is INSTALLED and WIRED;
# this runs the real script against a synthetic rootfs and Imager-shaped
# user-data, and checks what it did: keys installed once and only once,
# passwords applied, and the loud warning when a seed carries neither.
echo
echo "== the first-boot seed script, run for real (keyless image, 2026-09-23) =="
echo "   Against a synthetic rootfs, with throwaway keys generated per run."
echo "   Delegated to tests/test-first-boot-seed.sh."
if bash "${HERE}/test-first-boot-seed.sh" >"${WORK}/out.txt" 2>&1; then
	echo "  OK    the seed installs Imager keys once, applies passwords, warns on neither"
	PASSED=$((PASSED+1))
else
	echo "  FAIL  the first-boot seed script did not do what it claims."
	echo "        tests/test-first-boot-seed.sh said:"
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
