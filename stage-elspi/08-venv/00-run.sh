#!/bin/bash -e

# THE VENV, WITH KIVY ALREADY COMPILED -- but not reflex itself.
#
# docs/design/seam.md call 1, RATIFIED 2026-08-22. This is the load-bearing decision in the
# whole split. No cp313/armv7l Kivy wheel exists on PyPI, so somebody compiles
# Kivy from sdist. If that somebody is the DELTA layer, then recovery depends
# on PyPI still serving that exact sdist on the day the SD card dies -- in a
# machine shop, possibly with no network. Baking it makes recovery
# flash -> restore -> run, hermetically.
#
# The image ships everything in uv.lock EXCEPT the reflex package. The delta
# layer drops the app and runs `uv sync --no-dev`, which finds its dependencies
# already satisfied and finishes in seconds.
#
# THIS IS ALSO THE RISKIEST STEP IN THE BUILD, and docs/design/seam.md says so: compiling
# Kivy inside pi-gen's emulated armhf chroot is slow, on the critical path, and
# native-build failures under qemu-user are not exotic. If the build dies, it
# most likely dies here.
#
# VERSION PAIRING, an accepted consequence of call 1: pyproject.toml and
# uv.lock are VENDORED from the reflex repo at the commit in files/REFLEX_COMMIT.
# Add a dependency to reflex and this image's venv lacks it, so that provision
# needs the network after all. That is the development case, not the recovery
# case -- but it does mean images want tagging against app versions rather than
# floating. tests/test-lockfile-drift.sh is the tripwire.
#
# KNOWN GAP, decided but NOT applied: docs/design/seam.md also ratified "promote Pillow to
# a runtime dependency in pyproject.toml". In the vendored lock, pillow is
# still in the DEV group only, so --no-dev drops it and Kivy loses the img_pil
# provider. That fix belongs in the reflex repo, not here; until it lands, this
# image reproduces the gap rather than papering over it.

VENV=/opt/reflex-venv
SRC="${ROOTFS_DIR}/tmp/reflex-deps"

install -d -m 0755 "${SRC}"
install -m 0644 files/pyproject.toml "${SRC}/pyproject.toml"
install -m 0644 files/uv.lock        "${SRC}/uv.lock"
install -m 0644 files/README.md      "${SRC}/README.md"

REFLEX_COMMIT="$(tr -d '[:space:]' < files/REFLEX_COMMIT)"
[ -n "${REFLEX_COMMIT}" ] || { echo "FATAL: files/REFLEX_COMMIT is empty"; exit 1; }
echo "  building venv from reflex ${REFLEX_COMMIT}"

on_chroot << EOF
set -e
cd /tmp/reflex-deps

export UV_PROJECT_ENVIRONMENT=${VENV}
export UV_CACHE_DIR=/tmp/uv-cache
export UV_LINK_MODE=copy
# Never let uv fetch a managed CPython: the image must use trixie's system
# python3 (3.13.x), which is what the live machine runs and what the Kivy
# build must target.
export UV_PYTHON_DOWNLOADS=never

# KEEP KIVY'S BUILD OUT OF /root.
#
# Kivy's own setup.py does `import kivy` (2.3.1 setup.py:397, plus
# kivy.tools.packaging imports at 401 and 427). kivy/__init__.py then runs, at
# lines 351-369:
#
#     if 'KIVY_HOME' in environ: kivy_home_dir = expanduser(environ['KIVY_HOME'])
#     else:                      kivy_home_dir = join(expanduser('~'), '.kivy')
#     if not exists(kivy_home_dir): mkdir(kivy_home_dir)
#
# So BUILDING Kivy from sdist creates $HOME/.kivy, and in this chroot HOME is
# /root. A pristine image therefore shipped /root/.kivy -- silently, with no
# Kivy banner in the build log, because this happens during the build rather
# than at runtime.
#
# It is only an empty directory, but it is the exact artifact the 2026-09-01
# non-root decision exists to remove, and an image that carries it invites
# the next person to conclude the app still runs as root.
#
# Prevented rather than cleaned up: pointed at a scratch path that is deleted
# below, and gated on afterwards.
export KIVY_HOME=/tmp/kivy-build-home

uv --version

# --frozen            : use uv.lock exactly, never re-resolve
# --no-dev            : main group only (~20 fewer packages than the live venv,
#                       which carries dev because elspi runs uv sync against a
#                       live checkout)
# --no-install-project: everything EXCEPT the reflex package itself
uv sync --frozen --no-dev --no-install-project --python /usr/bin/python3

rm -rf /tmp/uv-cache /tmp/kivy-build-home
EOF

# GATE: /root/.kivy must NOT exist. This is the check that was missing -- the
# defect shipped in a pristine image and was only found because a separate
# integrity guard noticed the harness deleting it afterwards.
if [ -e "${ROOTFS_DIR}/root/.kivy" ]; then
	echo "FATAL: /root/.kivy exists after the venv build."
	echo "       Kivy's setup.py imports kivy, which creates \$HOME/.kivy"
	echo "       unless KIVY_HOME is set. It is set above, so if this fires"
	echo "       something else is importing kivy as root -- find it rather"
	echo "       than deleting the directory here."
	exit 1
fi
echo "  no /root/.kivy (KIVY_HOME kept Kivy's build out of root's home)"

# --- POST-WRITE CHECKS ------------------------------------------------------
# These gate on signals that could have come out differently. A venv directory
# existing proves nothing; the point of this stage is that KIVY IS COMPILED.

# ASSERT INSIDE THE CHROOT, not from the host.
#
# This check used to be `[ -x "${ROOTFS_DIR}${VENV}/bin/python" ]` and it
# FAILED A BUILD IN WHICH EVERYTHING HAD WORKED. uv writes
# ${VENV}/bin/python as an ABSOLUTE symlink to /usr/bin/python3. Inside the
# chroot that is correct. Evaluated from the build container, the absolute
# target resolves against the BUILD CONTAINER's root -- which has no python3
# at all, since the pi-gen Dockerfile never installs one -- so `-x` said no
# about a venv that was perfectly good.
#
# The rule this is an instance of: a path test on a rootfs is meaningless
# unless you say WHICH ROOT it is relative to. Anything following a symlink
# belongs on the inside.
on_chroot << EOF
set -e
test -x ${VENV}/bin/python
${VENV}/bin/python -c "import sys; print('venv python', sys.version.split()[0])"
EOF

KIVY_DIST="$(find "${ROOTFS_DIR}${VENV}" -maxdepth 5 -iname "kivy-*.dist-info" -print -quit)"
if [ -z "${KIVY_DIST}" ]; then
	echo "FATAL: no Kivy dist-info in ${VENV} -- Kivy is not installed"
	exit 1
fi

# The whole reason this stage is expensive: a COMPILED Kivy. If this ever comes
# back as a pure-python or generic wheel tag, something resolved differently
# and the appliance will not render.
KIVY_SO="$(find "${ROOTFS_DIR}${VENV}" -name "*.so" -path "*kivy*" -print -quit)"
if [ -z "${KIVY_SO}" ]; then
	echo "FATAL: Kivy is installed but carries no compiled extensions (.so)."
	echo "       That is not the Kivy this image needs."
	exit 1
fi
echo "  kivy ok: $(basename "${KIVY_DIST}"), compiled extensions present"

# Record what was actually built, for the manifest and the harness.
install -d -m 0755 "${ROOTFS_DIR}/etc/elspi"
printf '%s\n' "${REFLEX_COMMIT}" > "${ROOTFS_DIR}/etc/elspi/reflex-lock-commit"

rm -rf "${SRC}"
echo "  venv built at ${VENV} (reflex package deliberately absent)"
