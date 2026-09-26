#!/bin/bash -e

# Keep every getty off the Modbus UART.
#
# 03-boot-config took the serial console off the kernel cmdline. That is half
# the job: systemd also starts serial-getty@ttyAMA0.service from the
# serial-getty generator when it sees the port. Both halves are needed, and the
# second one is invisible until something is already garbling Modbus frames.

on_chroot << 'EOF'
set -e

# Mask rather than disable: masking survives a unit being pulled in later by a
# generator or a dependency, which is exactly how this one arrives.
systemctl mask serial-getty@ttyAMA0.service

# The Pi 5's dedicated debug UART is a different device (ttyAMA10) and is not
# the Modbus line, so it is deliberately left alone.
EOF

# Post-write check: the mask is a symlink to /dev/null. Assert it exists rather
# than trusting that systemctl in a chroot did what it said.
MASK="${ROOTFS_DIR}/etc/systemd/system/serial-getty@ttyAMA0.service"
if [ ! -L "${MASK}" ]; then
	echo "FATAL: serial-getty@ttyAMA0.service mask symlink was not created"
	exit 1
fi
if [ "$(readlink "${MASK}")" != "/dev/null" ]; then
	echo "FATAL: ${MASK} exists but does not point at /dev/null"
	exit 1
fi
echo "  masked: serial-getty@ttyAMA0.service"
