#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi

# Reaching this line means build.sh (`#!/bin/bash -e`) came through every stage
# before this one without an error. With the package layer active (the stage
# after stage2 in STAGE_LIST), stage-elspi-pkgs/prerun.sh has recorded the
# stage2 base, and a BUILD run records the package layer HERE; without it, the
# base is recorded here, as before the layer existed. A REUSE run leaves either
# mark alone. See elspi-base-reuse.sh.
# shellcheck source=../elspi-base-reuse.sh
. "${BASE_DIR}/elspi-base-reuse.sh"
elspi_pkgs_record

# This stage still installs packages (10-splash), with the apt lists of the
# layer it copied, which can be up to 7 days old when that layer was REUSED --
# the package layer, or, with no package layer, the stage2 base -- and the
# archives drop superseded versions, so an install could 404 part way through.
# Refresh them then. A layer built in this run fetched them minutes ago and is
# left exactly as it was.
case "${ELSPI_PKGS_MODE:-OFF}:${ELSPI_BASE_MODE:-}" in
	REUSE:*|OFF:REUSE)
		on_chroot << EOF
apt-get -o Acquire::Retries=3 update
EOF
		;;
esac
