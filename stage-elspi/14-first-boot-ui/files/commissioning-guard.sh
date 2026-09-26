#!/bin/bash
# commissioning-guard.sh <reflex checkout> -- does this checkout carry reflex's
# COMMISSIONING GUARD? Prints exactly `yes` or `no` and exits 0; exits 2 (and
# prints nothing on stdout) when the question cannot be asked at all.
#
# WHY THIS IS THE GATE ON STARTING THE APP UNATTENDED. docs/design/seam.md's
# 2026-09-21 amendment moved the app into the image and ratified, with it, the
# condition for starting it on first boot: with /var/lib/reflex-config empty
# the UI must come up in an EXPLICIT uncommissioned state, named on screen, and
# no dispatcher may write a commissioning event until a restore or a deliberate
# dismissal. "Silent defaults are the one outcome this amendment forbids."
#
# That state is the APPLICATION's to show, not the image's: reflex latches it
# once at startup (ui/reflex/utils/commissioning_state.py, called as the first
# act of MainApp.build() via latch_commissioning_state) and shows the
# UNCOMMISSIONED strip (ui/reflex/components/home/uncommissioned_banner.*).
# It first shipped in reflex v1.2.0-rc.5 and is in v1.2.0. A release WITHOUT it
# -- v1.1.0, or any pin older than rc.5 (the venv's lock was pinned at rc.3
# until 2026-09-26) -- would start on in-code defaults and record them as the
# commissioning baseline on the first save. So the image starts the app at
# first boot only when this says `yes`.
#
# WHAT IS CHECKED, and why these and not a version number: the three places
# the mechanism physically lives. A version comparison would be a second copy
# of "which release added it" that nobody updates; the files are the thing.
#
#   ui/reflex/utils/commissioning_state.py     defines latch()
#   ui/reflex/app.py                           calls it (latch_commissioning_state)
#   ui/reflex/components/home/uncommissioned_banner.kv   the on-screen strip
#
# ONE PREDICATE, TWO CALLERS: stage-elspi/10b-app-install asks at BUILD time
# (and the manifest records the answer), and /usr/local/sbin/elspi-first-boot-ui
# asks again on the card, against the checkout as it actually is. The image
# installs this file as /usr/local/lib/elspi/commissioning-guard.

set -u
APP="${1:-}"
if [ -z "${APP}" ] || [ ! -d "${APP}" ]; then
	echo "commissioning-guard: no checkout at '${APP}'" >&2
	exit 2
fi

STATE="${APP}/ui/reflex/utils/commissioning_state.py"
APPPY="${APP}/ui/reflex/app.py"
STRIP="${APP}/ui/reflex/components/home/uncommissioned_banner.kv"

if [ ! -f "${APPPY}" ]; then
	echo "commissioning-guard: ${APPPY} is missing -- not a reflex monorepo checkout" >&2
	exit 2
fi

if [ -f "${STATE}" ] \
	&& grep -qE '^def latch\(' "${STATE}" \
	&& grep -qF 'commissioning_state.latch()' "${APPPY}" \
	&& grep -qF 'latch_commissioning_state()' "${APPPY}" \
	&& [ -f "${STRIP}" ]; then
	echo yes
else
	echo no
fi
exit 0
