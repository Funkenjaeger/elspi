#!/bin/bash -e

# The service user, and the directories the application writes to.
#
# DECIDED 2026-09-01 (docs/design/runtime-inventory.md): the image runs reflex-ui as a
# NON-ROOT service user. Root was inherited from ospi and never justified.
# Measured on the live machine, four of the five reasons for root were
# self-inflicted -- serial access, kivy config location, config-dir ownership,
# and the log directory. This stage removes all four. The fifth (DRM master)
# is 06-seat's problem and is NOT a permission problem at all.
#
# Upstream stage2/01-sys-tweaks/01-run.sh ALREADY adds the first user to
# exactly the live group set and ALREADY runs `usermod --pass='*' root`.
# We therefore ASSERT that rather than doing it again -- a second adduser loop
# would be a check that cannot fail.

SERVICE_USER="${FIRST_USER_NAME}"

# --- Gate: the groups must already be right ---------------------------------
# Measured on the live elspi 2026-09-01. Every device permission the
# application needs is granted by group membership; none of it needs root.
REQUIRED_GROUPS="dialout video render input plugdev netdev spi i2c gpio audio sudo"

for grp in ${REQUIRED_GROUPS}; do
	if ! grep -qE "^${grp}:.*[:,]${SERVICE_USER}(,|\$)" "${ROOTFS_DIR}/etc/group"; then
		echo "FATAL: user '${SERVICE_USER}' is not in group '${grp}'."
		echo "       Upstream stage2 is expected to have done this. If stage2"
		echo "       changed, this stage must add the groups itself."
		exit 1
	fi
done
echo "  groups ok: ${SERVICE_USER} in ${REQUIRED_GROUPS}"

# --- Gate: root must be locked ----------------------------------------------
# stage1 sets root's password to "root"; stage2 then does usermod --pass='*'.
# If that ever stops happening we ship a public image with a known root
# password, so this is a hard gate rather than a note.
if ! grep -qE '^root:[*!]' "${ROOTFS_DIR}/etc/shadow"; then
	echo "FATAL: root's password is not locked in /etc/shadow."
	echo "       stage1 sets root:root and stage2 is expected to clear it."
	exit 1
fi
echo "  root password locked"

on_chroot << EOF
set -e

# --- Lock the service account -----------------------------------------------
# docs/design/seam.md call 2, RATIFIED: no credential enters this repo, and the image ships
# no usable password. The build config had to set FIRST_USER_PASS to a random
# throwaway purely to satisfy build.sh's DISABLE_FIRST_BOOT_USER_RENAME guard
# (build.sh:291 exits 1 without it). That throwaway is revoked here.
#
# REVOKED WITH A BARE '!', NOT WITH passwd -l (2026-09-23). passwd -l only
# PREFIXES '!' to the existing hash, so /etc/shadow shipped
# '!<sha512 of the throwaway>' -- a hash of a random string in a public image,
# and, worse, the root of the cloud-init unlock hole: cloud-init 25.2 treats
# only 'name::' and 'name:!:' as "no password" (distros/__init__.py:139), so a
# hash behind the '!' counted as an existing password, and an Imager seed with
# lock_passwd: false unlocked it into a live password nobody knows
# (distros/__init__.py:912-940). usermod -p '!' REPLACES the field: no hash
# ships at all, cloud-init's pattern matches, and it declines to unlock.
# passwd -u would refuse it too (shadow 4.17.4 src/passwd.c:522-528: "would
# result in a passwordless account"). stage-elspi/12-first-boot-seed/README.md
# has the derivation.
#
# NO BACKTICKS AND NO DOLLAR SIGNS IN THESE COMMENTS: this is the body of an
# UNQUOTED heredoc, so the build host's shell expands both before on_chroot
# ever sees a comment.
#
# Locking the password means sudo needs a password that does not exist yet --
# the one typed into Imager (installed by 12-first-boot-seed), or the one the
# interactive provision phase sets. (Until 2026-09-13 this comment also noted
# that the lock did not block 06-seat's tty1 autologin; that logind-seat rung
# was deleted once first-opener was verified on hardware, and no autologin is
# staged any more.)
usermod -p '!' ${SERVICE_USER}

# --- Directories the application WRITES to ----------------------------------
# /var/lib/reflex-config is live commissioned machine data. reflex WRITES here,
# so read permission is not enough. It is created empty and owned; the RESTORE
# phase of provisioning fills it, and must HARD FAIL if no backup exists rather
# than generating defaults.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /var/lib/reflex-config

# The Kivy log directory. Do NOT reproduce the live state, which scatters
# root-owned kivy_*.txt files across /var/log.
#
# SEQUENCING TRAP, carried from docs/design/runtime-inventory.md and NOT optional: this
# directory must exist and be writable BEFORE anything points KCFG_KIVY_LOG_DIR
# at it. In the image the two are created together by construction. The
# constraint therefore lands on the DELTA layer, which installs start.sh -- see
# /etc/elspi-image.json, which declares this path so the delta can gate on it
# instead of assuming it.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /var/log/reflex

# The application root. The delta layer drops the reflex MONOREPO checkout
# here.
#
# CORRECTED 2026-09-07: this was /opt/reflex, which was invented rather than
# measured. The live machine runs the app from
# /home/default/projects/reflex/ui/deploy/start.sh -- the monorepo layout since
# the 2026-08-17 weld, with the old /reflex-ui standalone checkout deleted on
# 2026-08-25. The app's own unit hardcodes that path, so an image offering
# /opt/reflex would have had the delta fighting the unit for no reason. This
# task's job is the LIKE-FOR-LIKE rebuild.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /home/${SERVICE_USER}/projects

# Kivy's config.ini lands in the service user's ~/.kivy by construction now,
# not /root/.kivy. Pre-creating it keeps ownership right on first run.
install -d -o ${SERVICE_USER} -g ${SERVICE_USER} -m 0755 /home/${SERVICE_USER}/.kivy
EOF

# --- polkit: NetworkManager for the SESSIONLESS service user ----------------
# FOUND ON THE FIRST REAL CARD 2026-09-13. The UI's Network screen runs
# `nmcli radio wifi on` at startup and got "Not authorized to perform this
# operation", which is fatal to that screen.
#
# The non-root decision above is what exposes it. reflex-ui runs as the service
# user under systemd with NO logind session, so polkit classifies the subject
# as neither "active" nor "inactive": every NetworkManager action falls through
# to its "any" default, which for enable-disable-wifi is "no". Debian's shipped
# /usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules covers only
# settings.modify.system and only for a local ACTIVE session, so the netdev
# group asserted above does not help. This is not a group problem, and no
# amount of group membership fixes it.
#
# files/50-reflex-service-user.rules is the file PROVEN on that card, kept
# verbatim. It names the pi-gen default user, and the subject.user line is
# regenerated here from ${FIRST_USER_NAME} so an image built with a different
# first user does not ship a rule that grants nothing.
POLKIT_RULES_DIR="${ROOTFS_DIR}/etc/polkit-1/rules.d"
POLKIT_RULE="${POLKIT_RULES_DIR}/50-reflex-service-user.rules"

# Assert the substitution anchor BEFORE writing. A template whose subject.user
# line changed shape would make the sed a silent no-op, and the image would
# ship a rule scoped to whoever the file happens to name.
if ! grep -q 'subject\.user === "' files/50-reflex-service-user.rules; then
	echo "FATAL: files/50-reflex-service-user.rules has no 'subject.user === \"...\"'"
	echo "       line to substitute. The substitution below would do nothing and"
	echo "       the image would ship a rule naming the wrong user."
	exit 1
fi

install -d -m 0755 "${POLKIT_RULES_DIR}"
sed -E "s/subject\.user === \"[^\"]*\"/subject.user === \"${SERVICE_USER}\"/" \
	files/50-reflex-service-user.rules > "${POLKIT_RULE}"
chmod 0644 "${POLKIT_RULE}"

# --- Post-write checks ------------------------------------------------------
if [ ! -f "${POLKIT_RULE}" ]; then
	echo "FATAL: post-write check failed -- the polkit rule was not written"
	exit 1
fi
if ! grep -q "subject.user === \"${SERVICE_USER}\"" "${POLKIT_RULE}"; then
	echo "FATAL: post-write check failed -- the installed polkit rule does not"
	echo "       name '${SERVICE_USER}'. A rule naming a user that does not exist"
	echo "       is inert, and looks installed. Contents:"
	sed 's/^/         /' "${POLKIT_RULE}"
	exit 1
fi
if [ "$(stat -c %a "${POLKIT_RULE}")" != "644" ]; then
	echo "FATAL: post-write check failed -- polkit rule mode is"
	echo "       $(stat -c %a "${POLKIT_RULE}"), expected 644"
	exit 1
fi
echo "  polkit rule installed: /etc/polkit-1/rules.d/50-reflex-service-user.rules (${SERVICE_USER})"

for d in var/lib/reflex-config var/log/reflex "home/${SERVICE_USER}/projects" "home/${SERVICE_USER}/.kivy"; do
	if [ ! -d "${ROOTFS_DIR}/${d}" ]; then
		echo "FATAL: post-write check failed -- /${d} was not created"
		exit 1
	fi
done
echo "  created: /var/lib/reflex-config /var/log/reflex ~/projects ~/.kivy"

# EXACTLY '!', not merely "starts with '!'": a '!' in front of a hash is the
# `passwd -l` shape this stage no longer ships -- the throwaway's hash in a
# public image, and the one cloud-init unlocks.
if ! grep -qE "^${SERVICE_USER}:!:" "${ROOTFS_DIR}/etc/shadow"; then
	echo "FATAL: post-write check failed -- ${SERVICE_USER}'s password field is not a"
	echo "       bare '!'. Either the account is unlocked (the build-time throwaway"
	echo "       from FIRST_USER_PASS would ship usable) or a hash sits behind the"
	echo "       '!' (the passwd -l shape, which cloud-init unlocks on first boot)."
	exit 1
fi
echo "  ${SERVICE_USER} password field is a bare '!' (build-time throwaway revoked, no hash ships)"
