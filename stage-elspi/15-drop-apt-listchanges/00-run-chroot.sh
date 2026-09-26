#!/bin/bash -e
# Drop apt-listchanges (2026-09-26). See README.md beside this file.
#
# stage2/01-sys-tweaks/00-packages (upstream) installs it, and
# export-image/05-finalise/01-run.sh:13-15 (upstream) then runs
# `python3 -m apt_listchanges.populate_database` in the chroot whenever
# /usr/lib/systemd/system/apt-listchanges.service exists. Under qemu that one
# step was most of an 11-minute finalise. Purging it here, after every elspi
# package stage, makes finalise skip the step without editing either upstream
# file (docs/design/fork.md: every upstream edit is a conflict on every sync).

if dpkg-query -W -f='${Status}' apt-listchanges 2>/dev/null | grep -q "install ok installed"; then
	apt-get purge -y apt-listchanges
else
	echo "apt-listchanges not installed; nothing to drop"
fi

# Gate on the exact file finalise tests, not on dpkg's word.
if [ -e /usr/lib/systemd/system/apt-listchanges.service ]; then
	echo "FATAL: apt-listchanges.service still present after the purge; finalise would still run populate_database"
	exit 1
fi
echo "apt-listchanges: absent (export-image finalise will skip populate_database)"
