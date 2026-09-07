#!/bin/bash -e

# ALSA default card -- and a deliberate refusal to reproduce the live machine.
#
# elspi's audio is BROKEN right now:
#   [CRITICAL] AudioSDL2: Unable to open mixer: ALSA: Couldn't open audio
#              device: Unknown error 524
#
# SEAM.md's CORRECTION of 2026-08-22 is what this file encodes, and it matters
# because the first diagnosis was wrong twice over. elspi's /etc/asound.conf is
# BYTE-IDENTICAL to ospi's reference, and the shape was never the bug. THE BUG
# IS THE CARD INDEX. `aplay -l` shows two HDMI outputs (vc4hdmi0/vc4hdmi1); the
# kernel reports card1-HDMI-A-1 connected and card1-HDMI-A-2 disconnected;
# hw:1,0 returns exactly reflex-ui's "Unknown error 524" while plughw:0,0
# plays. The live file selected card 1 -- the empty port.
#
# So: bake card 0.
#
# The task's own checklist carries the matching instruction from the other
# direction: EXCLUDE /etc/asound.conf from the elspi backup, deliberately,
# because backing the live file up would enshrine this defect as the recovery
# target. Two routes to the same trap; this is the image-side half.

install -m 0644 files/asound.conf "${ROOTFS_DIR}/etc/asound.conf"

# POST-WRITE CHECK: assert the CARD INDEX, which is the thing that was wrong --
# not merely that a file exists.
grep -qx "defaults.pcm.card 0" "${ROOTFS_DIR}/etc/asound.conf" || {
	echo "FATAL: /etc/asound.conf does not select pcm card 0"
	exit 1
}
grep -qx "defaults.ctl.card 0" "${ROOTFS_DIR}/etc/asound.conf" || {
	echo "FATAL: /etc/asound.conf does not select ctl card 0"
	exit 1
}
if grep -qE "card 1( |$)" "${ROOTFS_DIR}/etc/asound.conf"; then
	echo "FATAL: /etc/asound.conf still references card 1 -- that is the live bug"
	exit 1
fi
echo "  asound.conf: card 0 (not the live machine's card 1)"
