#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi

# Reaching this line means build.sh (`#!/bin/bash -e`) came through stage0-2
# without an error, so a FULL run marks its stage2 base reusable HERE, and a
# REUSE run leaves the mark alone. See elspi-base-reuse.sh's header.
# shellcheck source=../elspi-base-reuse.sh
. "${BASE_DIR}/elspi-base-reuse.sh"
elspi_base_record

# A REUSED base carries the apt lists stage0 fetched when it was built, up to
# 7 days ago, and the archives drop superseded versions -- so this stage's
# package installs could 404 part way through. Refresh the lists first. A FULL
# run fetched them minutes ago and is left exactly as it was.
if [ "${ELSPI_BASE_MODE:-}" = REUSE ]; then
	on_chroot << EOF
apt-get -o Acquire::Retries=3 update
EOF
fi
